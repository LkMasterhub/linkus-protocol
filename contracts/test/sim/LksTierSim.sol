// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// =============================================================================
// LksTierSim.sol — Reference simulator for Tier1155 expiry & refund math
//
// Couvre :
// - subscribe : nouvelle expiry = max(now, current) + duration
// - cancelAndRefund : refund = paid * remainingSeconds / totalDuration
//
// Le rounding se fait floor() — l'utilisateur perd le résiduel sub-second
// (négligeable, et empêche tout exploit du rounding contre le contrat).
// =============================================================================

library LksTierSim {
    /// @notice Calcule la nouvelle expiry après subscribe.
    /// @param currentExpiry Expiry actuelle (0 si jamais souscrit).
    /// @param nowTs Timestamp actuel.
    /// @param duration Durée de la nouvelle période en secondes.
    function newExpiry(uint64 currentExpiry, uint64 nowTs, uint64 duration)
        internal
        pure
        returns (uint64)
    {
        uint64 base = currentExpiry > nowTs ? currentExpiry : nowTs;
        return base + duration;
    }

    /// @notice Refund proportionnel au temps restant.
    /// @param paid Montant payé pour la période en cours.
    /// @param subscriptionStart Timestamp du début de la période actuelle.
    /// @param expiresAt Timestamp d'expiration prévue.
    /// @param nowTs Timestamp actuel (au moment du cancel).
    /// @return refunded Montant à rembourser. Zero si déjà expiré ou nowTs >= expiresAt.
    function refund(
        uint256 paid,
        uint64 subscriptionStart,
        uint64 expiresAt,
        uint64 nowTs
    ) internal pure returns (uint256 refunded) {
        if (nowTs >= expiresAt) return 0;
        if (expiresAt <= subscriptionStart) return 0; // garde-fou logique
        if (nowTs <= subscriptionStart) return paid; // pas encore démarrée → full refund
        uint256 totalDuration = uint256(expiresAt - subscriptionStart);
        uint256 remaining = uint256(expiresAt - nowTs);
        refunded = (paid * remaining) / totalDuration;
    }
}
