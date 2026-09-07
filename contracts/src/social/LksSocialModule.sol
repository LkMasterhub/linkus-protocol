// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import "../core/ILksCore.sol";
import "./ILksIdentityV2.sol";

/**
 * @title  LksSocialModule
 * @author LinkUs Protocol V7 refonte (2026-04-06)
 * @notice Module Social : Posts (hashes OrbitDB), Tips (pull pattern), Follows, Batch follow.
 *         Délègue la réputation et le tier check à LksCoreUpgradeable.
 *
 * @dev    Findings V6 résolus :
 *           - LKS-SOC-01/02 : Tips via `tipsOwed` + `withdrawTips` (pull pattern), plus de push
 *             direct avec `.call{value}` qui était DoSable
 *           - LKS-SOC-04 : `isPremium` lit `LksCore.getTier >= PREMIUM` au lieu de `tokenId > 0`,
 *             qui traitait comme premium tout porteur d'Identity NFT (même UNVERIFIED)
 *           - V6 manquait `batchFollow` — ajouté
 *
 *         Réputation :
 *           - Local storage `UserStats.reputation` supprimé (délégué à Core)
 *           - Ce contrat doit avoir le rôle `SOCIAL_WRITER` sur LksCore
 *           - Toute écriture se fait via `coreContract.addReputation(user, amount)`
 *
 * @custom:security-contact security@linkus-protocol.io
 */
