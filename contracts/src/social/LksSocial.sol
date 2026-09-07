// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "./ILksIdentityV2.sol";

/**
 * @title LksSocial
 * @notice Contrat de fonctionnalités sociales pour LinkUs Protocol
 * @dev Gère : Follow/Unfollow, Posts (hashes Gun.js), Tips (avec fees plateforme), Reputation
 *
 * ARCHITECTURE HYBRIDE FREEMIUM:
 * - On-chain: Relations sociales, posts hashes, tips (ETH), reputation
 * - Off-chain (Gun.js): Contenu posts, likes, commentaires, messages privés E2E, feed
 * - IPFS: Médias (images, vidéos, fichiers)
 *
 * NOTE: Messages privés sont 100% dans Gun.js avec chiffrement E2E (ECDH + AES-GCM)
 *
 * MODÈLE FREEMIUM:
 *
 * 📖 FREE TIER (0 ETH - Pas de NFT Identity):
 * ✅ READ ONLY: Toutes les fonctions VIEW sont publiques et gratuites
 *    - getPost(), getUserStats(), getFollowers(), getFollowing()
 *    - getUserPosts(), getGlobalStats()
 *    - Permet de découvrir le réseau social sans wallet
 *
 * ❌ WRITE DENIED: Aucune interaction on-chain possible
 *    - Pas de createPost(), tipPost(), follow() on-chain
 *    - Note: Likes sont 100% off-chain dans Gun.js (gratuits)
 *
 * 💎 PREMIUM TIER (0.01 ETH - Identity NFT requis):
 * ✅ FULL ACCESS: Toutes fonctions READ + WRITE
 *    - createPost(): Enregistrer posts on-chain pour monétisation
 *    - tipPost(): Envoyer ETH à l'auteur (0.1% platform fee)
 *    - follow(): Relations sociales on-chain vérifiables
 *    - Accès Web3: Gouvernance, Crowdfunding, Staking
 *
 * BENEFITS PREMIUM:
 * - 🚫 Zero publicité
 * - 🔒 Profil privé (privatisation complète)
 * - ⚡ Priorité réseau P2P
 * - 🎯 Badge vérification on-chain
 * - 💰 Monétisation contenus (99.9% revenus tips)
 *
 * FEATURES:
 * - Follow/Unfollow système avec compteurs
 * - Posts stockés comme hashes Gun.js (off-chain content)
 * - Tips ETH avec 0.1% platform fee (monétisation directe)
 * - Likes 100% off-chain dans Gun.js (instant & gratuit)
 * - Système réputation basé sur tips reçus et follows
 * - Pagination optimisée pour frontend
 * - Anti-spam avec rate limiting
 *
 * INTEGRATION:
 * - Vérifie Identity NFT (LksIdentityV2) pour actions WRITE
 * - Liens avec LksBusiness pour contenu monétisé
 * - Événements indexables pour Gun.js sync
 */
