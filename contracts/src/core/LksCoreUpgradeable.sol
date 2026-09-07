// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import "./ILksCore.sol";

/**
 * @title  LksCoreUpgradeable
 * @author LinkUs Protocol V7 refonte (2026-04-06)
 * @notice Source unique de vérité pour tiers, réputation, subscription, pause globale
 *         et registry d'adresses des modules. Remplace LksSubscriptionUpgradeable (fusionné)
 *         et centralise des mappings précédemment dupliqués dans LksBusiness et LksSocial.
 *
 * @dev    Architecture Core + Modules :
 *           LksCore ◄── LksBusinessModule (lit tier, gating)
 *                 ◄── LksSocialModule   (lit tier, écrit réputation via SOCIAL_WRITER)
 *
 *         Findings V6 résolus dans ce contrat :
 *           - LKS-SUB-01 : cancelSubscription() rembourse autoRenewAllowance
 *           - LKS-SUB-02 : refundDeposit() lit la réputation on-chain, pas en paramètre
 *           - LKS-BIZ-07 : withdrawTreasury() présent
 *           - LKS-BIZ-02 : refunds ETH via .call (pas .transfer stipend 2300)
 *
 * @custom:security-contact security@linkus-protocol.io
 */
contract LksCoreUpgradeable is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    ILksCore
{
    // ============================================================================
    // ROLES
    // ============================================================================

    bytes32 public constant ADMIN_ROLE      = keccak256("ADMIN_ROLE");
    bytes32 public constant PAUSER_ROLE     = keccak256("PAUSER_ROLE");
    bytes32 public constant UPGRADER_ROLE   = keccak256("UPGRADER_ROLE");
    bytes32 public constant REGISTRY_ADMIN  = keccak256("REGISTRY_ADMIN");
    bytes32 public constant SOCIAL_WRITER   = keccak256("SOCIAL_WRITER");
    bytes32 public constant BUSINESS_WRITER = keccak256("BUSINESS_WRITER");

    // ============================================================================
    // CONSTANTS
    // ============================================================================

    uint256 public constant TRIAL_DURATION            = 7 days;
    uint256 public constant SUBSCRIPTION_DURATION     = 30 days;
    uint256 public constant MIN_REPUTATION_FOR_REFUND = 100;
    uint256 public constant AUTO_RENEW_DEPOSIT        = 0.01 ether;
    uint256 public constant MAX_PLATFORM_FEE_BPS      = 3000; // 30 %

    // ============================================================================
    // STORAGE — REGISTRY
    // ============================================================================

    mapping(bytes32 => address) private _contracts;

    // ============================================================================
    // STORAGE — TIER CONFIG
    // ============================================================================

    mapping(AccessTier => TierConfig) private _tierConfigs;

    uint256 public override platformFeeRate;    // bps (10000 = 100%)
    address public override protocolTreasury;

    // ============================================================================
    // STORAGE — USER STATE
    // ============================================================================

    mapping(address => UserState) internal userStates;

    // ============================================================================
    // STORAGE GAP
    // ============================================================================

    /// @dev gap pour futurs upgrades (40 slots)
    uint256[40] private __gap;

    // ============================================================================
    // ERRORS
    // ============================================================================

    error ZeroAddress();
    error InvalidTier();
    error TierInactive();
    error InvalidPayment(uint256 required, uint256 provided);
    error TrialAlreadyUsed();
    error NoActiveSubscription();
    error AlreadyCancelled();
    error NotCancelled();
    error InsufficientReputation(uint256 required, uint256 actual);
    error AutoRenewAlreadyEnabled();
    error AutoRenewNotEnabled();
    error InsufficientBalance(uint256 requested, uint256 available);
    error RefundFailed();
    error FeeRateTooHigh(uint256 requested, uint256 max);
    error DepositAlreadyRefunded();
    error ReputationUnderflow(uint256 current, uint256 amount);

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
     * @notice Initialise LksCore.
     * @param admin    Adresse qui reçoit tous les rôles admin (deployer EOA avant audit externe)
     * @param treasury Adresse du treasury qui reçoit les fees
     */
    function initialize(address admin, address treasury) external initializer {
        if (admin == address(0) || treasury == address(0)) revert ZeroAddress();

        __UUPSUpgradeable_init();
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        _grantRole(REGISTRY_ADMIN, admin);

        protocolTreasury = treasury;
        platformFeeRate = 500; // 5 % default

        emit ProtocolTreasuryUpdated(address(0), treasury);
        emit PlatformFeeRateUpdated(0, 500);
    }

    // ============================================================================
    // REGISTRY
    // ============================================================================

    function setContract(bytes32 role, address addr) external override onlyRole(REGISTRY_ADMIN) {
        if (addr == address(0)) revert ZeroAddress();
        address old = _contracts[role];
        _contracts[role] = addr;
        emit ContractUpdated(role, old, addr);
    }

    function getContract(bytes32 role) external view override returns (address) {
        return _contracts[role];
    }

    // ============================================================================
    // USER STATE (views)
    // ============================================================================

    function getUserState(address user) external view override returns (UserState memory) {
        return userStates[user];
    }

    function getTier(address user) external view override returns (AccessTier) {
        UserState memory s = userStates[user];
        if (_isActive(s)) return s.tier;
        return AccessTier.NONE;
    }

    function getReputation(address user) external view override returns (uint256) {
        return userStates[user].reputation;
    }

    function isSubscriptionActive(address user) external view override returns (bool) {
        return _isActive(userStates[user]);
    }

    function tierConfigs(AccessTier tier) external view override returns (TierConfig memory) {
        return _tierConfigs[tier];
    }

    // ============================================================================
    // SUBSCRIPTION — CORE LOGIC
    // ============================================================================

    /**
     * @notice Active un trial gratuit de 7 jours au tier BASIC.
     * @dev    Ne peut être appelé qu'une seule fois par adresse (trialUsedAt > 0 bloque).
     */
    function claimTrial() external override nonReentrant whenNotPaused {
        UserState storage s = userStates[msg.sender];
        if (s.trialUsedAt != 0) revert TrialAlreadyUsed();

        s.tier = AccessTier.BASIC;
        s.subState = SubscriptionState.TRIAL;
        s.expiresAt = block.timestamp + TRIAL_DURATION;
        s.trialUsedAt = block.timestamp;

        emit TrialClaimed(msg.sender, s.expiresAt);
    }

    /**
     * @notice Souscrit à un tier. msg.value doit être >= monthlyPrice du tier.
     *         Le surplus est refundé via .call (LKS-BIZ-02).
     */
    function subscribe(AccessTier tier) external payable override nonReentrant whenNotPaused {
        if (tier == AccessTier.NONE) revert InvalidTier();
        TierConfig memory cfg = _tierConfigs[tier];
        if (!cfg.active) revert TierInactive();
        if (msg.value < cfg.monthlyPrice) revert InvalidPayment(cfg.monthlyPrice, msg.value);

        UserState storage s = userStates[msg.sender];
        s.tier = tier;
        s.subState = SubscriptionState.ACTIVE;
        s.expiresAt = block.timestamp + SUBSCRIPTION_DURATION;

        // Refund du surplus (.call, pas .transfer)
        uint256 excess = msg.value - cfg.monthlyPrice;
        if (excess > 0) {
            (bool ok, ) = payable(msg.sender).call{value: excess}("");
            if (!ok) revert RefundFailed();
        }

        emit Subscribed(msg.sender, tier, cfg.monthlyPrice, s.expiresAt);
    }

    /**
     * @notice Renouvelle la subscription existante pour SUBSCRIPTION_DURATION supplémentaire.
     *         msg.value >= monthlyPrice du tier actuel.
     */
    function renew() external payable override nonReentrant whenNotPaused {
        UserState storage s = userStates[msg.sender];
        if (s.tier == AccessTier.NONE) revert NoActiveSubscription();
        TierConfig memory cfg = _tierConfigs[s.tier];
        if (!cfg.active) revert TierInactive();
        if (msg.value < cfg.monthlyPrice) revert InvalidPayment(cfg.monthlyPrice, msg.value);

        // Extension depuis max(now, expiresAt) pour gérer les renouvellements anticipés
        uint256 base = s.expiresAt > block.timestamp ? s.expiresAt : block.timestamp;
        s.expiresAt = base + SUBSCRIPTION_DURATION;
        s.subState = SubscriptionState.ACTIVE;

        uint256 excess = msg.value - cfg.monthlyPrice;
        if (excess > 0) {
            (bool ok, ) = payable(msg.sender).call{value: excess}("");
            if (!ok) revert RefundFailed();
        }

        emit Renewed(msg.sender, s.tier, s.expiresAt);
    }

    /**
     * @notice Annule la subscription et rembourse l'autoRenewAllowance.
     * @dev    LKS-SUB-01 : le refund était manquant en V6, causant le vol du deposit.
     *         Le autoRenewDeposit reste verrouillé (récupérable via refundDeposit si reputation OK).
     */
    function cancelSubscription() external override nonReentrant {
        UserState storage s = userStates[msg.sender];
        if (s.subState == SubscriptionState.CANCELLED || s.subState == SubscriptionState.INACTIVE) {
            revert AlreadyCancelled();
        }

        uint256 refund = s.autoRenewAllowance;
        s.autoRenewAllowance = 0;
        s.autoRenewEnabled = false;
        s.subState = SubscriptionState.CANCELLED;

        if (refund > 0) {
            (bool ok, ) = payable(msg.sender).call{value: refund}("");
            if (!ok) revert RefundFailed();
        }

        emit SubscriptionCancelled(msg.sender, refund);
    }

    /**
     * @notice Active l'auto-renew. msg.value >= AUTO_RENEW_DEPOSIT, surplus va dans allowance.
     */
    function enableAutoRenew() external payable override nonReentrant whenNotPaused {
        UserState storage s = userStates[msg.sender];
        if (s.autoRenewEnabled) revert AutoRenewAlreadyEnabled();

        // Premier enable : exige le deposit complet
        if (s.autoRenewDeposit < AUTO_RENEW_DEPOSIT) {
            uint256 missing = AUTO_RENEW_DEPOSIT - s.autoRenewDeposit;
            if (msg.value < missing) revert InvalidPayment(missing, msg.value);
            s.autoRenewDeposit = AUTO_RENEW_DEPOSIT;
            s.autoRenewAllowance += (msg.value - missing);
        } else {
            // Deposit déjà payé précédemment — tout va dans l'allowance
            s.autoRenewAllowance += msg.value;
        }
        s.autoRenewEnabled = true;

        emit AutoRenewEnabled(msg.sender, s.autoRenewAllowance, s.autoRenewDeposit);
    }

    /**
     * @notice Désactive l'auto-renew et rembourse l'autoRenewAllowance.
     *         Le deposit reste verrouillé (récupérable via refundDeposit).
     */
    function disableAutoRenew() external override nonReentrant {
        UserState storage s = userStates[msg.sender];
        if (!s.autoRenewEnabled) revert AutoRenewNotEnabled();

        uint256 refund = s.autoRenewAllowance;
        s.autoRenewAllowance = 0;
        s.autoRenewEnabled = false;

        if (refund > 0) {
            (bool ok, ) = payable(msg.sender).call{value: refund}("");
            if (!ok) revert RefundFailed();
        }

        emit AutoRenewDisabled(msg.sender, refund);
    }

    /**
     * @notice Rembourse le autoRenewDeposit si la reputation de l'appelant >= MIN_REPUTATION.
     * @dev    LKS-SUB-02 : la reputation est lue depuis le state on-chain, pas passée en param.
     */
    function refundDeposit() external override nonReentrant {
        UserState storage s = userStates[msg.sender];
        if (s.autoRenewDeposit == 0) revert DepositAlreadyRefunded();
        if (s.reputation < MIN_REPUTATION_FOR_REFUND) {
            revert InsufficientReputation(MIN_REPUTATION_FOR_REFUND, s.reputation);
        }

        uint256 amount = s.autoRenewDeposit;
        s.autoRenewDeposit = 0;

        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        if (!ok) revert RefundFailed();

        emit DepositRefunded(msg.sender, amount);
    }

    // ============================================================================
    // REPUTATION (cross-module writes)
    // ============================================================================

    function addReputation(address user, uint256 amount) external override onlyRole(SOCIAL_WRITER) {
        if (user == address(0)) revert ZeroAddress();
        UserState storage s = userStates[user];
        s.reputation += amount;
        emit ReputationAdded(user, amount, s.reputation);
    }

    function removeReputation(address user, uint256 amount) external override onlyRole(SOCIAL_WRITER) {
        if (user == address(0)) revert ZeroAddress();
        UserState storage s = userStates[user];
        if (s.reputation < amount) revert ReputationUnderflow(s.reputation, amount);
        s.reputation -= amount;
        emit ReputationRemoved(user, amount, s.reputation);
    }

    // ============================================================================
    // ADMIN
    // ============================================================================

    function setTierConfig(AccessTier tier, TierConfig calldata config) external override onlyRole(ADMIN_ROLE) {
        if (tier == AccessTier.NONE) revert InvalidTier();
        _tierConfigs[tier] = config;
        emit TierConfigUpdated(tier, config.monthlyPrice, config.reputationBonus, config.active);
    }

    function setPlatformFeeRate(uint256 bps) external override onlyRole(ADMIN_ROLE) {
        if (bps > MAX_PLATFORM_FEE_BPS) revert FeeRateTooHigh(bps, MAX_PLATFORM_FEE_BPS);
        uint256 old = platformFeeRate;
        platformFeeRate = bps;
        emit PlatformFeeRateUpdated(old, bps);
    }

    function setProtocolTreasury(address treasury) external override onlyRole(ADMIN_ROLE) {
        if (treasury == address(0)) revert ZeroAddress();
        address old = protocolTreasury;
        protocolTreasury = treasury;
        emit ProtocolTreasuryUpdated(old, treasury);
    }

    /**
     * @notice Transfert `amount` wei du contrat vers protocolTreasury.
     * @dev    LKS-BIZ-07 : la V6 n'avait pas de withdraw — ETH reçu via subscribe() était verrouillé.
     */
    function withdrawTreasury(uint256 amount) external override onlyRole(ADMIN_ROLE) nonReentrant {
        uint256 bal = address(this).balance;
        if (amount > bal) revert InsufficientBalance(amount, bal);

        (bool ok, ) = payable(protocolTreasury).call{value: amount}("");
        if (!ok) revert RefundFailed();

        emit TreasuryWithdrawn(protocolTreasury, amount);
    }

    function pause() external override onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external override onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // ============================================================================
    // INTERNAL HELPERS
    // ============================================================================

    function _isActive(UserState memory s) internal view returns (bool) {
        if (s.tier == AccessTier.NONE) return false;
        if (s.expiresAt < block.timestamp) return false;
        if (s.subState != SubscriptionState.TRIAL && s.subState != SubscriptionState.ACTIVE) return false;
        return true;
    }

    // ============================================================================
    // UUPS
    // ============================================================================

    function _authorizeUpgrade(address newImpl) internal override onlyRole(UPGRADER_ROLE) {
        // Guard only
    }

    // ============================================================================
    // RECEIVE / FALLBACK
    // ============================================================================

    /// @notice Permet au contrat de recevoir de l'ETH (pour les refunds entrants).
    receive() external payable {}
}
