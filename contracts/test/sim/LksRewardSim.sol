// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// =============================================================================
// LksRewardSim.sol — Reference simulator pour LKSV V3 reward distribution
//
// Formule canonique (Synthetix-style staking) :
//
//   newRewards            = (now - lastUpdateTime) * rewardRate
//   rewardPerTokenDelta   = newRewards * PRECISION / totalSupply        ← shares, pas assets
//   rewardPerToken_after  = rewardPerToken_before + rewardPerTokenDelta
//   earned[user]          = userShares * (rewardPerToken_after - userPaid) / PRECISION + accrued[user]
//
// Bug V1/V2 : `rewardPerToken` divisait par `totalAssets` (sous-jacent LKST)
//             au lieu de `totalSupply` (shares ERC4626). Avec _decimalsOffset=3
//             ⇒ totalShares ≈ totalAssets × 1000 ⇒ rate effectif × 1000.
//
// V3 fix : diviser par totalSupply (cohérent avec userShares dans earned()).
//
// Cette library encode la formule canonique pour cross-validation dans
// les tests Foundry (LKSVUpgradeableV3.t.sol) ET sert de spec pour les
// futurs ports (Rust off-chain, Stylus). Doit rester strictement identique
// au comportement on-chain.
// =============================================================================

library LksRewardSim {
    uint256 internal constant PRECISION = 1e18;

    /// @notice Calcule l'incrément de rewardPerToken pour un intervalle de temps.
    /// @dev Si totalSupply == 0, l'incrément est 0 (pas de stakers, pas de reward).
    function rewardPerTokenDelta(
        uint256 timeElapsed,
        uint256 rewardRate,
        uint256 totalSupply
    ) internal pure returns (uint256) {
        if (totalSupply == 0) return 0;
        return (timeElapsed * rewardRate * PRECISION) / totalSupply;
    }

    /// @notice Earnings calculés pour un user.
    /// @param userShares balanceOf ERC4626 shares.
    /// @param rewardPerTokenAfter rewardPerToken courant (incluant delta).
    /// @param userPaid userRewardPerTokenPaid stocké.
    /// @param accrued rewards[user] accumulés mais non claimés.
    function earned(
        uint256 userShares,
        uint256 rewardPerTokenAfter,
        uint256 userPaid,
        uint256 accrued
    ) internal pure returns (uint256) {
        if (rewardPerTokenAfter < userPaid) return accrued; // garde-fou (ne devrait jamais arriver)
        uint256 delta = rewardPerTokenAfter - userPaid;
        return (userShares * delta) / PRECISION + accrued;
    }

    /// @notice Cycle complet : depuis (lastRPT, lastUpdate, accrued) calcule earned à `nowTs`.
    /// @dev Combine rewardPerTokenDelta + earned en un seul appel pour les tests.
    function earnedAt(
        uint256 userShares,
        uint256 totalSupply,
        uint256 rewardRate,
        uint256 lastRewardPerTokenStored,
        uint256 lastUpdateTime,
        uint256 userPaid,
        uint256 accrued,
        uint256 nowTs
    ) internal pure returns (uint256 expected, uint256 newRewardPerToken) {
        uint256 timeElapsed = nowTs > lastUpdateTime ? nowTs - lastUpdateTime : 0;
        uint256 delta = rewardPerTokenDelta(timeElapsed, rewardRate, totalSupply);
        newRewardPerToken = lastRewardPerTokenStored + delta;
        expected = earned(userShares, newRewardPerToken, userPaid, accrued);
    }
}
