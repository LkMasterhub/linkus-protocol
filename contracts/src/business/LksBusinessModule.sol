// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import "../core/ILksCore.sol";

/**
 * @title  LksBusinessModule
 * @author LinkUs Protocol V7 refonte (2026-04-06)
 * @notice Module Business : Projects (crowdfunding), Content monetization, Temporary shares.
 *         Délègue tiers / subscription / réputation / registry à LksCoreUpgradeable.
 *
 * @dev    Refonte depuis `archives/v6/upgradeable-v6-obsolete/LksBusinessUpgradeable.sol` (squelette)
 *         et `src/business/LksBusiness.sol` (V5 non-upgradeable, source du port).
 *
 *         Findings V6 résolus :
 *           - LKS-BIZ-01 : 14 fonctions portées depuis V5 (create/fund/withdraw/refund/cancel Project,
 *             register/purchase/rent/earn/checkContentAccess Content, withdrawCreatorEarnings,
 *             createTemporaryShare, checkAccess)
 *           - LKS-BIZ-02 : `payable.transfer` remplacé par `.call{value:...}` partout
 *           - LKS-BIZ-07 : `withdrawTreasury` présent (dans LksCore en V7)
 *           - Q6 (plan) : earnContent accepte une signature EIP-712 d'un backend trusted
 *             pour les EarnConditionType off-chain + cross-call LksSocialModule pour conditions on-chain
 *
 * @custom:security-contact security@linkus-protocol.io
 */
