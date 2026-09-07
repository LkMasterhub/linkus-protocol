// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// =============================================================================
// LksTipSim.sol — Reference simulator for tip splits
//
// Formule canonique : split d'un tip ETH en authorShare + platformFee selon
// un taux feeBps. Cette library est Solidity-pure et déterministe — utilisée
// dans les tests comme référence pour assertEq() avec la valeur réelle
// retournée par LksTipVault.
//
// Règle de rounding : platformFee = floor(amount * feeBps / 10000)
//                     authorShare = amount - platformFee
// (le créateur récolte le rounding différentiel, jamais la plateforme)
// =============================================================================

library LksTipSim {
    uint16 internal constant BPS_DENOMINATOR = 10_000;

    /// @notice Split un tip en (authorShare, platformFee).
    /// @param amount Total tip envoyé en wei.
    /// @param feeBps Taux fee plateforme en basis points (ex: 250 = 2.5%).
    function split(uint256 amount, uint16 feeBps)
        internal
        pure
        returns (uint256 authorShare, uint256 platformFee)
    {
        platformFee = (amount * feeBps) / BPS_DENOMINATOR;
        authorShare = amount - platformFee;
    }

    /// @notice Total accumulé après N tips (vérification cumulative).
    /// @param amounts Array des montants tipped.
    /// @param feeBps Taux fee plateforme constant pendant la période.
    /// @return totalAuthor Sum des authorShare.
    /// @return totalFees Sum des platformFee.
    function aggregate(uint256[] memory amounts, uint16 feeBps)
        internal
        pure
        returns (uint256 totalAuthor, uint256 totalFees)
    {
        uint256 n = amounts.length;
        for (uint256 i; i < n; ) {
            (uint256 a, uint256 f) = split(amounts[i], feeBps);
            totalAuthor += a;
            totalFees += f;
            unchecked { ++i; }
        }
    }
}
