// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "./ILksIdentityV2.sol";

/**
 * @title LksSocialUpgradeable
 * @notice Contrat de fonctionnalités sociales pour LinkUs Protocol (UUPS Upgradeable)
 * @dev Gère : Follow/Unfollow, Posts (hashes Gun.js), Tips (avec fees plateforme), Reputation
 */
contract LksSocialUpgradeable is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using EnumerableSet for EnumerableSet.AddressSet;

    // ========== TYPES ==========

    struct Post {
        uint256 postId;
        address author;
        bytes32 gunHash;
        bytes32 ipfsMediaHash;
        uint256 timestamp;
        uint256 likes;
        bool exists;
        bool isMonetized;
        bytes32 contentId;
    }

    struct UserStats {
        uint256 followers;
        uint256 following;
        uint256 posts;
        uint256 tipsReceived;
        uint256 reputation;
        uint256 lastPostTime;
    }

    // ========== STORAGE ==========

    ILksIdentityV2 public identityContract;
    uint256 private _nextPostId;
    mapping(uint256 => Post) public posts;
    mapping(address => uint256[]) private userPosts;
    mapping(address => EnumerableSet.AddressSet) private followers;
    mapping(address => EnumerableSet.AddressSet) private following;
    mapping(address => mapping(address => bool)) public isFollowing;
    mapping(address => UserStats) public userStats;
    mapping(bytes32 => bool) private usedGunHashes;
    mapping(address => mapping(uint256 => uint256)) private dailyTipsCount;

    uint256 public totalPosts;
    uint256 public totalTips;
    uint256 public totalTipAmount;
    uint256 public totalFollows;
    address public platformFeeRecipient;
    uint256 public platformFeeRate;
    uint256 public minPostInterval;
    uint256 public reputationPerTip;
    uint256 public reputationPerFollow;
    uint256 public reputationPerPost;

    uint256 public constant FREE_DAILY_TIP_LIMIT = 5;
    uint256 public constant MIN_TIP_AMOUNT = 0.0001 ether;

    // ========== EVENTS ==========

    event PostCreated(uint256 indexed postId, address indexed author, bytes32 gunHash, bytes32 ipfsMediaHash, uint256 timestamp);
    event PostTipped(uint256 indexed postId, address indexed tipper, address indexed author, uint256 amount, uint256 platformFee, string message);
    event UserFollowed(address indexed follower, address indexed followed, uint256 timestamp);
    event UserUnfollowed(address indexed follower, address indexed unfollowed, uint256 timestamp);
    event ReputationUpdated(address indexed user, uint256 oldReputation, uint256 newReputation, string reason);
    event BatchProcessed(address indexed user, uint256 interactionsCount);

    // ========== ERRORS ==========

    error IdentityRequired();
    error InvalidIdentityNFT();
    error PostNotFound(uint256 postId);
    error AlreadyFollowing(address user);
    error NotFollowing(address user);
    error CannotFollowSelf();
    error CannotTipSelf();
    error PostTooSoon(uint256 timeRemaining);
    error GunHashAlreadyUsed(bytes32 gunHash);
    error InvalidAddress();
    error InvalidPostId();
    error NoETHSent();
    error ETHTransferFailed();
    error TipAmountTooLow(uint256 sent, uint256 minimum);
    error FreeTierDailyLimitReached(uint256 current, uint256 limit);

    // ========== CONSTRUCTOR & INITIALIZER ==========

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _identityContract) public initializer {
        if (_identityContract == address(0)) revert InvalidAddress();

        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        identityContract = ILksIdentityV2(_identityContract);
        platformFeeRecipient = msg.sender;
        platformFeeRate = 10;
        minPostInterval = 10 seconds;
        reputationPerTip = 10;
        reputationPerFollow = 5;
        reputationPerPost = 2;
        _nextPostId = 1;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // ========== MODIFIERS ==========

    modifier requiresIdentity() {
        uint256 tokenId = _getIdentityTokenId(msg.sender);
        if (tokenId == 0) revert IdentityRequired();
        _;
    }

    modifier validAddress(address addr) {
        if (addr == address(0)) revert InvalidAddress();
        _;
    }

    // ========== POST FUNCTIONS ==========

    function createPost(
        bytes32 gunHash,
        bytes32 ipfsMediaHash
    ) external whenNotPaused requiresIdentity nonReentrant returns (uint256) {
        UserStats storage stats = userStats[msg.sender];
        if (block.timestamp < stats.lastPostTime + minPostInterval) {
            uint256 timeRemaining = (stats.lastPostTime + minPostInterval) - block.timestamp;
            revert PostTooSoon(timeRemaining);
        }

        if (usedGunHashes[gunHash]) {
            revert GunHashAlreadyUsed(gunHash);
        }

        uint256 postId = _nextPostId++;
        posts[postId] = Post({
            postId: postId,
            author: msg.sender,
            gunHash: gunHash,
            ipfsMediaHash: ipfsMediaHash,
            timestamp: block.timestamp,
            likes: 0,
            exists: true,
            isMonetized: false,
            contentId: bytes32(0)
        });

        userPosts[msg.sender].push(postId);
        usedGunHashes[gunHash] = true;

        stats.posts++;
        stats.lastPostTime = block.timestamp;
        stats.reputation += reputationPerPost;

        totalPosts++;

        emit PostCreated(postId, msg.sender, gunHash, ipfsMediaHash, block.timestamp);
        emit ReputationUpdated(msg.sender, stats.reputation - reputationPerPost, stats.reputation, "post_created");

        return postId;
    }

    function tipPost(uint256 postId, string calldata message) external payable whenNotPaused requiresIdentity nonReentrant {
        Post storage post = posts[postId];
        if (!post.exists) revert PostNotFound(postId);
        if (msg.value == 0) revert NoETHSent();
        if (msg.value < MIN_TIP_AMOUNT) revert TipAmountTooLow(msg.value, MIN_TIP_AMOUNT);
        if (post.author == msg.sender) revert CannotTipSelf();

        uint256 tokenId = _getIdentityTokenId(msg.sender);
        bool isPremium = tokenId > 0;

        if (!isPremium) {
            uint256 today = block.timestamp / 1 days;
            uint256 todayTips = dailyTipsCount[msg.sender][today];

            if (todayTips >= FREE_DAILY_TIP_LIMIT) {
                revert FreeTierDailyLimitReached(todayTips, FREE_DAILY_TIP_LIMIT);
            }

            dailyTipsCount[msg.sender][today] = todayTips + 1;
        }

        uint256 platformFee = (msg.value * platformFeeRate) / 10000;
        uint256 authorAmount = msg.value - platformFee;

        (bool authorSuccess, ) = payable(post.author).call{value: authorAmount}("");
        if (!authorSuccess) revert ETHTransferFailed();

        if (platformFee > 0 && platformFeeRecipient != address(0)) {
            (bool feeSuccess, ) = payable(platformFeeRecipient).call{value: platformFee}("");
            if (!feeSuccess) revert ETHTransferFailed();
        }

        UserStats storage authorStats = userStats[post.author];
        authorStats.tipsReceived++;
        authorStats.reputation += reputationPerTip;

        totalTips++;
        totalTipAmount += msg.value;

        emit PostTipped(postId, msg.sender, post.author, authorAmount, platformFee, message);
        emit ReputationUpdated(post.author, authorStats.reputation - reputationPerTip, authorStats.reputation, "post_tipped");
    }

    // ========== FOLLOW FUNCTIONS ==========

    function follow(address user) external whenNotPaused requiresIdentity validAddress(user) {
        if (user == msg.sender) revert CannotFollowSelf();
        if (isFollowing[msg.sender][user]) revert AlreadyFollowing(user);

        isFollowing[msg.sender][user] = true;
        followers[user].add(msg.sender);
        following[msg.sender].add(user);

        userStats[user].followers++;
        userStats[msg.sender].following++;
        userStats[user].reputation += reputationPerFollow;

        totalFollows++;

        emit UserFollowed(msg.sender, user, block.timestamp);
        emit ReputationUpdated(user, userStats[user].reputation - reputationPerFollow, userStats[user].reputation, "new_follower");
    }

    function unfollow(address user) external whenNotPaused requiresIdentity validAddress(user) {
        if (!isFollowing[msg.sender][user]) revert NotFollowing(user);

        isFollowing[msg.sender][user] = false;
        followers[user].remove(msg.sender);
        following[msg.sender].remove(user);

        if (userStats[user].followers > 0) userStats[user].followers--;
        if (userStats[msg.sender].following > 0) userStats[msg.sender].following--;
        if (userStats[user].reputation >= reputationPerFollow) {
            userStats[user].reputation -= reputationPerFollow;
        }

        if (totalFollows > 0) totalFollows--;

        emit UserUnfollowed(msg.sender, user, block.timestamp);
    }

    // ========== VIEW FUNCTIONS ==========

    function getUserPosts(address user, uint256 offset, uint256 limit) external view returns (Post[] memory) {
        uint256[] storage postIds = userPosts[user];
        uint256 total = postIds.length;

        if (offset >= total) return new Post[](0);

        uint256 end = offset + limit > total ? total : offset + limit;
        uint256 size = end - offset;

        Post[] memory result = new Post[](size);
        for (uint256 i = 0; i < size; i++) {
            result[i] = posts[postIds[total - 1 - (offset + i)]];
        }

        return result;
    }

    function getFollowers(address user, uint256 offset, uint256 limit) external view returns (address[] memory) {
        return _getPaginatedAddresses(followers[user], offset, limit);
    }

    function getFollowing(address user, uint256 offset, uint256 limit) external view returns (address[] memory) {
        return _getPaginatedAddresses(following[user], offset, limit);
    }

    function getPost(uint256 postId) external view returns (Post memory) {
        if (!posts[postId].exists) revert PostNotFound(postId);
        return posts[postId];
    }

    function getUserStats(address user) external view returns (UserStats memory) {
        return userStats[user];
    }

    function getUserPostsCount(address user) external view returns (uint256) {
        return userPosts[user].length;
    }

    function getFollowersCount(address user) external view returns (uint256) {
        return followers[user].length();
    }

    function getFollowingCount(address user) external view returns (uint256) {
        return following[user].length();
    }

    function getGlobalStats() external view returns (uint256, uint256, uint256, uint256) {
        return (totalPosts, totalTips, totalFollows, totalTipAmount);
    }

    function hasIdentityNFT(address user) external view returns (bool) {
        return _getIdentityTokenId(user) > 0;
    }

    function getIdentityTokenId(address user) external view returns (uint256) {
        return _getIdentityTokenId(user);
    }

    function getUserTier(address user) external view returns (string memory tier) {
        return _getIdentityTokenId(user) > 0 ? "PREMIUM" : "FREE";
    }

    function getRemainingTipsToday(address user) external view returns (uint256 remaining) {
        uint256 tokenId = _getIdentityTokenId(user);
        if (tokenId > 0) return type(uint256).max;

        uint256 today = block.timestamp / 1 days;
        uint256 used = dailyTipsCount[user][today];

        if (used >= FREE_DAILY_TIP_LIMIT) return 0;
        return FREE_DAILY_TIP_LIMIT - used;
    }

    // ========== ADMIN FUNCTIONS ==========

    function setMinPostInterval(uint256 interval) external onlyOwner {
        minPostInterval = interval;
    }

    function setReputationRates(uint256 perTip, uint256 perFollow, uint256 perPost) external onlyOwner {
        reputationPerTip = perTip;
        reputationPerFollow = perFollow;
        reputationPerPost = perPost;
    }

    function setPlatformFeeRecipient(address recipient) external onlyOwner {
        if (recipient == address(0)) revert InvalidAddress();
        platformFeeRecipient = recipient;
    }

    function setPlatformFeeRate(uint256 rate) external onlyOwner {
        require(rate <= 1000, "LksSocial: Fee too high (max 10%)");
        platformFeeRate = rate;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function linkPostToContent(uint256 postId, bytes32 contentId) external onlyOwner {
        Post storage post = posts[postId];
        if (!post.exists) revert PostNotFound(postId);
        post.isMonetized = true;
        post.contentId = contentId;
    }

    // ========== INTERNAL HELPERS ==========

    function _getIdentityTokenId(address user) internal view returns (uint256) {
        try identityContract.getTokenIdByOwner(user) returns (uint256 tokenId) {
            return tokenId;
        } catch {
            return 0;
        }
    }

    function _getPaginatedAddresses(
        EnumerableSet.AddressSet storage addressSet,
        uint256 offset,
        uint256 limit
    ) internal view returns (address[] memory) {
        uint256 total = addressSet.length();
        if (offset >= total) return new address[](0);

        uint256 end = offset + limit > total ? total : offset + limit;
        uint256 size = end - offset;

        address[] memory result = new address[](size);
        for (uint256 i = 0; i < size; i++) {
            result[i] = addressSet.at(offset + i);
        }

        return result;
    }

    // ========== STORAGE GAP ==========

    uint256[50] private __gap;
}
