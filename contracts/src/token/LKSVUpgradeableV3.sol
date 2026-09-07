// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./LKSVUpgradeableV2.sol";

/**
 * @title LKSVUpgradeableV3 — fix de la formule de distribution des rewards
 * @notice V3 corrige le mismatch entre `rewardPerToken()` et `earned()` qui
 *         multipliait le débit effectif par 1000 à cause de `_decimalsOffset = 3`.
 *
 * Bug V1/V2 :
 * - `rewardPerToken()` divise par `totalAssets()` (LKST sous-jacents)
 * - `earned()` multiplie par `userShares = balanceOf(account)` (= shares ERC4626)
 * - Avec `_decimalsOffset = 3`, `totalShares ≈ totalAssets × 1000` au boot
 * - Conséquence : rate effectif = rate configuré × 1000
 *
 * Fix V3 (Synthetix-style staking) :
 * - `rewardPerToken()` divise par `totalSupply()` (= shares totales)
 * - `earned()` reste inchangé (multiplie par userShares)
 * - Formule cohérente, débit effectif = rate configuré
 *
 * Voir `docs/architecture/LKSV_REWARD_FORMULA.md` pour la formule canonique
 * Solidity / Rust off-chain / Stylus future port.
 *
 * Storage layout : aucune nouvelle variable d'état (UUPS-safe).
 *
 * Pas de fonction admin de reset : le fix de formule à lui seul suffit. Les
 * pending erronés sous V2 étaient calculés live par `earned()` (jamais
 * persistés en storage tant qu'aucune tx n'aboutissait — les claims revertaient).
 * Après upgrade, `earned()` recompute avec la formule V3, ramenant les pending
 * à la valeur correcte.
 */
contract LKSVUpgradeableV3 is LKSVUpgradeableV2 {
    /// @notice Version du contrat.
    function version() external pure virtual override returns (string memory) {
        return "3.0.0";
    }

    /**
     * @notice Reward per token corrigé : divise par `totalSupply()` (shares),
     *         pas `totalAssets()` (assets sous-jacents). Cohérent avec earned().
     * @dev Override de la fonction `virtual` de LKSVUpgradeable.
     */
    function rewardPerToken() public view virtual override returns (uint256) {
        uint256 _supply = totalSupply();
        if (_supply == 0) {
            return rewardPerTokenStored;
        }

        uint256 timeElapsed = block.timestamp - lastUpdateTime;
        uint256 newRewards = timeElapsed * rewardRate;

        return rewardPerTokenStored + (newRewards * PRECISION / _supply);
    }
}
