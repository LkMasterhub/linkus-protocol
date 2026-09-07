// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// =============================================================================
// LksFeeSim.sol — Reference simulator for fee splits
//
// Couvre :
// - Content1155.purchase : msg.value → creatorShare + platformFee
// - BusinessV8.withdrawFunds : project.raised → creatorAmount + platformFee
// - ERC2981 royalty : salePrice * royaltyBps / 10000
//
// Règle de rounding identique à LksTipSim : platformFee = floor, le reste
// va à l'acteur principal (créateur ou vendeur).
// =============================================================================

library LksFeeSim {
    uint16 internal constant BPS_DENOMINATOR = 10_000;

    /// @notice Split d'un paiement en (mainShare, platformFee).
    /// @dev Utilisé par Content1155.purchase et BusinessV8.withdrawFunds.
    function feeSplit(uint256 amount, uint16 platformFeeBps)
        internal
        pure
        returns (uint256 mainShare, uint256 platformFee)
    {
        platformFee = (amount * platformFeeBps) / BPS_DENOMINATOR;
        mainShare = amount - platformFee;
    }

    /// @notice Calcul ERC2981 royalty pour une vente secondaire.
    /// @return royaltyAmount Montant à reverser au créateur original.
    function royaltyAmount(uint256 salePrice, uint16 royaltyBps)
        internal
        pure
        returns (uint256)
    {
        return (salePrice * royaltyBps) / BPS_DENOMINATOR;
    }
}
