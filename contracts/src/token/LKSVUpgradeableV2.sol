// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./LKSVUpgradeable.sol";

/**
 * @title LKSVUpgradeableV2 - Version avec fix pour rewardReserve
 * @notice Ajoute une fonction pour corriger la rewardReserve
 */
contract LKSVUpgradeableV2 is LKSVUpgradeable {

    /// @notice Version du contrat
    function version() external pure virtual returns (string memory) {
        return "2.0.0";
    }

    /**
     * @notice Corrige la rewardReserve en ajoutant les tokens déjà dans le contrat
     * @dev Utilisé pour corriger les tokens envoyés directement sans fundRewards()
     * @param amount Montant à ajouter à la rewardReserve
     */
    function fixRewardReserve(uint256 amount) external onlyOwner {
        uint256 currentBalance = lkstToken.balanceOf(address(this));
        uint256 currentTotalAssets = totalAssets();

        // S'assurer qu'on ne dépasse pas le solde disponible
        require(amount <= currentTotalAssets, "Amount exceeds available balance");

        rewardReserve += amount;

        emit RewardsFunded(amount, rewardReserve);
    }

    /**
     * @notice Définit directement la rewardReserve (pour correction initiale)
     * @dev À utiliser avec précaution - uniquement pour corriger l'état initial
     * @param amount Nouvelle valeur de rewardReserve
     */
    function setRewardReserve(uint256 amount) external onlyOwner {
        uint256 currentBalance = lkstToken.balanceOf(address(this));
        require(amount <= currentBalance, "Amount exceeds contract balance");

        uint256 oldReserve = rewardReserve;
        rewardReserve = amount;

        emit RewardsFunded(amount - oldReserve, rewardReserve);
    }
}
