// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/**
 * @title LksBusiness
 * @notice Contrat financier unifié pour LinkUs Protocol
 * @dev Gère : Tiers d'accès, Crowdfunding, Monétisation contenu, Marketplace
 *
 * PRICING AJUSTÉ (ETH @ $4,332.06 - Oct 2025):
 * - Identity NFT: 0.01 ETH ($43.32 one-time) - Anti-Sybil
 * - PREMIUM: 0.002 ETH/mois ($8.66) - Compétitif vs Twitter Blue
 * - ENTERPRISE: 0.01 ETH/mois ($43.32) - Meilleur que LinkedIn Sales
 *
 * ARCHITECTURE:
 * - Vérifie Soulbound Identity NFT (requis pour tiers VERIFIED+)
 * - Gestion granulaire des accès multi-niveaux
 * - Crowdfunding avec escrow automatique
 * - Monétisation contenu (FREE/PAID/EARNED/RENTAL/SUBSCRIPTION/etc.)
 * - Marketplace avec royalties créateurs
 */
contract LksBusiness is Ownable, ReentrancyGuard, Pausable {

    // ========== TYPES ==========

    /// @notice Tiers d'accès plateforme
    enum AccessTier {
        FREE,           // 0 ETH - Accès de base
        VERIFIED,       // 0 ETH - Identity NFT requis
        PREMIUM,        // 0.002 ETH/mois - $8.66
        ENTERPRISE,     // 0.01 ETH/mois - $43.32
        PROTOCOL        // 0 ETH - Équipe uniquement
    }

    /// @notice Types de ressources
    enum ResourceType {
        POSTS,
        MESSAGES,
        STORAGE,
        PROJECTS,
        GOVERNANCE,
        API,
        ANALYTICS,
        CUSTOM_BRANDING,
        PRIORITY_SUPPORT,
        BETA_FEATURES
    }

    /// @notice Actions possibles
    enum Action {
        READ,
        WRITE,
        DELETE,
        ADMIN,
        EXECUTE
    }

    /// @notice Statut projet crowdfunding
    enum ProjectStatus {
        ACTIVE,
        FUNDED,
        CANCELLED,
        COMPLETED
    }

    /// @notice Types d'accès au contenu
    enum ContentAccessType {
        FREE,           // Gratuit/public
        PAID,           // Payant one-time (NFT reçu)
        EARNED,         // Déblocable via actions (gamification)
        TIME_LIMITED,   // Accès temporaire
        SUBSCRIPTION,   // Inclus dans tier
        RENTAL,         // Location temporaire payante
        HYBRID          // Combinaison de plusieurs types
    }

    /// @notice Conditions pour débloquer contenu
    enum EarnConditionType {
        FOLLOW_CREATOR,
        LIKE_POST,
        SHARE_CONTENT,
        REACH_FOLLOWERS,
        COMPLETE_QUIZ,
        TIME_SPENT,
        REFERRAL,
        STREAK,
        BADGE,
        LEVEL
    }

    // ========== STRUCTURES ==========

    /// @notice Configuration d'un tier
    struct TierConfig {
        uint256 price;              // Prix mensuel en Wei
        uint256 duration;           // Durée en secondes
        bool requiresIdentity;      // Soulbound NFT requis
        bytes32[] capabilities;     // Capacités par défaut
        uint256 maxStorage;         // Stockage IPFS max (bytes)
        uint256 maxAPICalls;        // API calls/jour
        uint256 maxProjects;        // Projets max
        uint256 maxContentCreation; // Contenus créables
    }

    /// @notice Accès utilisateur
    struct UserAccess {
        AccessTier tier;
        uint256 subscribedAt;
        uint256 expiresAt;          // 0 = permanent
        uint256 identityNFT;        // Token ID (0 = aucun)
        bytes32 orbitDBKey;         // Clé OrbitDB P2P
        bool active;
        mapping(bytes32 => bool) capabilities;
        mapping(ResourceType => mapping(Action => uint256)) usageCount;
        mapping(ResourceType => mapping(Action => uint256)) lastUsage;
    }

    /// @notice Capacité (permission granulaire)
    struct Capability {
        bytes32 id;
        string name;
        ResourceType resource;
        Action action;
        bool enabled;
        uint256 rateLimit;          // Limite/jour (0 = illimité)
        uint256 expiry;             // Expiration (0 = jamais)
    }

    /// @notice Projet crowdfunding
    struct Project {
        address creator;
        string title;
        bytes32 ipfsHash;           // IPFS metadata
        uint256 fundingGoal;
        uint256 currentFunding;
        uint256 deadline;
        ProjectStatus status;
        bool exists;
        uint256 creatorWithdrawn;   // Montant déjà retiré
    }

    /// @notice Configuration contenu monétisé
    struct ContentConfig {
        bytes32 contentId;
        address creator;
        ContentAccessType[] accessTypes;
        bool isPaid;
        uint256 price;              // Prix one-time
        bool isResellable;
        uint256 resellRoyalty;      // Pourcentage (basis points)
        bool isEarnable;
        EarnConditionType[] earnConditions;
        bool isRentable;
        uint256 rentalPrice;
        uint256 rentalDuration;
        bool isTimeLimited;
        uint256 timeLimitDuration;
        bool requiresSubscription;
        AccessTier minSubscriptionTier;
        bool active;
    }

    /// @notice Accès utilisateur au contenu
    struct UserContentAccess {
        bytes32 contentId;
        address user;
        ContentAccessType accessType;
        uint256 grantedAt;
        uint256 expiresAt;          // 0 = permanent
        uint256 pricePaid;
        bool active;
        uint256 viewCount;
    }

    /// @notice Reçu d'achat (NFT-like)
    struct ContentReceipt {
        uint256 receiptId;
        bytes32 contentId;
        address owner;
        uint256 purchasePrice;
        uint256 purchasedAt;
        bool isResold;
        uint256 resaleCount;
    }

    /// @notice Partage temporaire de fichier
    struct TemporaryShare {
        bytes32 fileHash;
        address sharedWith;
        uint256 expiresAt;
        bool isPaid;
        uint256 price;
        bool used;
    }

    // ========== STORAGE ==========

    // Identity NFT contract (Soulbound Token)
    IERC721 public identityContract;

    // Tiers configuration
    mapping(AccessTier => TierConfig) public tierConfigs;
    mapping(address => UserAccess) private userAccess;

    // Capabilities
    mapping(bytes32 => Capability) public capabilities;
    bytes32[] public capabilityIds;

    // Projects
    uint256 private _nextProjectId = 1;
    mapping(uint256 => Project) public projects;
    mapping(uint256 => mapping(address => uint256)) public contributions;
    mapping(address => uint256[]) public userProjects;

    // Content monetization
    mapping(bytes32 => ContentConfig) public contentConfigs;
    mapping(bytes32 => mapping(address => UserContentAccess)) public userContentAccess;
    uint256 private _nextReceiptId = 1;
    mapping(uint256 => ContentReceipt) public contentReceipts;
    mapping(address => uint256[]) public userReceipts;
    mapping(bytes32 => uint256) public contentTotalRevenue;
    mapping(address => uint256) public creatorEarnings;

    // Temporary shares
    mapping(bytes32 => TemporaryShare) public temporaryShares;
    mapping(address => bytes32[]) public userShares;

    // Stats
    uint256 public totalUsers;
    mapping(AccessTier => uint256) public usersByTier;
    uint256 public totalRevenue;
    mapping(AccessTier => uint256) public revenueByTier;
    uint256 public totalProjects;
    uint256 public totalProjectsFunded;
    uint256 public totalContents;

    // Configuration
    uint256 public minProjectGoal = 0.01 ether;    // $43 @ $4,332
    uint256 public maxProjectDuration = 90 days;
    uint256 public platformFeeRate = 500;          // 5% (basis points)
    address public protocolTreasury;

    // ========== EVENTS ==========

    // Tiers
    event TierSubscribed(address indexed user, AccessTier tier, uint256 price, uint256 expiresAt);
    event TierUpgraded(address indexed user, AccessTier oldTier, AccessTier newTier);
    event IdentityLinked(address indexed user, uint256 tokenId);
    event OrbitDBKeyLinked(address indexed user, bytes32 orbitDBKey);

    // Projects
    event ProjectCreated(uint256 indexed projectId, address indexed creator, uint256 fundingGoal);
    event ProjectFunded(uint256 indexed projectId, address indexed backer, uint256 amount);
    event ProjectCompleted(uint256 indexed projectId, uint256 totalFunded);
    event ProjectCancelled(uint256 indexed projectId);
    event CreatorWithdrawal(uint256 indexed projectId, address indexed creator, uint256 amount);
    event BackerRefund(uint256 indexed projectId, address indexed backer, uint256 amount);

    // Content
    event ContentRegistered(bytes32 indexed contentId, address indexed creator);
    event ContentPurchased(bytes32 indexed contentId, address indexed buyer, uint256 price);
    event ContentRented(bytes32 indexed contentId, address indexed renter, uint256 price, uint256 duration);
    event ContentEarned(bytes32 indexed contentId, address indexed user, EarnConditionType condition);
    event ContentResold(uint256 indexed receiptId, address indexed seller, address indexed buyer, uint256 price);
    event CreatorEarningsWithdrawn(address indexed creator, uint256 amount);

    // Shares
    event TemporaryShareCreated(bytes32 indexed shareHash, bytes32 indexed fileHash, address indexed sharedWith);

    // ========== ERRORS ==========

    error InsufficientPayment(uint256 required, uint256 provided);
    error IdentityRequired();
    error InvalidIdentityNFT();
    error TierNotActive();
    error TierExpired();
    error AccessDenied(ResourceType resource, Action action);
    error RateLimitExceeded(ResourceType resource, Action action);
    error ProjectNotFound(uint256 projectId);
    error ProjectNotActive(uint256 projectId);
    error ProjectExpired(uint256 projectId);
    error RefundNotAvailable(uint256 projectId);
    error NoContributionToRefund(uint256 projectId, address backer);
    error ContentNotFound(bytes32 contentId);
    error ContentNotAccessible(bytes32 contentId);
    error AlreadyPurchased(bytes32 contentId);
    error NotContentOwner(bytes32 contentId);
    error InvalidConfiguration();

    // ========== CONSTRUCTOR ==========

    constructor(
        address _identityContract,
        address _protocolTreasury
    ) Ownable(msg.sender) {
        if (_identityContract == address(0) || _protocolTreasury == address(0)) {
            revert InvalidConfiguration();
        }

        identityContract = IERC721(_identityContract);
        protocolTreasury = _protocolTreasury;

        _initializeTiers();
        _initializeCapabilities();
    }

    // ========== INITIALIZATION ==========

    function _initializeTiers() private {
        // FREE - Accès de base
        tierConfigs[AccessTier.FREE] = TierConfig({
            price: 0,
            duration: 0,
            requiresIdentity: false,
            capabilities: new bytes32[](0),
            maxStorage: 100 * 1024 * 1024,      // 100 MB
            maxAPICalls: 100,
            maxProjects: 1,
            maxContentCreation: 5
        });

        // VERIFIED - Identity NFT requis
        tierConfigs[AccessTier.VERIFIED] = TierConfig({
            price: 0,
            duration: 0,
            requiresIdentity: true,
            capabilities: new bytes32[](0),
            maxStorage: 500 * 1024 * 1024,      // 500 MB
            maxAPICalls: 500,
            maxProjects: 3,
            maxContentCreation: 20
        });

        // PREMIUM - $8.66/mois (0.002 ETH @ $4,332)
        tierConfigs[AccessTier.PREMIUM] = TierConfig({
            price: 0.002 ether,
            duration: 30 days,
            requiresIdentity: true,
            capabilities: new bytes32[](0),
            maxStorage: 10 * 1024 * 1024 * 1024, // 10 GB
            maxAPICalls: 10000,
            maxProjects: 10,
            maxContentCreation: 100
        });

        // ENTERPRISE - $43.32/mois (0.01 ETH @ $4,332)
        tierConfigs[AccessTier.ENTERPRISE] = TierConfig({
            price: 0.01 ether,
            duration: 30 days,
            requiresIdentity: true,
            capabilities: new bytes32[](0),
            maxStorage: 100 * 1024 * 1024 * 1024, // 100 GB
            maxAPICalls: 100000,
            maxProjects: 50,
            maxContentCreation: 1000
        });

        // PROTOCOL - Équipe
        tierConfigs[AccessTier.PROTOCOL] = TierConfig({
            price: 0,
            duration: 0,
            requiresIdentity: true,
            capabilities: new bytes32[](0),
            maxStorage: type(uint256).max,
            maxAPICalls: type(uint256).max,
            maxProjects: type(uint256).max,
            maxContentCreation: type(uint256).max
        });
    }

    function _initializeCapabilities() private {
        // POSTS
        _createCapability("POSTS_READ", ResourceType.POSTS, Action.READ, 1000);
        _createCapability("POSTS_WRITE", ResourceType.POSTS, Action.WRITE, 100);
        _createCapability("POSTS_DELETE", ResourceType.POSTS, Action.DELETE, 50);

        // MESSAGES
        _createCapability("MESSAGES_READ", ResourceType.MESSAGES, Action.READ, 1000);
        _createCapability("MESSAGES_WRITE", ResourceType.MESSAGES, Action.WRITE, 500);

        // STORAGE
        _createCapability("STORAGE_WRITE", ResourceType.STORAGE, Action.WRITE, 100);
        _createCapability("STORAGE_READ", ResourceType.STORAGE, Action.READ, 1000);

        // PROJECTS
        _createCapability("PROJECTS_CREATE", ResourceType.PROJECTS, Action.WRITE, 10);
        _createCapability("PROJECTS_FUND", ResourceType.PROJECTS, Action.EXECUTE, 100);

        // GOVERNANCE
        _createCapability("GOVERNANCE_VOTE", ResourceType.GOVERNANCE, Action.EXECUTE, 50);

        // API
        _createCapability("API_CALL", ResourceType.API, Action.EXECUTE, 10000);

        // ANALYTICS (PREMIUM+)
        _createCapability("ANALYTICS_VIEW", ResourceType.ANALYTICS, Action.READ, 1000);

        // CUSTOM_BRANDING (ENTERPRISE+)
        _createCapability("CUSTOM_BRANDING", ResourceType.CUSTOM_BRANDING, Action.WRITE, 10);

        // PRIORITY_SUPPORT (ENTERPRISE+)
        _createCapability("PRIORITY_SUPPORT", ResourceType.PRIORITY_SUPPORT, Action.EXECUTE, 100);

        // BETA_FEATURES (PROTOCOL)
        _createCapability("BETA_FEATURES", ResourceType.BETA_FEATURES, Action.EXECUTE, type(uint256).max);

        _assignDefaultCapabilities();
    }

    function _createCapability(
        string memory name,
        ResourceType resource,
        Action action,
        uint256 rateLimit
    ) private {
        bytes32 id = keccak256(abi.encodePacked(name));
        capabilities[id] = Capability({
            id: id,
            name: name,
            resource: resource,
            action: action,
            enabled: true,
            rateLimit: rateLimit,
            expiry: 0
        });
        capabilityIds.push(id);
    }

    function _assignDefaultCapabilities() private {
        // FREE
        bytes32[] memory freeCapabilities = new bytes32[](3);
        freeCapabilities[0] = keccak256("POSTS_READ");
        freeCapabilities[1] = keccak256("MESSAGES_READ");
        freeCapabilities[2] = keccak256("STORAGE_READ");
        tierConfigs[AccessTier.FREE].capabilities = freeCapabilities;

        // VERIFIED
        bytes32[] memory verifiedCapabilities = new bytes32[](6);
        verifiedCapabilities[0] = keccak256("POSTS_READ");
        verifiedCapabilities[1] = keccak256("POSTS_WRITE");
        verifiedCapabilities[2] = keccak256("MESSAGES_READ");
        verifiedCapabilities[3] = keccak256("MESSAGES_WRITE");
        verifiedCapabilities[4] = keccak256("STORAGE_READ");
        verifiedCapabilities[5] = keccak256("STORAGE_WRITE");
        tierConfigs[AccessTier.VERIFIED].capabilities = verifiedCapabilities;

        // PREMIUM
        bytes32[] memory premiumCapabilities = new bytes32[](10);
        premiumCapabilities[0] = keccak256("POSTS_READ");
        premiumCapabilities[1] = keccak256("POSTS_WRITE");
        premiumCapabilities[2] = keccak256("POSTS_DELETE");
        premiumCapabilities[3] = keccak256("MESSAGES_READ");
        premiumCapabilities[4] = keccak256("MESSAGES_WRITE");
        premiumCapabilities[5] = keccak256("STORAGE_READ");
        premiumCapabilities[6] = keccak256("STORAGE_WRITE");
        premiumCapabilities[7] = keccak256("PROJECTS_CREATE");
        premiumCapabilities[8] = keccak256("PROJECTS_FUND");
        premiumCapabilities[9] = keccak256("ANALYTICS_VIEW");
        tierConfigs[AccessTier.PREMIUM].capabilities = premiumCapabilities;

        // ENTERPRISE
        bytes32[] memory enterpriseCapabilities = new bytes32[](13);
        enterpriseCapabilities[0] = keccak256("POSTS_READ");
        enterpriseCapabilities[1] = keccak256("POSTS_WRITE");
        enterpriseCapabilities[2] = keccak256("POSTS_DELETE");
        enterpriseCapabilities[3] = keccak256("MESSAGES_READ");
        enterpriseCapabilities[4] = keccak256("MESSAGES_WRITE");
        enterpriseCapabilities[5] = keccak256("STORAGE_READ");
        enterpriseCapabilities[6] = keccak256("STORAGE_WRITE");
        enterpriseCapabilities[7] = keccak256("PROJECTS_CREATE");
        enterpriseCapabilities[8] = keccak256("PROJECTS_FUND");
        enterpriseCapabilities[9] = keccak256("GOVERNANCE_VOTE");
        enterpriseCapabilities[10] = keccak256("ANALYTICS_VIEW");
        enterpriseCapabilities[11] = keccak256("CUSTOM_BRANDING");
        enterpriseCapabilities[12] = keccak256("PRIORITY_SUPPORT");
        tierConfigs[AccessTier.ENTERPRISE].capabilities = enterpriseCapabilities;

        // PROTOCOL - Tout
        tierConfigs[AccessTier.PROTOCOL].capabilities = capabilityIds;
    }

    // ========== TIER MANAGEMENT ==========

    /**
     * @notice Souscrire à un tier
     * @param tier Tier choisi
     */
    function subscribe(AccessTier tier) external payable nonReentrant whenNotPaused {
        if (tier == AccessTier.PROTOCOL) revert InvalidConfiguration();

        TierConfig memory config = tierConfigs[tier];
        UserAccess storage access = userAccess[msg.sender];

        // Vérifier Identity NFT si requis
        if (config.requiresIdentity) {
            if (access.identityNFT == 0) revert IdentityRequired();
            if (identityContract.ownerOf(access.identityNFT) != msg.sender) {
                revert InvalidIdentityNFT();
            }
        }

        // Vérifier paiement
        if (msg.value < config.price) {
            revert InsufficientPayment(config.price, msg.value);
        }

        // Nouvel utilisateur
        if (access.tier == AccessTier.FREE && tier != AccessTier.FREE) {
            totalUsers++;
        }

        // Mise à jour tier
        AccessTier oldTier = access.tier;
        access.tier = tier;
        access.subscribedAt = block.timestamp;
        access.expiresAt = config.duration > 0 ? block.timestamp + config.duration : 0;
        access.active = true;

        // Stats
        if (oldTier != tier) {
            if (oldTier != AccessTier.FREE) usersByTier[oldTier]--;
            usersByTier[tier]++;
        }

        // Grant capacités
        _grantDefaultCapabilities(msg.sender, tier);

        // Revenus
        if (config.price > 0) {
            totalRevenue += msg.value;
            revenueByTier[tier] += msg.value;
        }

        // Rembourser excédent
        if (msg.value > config.price) {
            payable(msg.sender).transfer(msg.value - config.price);
        }

        emit TierSubscribed(msg.sender, tier, config.price, access.expiresAt);

        if (oldTier != AccessTier.FREE && oldTier != tier) {
            emit TierUpgraded(msg.sender, oldTier, tier);
        }
    }

    /**
     * @notice Lier Identity NFT (Soulbound Token)
     * @param tokenId Token ID de l'Identity NFT
     */
    function linkIdentityNFT(uint256 tokenId) external {
        if (identityContract.ownerOf(tokenId) != msg.sender) {
            revert InvalidIdentityNFT();
        }

        userAccess[msg.sender].identityNFT = tokenId;
        emit IdentityLinked(msg.sender, tokenId);
    }

    /**
     * @notice Lier clé OrbitDB P2P
     * @param orbitDBKey Clé publique OrbitDB
     */
    function linkOrbitDBKey(bytes32 orbitDBKey) external {
        userAccess[msg.sender].orbitDBKey = orbitDBKey;
        emit OrbitDBKeyLinked(msg.sender, orbitDBKey);
    }

    // ========== ACCESS CONTROL ==========

    /**
     * @notice Vérifier accès à une ressource
     * @param user Adresse utilisateur
     * @param resource Type de ressource
     * @param action Action demandée
     */
    function checkAccess(
        address user,
        ResourceType resource,
        Action action
    ) public view returns (bool) {
        UserAccess storage access = userAccess[user];

        if (!access.active) return false;
        if (access.expiresAt > 0 && access.expiresAt < block.timestamp) return false;

        bytes32 capabilityId = _findCapabilityId(resource, action);
        if (capabilityId == bytes32(0)) return false;

        return access.capabilities[capabilityId];
    }

    /**
     * @notice Enregistrer accès (avec rate limiting)
     */
    function recordAccess(
        address user,
        ResourceType resource,
        Action action
    ) external whenNotPaused {
        UserAccess storage access = userAccess[user];

        if (!access.active) revert TierNotActive();
        if (access.expiresAt > 0 && access.expiresAt < block.timestamp) {
            revert TierExpired();
        }

        bytes32 capabilityId = _findCapabilityId(resource, action);
        if (capabilityId == bytes32(0) || !access.capabilities[capabilityId]) {
            revert AccessDenied(resource, action);
        }

        // Rate limiting
        Capability memory cap = capabilities[capabilityId];
        if (cap.rateLimit > 0) {
            uint256 lastUsageTime = access.lastUsage[resource][action];
            uint256 usageCount = access.usageCount[resource][action];

            if (block.timestamp >= lastUsageTime + 1 days) {
                usageCount = 0;
            }

            if (usageCount >= cap.rateLimit) {
                revert RateLimitExceeded(resource, action);
            }

            access.usageCount[resource][action] = usageCount + 1;
            access.lastUsage[resource][action] = block.timestamp;
        }
    }

    function _grantDefaultCapabilities(address user, AccessTier tier) private {
        bytes32[] memory defaultCapabilities = tierConfigs[tier].capabilities;

        for (uint256 i = 0; i < defaultCapabilities.length; i++) {
            userAccess[user].capabilities[defaultCapabilities[i]] = true;
        }
    }

    function _findCapabilityId(ResourceType resource, Action action) private view returns (bytes32) {
        for (uint256 i = 0; i < capabilityIds.length; i++) {
            Capability memory cap = capabilities[capabilityIds[i]];
            if (cap.resource == resource && cap.action == action && cap.enabled) {
                return cap.id;
            }
        }
        return bytes32(0);
    }

    // ========== CROWDFUNDING ==========

    /**
     * @notice Créer projet crowdfunding
     */
    function createProject(
        string calldata title,
        bytes32 ipfsHash,
        uint256 fundingGoal,
        uint256 duration
    ) external whenNotPaused returns (uint256) {
        if (bytes(title).length == 0) revert InvalidConfiguration();
        if (fundingGoal < minProjectGoal) revert InvalidConfiguration();
        if (duration > maxProjectDuration) revert InvalidConfiguration();

        uint256 projectId = _nextProjectId++;
        uint256 deadline = block.timestamp + duration;

        projects[projectId] = Project({
            creator: msg.sender,
            title: title,
            ipfsHash: ipfsHash,
            fundingGoal: fundingGoal,
            currentFunding: 0,
            deadline: deadline,
            status: ProjectStatus.ACTIVE,
            exists: true,
            creatorWithdrawn: 0
        });

        userProjects[msg.sender].push(projectId);
        totalProjects++;

        emit ProjectCreated(projectId, msg.sender, fundingGoal);
        return projectId;
    }

    /**
     * @notice Financer un projet
     */
    function fundProject(uint256 projectId) external payable nonReentrant whenNotPaused {
        Project storage project = projects[projectId];

        if (!project.exists) revert ProjectNotFound(projectId);
        if (project.status != ProjectStatus.ACTIVE) revert ProjectNotActive(projectId);
        if (block.timestamp >= project.deadline) revert ProjectExpired(projectId);
        if (msg.value == 0) revert InsufficientPayment(1, 0);

        contributions[projectId][msg.sender] += msg.value;
        project.currentFunding += msg.value;

        if (project.currentFunding >= project.fundingGoal) {
            project.status = ProjectStatus.FUNDED;
            totalProjectsFunded++;
            emit ProjectCompleted(projectId, project.currentFunding);
        }

        emit ProjectFunded(projectId, msg.sender, msg.value);
    }

    /**
     * @notice Retrait créateur (projet financé)
     */
    function withdrawProjectFunds(uint256 projectId) external nonReentrant {
        Project storage project = projects[projectId];

        if (!project.exists) revert ProjectNotFound(projectId);
        if (project.creator != msg.sender) revert NotContentOwner(bytes32(projectId));
        if (project.status != ProjectStatus.FUNDED && project.status != ProjectStatus.COMPLETED) {
            revert ProjectNotActive(projectId);
        }

        uint256 availableAmount = project.currentFunding - project.creatorWithdrawn;
        if (availableAmount == 0) revert InsufficientPayment(1, 0);

        uint256 platformFee = (availableAmount * platformFeeRate) / 10000;
        uint256 creatorAmount = availableAmount - platformFee;

        project.creatorWithdrawn += availableAmount;
        project.status = ProjectStatus.COMPLETED;

        // Transfer au créateur
        payable(project.creator).transfer(creatorAmount);

        // Fee protocole
        if (platformFee > 0) {
            payable(protocolTreasury).transfer(platformFee);
        }

        emit CreatorWithdrawal(projectId, msg.sender, creatorAmount);
    }

    /**
     * @notice Refund backer contribution for cancelled/expired projects
     * @dev Backers can claim refund if:
     *      - Project is CANCELLED, or
     *      - Project deadline passed AND status is still ACTIVE (failed to reach goal)
     * @param projectId ID du projet
     */
    function refundProject(uint256 projectId) external nonReentrant {
        Project storage project = projects[projectId];

        if (!project.exists) revert ProjectNotFound(projectId);

        // Check if refund is available
        bool isCancelled = project.status == ProjectStatus.CANCELLED;
        bool isExpiredAndNotFunded = block.timestamp >= project.deadline &&
                                     project.status == ProjectStatus.ACTIVE;

        if (!isCancelled && !isExpiredAndNotFunded) {
            revert RefundNotAvailable(projectId);
        }

        // Get backer's contribution
        uint256 contribution = contributions[projectId][msg.sender];
        if (contribution == 0) {
            revert NoContributionToRefund(projectId, msg.sender);
        }

        // Clear contribution before transfer (reentrancy protection)
        contributions[projectId][msg.sender] = 0;
        project.currentFunding -= contribution;

        // Transfer refund to backer
        payable(msg.sender).transfer(contribution);

        emit BackerRefund(projectId, msg.sender, contribution);
    }

    /**
     * @notice Cancel a project (only creator or admin)
     * @dev Sets status to CANCELLED, enabling refunds for backers
     * @param projectId ID du projet
     */
    function cancelProject(uint256 projectId) external {
        Project storage project = projects[projectId];

        if (!project.exists) revert ProjectNotFound(projectId);
        if (project.creator != msg.sender && msg.sender != owner()) {
            revert NotContentOwner(bytes32(projectId));
        }
        if (project.status != ProjectStatus.ACTIVE) {
            revert ProjectNotActive(projectId);
        }

        project.status = ProjectStatus.CANCELLED;

        emit ProjectCancelled(projectId);
    }

    // ========== CONTENT MONETIZATION ==========

    /**
     * @notice Enregistrer contenu monétisé
     */
    function registerContent(
        bytes32 contentId,
        ContentAccessType[] calldata accessTypes,
        uint256 price,
        uint256 rentalPrice,
        uint256 rentalDuration,
        uint256 resellRoyalty,
        EarnConditionType[] calldata earnConditions,
        bool requiresSubscription,
        AccessTier minSubscriptionTier
    ) external whenNotPaused {
        if (contentConfigs[contentId].creator != address(0)) {
            revert InvalidConfiguration(); // Already exists
        }

        ContentConfig storage config = contentConfigs[contentId];
        config.contentId = contentId;
        config.creator = msg.sender;
        config.accessTypes = accessTypes;
        config.isPaid = _hasAccessType(accessTypes, ContentAccessType.PAID);
        config.price = price;
        config.isResellable = price > 0; // Si payant, revendable
        config.resellRoyalty = resellRoyalty;
        config.isEarnable = _hasAccessType(accessTypes, ContentAccessType.EARNED);
        config.earnConditions = earnConditions;
        config.isRentable = _hasAccessType(accessTypes, ContentAccessType.RENTAL);
        config.rentalPrice = rentalPrice;
        config.rentalDuration = rentalDuration;
        config.isTimeLimited = _hasAccessType(accessTypes, ContentAccessType.TIME_LIMITED);
        config.timeLimitDuration = 7 days; // Default
        config.requiresSubscription = requiresSubscription;
        config.minSubscriptionTier = minSubscriptionTier;
        config.active = true;

        totalContents++;

        emit ContentRegistered(contentId, msg.sender);
    }

    /**
     * @notice Acheter contenu (one-time)
     */
    function purchaseContent(bytes32 contentId) external payable nonReentrant whenNotPaused {
        ContentConfig storage config = contentConfigs[contentId];

        if (config.creator == address(0)) revert ContentNotFound(contentId);
        if (!config.isPaid) revert ContentNotAccessible(contentId);
        if (userContentAccess[contentId][msg.sender].active) {
            revert AlreadyPurchased(contentId);
        }
        if (msg.value < config.price) {
            revert InsufficientPayment(config.price, msg.value);
        }

        // Grant accès permanent
        userContentAccess[contentId][msg.sender] = UserContentAccess({
            contentId: contentId,
            user: msg.sender,
            accessType: ContentAccessType.PAID,
            grantedAt: block.timestamp,
            expiresAt: 0, // Permanent
            pricePaid: msg.value,
            active: true,
            viewCount: 0
        });

        // Créer NFT reçu
        uint256 receiptId = _nextReceiptId++;
        contentReceipts[receiptId] = ContentReceipt({
            receiptId: receiptId,
            contentId: contentId,
            owner: msg.sender,
            purchasePrice: msg.value,
            purchasedAt: block.timestamp,
            isResold: false,
            resaleCount: 0
        });
        userReceipts[msg.sender].push(receiptId);

        // Revenus
        contentTotalRevenue[contentId] += msg.value;
        creatorEarnings[config.creator] += msg.value;

        // Rembourser excédent
        if (msg.value > config.price) {
            payable(msg.sender).transfer(msg.value - config.price);
        }

        emit ContentPurchased(contentId, msg.sender, msg.value);
    }

    /**
     * @notice Louer contenu (temporaire)
     */
    function rentContent(bytes32 contentId) external payable nonReentrant whenNotPaused {
        ContentConfig storage config = contentConfigs[contentId];

        if (config.creator == address(0)) revert ContentNotFound(contentId);
        if (!config.isRentable) revert ContentNotAccessible(contentId);
        if (msg.value < config.rentalPrice) {
            revert InsufficientPayment(config.rentalPrice, msg.value);
        }

        // Grant accès temporaire
        userContentAccess[contentId][msg.sender] = UserContentAccess({
            contentId: contentId,
            user: msg.sender,
            accessType: ContentAccessType.RENTAL,
            grantedAt: block.timestamp,
            expiresAt: block.timestamp + config.rentalDuration,
            pricePaid: msg.value,
            active: true,
            viewCount: 0
        });

        // Revenus
        contentTotalRevenue[contentId] += msg.value;
        creatorEarnings[config.creator] += msg.value;

        // Rembourser excédent
        if (msg.value > config.rentalPrice) {
            payable(msg.sender).transfer(msg.value - config.rentalPrice);
        }

        emit ContentRented(contentId, msg.sender, msg.value, config.rentalDuration);
    }

    /**
     * @notice Débloquer contenu via action (gamification)
     */
    function earnContent(
        bytes32 contentId,
        EarnConditionType condition
    ) external whenNotPaused {
        ContentConfig storage config = contentConfigs[contentId];

        if (config.creator == address(0)) revert ContentNotFound(contentId);
        if (!config.isEarnable) revert ContentNotAccessible(contentId);

        // TODO: Vérifier condition via Oracle ou off-chain signature
        // Pour l'instant, on fait confiance

        userContentAccess[contentId][msg.sender] = UserContentAccess({
            contentId: contentId,
            user: msg.sender,
            accessType: ContentAccessType.EARNED,
            grantedAt: block.timestamp,
            expiresAt: 0, // Permanent
            pricePaid: 0,
            active: true,
            viewCount: 0
        });

        emit ContentEarned(contentId, msg.sender, condition);
    }

    /**
     * @notice Vérifier accès au contenu
     */
    function checkContentAccess(
        bytes32 contentId,
        address user
    ) external view returns (bool hasAccess, ContentAccessType accessType, uint256 expiresAt) {
        ContentConfig storage config = contentConfigs[contentId];

        // FREE content
        if (_hasAccessType(config.accessTypes, ContentAccessType.FREE)) {
            return (true, ContentAccessType.FREE, 0);
        }

        // Créateur a toujours accès
        if (config.creator == user) {
            return (true, ContentAccessType.FREE, 0);
        }

        // Vérifier accès utilisateur
        UserContentAccess storage access = userContentAccess[contentId][user];
        if (access.active) {
            if (access.expiresAt == 0 || access.expiresAt > block.timestamp) {
                return (true, access.accessType, access.expiresAt);
            }
        }

        // Vérifier subscription
        if (config.requiresSubscription) {
            UserAccess storage userTier = userAccess[user];
            if (uint8(userTier.tier) >= uint8(config.minSubscriptionTier)) {
                return (true, ContentAccessType.SUBSCRIPTION, 0);
            }
        }

        return (false, ContentAccessType.FREE, 0);
    }

    /**
     * @notice Retrait earnings créateur
     */
    function withdrawCreatorEarnings() external nonReentrant {
        uint256 earnings = creatorEarnings[msg.sender];
        if (earnings == 0) revert InsufficientPayment(1, 0);

        creatorEarnings[msg.sender] = 0;

        payable(msg.sender).transfer(earnings);

        emit CreatorEarningsWithdrawn(msg.sender, earnings);
    }

    // ========== TEMPORARY SHARES ==========

    /**
     * @notice Créer partage temporaire de fichier
     */
    function createTemporaryShare(
        bytes32 fileHash,
        address sharedWith,
        uint256 duration,
        bool isPaid,
        uint256 price
    ) external payable whenNotPaused returns (bytes32) {
        if (isPaid && msg.value < price) {
            revert InsufficientPayment(price, msg.value);
        }

        bytes32 shareHash = keccak256(abi.encodePacked(fileHash, sharedWith, block.timestamp));

        temporaryShares[shareHash] = TemporaryShare({
            fileHash: fileHash,
            sharedWith: sharedWith,
            expiresAt: block.timestamp + duration,
            isPaid: isPaid,
            price: isPaid ? msg.value : 0,
            used: false
        });

        userShares[sharedWith].push(shareHash);

        emit TemporaryShareCreated(shareHash, fileHash, sharedWith);
        return shareHash;
    }

    // ========== HELPERS ==========

    function _hasAccessType(
        ContentAccessType[] memory types,
        ContentAccessType target
    ) private pure returns (bool) {
        for (uint256 i = 0; i < types.length; i++) {
            if (types[i] == target) return true;
        }
        return false;
    }

    // ========== ADMIN ==========

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function setProtocolTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert InvalidConfiguration();
        protocolTreasury = newTreasury;
    }

    function setProjectConfig(
        uint256 _minProjectGoal,
        uint256 _maxProjectDuration,
        uint256 _platformFeeRate
    ) external onlyOwner {
        minProjectGoal = _minProjectGoal;
        maxProjectDuration = _maxProjectDuration;
        platformFeeRate = _platformFeeRate;
    }

    // ========== VIEW FUNCTIONS ==========

    function getUserTier(address user) external view returns (AccessTier) {
        return userAccess[user].tier;
    }

    function isActive(address user) external view returns (bool) {
        UserAccess storage access = userAccess[user];
        if (!access.active) return false;
        if (access.expiresAt > 0 && access.expiresAt < block.timestamp) return false;
        return true;
    }

    function getProject(uint256 projectId) external view returns (Project memory) {
        if (!projects[projectId].exists) revert ProjectNotFound(projectId);
        return projects[projectId];
    }

    function getUserProjects(address user) external view returns (uint256[] memory) {
        return userProjects[user];
    }

    function getContentConfig(bytes32 contentId) external view returns (ContentConfig memory) {
        return contentConfigs[contentId];
    }

    function getUserReceipts(address user) external view returns (uint256[] memory) {
        return userReceipts[user];
    }

    function getStats() external view returns (
        uint256 _totalUsers,
        uint256 _totalRevenue,
        uint256 _totalProjects,
        uint256 _totalProjectsFunded,
        uint256 _totalContents
    ) {
        return (totalUsers, totalRevenue, totalProjects, totalProjectsFunded, totalContents);
    }
}