contract LksSocialModule is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using EnumerableSet for EnumerableSet.AddressSet;

    // ============================================================================
    // ROLES
    // ============================================================================

    bytes32 public constant ADMIN_ROLE    = keccak256("ADMIN_ROLE");
    bytes32 public constant PAUSER_ROLE   = keccak256("PAUSER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // ============================================================================
    // STRUCTS
    // ============================================================================

    struct Post {
        uint256 postId;
        address author;
        bytes32 contentHash; // OrbitDB / IPFS hash
        bytes32 ipfsMediaHash;
        uint256 timestamp;
        uint256 likes;
        bool exists;
    }

    struct UserStats {
        uint256 followers;
        uint256 following;
        uint256 posts;
        uint256 tipsReceived;      // count
        uint256 tipsReceivedAmount;// cumulative amount
        uint256 lastPostTime;
    }

    // ============================================================================
    // STORAGE — DEPENDENCIES
    // ============================================================================

    ILksCore public coreContract;
    ILksIdentityV2 public identityContract;

    // ============================================================================
    // STORAGE — POSTS
    // ============================================================================

    uint256 private _nextPostId;
    mapping(uint256 => Post) public posts;
    mapping(address => uint256[]) private _userPosts;
    mapping(bytes32 => bool) public usedContentHashes;

    // ============================================================================
    // STORAGE — FOLLOWS
    // ============================================================================

    mapping(address => EnumerableSet.AddressSet) private _followers;
    mapping(address => EnumerableSet.AddressSet) private _following;
    mapping(address => mapping(address => bool)) public isFollowing;

    // ============================================================================
    // STORAGE — LIKES
    // ============================================================================

    mapping(uint256 => mapping(address => bool)) public hasLiked;

    // ============================================================================
    // STORAGE — USER STATS (sans reputation)
    // ============================================================================

    mapping(address => UserStats) public userStats;

    // ============================================================================
    // STORAGE — TIPS (PULL PATTERN)
    // ============================================================================

    /// @notice Montants dus aux auteurs (pull pattern, fix LKS-SOC-01/02)
    mapping(address => uint256) public tipsOwed;

    /// @notice Comptage des tips quotidiens par user (pour limiter free tier)
    mapping(address => mapping(uint256 => uint256)) private _dailyTipsCount;

    // ============================================================================
    // STORAGE — GLOBAL STATS & CONFIG
    // ============================================================================

    uint256 public totalPosts;
    uint256 public totalTips;
    uint256 public totalTipAmount;
    uint256 public totalFollows;

    address public platformFeeRecipient;
    uint256 public platformFeeRate; // bps
    uint256 public accumulatedPlatformFees;

    uint256 public minPostInterval;
    uint256 public reputationPerTip;
    uint256 public reputationPerFollow;
    uint256 public reputationPerPost;
    uint256 public reputationPerLike;

    uint256 public constant FREE_DAILY_TIP_LIMIT = 5;
    uint256 public constant MIN_TIP_AMOUNT = 0.0001 ether;
    uint256 public constant MAX_PLATFORM_FEE_BPS = 1000; // 10 % max
    uint256 public constant MAX_BATCH_FOLLOW = 50;

    /// @dev gap
    uint256[40] private __gap;

    // ============================================================================
    // EVENTS
    // ============================================================================

    event PostCreated(uint256 indexed postId, address indexed author, bytes32 contentHash, bytes32 ipfsMediaHash, uint256 timestamp);
    event PostLiked(uint256 indexed postId, address indexed liker);
    event PostUnliked(uint256 indexed postId, address indexed unliker);
    event PostTipped(uint256 indexed postId, address indexed tipper, address indexed author, uint256 authorAmount, uint256 platformFee);
    event TipsWithdrawn(address indexed user, uint256 amount);
    event PlatformFeesWithdrawn(address indexed recipient, uint256 amount);

    event UserFollowed(address indexed follower, address indexed followed);
    event UserUnfollowed(address indexed follower, address indexed unfollowed);
    event BatchFollowCompleted(address indexed follower, uint256 successCount, uint256 skippedCount);

    event CoreContractUpdated(address indexed oldCore, address indexed newCore);
    event PlatformFeeRateUpdated(uint256 oldRate, uint256 newRate);
    event ReputationRatesUpdated(uint256 perTip, uint256 perFollow, uint256 perPost, uint256 perLike);

    // ============================================================================
    // ERRORS
    // ============================================================================

    error ZeroAddress();
    error IdentityRequired();
    error PostNotFound(uint256 postId);
    error PostTooSoon(uint256 timeRemaining);
    error ContentHashAlreadyUsed(bytes32 contentHash);
    error CannotFollowSelf();
    error CannotTipSelf();
    error AlreadyFollowing(address user);
    error NotFollowing(address user);
    error AlreadyLiked(uint256 postId);
    error NotLiked(uint256 postId);
    error TipAmountTooLow(uint256 sent, uint256 minimum);
    error FreeTierDailyLimitReached(uint256 current, uint256 limit);
    error NothingToWithdraw();
    error TransferFailed();
    error FeeRateTooHigh(uint256 requested, uint256 max);
    error BatchTooLarge(uint256 length, uint256 max);

    // ============================================================================
    // CONSTRUCTOR
    // ============================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============================================================================
    // INITIALIZER
    // ============================================================================

    function initialize(
        address core_,
        address identity_,
        address admin
    ) external initializer {
        if (core_ == address(0) || identity_ == address(0) || admin == address(0)) {
            revert ZeroAddress();
        }

        __UUPSUpgradeable_init();
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);

        coreContract = ILksCore(core_);
        identityContract = ILksIdentityV2(identity_);
        platformFeeRecipient = admin;

        platformFeeRate = 100; // 1 %
        minPostInterval = 10 seconds;
        reputationPerTip = 10;
        reputationPerFollow = 5;
        reputationPerPost = 2;
        reputationPerLike = 1;

        _nextPostId = 1;

        emit CoreContractUpdated(address(0), core_);
    }

    // ============================================================================
    // MODIFIERS
    // ============================================================================

    modifier requiresIdentity() {
        if (_getIdentityTokenId(msg.sender) == 0) revert IdentityRequired();
        _;
    }

    // ============================================================================
    // POSTS
    // ============================================================================

    /**
     * @notice Crée un post (hash stocké on-chain, contenu off-chain sur OrbitDB/IPFS)
     * @param contentHash    Hash du post (OrbitDB entry hash ou CID IPFS)
     * @param ipfsMediaHash  Hash du média associé (0 si pas de média)
     */
    function createPost(
        bytes32 contentHash,
        bytes32 ipfsMediaHash
    ) external whenNotPaused requiresIdentity nonReentrant returns (uint256) {
        UserStats storage stats = userStats[msg.sender];
        if (stats.lastPostTime > 0 && block.timestamp < stats.lastPostTime + minPostInterval) {
            revert PostTooSoon((stats.lastPostTime + minPostInterval) - block.timestamp);
        }
        if (usedContentHashes[contentHash]) revert ContentHashAlreadyUsed(contentHash);

        uint256 postId = _nextPostId++;
        posts[postId] = Post({
            postId: postId,
            author: msg.sender,
            contentHash: contentHash,
            ipfsMediaHash: ipfsMediaHash,
            timestamp: block.timestamp,
            likes: 0,
            exists: true
        });

        _userPosts[msg.sender].push(postId);
        usedContentHashes[contentHash] = true;

        stats.posts++;
        stats.lastPostTime = block.timestamp;

        totalPosts++;

        // Reputation écrite dans Core (cross-contract)
        _addReputation(msg.sender, reputationPerPost);

        emit PostCreated(postId, msg.sender, contentHash, ipfsMediaHash, block.timestamp);
        return postId;
    }

    function likePost(uint256 postId) external whenNotPaused requiresIdentity {
        Post storage post = posts[postId];
        if (!post.exists) revert PostNotFound(postId);
        if (hasLiked[postId][msg.sender]) revert AlreadyLiked(postId);

        hasLiked[postId][msg.sender] = true;
        post.likes++;

        _addReputation(post.author, reputationPerLike);

        emit PostLiked(postId, msg.sender);
    }

    function unlikePost(uint256 postId) external whenNotPaused {
        Post storage post = posts[postId];
        if (!post.exists) revert PostNotFound(postId);
        if (!hasLiked[postId][msg.sender]) revert NotLiked(postId);

        hasLiked[postId][msg.sender] = false;
        if (post.likes > 0) post.likes--;

        emit PostUnliked(postId, msg.sender);
    }

    // ============================================================================
    // TIPS (PULL PATTERN — LKS-SOC-01/02 FIX)
    // ============================================================================

    /**
     * @notice Tip un post. Les fonds vont dans `tipsOwed[author]` et `accumulatedPlatformFees`,
     *         pas directement à l'auteur / au recipient (pull pattern pour éviter DoS).
     */
    function tipPost(uint256 postId) external payable whenNotPaused requiresIdentity nonReentrant {
        Post storage post = posts[postId];
        if (!post.exists) revert PostNotFound(postId);
        if (msg.value == 0) revert TipAmountTooLow(0, MIN_TIP_AMOUNT);
        if (msg.value < MIN_TIP_AMOUNT) revert TipAmountTooLow(msg.value, MIN_TIP_AMOUNT);
        if (post.author == msg.sender) revert CannotTipSelf();

        // LKS-SOC-04 fix : isPremium lit le tier via Core
        if (!_isPremium(msg.sender)) {
            uint256 today = block.timestamp / 1 days;
            uint256 todayTips = _dailyTipsCount[msg.sender][today];
            if (todayTips >= FREE_DAILY_TIP_LIMIT) {
                revert FreeTierDailyLimitReached(todayTips, FREE_DAILY_TIP_LIMIT);
            }
            _dailyTipsCount[msg.sender][today] = todayTips + 1;
        }

        uint256 platformFee = (msg.value * platformFeeRate) / 10_000;
        uint256 authorAmount = msg.value - platformFee;

        // PULL PATTERN : stocker, ne pas envoyer
        tipsOwed[post.author] += authorAmount;
        if (platformFee > 0) {
            accumulatedPlatformFees += platformFee;
        }

        UserStats storage authorStats = userStats[post.author];
        authorStats.tipsReceived++;
        authorStats.tipsReceivedAmount += authorAmount;

        totalTips++;
        totalTipAmount += msg.value;

        _addReputation(post.author, reputationPerTip);

        emit PostTipped(postId, msg.sender, post.author, authorAmount, platformFee);
    }

    /**
     * @notice L'auteur retire ses tips accumulés.
     * @dev    Partie 2 du pull pattern : les auteurs appellent cette fonction pour récupérer.
     */
    function withdrawTips() external nonReentrant {
        uint256 amount = tipsOwed[msg.sender];
        if (amount == 0) revert NothingToWithdraw();

        tipsOwed[msg.sender] = 0;

        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        if (!ok) revert TransferFailed();

        emit TipsWithdrawn(msg.sender, amount);
    }

    /**
     * @notice Le feeRecipient retire les platform fees accumulés.
     */
    function withdrawPlatformFees() external nonReentrant {
        if (msg.sender != platformFeeRecipient) revert TransferFailed();
        uint256 amount = accumulatedPlatformFees;
        if (amount == 0) revert NothingToWithdraw();

        accumulatedPlatformFees = 0;

        (bool ok, ) = payable(platformFeeRecipient).call{value: amount}("");
        if (!ok) revert TransferFailed();

        emit PlatformFeesWithdrawn(platformFeeRecipient, amount);
    }

    // ============================================================================
    // FOLLOWS
    // ============================================================================

    function follow(address user) external whenNotPaused requiresIdentity {
        _follow(user);
    }

    function unfollow(address user) external whenNotPaused requiresIdentity {
        if (user == address(0)) revert ZeroAddress();
        if (!isFollowing[msg.sender][user]) revert NotFollowing(user);

        isFollowing[msg.sender][user] = false;
        _followers[user].remove(msg.sender);
        _following[msg.sender].remove(user);

        UserStats storage ts = userStats[user];
        UserStats storage fs = userStats[msg.sender];
        if (ts.followers > 0) ts.followers--;
        if (fs.following > 0) fs.following--;

        if (totalFollows > 0) totalFollows--;

        emit UserUnfollowed(msg.sender, user);
    }

    /**
     * @notice Follow plusieurs utilisateurs en une seule transaction.
     * @dev    Ne revert pas sur les duplicates ou les self-follows — les skip et continue.
     *         Limité à MAX_BATCH_FOLLOW pour éviter les limites de gas.
     */
    function batchFollow(address[] calldata users)
        external
        whenNotPaused
        requiresIdentity
        returns (uint256 successCount, uint256 skippedCount)
    {
        uint256 len = users.length;
        if (len == 0) return (0, 0);
        if (len > MAX_BATCH_FOLLOW) revert BatchTooLarge(len, MAX_BATCH_FOLLOW);

        for (uint256 i = 0; i < len; ) {
            address u = users[i];
            if (u == address(0) || u == msg.sender || isFollowing[msg.sender][u]) {
                unchecked { ++skippedCount; ++i; }
                continue;
            }

            isFollowing[msg.sender][u] = true;
            _followers[u].add(msg.sender);
            _following[msg.sender].add(u);
            userStats[u].followers++;
            userStats[msg.sender].following++;
            totalFollows++;

            _addReputation(u, reputationPerFollow);

            emit UserFollowed(msg.sender, u);

            unchecked { ++successCount; ++i; }
        }

        emit BatchFollowCompleted(msg.sender, successCount, skippedCount);
    }

    function _follow(address user) internal {
        if (user == address(0)) revert ZeroAddress();
        if (user == msg.sender) revert CannotFollowSelf();
        if (isFollowing[msg.sender][user]) revert AlreadyFollowing(user);

        isFollowing[msg.sender][user] = true;
        _followers[user].add(msg.sender);
        _following[msg.sender].add(user);

        userStats[user].followers++;
        userStats[msg.sender].following++;

        totalFollows++;

        _addReputation(user, reputationPerFollow);

        emit UserFollowed(msg.sender, user);
    }

    // ============================================================================
    // VIEW FUNCTIONS
    // ============================================================================

    function getPost(uint256 postId) external view returns (Post memory) {
        if (!posts[postId].exists) revert PostNotFound(postId);
        return posts[postId];
    }

    function getUserPosts(address user, uint256 offset, uint256 limit) external view returns (Post[] memory) {
        uint256[] storage postIds = _userPosts[user];
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

    function getUserPostsCount(address user) external view returns (uint256) {
        return _userPosts[user].length;
    }

    function getFollowers(address user, uint256 offset, uint256 limit) external view returns (address[] memory) {
        return _paginate(_followers[user], offset, limit);
    }

    function getFollowing(address user, uint256 offset, uint256 limit) external view returns (address[] memory) {
        return _paginate(_following[user], offset, limit);
    }

    function getFollowersCount(address user) external view returns (uint256) {
        return _followers[user].length();
    }

    function getFollowingCount(address user) external view returns (uint256) {
        return _following[user].length();
    }

    function getUserStats(address user) external view returns (UserStats memory) {
        return userStats[user];
    }

    function getGlobalStats() external view returns (uint256, uint256, uint256, uint256) {
        return (totalPosts, totalTips, totalFollows, totalTipAmount);
    }

    /**
     * @notice Retourne `true` si l'utilisateur est premium (tier >= PREMIUM dans Core).
     * @dev    LKS-SOC-04 fix : en V6, renvoyait simplement `tokenId > 0` qui traitait
     *         tous les porteurs d'Identity NFT comme premium, même ceux UNVERIFIED.
     */
    function isPremium(address user) external view returns (bool) {
        return _isPremium(user);
    }

    function getRemainingTipsToday(address user) external view returns (uint256) {
        if (_isPremium(user)) return type(uint256).max;
        uint256 today = block.timestamp / 1 days;
        uint256 used = _dailyTipsCount[user][today];
        if (used >= FREE_DAILY_TIP_LIMIT) return 0;
        return FREE_DAILY_TIP_LIMIT - used;
    }

    function hasIdentityNFT(address user) external view returns (bool) {
        return _getIdentityTokenId(user) > 0;
    }

    // ============================================================================
    // ADMIN
    // ============================================================================

    function setCoreContract(address newCore) external onlyRole(ADMIN_ROLE) {
        if (newCore == address(0)) revert ZeroAddress();
        address old = address(coreContract);
        coreContract = ILksCore(newCore);
        emit CoreContractUpdated(old, newCore);
    }

    function setPlatformFeeRecipient(address recipient) external onlyRole(ADMIN_ROLE) {
        if (recipient == address(0)) revert ZeroAddress();
        platformFeeRecipient = recipient;
    }

    function setPlatformFeeRate(uint256 rate) external onlyRole(ADMIN_ROLE) {
        if (rate > MAX_PLATFORM_FEE_BPS) revert FeeRateTooHigh(rate, MAX_PLATFORM_FEE_BPS);
        uint256 old = platformFeeRate;
        platformFeeRate = rate;
        emit PlatformFeeRateUpdated(old, rate);
    }

    function setReputationRates(
        uint256 perTip,
        uint256 perFollow,
        uint256 perPost,
        uint256 perLike
    ) external onlyRole(ADMIN_ROLE) {
        reputationPerTip = perTip;
        reputationPerFollow = perFollow;
        reputationPerPost = perPost;
        reputationPerLike = perLike;
        emit ReputationRatesUpdated(perTip, perFollow, perPost, perLike);
    }

    function setMinPostInterval(uint256 interval) external onlyRole(ADMIN_ROLE) {
        minPostInterval = interval;
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // ============================================================================
    // INTERNAL HELPERS
    // ============================================================================

    function _getIdentityTokenId(address user) internal view returns (uint256) {
        try identityContract.getTokenIdByOwner(user) returns (uint256 tokenId) {
            return tokenId;
        } catch {
            return 0;
        }
    }

    function _isPremium(address user) internal view returns (bool) {
        try coreContract.getTier(user) returns (ILksCore.AccessTier tier) {
            return uint8(tier) >= uint8(ILksCore.AccessTier.PREMIUM);
        } catch {
            return false;
        }
    }

    /**
     * @dev Écrit la reputation dans Core via le rôle SOCIAL_WRITER.
     *      Wrapped en try/catch pour ne pas bloquer les flows si Core est temporairement paused
     *      ou si le rôle n'est pas encore accordé.
     */
    function _addReputation(address user, uint256 amount) internal {
        if (amount == 0) return;
        try coreContract.addReputation(user, amount) {
            // success
        } catch {
            // Silently skip — reputation écriture est best-effort, ne doit pas bloquer le flow
        }
    }

    function _paginate(
        EnumerableSet.AddressSet storage set,
        uint256 offset,
        uint256 limit
    ) internal view returns (address[] memory) {
        uint256 total = set.length();
        if (offset >= total) return new address[](0);

        uint256 end = offset + limit > total ? total : offset + limit;
        uint256 size = end - offset;

        address[] memory result = new address[](size);
        for (uint256 i = 0; i < size; i++) {
            result[i] = set.at(offset + i);
        }
        return result;
    }

    // ============================================================================
    // UUPS
    // ============================================================================

    function _authorizeUpgrade(address newImpl) internal override onlyRole(UPGRADER_ROLE) {}

    /// @notice Permet au contrat de recevoir de l'ETH (pour les tips entrants)
    receive() external payable {}
}
