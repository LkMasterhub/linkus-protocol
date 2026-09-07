// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ILksCore
 * @notice Interface publique de LksCoreUpgradeable.
 *         Utilisée par LksBusinessModule et LksSocialModule pour lire l'état
 *         utilisateur et, pour Social, écrire la réputation.
 * @dev    Architecture Core + Modules issue de la refonte V7.
 */
interface ILksCore {
    // ============================================================================
    // ENUMS
    // ============================================================================

    enum AccessTier {
        NONE,        // 0 — pas d'abonnement
        BASIC,       // 1 — tier d'entrée (trial gratuit ou payant)
        STANDARD,    // 2
        PREMIUM,     // 3
        ENTERPRISE   // 4
    }

    enum SubscriptionState {
        INACTIVE,  // 0 — jamais souscrit
        TRIAL,     // 1 — en période d'essai
        ACTIVE,    // 2 — abonnement payé et actif
        EXPIRED,   // 3 — expiré, non renouvelé
        CANCELLED  // 4 — annulé par l'utilisateur
    }

    // ============================================================================
    // STRUCTS
    // ============================================================================

    struct TierConfig {
        uint256 monthlyPrice;     // wei par mois
        uint256 reputationBonus;  // bonus multiplier pour la réputation (bps)
        bool active;              // tier disponible à la souscription
    }

    struct UserState {
        AccessTier tier;
        SubscriptionState subState;
        uint256 expiresAt;          // timestamp d'expiration de la subscription
        uint256 reputation;         // score réputation cumulé
        uint256 trialUsedAt;        // timestamp du dernier claim trial (0 si jamais)
        uint256 autoRenewAllowance; // fonds prépayés pour futurs renouvellements
        uint256 autoRenewDeposit;   // dépôt de sécurité pour auto-renew
        bool autoRenewEnabled;
    }

    // ============================================================================
    // EVENTS
    // ============================================================================

    event ContractUpdated(bytes32 indexed role, address indexed oldAddr, address indexed newAddr);
    event TierConfigUpdated(AccessTier indexed tier, uint256 monthlyPrice, uint256 reputationBonus, bool active);
    event TrialClaimed(address indexed user, uint256 expiresAt);
    event Subscribed(address indexed user, AccessTier indexed tier, uint256 paidAmount, uint256 expiresAt);
    event Renewed(address indexed user, AccessTier indexed tier, uint256 expiresAt);
    event SubscriptionCancelled(address indexed user, uint256 refundedAllowance);
    event AutoRenewEnabled(address indexed user, uint256 allowance, uint256 deposit);
    event AutoRenewDisabled(address indexed user, uint256 refundedAllowance);
    event DepositRefunded(address indexed user, uint256 amount);
    event ReputationAdded(address indexed user, uint256 amount, uint256 newTotal);
    event ReputationRemoved(address indexed user, uint256 amount, uint256 newTotal);
    event TreasuryWithdrawn(address indexed recipient, uint256 amount);
    event PlatformFeeRateUpdated(uint256 oldRate, uint256 newRate);
    event ProtocolTreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    // ============================================================================
    // REGISTRY
    // ============================================================================

    function setContract(bytes32 role, address addr) external;
    function getContract(bytes32 role) external view returns (address);

    // ============================================================================
    // USER STATE (views)
    // ============================================================================

    function getUserState(address user) external view returns (UserState memory);
    function getTier(address user) external view returns (AccessTier);
    function getReputation(address user) external view returns (uint256);
    function isSubscriptionActive(address user) external view returns (bool);
    function tierConfigs(AccessTier tier) external view returns (TierConfig memory);
    function platformFeeRate() external view returns (uint256);
    function protocolTreasury() external view returns (address);

    // ============================================================================
    // SUBSCRIPTION
    // ============================================================================

    function claimTrial() external;
    function subscribe(AccessTier tier) external payable;
    function renew() external payable;
    function cancelSubscription() external;
    function enableAutoRenew() external payable;
    function disableAutoRenew() external;
    function refundDeposit() external;

    // ============================================================================
    // REPUTATION (cross-module writes)
    // ============================================================================

    function addReputation(address user, uint256 amount) external;
    function removeReputation(address user, uint256 amount) external;

    // ============================================================================
    // ADMIN
    // ============================================================================

    function setTierConfig(AccessTier tier, TierConfig calldata config) external;
    function setPlatformFeeRate(uint256 bps) external;
    function setProtocolTreasury(address treasury) external;
    function withdrawTreasury(uint256 amount) external;
    function pause() external;
    function unpause() external;
}
