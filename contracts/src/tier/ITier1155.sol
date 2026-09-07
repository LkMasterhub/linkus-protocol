// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ITier1155
 * @notice Subscription tiers comme tokens ERC1155 soulbound.
 *
 * Token IDs : 1=BASIC, 2=PREMIUM, 3=PRO. Un utilisateur ne peut détenir
 * qu'au plus 1 token par tierId. Soulbound = `safeTransferFrom` revert.
 *
 * Pattern subscribe :
 * - subscribe(tierId) avec msg.value >= price → mint 1 token + set expiry
 * - re-subscribe étend l'expiry : `expiresAt = max(now, current) + duration`
 * - cancelAndRefund() : burn token + refund proportionnel au temps restant
 *
 * Invariants protégés :
 * - balanceOf(user, tierId) <= 1 toujours
 * - balanceOf > 0 ⇒ expiresAt[user][tierId] > 0
 * - safeTransferFrom revert toujours (soulbound)
 */
interface ITier1155 {
    // ─────────────────────────────────────────────────────────────────
    // Types
    // ─────────────────────────────────────────────────────────────────

    struct TierConfig {
        uint128 price; // wei par période
        uint64 duration; // secondes par période (ex: 30 days)
        uint96 maxSupply; // 0 = unlimited
        bool active; // true = subscriptions ouvertes
    }

    // ─────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────

    function TIER_BASIC() external view returns (uint256);
    function TIER_PREMIUM() external view returns (uint256);
    function TIER_PRO() external view returns (uint256);

    // ─────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────

    event Subscribed(
        address indexed user,
        uint256 indexed tierId,
        uint64 expiresAt,
        uint256 paid
    );
    event Cancelled(address indexed user, uint256 indexed tierId, uint256 refunded);
    event TierConfigUpdated(uint256 indexed tierId, TierConfig config);
    event TierActiveSet(uint256 indexed tierId, bool active);

    // ─────────────────────────────────────────────────────────────────
    // Reads
    // ─────────────────────────────────────────────────────────────────

    /// @notice True si l'utilisateur a un token actif pour ce tierId.
    function isActive(address user, uint256 tierId) external view returns (bool);

    /// @notice Date d'expiration du tier pour l'utilisateur (0 si jamais souscrit).
    function expiresAt(address user, uint256 tierId) external view returns (uint64);

    /// @notice Configuration d'un tier.
    function tierConfig(uint256 tierId) external view returns (TierConfig memory);

    /// @notice Total de tokens en circulation pour ce tier.
    function totalSupply(uint256 tierId) external view returns (uint256);

    // ─────────────────────────────────────────────────────────────────
    // User flows
    // ─────────────────────────────────────────────────────────────────

    /// @notice Souscrire ou étendre un tier. msg.value doit >= config.price.
    /// @dev Excès remboursé. expiresAt = max(now, current) + duration.
    function subscribe(uint256 tierId) external payable;

    /// @notice Annuler et obtenir un refund proportionnel.
    /// @return refunded Montant remboursé en wei.
    function cancelAndRefund(uint256 tierId) external returns (uint256 refunded);

    // ─────────────────────────────────────────────────────────────────
    // Admin (TIMELOCK)
    // ─────────────────────────────────────────────────────────────────

    function setTierConfig(uint256 tierId, TierConfig calldata config) external;
    function setTierActive(uint256 tierId, bool active) external;
    function pause() external;
    function unpause() external;
}