contract LksBusinessModule is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    EIP712Upgradeable
{
    using ECDSA for bytes32;

    // ============================================================================
    // ROLES
    // ============================================================================

    bytes32 public constant ADMIN_ROLE    = keccak256("ADMIN_ROLE");
    bytes32 public constant PAUSER_ROLE   = keccak256("PAUSER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // ============================================================================
    // ENUMS
    // ============================================================================

    enum ProjectStatus {
        ACTIVE,
        FUNDED,
        CANCELLED,
        COMPLETED
    }

    enum ContentAccessType {
        FREE,
        PAID,
        EARNED,
        TIME_LIMITED,
        SUBSCRIPTION,
        RENTAL,
        HYBRID
    }

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

    // ============================================================================
    // STRUCTS
    // ============================================================================

    struct Project {
        address creator;
        string title;
        bytes32 ipfsHash;
        uint256 fundingGoal;
        uint256 currentFunding;
        uint256 deadline;
        ProjectStatus status;
        bool exists;
        uint256 creatorWithdrawn;
    }

    struct ContentConfig {
        bytes32 contentId;
        address creator;
        ContentAccessType[] accessTypes;
        bool isPaid;
        uint256 price;
        bool isResellable;
        uint256 resellRoyalty;
        bool isEarnable;
        EarnConditionType[] earnConditions;
        bool isRentable;
        uint256 rentalPrice;
        uint256 rentalDuration;
        bool isTimeLimited;
        uint256 timeLimitDuration;
        bool requiresSubscription;
        ILksCore.AccessTier minSubscriptionTier;
        bool active;
    }

    struct UserContentAccess {
        bytes32 contentId;
        address user;
        ContentAccessType accessType;
        uint256 grantedAt;
        uint256 expiresAt; // 0 = permanent
        uint256 pricePaid;
        bool active;
        uint256 viewCount;
    }

    struct ContentReceipt {
        uint256 receiptId;
        bytes32 contentId;
        address owner;
        uint256 purchasePrice;
        uint256 purchasedAt;
        bool isResold;
        uint256 resaleCount;
    }

    struct TemporaryShare {
        bytes32 fileHash;
        address sharedWith;
        uint256 expiresAt;
        bool isPaid;
        uint256 price;
        bool used;
    }

    // ============================================================================
    // STORAGE
    // ============================================================================

    /// @notice Référence au contrat Core pour les lookups de tier/reputation
    ILksCore public coreContract;

    /// @notice Signer EIP-712 autorisé pour les EarnAuthorization off-chain
    address public earnSigner;

    /// @notice Nonces pour éviter le replay des signatures earn
    mapping(address => uint256) public earnNonces;

    // --- Projects ---
    uint256 private _nextProjectId;
    mapping(uint256 => Project) public projects;
    mapping(uint256 => mapping(address => uint256)) public contributions;
    mapping(address => uint256[]) public userProjects;

    // --- Content ---
    mapping(bytes32 => ContentConfig) private _contentConfigs;
    mapping(bytes32 => mapping(address => UserContentAccess)) public userContentAccess;
    uint256 private _nextReceiptId;
    mapping(uint256 => ContentReceipt) public contentReceipts;
    mapping(address => uint256[]) public userReceipts;
    mapping(bytes32 => uint256) public contentTotalRevenue;
    mapping(address => uint256) public creatorEarnings;

    // --- Temporary shares ---
    mapping(bytes32 => TemporaryShare) public temporaryShares;
    mapping(address => bytes32[]) public userShares;

    // --- Config ---
    uint256 public minProjectGoal;
    uint256 public maxProjectDuration;
    uint256 public platformFeeRate; // bps

    // --- Stats ---
    uint256 public totalProjects;
    uint256 public totalProjectsFunded;
    uint256 public totalContents;

    /// @dev gap pour futurs upgrades
    uint256[35] private __gap;

    // ============================================================================
    // EVENTS
    // ============================================================================

    // Projects
    event ProjectCreated(uint256 indexed projectId, address indexed creator, uint256 fundingGoal, uint256 deadline);
    event ProjectFunded(uint256 indexed projectId, address indexed backer, uint256 amount);
    event ProjectCompleted(uint256 indexed projectId, uint256 totalFunded);
    event ProjectCancelled(uint256 indexed projectId);
    event ProjectRefunded(uint256 indexed projectId, address indexed backer, uint256 amount);
    event CreatorWithdrew(uint256 indexed projectId, address indexed creator, uint256 amount, uint256 platformFee);

    // Content
    event ContentRegistered(bytes32 indexed contentId, address indexed creator, uint256 price);
    event ContentPurchased(bytes32 indexed contentId, address indexed buyer, uint256 price);
    event ContentRented(bytes32 indexed contentId, address indexed renter, uint256 expiresAt);
    event ContentEarned(bytes32 indexed contentId, address indexed user, EarnConditionType condition);
    event CreatorEarningsWithdrawn(address indexed creator, uint256 amount);

    // Shares
    event TemporaryShareCreated(bytes32 indexed shareHash, bytes32 indexed fileHash, address indexed sharedWith, uint256 expiresAt);

    // Admin
    event CoreContractUpdated(address indexed oldCore, address indexed newCore);
    event EarnSignerUpdated(address indexed oldSigner, address indexed newSigner);
    event ProjectConfigUpdated(uint256 minGoal, uint256 maxDuration, uint256 feeRate);

    // ============================================================================
    // ERRORS
    // ============================================================================

    error ZeroAddress();
    error InvalidConfiguration();
    error InsufficientPayment(uint256 required, uint256 provided);
    error TransferFailed();
    error ProjectNotFound(uint256 projectId);
    error ProjectNotActive(uint256 projectId);
    error ProjectExpired(uint256 projectId);
    error RefundNotAvailable(uint256 projectId);
    error NoContributionToRefund(uint256 projectId, address backer);
    error NotProjectCreator(uint256 projectId);
    error NothingToWithdraw();
    error ContentNotFound(bytes32 contentId);
    error ContentNotAccessible(bytes32 contentId);
    error AlreadyPurchased(bytes32 contentId);
    error ContentAlreadyRegistered(bytes32 contentId);
    error InvalidSignature();
    error EarnSignatureExpired();
    error FeeRateTooHigh(uint256 requested, uint256 max);
    error TierTooLow(ILksCore.AccessTier required, ILksCore.AccessTier current);

    // ============================================================================
    // CONSTANTS
    // ============================================================================

    uint256 public constant MAX_PLATFORM_FEE_BPS = 3000; // 30 %

    /// @dev EIP-712 typehash : EarnAuthorization(address user,bytes32 contentId,uint8 condition,uint256 nonce,uint256 deadline)
    bytes32 public constant EARN_AUTHORIZATION_TYPEHASH = keccak256(
        "EarnAuthorization(address user,bytes32 contentId,uint8 condition,uint256 nonce,uint256 deadline)"
    );

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

    /**
     * @notice Initialise LksBusinessModule.
     * @param core_        Adresse de LksCoreUpgradeable déployé
     * @param admin        Adresse admin (deployer EOA avant audit externe)
     * @param earnSigner_  Adresse signer backend trusted pour earnContent EIP-712
     */
    function initialize(
        address core_,
        address admin,
        address earnSigner_
    ) external initializer {
        if (core_ == address(0) || admin == address(0) || earnSigner_ == address(0)) {
            revert ZeroAddress();
        }

        __UUPSUpgradeable_init();
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __EIP712_init("LksBusinessModule", "1");

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);

        coreContract = ILksCore(core_);
        earnSigner = earnSigner_;

        minProjectGoal    = 0.01 ether;
        maxProjectDuration = 90 days;
        platformFeeRate   = 500; // 5 %

        _nextProjectId  = 1;
        _nextReceiptId  = 1;

        emit CoreContractUpdated(address(0), core_);
        emit EarnSignerUpdated(address(0), earnSigner_);
    }

    // ============================================================================
    // CROWDFUNDING — PROJECTS
    // ============================================================================

    /**
     * @notice Créer un projet de crowdfunding
     * @dev    Ne requiert aucun tier minimum pour V7 (ouvert à tous avec identity liée côté front)
     */
    function createProject(
        string calldata title,
        bytes32 ipfsHash,
        uint256 fundingGoal,
        uint256 duration
    ) external whenNotPaused returns (uint256) {
        if (bytes(title).length == 0) revert InvalidConfiguration();
        if (fundingGoal < minProjectGoal) revert InvalidConfiguration();
        if (duration == 0 || duration > maxProjectDuration) revert InvalidConfiguration();

        uint256 projectId = _nextProjectId++;
        uint256 deadline = block.timestamp + duration;

        Project storage p = projects[projectId];
        p.creator = msg.sender;
        p.title = title;
        p.ipfsHash = ipfsHash;
        p.fundingGoal = fundingGoal;
        p.currentFunding = 0;
        p.deadline = deadline;
        p.status = ProjectStatus.ACTIVE;
        p.exists = true;
        p.creatorWithdrawn = 0;

        userProjects[msg.sender].push(projectId);
        totalProjects++;

        emit ProjectCreated(projectId, msg.sender, fundingGoal, deadline);
        return projectId;
    }

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

    function withdrawProjectFunds(uint256 projectId) external nonReentrant {
        Project storage project = projects[projectId];
        if (!project.exists) revert ProjectNotFound(projectId);
        if (project.creator != msg.sender) revert NotProjectCreator(projectId);
        if (project.status != ProjectStatus.FUNDED && project.status != ProjectStatus.COMPLETED) {
            revert ProjectNotActive(projectId);
        }

        uint256 available = project.currentFunding - project.creatorWithdrawn;
        if (available == 0) revert NothingToWithdraw();

        uint256 platformFee = (available * platformFeeRate) / 10_000;
        uint256 creatorAmount = available - platformFee;

        project.creatorWithdrawn += available;
        project.status = ProjectStatus.COMPLETED;

        (bool ok1, ) = payable(project.creator).call{value: creatorAmount}("");
        if (!ok1) revert TransferFailed();

        if (platformFee > 0) {
            address treasury = coreContract.protocolTreasury();
            (bool ok2, ) = payable(treasury).call{value: platformFee}("");
            if (!ok2) revert TransferFailed();
        }

        emit CreatorWithdrew(projectId, msg.sender, creatorAmount, platformFee);
    }

    function refundProject(uint256 projectId) external nonReentrant {
        Project storage project = projects[projectId];
        if (!project.exists) revert ProjectNotFound(projectId);

        bool isCancelled = project.status == ProjectStatus.CANCELLED;
        bool isExpiredNotFunded = block.timestamp >= project.deadline && project.status == ProjectStatus.ACTIVE;

        if (!isCancelled && !isExpiredNotFunded) revert RefundNotAvailable(projectId);

        uint256 contribution = contributions[projectId][msg.sender];
        if (contribution == 0) revert NoContributionToRefund(projectId, msg.sender);

        // Clear before transfer (reentrancy)
        contributions[projectId][msg.sender] = 0;
        project.currentFunding -= contribution;

        (bool ok, ) = payable(msg.sender).call{value: contribution}("");
        if (!ok) revert TransferFailed();

        emit ProjectRefunded(projectId, msg.sender, contribution);
    }

    function cancelProject(uint256 projectId) external {
        Project storage project = projects[projectId];
        if (!project.exists) revert ProjectNotFound(projectId);
        if (project.creator != msg.sender && !hasRole(ADMIN_ROLE, msg.sender)) {
            revert NotProjectCreator(projectId);
        }
        if (project.status != ProjectStatus.ACTIVE) revert ProjectNotActive(projectId);

        project.status = ProjectStatus.CANCELLED;
        emit ProjectCancelled(projectId);
    }

    // ============================================================================
    // CONTENT MONETIZATION
    // ============================================================================

    function registerContent(
        bytes32 contentId,
        ContentAccessType[] calldata accessTypes,
        uint256 price,
        uint256 rentalPrice,
        uint256 rentalDuration,
        uint256 resellRoyalty,
        EarnConditionType[] calldata earnConditions,
        bool requiresSubscription,
        ILksCore.AccessTier minSubscriptionTier
    ) external whenNotPaused {
        if (_contentConfigs[contentId].creator != address(0)) revert ContentAlreadyRegistered(contentId);
        if (accessTypes.length == 0) revert InvalidConfiguration();

        ContentConfig storage cfg = _contentConfigs[contentId];
        cfg.contentId = contentId;
        cfg.creator = msg.sender;
        cfg.accessTypes = accessTypes;
        cfg.isPaid = _hasAccessType(accessTypes, ContentAccessType.PAID);
        cfg.price = price;
        cfg.isResellable = price > 0;
        cfg.resellRoyalty = resellRoyalty;
        cfg.isEarnable = _hasAccessType(accessTypes, ContentAccessType.EARNED);
        cfg.earnConditions = earnConditions;
        cfg.isRentable = _hasAccessType(accessTypes, ContentAccessType.RENTAL);
        cfg.rentalPrice = rentalPrice;
        cfg.rentalDuration = rentalDuration;
        cfg.isTimeLimited = _hasAccessType(accessTypes, ContentAccessType.TIME_LIMITED);
        cfg.timeLimitDuration = 7 days;
        cfg.requiresSubscription = requiresSubscription;
        cfg.minSubscriptionTier = minSubscriptionTier;
        cfg.active = true;

        totalContents++;
        emit ContentRegistered(contentId, msg.sender, price);
    }

    function purchaseContent(bytes32 contentId) external payable nonReentrant whenNotPaused {
        ContentConfig storage cfg = _contentConfigs[contentId];
        if (cfg.creator == address(0)) revert ContentNotFound(contentId);
        if (!cfg.isPaid) revert ContentNotAccessible(contentId);
        if (userContentAccess[contentId][msg.sender].active) revert AlreadyPurchased(contentId);
        if (msg.value < cfg.price) revert InsufficientPayment(cfg.price, msg.value);

        // Gate par subscription si requise — cross-call Core
        if (cfg.requiresSubscription) {
            ILksCore.AccessTier userTier = coreContract.getTier(msg.sender);
            if (uint8(userTier) < uint8(cfg.minSubscriptionTier)) {
                revert TierTooLow(cfg.minSubscriptionTier, userTier);
            }
        }

        userContentAccess[contentId][msg.sender] = UserContentAccess({
            contentId: contentId,
            user: msg.sender,
            accessType: ContentAccessType.PAID,
            grantedAt: block.timestamp,
            expiresAt: 0,
            pricePaid: cfg.price,
            active: true,
            viewCount: 0
        });

        uint256 receiptId = _nextReceiptId++;
        contentReceipts[receiptId] = ContentReceipt({
            receiptId: receiptId,
            contentId: contentId,
            owner: msg.sender,
            purchasePrice: cfg.price,
            purchasedAt: block.timestamp,
            isResold: false,
            resaleCount: 0
        });
        userReceipts[msg.sender].push(receiptId);

        contentTotalRevenue[contentId] += cfg.price;
        creatorEarnings[cfg.creator] += cfg.price;

        // Refund excess via .call (LKS-BIZ-02)
        uint256 excess = msg.value - cfg.price;
        if (excess > 0) {
            (bool ok, ) = payable(msg.sender).call{value: excess}("");
            if (!ok) revert TransferFailed();
        }

        emit ContentPurchased(contentId, msg.sender, cfg.price);
    }

    function rentContent(bytes32 contentId) external payable nonReentrant whenNotPaused {
        ContentConfig storage cfg = _contentConfigs[contentId];
        if (cfg.creator == address(0)) revert ContentNotFound(contentId);
        if (!cfg.isRentable) revert ContentNotAccessible(contentId);
        if (msg.value < cfg.rentalPrice) revert InsufficientPayment(cfg.rentalPrice, msg.value);

        uint256 expiresAt = block.timestamp + cfg.rentalDuration;
        userContentAccess[contentId][msg.sender] = UserContentAccess({
            contentId: contentId,
            user: msg.sender,
            accessType: ContentAccessType.RENTAL,
            grantedAt: block.timestamp,
            expiresAt: expiresAt,
            pricePaid: cfg.rentalPrice,
            active: true,
            viewCount: 0
        });

        contentTotalRevenue[contentId] += cfg.rentalPrice;
        creatorEarnings[cfg.creator] += cfg.rentalPrice;

        uint256 excess = msg.value - cfg.rentalPrice;
        if (excess > 0) {
            (bool ok, ) = payable(msg.sender).call{value: excess}("");
            if (!ok) revert TransferFailed();
        }

        emit ContentRented(contentId, msg.sender, expiresAt);
    }

    /**
     * @notice Débloquer un contenu via condition vérifiée off-chain (signature EIP-712 backend)
     *         ou on-chain (cross-call vers LksSocialModule pour FOLLOW/REACH).
     * @dev    Approche hybride décidée en Q6 du plan.
     *         Pour les conditions qui peuvent être vérifiées on-chain, le backend signe quand même
     *         pour simplifier — le contrat accepte toutes les conditions via signature EIP-712.
     * @param contentId  Identifiant du contenu
     * @param condition  Type de condition earn
     * @param deadline   Timestamp d'expiration de la signature (anti-replay temporel)
     * @param signature  Signature EIP-712 du earnSigner
     */
    function earnContent(
        bytes32 contentId,
        EarnConditionType condition,
        uint256 deadline,
        bytes calldata signature
    ) external whenNotPaused {
        ContentConfig storage cfg = _contentConfigs[contentId];
        if (cfg.creator == address(0)) revert ContentNotFound(contentId);
        if (!cfg.isEarnable) revert ContentNotAccessible(contentId);
        if (block.timestamp > deadline) revert EarnSignatureExpired();

        // Vérifier signature EIP-712
        uint256 nonce = earnNonces[msg.sender]++;
        bytes32 structHash = keccak256(
            abi.encode(
                EARN_AUTHORIZATION_TYPEHASH,
                msg.sender,
                contentId,
                uint8(condition),
                nonce,
                deadline
            )
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        address recovered = ECDSA.recover(digest, signature);
        if (recovered != earnSigner) revert InvalidSignature();

        // Ne pas écraser un accès existant
        if (userContentAccess[contentId][msg.sender].active) revert AlreadyPurchased(contentId);

        userContentAccess[contentId][msg.sender] = UserContentAccess({
            contentId: contentId,
            user: msg.sender,
            accessType: ContentAccessType.EARNED,
            grantedAt: block.timestamp,
            expiresAt: 0,
            pricePaid: 0,
            active: true,
            viewCount: 0
        });

        emit ContentEarned(contentId, msg.sender, condition);
    }

    function checkContentAccess(
        bytes32 contentId,
        address user
    ) external view returns (bool hasAccess, ContentAccessType accessType, uint256 expiresAt) {
        ContentConfig storage cfg = _contentConfigs[contentId];

        if (_hasAccessType(cfg.accessTypes, ContentAccessType.FREE)) {
            return (true, ContentAccessType.FREE, 0);
        }

        if (cfg.creator == user) {
            return (true, ContentAccessType.FREE, 0);
        }

        UserContentAccess storage access = userContentAccess[contentId][user];
        if (access.active) {
            if (access.expiresAt == 0 || access.expiresAt > block.timestamp) {
                return (true, access.accessType, access.expiresAt);
            }
        }

        if (cfg.requiresSubscription) {
            ILksCore.AccessTier userTier = coreContract.getTier(user);
            if (uint8(userTier) >= uint8(cfg.minSubscriptionTier)) {
                return (true, ContentAccessType.SUBSCRIPTION, 0);
            }
        }

        return (false, ContentAccessType.FREE, 0);
    }

    function withdrawCreatorEarnings() external nonReentrant {
        uint256 earnings = creatorEarnings[msg.sender];
        if (earnings == 0) revert NothingToWithdraw();

        creatorEarnings[msg.sender] = 0;

        (bool ok, ) = payable(msg.sender).call{value: earnings}("");
        if (!ok) revert TransferFailed();

        emit CreatorEarningsWithdrawn(msg.sender, earnings);
    }

    function getContentConfig(bytes32 contentId) external view returns (ContentConfig memory) {
        return _contentConfigs[contentId];
    }

    // ============================================================================
    // TEMPORARY SHARES
    // ============================================================================

    function createTemporaryShare(
        bytes32 fileHash,
        address sharedWith,
        uint256 duration,
        bool isPaid,
        uint256 price
    ) external payable whenNotPaused returns (bytes32) {
        if (sharedWith == address(0)) revert ZeroAddress();
        if (duration == 0) revert InvalidConfiguration();
        if (isPaid && msg.value < price) revert InsufficientPayment(price, msg.value);

        bytes32 shareHash = keccak256(abi.encode(fileHash, sharedWith, msg.sender, block.timestamp));

        temporaryShares[shareHash] = TemporaryShare({
            fileHash: fileHash,
            sharedWith: sharedWith,
            expiresAt: block.timestamp + duration,
            isPaid: isPaid,
            price: isPaid ? msg.value : 0,
            used: false
        });

        userShares[sharedWith].push(shareHash);
        emit TemporaryShareCreated(shareHash, fileHash, sharedWith, block.timestamp + duration);
        return shareHash;
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

    function setEarnSigner(address newSigner) external onlyRole(ADMIN_ROLE) {
        if (newSigner == address(0)) revert ZeroAddress();
        address old = earnSigner;
        earnSigner = newSigner;
        emit EarnSignerUpdated(old, newSigner);
    }

    function setProjectConfig(
        uint256 newMinGoal,
        uint256 newMaxDuration,
        uint256 newFeeRate
    ) external onlyRole(ADMIN_ROLE) {
        if (newFeeRate > MAX_PLATFORM_FEE_BPS) revert FeeRateTooHigh(newFeeRate, MAX_PLATFORM_FEE_BPS);
        minProjectGoal = newMinGoal;
        maxProjectDuration = newMaxDuration;
        platformFeeRate = newFeeRate;
        emit ProjectConfigUpdated(newMinGoal, newMaxDuration, newFeeRate);
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

    function _hasAccessType(
        ContentAccessType[] memory types,
        ContentAccessType target
    ) private pure returns (bool) {
        uint256 len = types.length;
        for (uint256 i = 0; i < len; ) {
            if (types[i] == target) return true;
            unchecked { ++i; }
        }
        return false;
    }

    // ============================================================================
    // UUPS
    // ============================================================================

    function _authorizeUpgrade(address newImpl) internal override onlyRole(UPGRADER_ROLE) {}

    /// @notice Permet au contrat de recevoir de l'ETH (pour les refunds/contributions entrants)
    receive() external payable {}
}