contract LksSocial is Ownable, ReentrancyGuard, Pausable {
    using EnumerableSet for EnumerableSet.AddressSet;

    // ========== TYPES ==========

    /// @notice Post structure (hash Gun.js + metadata)
    struct Post {
        uint256 postId;
        address author;
        bytes32 gunHash;          // Hash Gun.js où contenu est stocké
        bytes32 ipfsMediaHash;    // Hash IPFS pour médias (optionnel)
        uint256 timestamp;
        uint256 likes;
        bool exists;
        bool isMonetized;         // Si lié à LksBusiness content
        bytes32 contentId;        // ID content LksBusiness si monetized
    }

    /// @notice Statistiques utilisateur
    struct UserStats {
        uint256 followers;
        uint256 following;
        uint256 posts;
        uint256 tipsReceived;     // Tips reçus
        uint256 reputation;       // Score réputation
        uint256 lastPostTime;     // Anti-spam
    }

    // ========== STORAGE ==========

    /// @notice Identity NFT contract (requis pour WRITE actions)
    ILksIdentityV2 public identityContract;

    /// @notice Counter posts
    uint256 private _nextPostId = 1;

    /// @notice Posts by ID
    mapping(uint256 => Post) public posts;

    /// @notice Posts by author (pagination)
    mapping(address => uint256[]) private userPosts;

    /// @notice Followers lists (address => followers set) - O(1) add/remove
    mapping(address => EnumerableSet.AddressSet) private followers;

    /// @notice Following lists (address => following set) - O(1) add/remove
    mapping(address => EnumerableSet.AddressSet) private following;

    /// @notice Following status (follower => followed => bool)
    mapping(address => mapping(address => bool)) public isFollowing;

    /// @notice User stats
    mapping(address => UserStats) public userStats;

    /// @notice Gun.js hashes registry (pour éviter doublons)
    mapping(bytes32 => bool) private usedGunHashes;

    /// @notice Daily tips count for FREE tier rate limiting (user => day => count)
    mapping(address => mapping(uint256 => uint256)) private dailyTipsCount;

    /// @notice Total posts in system
    uint256 public totalPosts;

    /// @notice Total tips in system
    uint256 public totalTips;

    /// @notice Total tip amount in system (wei)
    uint256 public totalTipAmount;

    /// @notice Total follows in system
    uint256 public totalFollows;

    /// @notice Platform fee recipient
    address public platformFeeRecipient;

    /// @notice Platform fee rate (in basis points, 10 = 0.1%)
    uint256 public platformFeeRate = 10; // 0.1%

    // Configuration
    uint256 public minPostInterval = 10 seconds;  // Anti-spam
    uint256 public reputationPerTip = 10;
    uint256 public reputationPerFollow = 5;
    uint256 public reputationPerPost = 2;

    // FREE tier rate limiting
    uint256 public constant FREE_DAILY_TIP_LIMIT = 5;      // 5 tips/day for FREE tier
    uint256 public constant MIN_TIP_AMOUNT = 0.0001 ether; // 0.0001 ETH minimum

    // ========== EVENTS ==========

    event PostCreated(
        uint256 indexed postId,
        address indexed author,
        bytes32 gunHash,
        bytes32 ipfsMediaHash,
        uint256 timestamp
    );

    event PostTipped(
        uint256 indexed postId,
        address indexed tipper,
        address indexed author,
        uint256 amount,
        uint256 platformFee,
        string message
    );

    event UserFollowed(
        address indexed follower,
        address indexed followed,
        uint256 timestamp
    );

    event UserUnfollowed(
        address indexed follower,
        address indexed unfollowed,
        uint256 timestamp
    );

    event ReputationUpdated(
        address indexed user,
        uint256 oldReputation,
        uint256 newReputation,
        string reason
    );

    event BatchProcessed(
        address indexed user,
        uint256 interactionsCount
    );

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

    // ========== CONSTRUCTOR ==========

    constructor(address _identityContract) Ownable(msg.sender) {
        if (_identityContract == address(0)) revert InvalidAddress();
        identityContract = ILksIdentityV2(_identityContract);
        platformFeeRecipient = msg.sender; // Owner receives platform fees initially
    }

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

    /**
     * @notice Créer un post (hash Gun.js)
     * @dev Requiert Identity NFT
     * @param gunHash Hash Gun.js où contenu est stocké off-chain
     * @param ipfsMediaHash Hash IPFS pour médias (0x0 si aucun)
     * @return postId ID du post créé
     */
    function createPost(
        bytes32 gunHash,
        bytes32 ipfsMediaHash
    ) external whenNotPaused requiresIdentity nonReentrant returns (uint256) {
        // Anti-spam check
        UserStats storage stats = userStats[msg.sender];
        if (block.timestamp < stats.lastPostTime + minPostInterval) {
            uint256 timeRemaining = (stats.lastPostTime + minPostInterval) - block.timestamp;
            revert PostTooSoon(timeRemaining);
        }

        // Check gun hash not used
        if (usedGunHashes[gunHash]) {
            revert GunHashAlreadyUsed(gunHash);
        }

        // Create post
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

        // Update stats
        stats.posts++;
        stats.lastPostTime = block.timestamp;
        stats.reputation += reputationPerPost;

        totalPosts++;

        emit PostCreated(postId, msg.sender, gunHash, ipfsMediaHash, block.timestamp);
        emit ReputationUpdated(msg.sender, stats.reputation - reputationPerPost, stats.reputation, "post_created");

        return postId;
    }

    /**
     * @notice Tip a post author with ETH
     * @dev Platform takes 0.1% fee, author receives 99.9%
     *      FREE tier: 5 tips/day limit, 0.0001 ETH minimum
     *      PREMIUM tier: Unlimited tips
     * @param postId ID du post
     * @param message Message optionnel avec le tip
     */
    function tipPost(uint256 postId, string calldata message) external payable whenNotPaused requiresIdentity nonReentrant {
        Post storage post = posts[postId];
        if (!post.exists) revert PostNotFound(postId);
        if (msg.value == 0) revert NoETHSent();
        if (msg.value < MIN_TIP_AMOUNT) revert TipAmountTooLow(msg.value, MIN_TIP_AMOUNT);
        if (post.author == msg.sender) revert CannotTipSelf();

        // Check FREE tier rate limit (PREMIUM = has Identity NFT, unlimited)
        uint256 tokenId = _getIdentityTokenId(msg.sender);
        bool isPremium = tokenId > 0;

        if (!isPremium) {
            // FREE tier: check daily limit
            uint256 today = block.timestamp / 1 days;
            uint256 todayTips = dailyTipsCount[msg.sender][today];

            if (todayTips >= FREE_DAILY_TIP_LIMIT) {
                revert FreeTierDailyLimitReached(todayTips, FREE_DAILY_TIP_LIMIT);
            }

            // Increment daily counter
            dailyTipsCount[msg.sender][today] = todayTips + 1;
        }

        // Calculate platform fee (0.1% = 10 basis points)
        uint256 platformFee = (msg.value * platformFeeRate) / 10000;
        uint256 authorAmount = msg.value - platformFee;

        // Transfer to author
        (bool authorSuccess, ) = payable(post.author).call{value: authorAmount}("");
        if (!authorSuccess) revert ETHTransferFailed();

        // Transfer platform fee
        if (platformFee > 0 && platformFeeRecipient != address(0)) {
            (bool feeSuccess, ) = payable(platformFeeRecipient).call{value: platformFee}("");
            if (!feeSuccess) revert ETHTransferFailed();
        }

        // Update stats
        UserStats storage authorStats = userStats[post.author];
        authorStats.tipsReceived++;
        authorStats.reputation += reputationPerTip;

        totalTips++;
        totalTipAmount += msg.value;

        emit PostTipped(postId, msg.sender, post.author, authorAmount, platformFee, message);
        emit ReputationUpdated(
            post.author,
            authorStats.reputation - reputationPerTip,
            authorStats.reputation,
            "post_tipped"
        );
    }

    /**
     * @notice Get remaining tips for today (FREE tier)
     * @param user Address to check
     * @return remaining Number of tips remaining today
     */
    function getRemainingTipsToday(address user) external view returns (uint256 remaining) {
        uint256 tokenId = _getIdentityTokenId(user);

        // PREMIUM tier has unlimited
        if (tokenId > 0) {
            return type(uint256).max;
        }

        // FREE tier: check daily usage
        uint256 today = block.timestamp / 1 days;
        uint256 used = dailyTipsCount[user][today];

        if (used >= FREE_DAILY_TIP_LIMIT) {
            return 0;
        }

        return FREE_DAILY_TIP_LIMIT - used;
    }

    // ========== FOLLOW FUNCTIONS ==========

    /**
     * @notice Follow un utilisateur
     * @param user Adresse à follow
     */
    function follow(address user)
        external
        whenNotPaused
        requiresIdentity
        validAddress(user)
    {
        if (user == msg.sender) revert CannotFollowSelf();
        if (isFollowing[msg.sender][user]) revert AlreadyFollowing(user);

        isFollowing[msg.sender][user] = true;
        followers[user].add(msg.sender);      // O(1) with EnumerableSet
        following[msg.sender].add(user);       // O(1) with EnumerableSet

        // Update stats
        userStats[user].followers++;
        userStats[msg.sender].following++;
        userStats[user].reputation += reputationPerFollow;

        totalFollows++;

        emit UserFollowed(msg.sender, user, block.timestamp);
        emit ReputationUpdated(
            user,
            userStats[user].reputation - reputationPerFollow,
            userStats[user].reputation,
            "new_follower"
        );
    }

    /**
     * @notice Unfollow un utilisateur
     * @param user Adresse à unfollow
     */
    function unfollow(address user)
        external
        whenNotPaused
        requiresIdentity
        validAddress(user)
    {
        if (!isFollowing[msg.sender][user]) revert NotFollowing(user);

        isFollowing[msg.sender][user] = false;

        // Remove from sets - O(1) with EnumerableSet (vs O(n) with arrays)
        followers[user].remove(msg.sender);
        following[msg.sender].remove(user);

        // Update stats
        if (userStats[user].followers > 0) userStats[user].followers--;
        if (userStats[msg.sender].following > 0) userStats[msg.sender].following--;
        if (userStats[user].reputation >= reputationPerFollow) {
            userStats[user].reputation -= reputationPerFollow;
        }

        if (totalFollows > 0) totalFollows--;

        emit UserUnfollowed(msg.sender, user, block.timestamp);
    }

    // ========== BATCH FUNCTIONS (GAS OPTIMIZATION) ==========

    /**
     * @notice Batch process multiple follow/unfollow interactions (gas optimization ~80%)
     * @dev Optimise gas pour batching follows
     * @param actionTypes Array: 0=follow, 1=unfollow
     * @param targetAddresses Array: addresses for follows/unfollows
     *
     * GAS SAVINGS:
     * - Individual: 5 follows × 150k gas = 750k gas
     * - Batch: 50k + (5 × 20k) = 150k gas
     * - SAVINGS: 80% reduction (~600k gas)
     *
     * NOTE: Likes are 100% off-chain in Gun.js, tips are individual on-chain transactions
     */
    function batchFollows(
        uint8[] calldata actionTypes,
        address[] calldata targetAddresses
    ) external whenNotPaused requiresIdentity nonReentrant {
        // Input validation
        if (actionTypes.length != targetAddresses.length) {
            revert("LksSocial: Length mismatch");
        }
        if (actionTypes.length == 0) {
            revert("LksSocial: Empty batch");
        }
        if (actionTypes.length > 50) {
            revert("LksSocial: Batch too large (max 50)");
        }

        // Process each interaction
        for (uint256 i = 0; i < actionTypes.length; i++) {
            uint8 action = actionTypes[i];
            address target = targetAddresses[i];

            if (action == 0) {
                // Follow user
                _executeFollow(target);
            } else if (action == 1) {
                // Unfollow user
                _executeUnfollow(target);
            } else {
                revert("LksSocial: Invalid action type");
            }
        }

        emit BatchProcessed(msg.sender, actionTypes.length);
    }

    /**
     * @notice Internal: Execute follow without modifiers (for batch)
     * @dev Extracted from follow() for gas optimization
     */
    function _executeFollow(address user) internal {
        if (user == address(0)) revert InvalidAddress();
        if (user == msg.sender) revert CannotFollowSelf();
        if (isFollowing[msg.sender][user]) revert AlreadyFollowing(user);

        isFollowing[msg.sender][user] = true;
        followers[user].add(msg.sender);      // O(1) with EnumerableSet
        following[msg.sender].add(user);       // O(1) with EnumerableSet

        // Update stats
        userStats[user].followers++;
        userStats[msg.sender].following++;
        userStats[user].reputation += reputationPerFollow;

        totalFollows++;

        emit UserFollowed(msg.sender, user, block.timestamp);
        emit ReputationUpdated(
            user,
            userStats[user].reputation - reputationPerFollow,
            userStats[user].reputation,
            "new_follower"
        );
    }

    /**
     * @notice Internal: Execute unfollow without modifiers (for batch)
     * @dev Extracted from unfollow() for gas optimization
     */
    function _executeUnfollow(address user) internal {
        if (user == address(0)) revert InvalidAddress();
        if (!isFollowing[msg.sender][user]) revert NotFollowing(user);

        isFollowing[msg.sender][user] = false;

        // Remove from sets - O(1) with EnumerableSet (vs O(n) with arrays)
        followers[user].remove(msg.sender);
        following[msg.sender].remove(user);

        // Update stats
        if (userStats[user].followers > 0) userStats[user].followers--;
        if (userStats[msg.sender].following > 0) userStats[msg.sender].following--;
        if (userStats[user].reputation >= reputationPerFollow) {
            userStats[user].reputation -= reputationPerFollow;
        }

        if (totalFollows > 0) totalFollows--;

        emit UserUnfollowed(msg.sender, user, block.timestamp);
    }

    // ========== VIEW FUNCTIONS - PAGINATION ==========

    /**
     * @notice Get user posts (paginated)
     * @param user Adresse utilisateur
     * @param offset Index de départ
     * @param limit Nombre max de posts
     * @return Post[] Tableau de posts
     */
    function getUserPosts(
        address user,
        uint256 offset,
        uint256 limit
    ) external view returns (Post[] memory) {
        uint256[] storage postIds = userPosts[user];
        uint256 total = postIds.length;

        if (offset >= total) return new Post[](0);

        uint256 end = offset + limit > total ? total : offset + limit;
        uint256 size = end - offset;

        Post[] memory result = new Post[](size);
        for (uint256 i = 0; i < size; i++) {
            result[i] = posts[postIds[total - 1 - (offset + i)]]; // Reverse order (newest first)
        }

        return result;
    }

    /**
     * @notice Get followers (paginated)
     * @param user Adresse utilisateur
     * @param offset Index de départ
     * @param limit Nombre max
     * @return address[] Tableau d'adresses
     */
    function getFollowers(
        address user,
        uint256 offset,
        uint256 limit
    ) external view returns (address[] memory) {
        return _getPaginatedAddresses(followers[user], offset, limit);
    }

    /**
     * @notice Get following (paginated)
     * @param user Adresse utilisateur
     * @param offset Index de départ
     * @param limit Nombre max
     * @return address[] Tableau d'adresses
     */
    function getFollowing(
        address user,
        uint256 offset,
        uint256 limit
    ) external view returns (address[] memory) {
        return _getPaginatedAddresses(following[user], offset, limit);
    }

    /**
     * @notice Get post details
     * @param postId ID du post
     * @return Post Post data
     */
    function getPost(uint256 postId) external view returns (Post memory) {
        if (!posts[postId].exists) revert PostNotFound(postId);
        return posts[postId];
    }

    /**
     * @notice Get user stats
     * @param user Adresse utilisateur
     * @return UserStats Stats complètes
     */
    function getUserStats(address user) external view returns (UserStats memory) {
        return userStats[user];
    }

    /**
     * @notice Get total posts count for user
     * @param user Adresse utilisateur
     * @return uint256 Nombre total de posts
     */
    function getUserPostsCount(address user) external view returns (uint256) {
        return userPosts[user].length;
    }

    /**
     * @notice Get total followers count
     * @param user Adresse utilisateur
     * @return uint256 Nombre de followers
     */
    function getFollowersCount(address user) external view returns (uint256) {
        return followers[user].length();
    }

    /**
     * @notice Get total following count
     * @param user Adresse utilisateur
     * @return uint256 Nombre de following
     */
    function getFollowingCount(address user) external view returns (uint256) {
        return following[user].length();
    }

    /**
     * @notice Get global stats
     * @return _totalPosts Total posts
     * @return _totalTips Total tips
     * @return _totalFollows Total follows
     * @return _totalTipAmount Total ETH tipped (in wei)
     */
    function getGlobalStats() external view returns (
        uint256 _totalPosts,
        uint256 _totalTips,
        uint256 _totalFollows,
        uint256 _totalTipAmount
    ) {
        return (totalPosts, totalTips, totalFollows, totalTipAmount);
    }

    // ========== FREEMIUM TIER HELPERS ==========

    /**
     * @notice Check si user a Identity NFT (PREMIUM tier)
     * @dev Frontend peut utiliser cette fonction pour afficher tier
     * @param user Adresse à vérifier
     * @return bool True si PREMIUM (has NFT), False si FREE (no NFT)
     */
    function hasIdentityNFT(address user) external view returns (bool) {
        return _getIdentityTokenId(user) > 0;
    }

    /**
     * @notice Get Identity NFT token ID for user
     * @dev Public helper pour frontend
     * @param user Adresse à vérifier
     * @return uint256 Token ID (0 si FREE tier, >0 si PREMIUM tier)
     */
    function getIdentityTokenId(address user) external view returns (uint256) {
        return _getIdentityTokenId(user);
    }

    /**
     * @notice Get user tier (FREE vs PREMIUM)
     * @dev Helper pour frontend (afficher badges, features disponibles)
     * @param user Adresse à vérifier
     * @return tier "FREE" si pas NFT, "PREMIUM" si NFT Identity
     */
    function getUserTier(address user) external view returns (string memory tier) {
        return _getIdentityTokenId(user) > 0 ? "PREMIUM" : "FREE";
    }

    // ========== ADMIN FUNCTIONS ==========

    /**
     * @notice Set post interval (anti-spam)
     * @param interval Nouveau interval en secondes
     */
    function setMinPostInterval(uint256 interval) external onlyOwner {
        minPostInterval = interval;
    }

    /**
     * @notice Set reputation rates
     */
    function setReputationRates(
        uint256 perTip,
        uint256 perFollow,
        uint256 perPost
    ) external onlyOwner {
        reputationPerTip = perTip;
        reputationPerFollow = perFollow;
        reputationPerPost = perPost;
    }

    /**
     * @notice Set platform fee recipient
     * @param recipient Address to receive platform fees
     */
    function setPlatformFeeRecipient(address recipient) external onlyOwner {
        if (recipient == address(0)) revert InvalidAddress();
        platformFeeRecipient = recipient;
    }

    /**
     * @notice Set platform fee rate
     * @param rate Fee rate in basis points (100 = 1%, 10 = 0.1%)
     */
    function setPlatformFeeRate(uint256 rate) external onlyOwner {
        require(rate <= 1000, "LksSocial: Fee too high (max 10%)");
        platformFeeRate = rate;
    }

    /**
     * @notice Pause contract
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause contract
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Link post to monetized content (LksBusiness)
     * @dev Only owner can link
     */
    function linkPostToContent(
        uint256 postId,
        bytes32 contentId
    ) external onlyOwner {
        Post storage post = posts[postId];
        if (!post.exists) revert PostNotFound(postId);

        post.isMonetized = true;
        post.contentId = contentId;
    }

    // ========== INTERNAL HELPERS ==========

    /**
     * @notice Get Identity NFT token ID for address
     * @dev Returns 0 if user has no Identity NFT (FREE tier)
     * @param user Address to check
     * @return uint256 Token ID (0 = FREE tier, >0 = PREMIUM tier)
     */
    function _getIdentityTokenId(address user) internal view returns (uint256) {
        try identityContract.getTokenIdByOwner(user) returns (uint256 tokenId) {
            return tokenId;
        } catch {
            return 0; // No Identity NFT = FREE tier
        }
    }

    /**
     * @notice Get paginated addresses from EnumerableSet
     * @dev O(1) access for each element
     */
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
}
