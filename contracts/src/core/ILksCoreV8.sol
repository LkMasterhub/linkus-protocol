// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ILksCoreV8
 * @notice Hub central V8 : registry des modules + tiers (lus depuis Tier1155)
 *         + reputation + pause globale.
 *
 * Différences vs V7 LksCoreUpgradeable :
 * - Plus de fusion subscription en interne — déléguée à LksTier1155
 * - `getTier(user)` lit `LksTier1155.balanceOf` via registry
 * - reputation reste on-chain (mais plus d'addReputation cross-contract via
 *   SOCIAL_WRITER/BUSINESS_WRITER ; les modules off-chain Rust signent les
 *   ReputationEvents qui sont anchorées par la governance)
 * - Storage packed (TierData : tier u8 + expiry u48 + reputation u96 = 1 slot)
 */
interface ILksCoreV8 {
    // ─────────────────────────────────────────────────────────────────
    // Types
    // ─────────────────────────────────────────────────────────────────

    /// @dev Packed dans 1 slot : 8+48+96+8 = 160 bits.
    struct TierData {
        uint8 tier; // 0=NONE, 1=BASIC, 2=PREMIUM, 3=PRO
        uint48 expiry; // unix seconds, 0 si NONE
        uint96 reputation; // capped par reputationCap
        bool flagged; // shadow-ban
    }

    // ─────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────

    event TierUpdated(address indexed user, uint8 tier, uint48 expiry);
    event ReputationChanged(address indexed user, uint96 before_, uint96 after_);
    event ModuleRegistered(bytes32 indexed key, address module);
    event ReputationCapSet(address indexed user, uint256 cap);
    event Flagged(address indexed user, bool flagged);
    event TreasuryUpdated(address indexed treasury);

    // ─────────────────────────────────────────────────────────────────
    // Reads
    // ─────────────────────────────────────────────────────────────────

    /// @notice Tier actif de l'utilisateur (lit Tier1155 via registry).
    /// @return tier 0=NONE, 1=BASIC, 2=PREMIUM, 3=PRO
    function getTier(address user) external view returns (uint8 tier);

    /// @notice Reputation actuelle (capped).
    function getReputation(address user) external view returns (uint96);

    /// @notice État utilisateur complet packé.
    function getUserState(address user) external view returns (TierData memory);

    /// @notice Adresse d'un module enregistré (ex: TIER1155, CONTENT1155).
    function getModule(bytes32 key) external view returns (address);

    /// @notice Cap de reputation configuré (par défaut MAX_REP).
    function reputationCap(address user) external view returns (uint256);

    /// @notice Adresse du treasury (recipient des fees plateforme globales).
    function treasury() external view returns (address);

    // ─────────────────────────────────────────────────────────────────
    // Writes (WRITER_ROLE)
    // ─────────────────────────────────────────────────────────────────

    /// @notice Ajoute de la reputation à un utilisateur (capped).
    function addReputation(address user, uint96 delta) external;

    /// @notice Soustrait de la reputation (saturate à 0).
    function slashReputation(address user, uint96 delta) external;

    /// @notice Flag un utilisateur (shadow-ban).
    function flag(address user, bool value) external;

    // ─────────────────────────────────────────────────────────────────
    // Admin (REGISTRY_ADMIN, TIMELOCK)
    // ─────────────────────────────────────────────────────────────────

    /// @notice Enregistre un module dans le registry.
    /// @dev Revert si déjà enregistré (use updateModule via timelock pour replace).
    function registerModule(bytes32 key, address module) external;

    /// @notice Set le cap de reputation pour un utilisateur.
    function setReputationCap(address user, uint256 cap) external;

    /// @notice Modifier le treasury.
    function setTreasury(address newTreasury) external;

    /// @notice Pause globale (PAUSER_ROLE).
    function pause() external;
    function unpause() external;
}
