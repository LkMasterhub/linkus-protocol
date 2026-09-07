// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LksTipSim} from "./LksTipSim.sol";
import {LksFeeSim} from "./LksFeeSim.sol";
import {LksTierSim} from "./LksTierSim.sol";
import {LksRewardSim} from "./LksRewardSim.sol";

/**
 * @notice Tests des reference simulators V8.
 *         Ces tests valident la spec mathématique avant que les contrats
 *         soient implémentés. Les contrats Phase 2 sont vérifiés via
 *         `assertApproxEqRel(actual, sim.compute(args), 1e14)`.
 */
contract SimulatorsTest is Test {
    // ─────────────────────────────────────────────────────────────────
    // LksTipSim
    // ─────────────────────────────────────────────────────────────────

    function test_TipSplit_zeroFee() public pure {
        (uint256 author, uint256 fee) = LksTipSim.split(1 ether, 0);
        assertEq(author, 1 ether);
        assertEq(fee, 0);
    }

    function test_TipSplit_2_5_percent() public pure {
        (uint256 author, uint256 fee) = LksTipSim.split(1 ether, 250);
        assertEq(fee, 0.025 ether);
        assertEq(author, 0.975 ether);
        assertEq(author + fee, 1 ether);
    }

    function test_TipSplit_30_percent_max() public pure {
        (uint256 author, uint256 fee) = LksTipSim.split(1 ether, 3000);
        assertEq(fee, 0.3 ether);
        assertEq(author, 0.7 ether);
    }

    function test_TipSplit_rounding_creator_keeps_residual() public pure {
        // 7 wei * 250 / 10000 = 0 (floor) → fee 0, author 7
        (uint256 author, uint256 fee) = LksTipSim.split(7, 250);
        assertEq(fee, 0);
        assertEq(author, 7);
    }

    function test_TipSplit_aggregate() public pure {
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 1 ether;
        amounts[1] = 2 ether;
        amounts[2] = 0.5 ether;
        (uint256 totalAuthor, uint256 totalFees) = LksTipSim.aggregate(amounts, 250);
        assertEq(totalFees, 0.025 ether + 0.05 ether + 0.0125 ether);
        assertEq(totalAuthor + totalFees, 3.5 ether);
    }

    function testFuzz_TipSplit_conservation(uint256 amount, uint16 feeBps) public pure {
        feeBps = uint16(bound(uint256(feeBps), 0, 10000));
        amount = bound(amount, 0, type(uint128).max);
        (uint256 author, uint256 fee) = LksTipSim.split(amount, feeBps);
        assertEq(author + fee, amount, "conservation: author + fee == amount");
    }

    // ─────────────────────────────────────────────────────────────────
    // LksFeeSim
    // ─────────────────────────────────────────────────────────────────

    function test_FeeSplit_5_percent() public pure {
        (uint256 main, uint256 fee) = LksFeeSim.feeSplit(10 ether, 500);
        assertEq(fee, 0.5 ether);
        assertEq(main, 9.5 ether);
    }

    function test_RoyaltyAmount_10_percent() public pure {
        uint256 amount = LksFeeSim.royaltyAmount(2 ether, 1000);
        assertEq(amount, 0.2 ether);
    }

    function testFuzz_FeeSplit_conservation(uint256 amount, uint16 bps) public pure {
        bps = uint16(bound(uint256(bps), 0, 10000));
        amount = bound(amount, 0, type(uint128).max);
        (uint256 main, uint256 fee) = LksFeeSim.feeSplit(amount, bps);
        assertEq(main + fee, amount);
    }

    function testFuzz_Royalty_bounded(uint256 salePrice, uint16 bps) public pure {
        bps = uint16(bound(uint256(bps), 0, 10000));
        salePrice = bound(salePrice, 0, type(uint128).max);
        uint256 r = LksFeeSim.royaltyAmount(salePrice, bps);
        assertLe(r, salePrice, "royalty <= salePrice");
    }

    // ─────────────────────────────────────────────────────────────────
    // LksTierSim
    // ─────────────────────────────────────────────────────────────────

    function test_NewExpiry_firstSubscription() public pure {
        // currentExpiry = 0, now = 1000, duration = 30 days
        uint64 e = LksTierSim.newExpiry(0, 1000, 30 days);
        assertEq(e, 1000 + 30 days);
    }

    function test_NewExpiry_extendBeforeExpiry() public pure {
        // currentExpiry = 2000, now = 1500 → base = 2000, expiry = 2000 + 30d
        uint64 e = LksTierSim.newExpiry(2000, 1500, 30 days);
        assertEq(e, 2000 + 30 days);
    }

    function test_NewExpiry_extendAfterExpiry() public pure {
        // currentExpiry = 1000, now = 2000 → base = 2000, expiry = 2000 + 30d
        uint64 e = LksTierSim.newExpiry(1000, 2000, 30 days);
        assertEq(e, 2000 + 30 days);
    }

    function test_Refund_halfwayThrough() public pure {
        // paid = 100, start = 0, expires = 100, now = 50 → refund = 50
        uint256 r = LksTierSim.refund(100, 0, 100, 50);
        assertEq(r, 50);
    }

    function test_Refund_almostExpired() public pure {
        uint256 r = LksTierSim.refund(100, 0, 100, 99);
        assertEq(r, 1);
    }

    function test_Refund_alreadyExpired() public pure {
        uint256 r = LksTierSim.refund(100, 0, 100, 200);
        assertEq(r, 0);
    }

    function test_Refund_atStart() public pure {
        uint256 r = LksTierSim.refund(100, 0, 100, 0);
        assertEq(r, 100);
    }

    function testFuzz_Refund_neverExceedsPaid(
        uint256 paid,
        uint64 startTs,
        uint64 expiresTs,
        uint64 nowTs
    ) public pure {
        startTs = uint64(bound(uint256(startTs), 0, type(uint64).max - 1));
        expiresTs = uint64(bound(uint256(expiresTs), uint256(startTs) + 1, type(uint64).max));
        nowTs = uint64(bound(uint256(nowTs), 0, type(uint64).max));
        paid = bound(paid, 0, type(uint128).max);
        uint256 r = LksTierSim.refund(paid, startTs, expiresTs, nowTs);
        assertLe(r, paid, "refund <= paid");
    }

    // ─────────────────────────────────────────────────────────────────
    // LksRewardSim
    // ─────────────────────────────────────────────────────────────────

    function test_RewardPerTokenDelta_basic() public pure {
        // 100 seconds * 1e15 rate * 1e18 PRECISION / 1000e18 supply
        // = 100 * 1e15 * 1e18 / 1000e18 = 1e14
        uint256 d = LksRewardSim.rewardPerTokenDelta(100, 1e15, 1000e18);
        assertEq(d, 1e14);
    }

    function test_RewardPerTokenDelta_zeroSupply() public pure {
        uint256 d = LksRewardSim.rewardPerTokenDelta(100, 1e15, 0);
        assertEq(d, 0);
    }

    function test_Earned_singleStaker() public pure {
        // user has 1000e18 shares, rPT went from 0 to 1e14
        // earned = 1000e18 * 1e14 / 1e18 = 1e17 = 0.1 ETH
        uint256 e = LksRewardSim.earned(1000e18, 1e14, 0, 0);
        assertEq(e, 0.1 ether);
    }

    function test_Earned_withAccrued() public pure {
        uint256 e = LksRewardSim.earned(1000e18, 1e14, 0, 5 ether);
        assertEq(e, 0.1 ether + 5 ether);
    }

    function test_EarnedAt_fullCycle_singleStaker_10s() public pure {
        // Spec: stake 1000e18, rate 1e15/s, supply 1000e18, warp 10s
        // expected = 10 * 1e15 = 1e16 (= 0.01 ETH)
        (uint256 expected, uint256 newRPT) = LksRewardSim.earnedAt(
            1000e18, // userShares (single staker)
            1000e18, // totalSupply
            1e15, // rewardRate
            0, // lastRewardPerTokenStored
            0, // lastUpdateTime
            0, // userPaid
            0, // accrued
            10 // nowTs
        );
        // delta = 10 * 1e15 * 1e18 / 1000e18 = 1e13
        assertEq(newRPT, 1e13);
        // earned = 1000e18 * 1e13 / 1e18 = 1e16
        assertEq(expected, 1e16);
    }

    function test_EarnedAt_proves_V2_bug_does_not_repeat() public pure {
        // Si on avait utilisé totalAssets au lieu de totalSupply, avec
        // _decimalsOffset = 3 → totalAssets = totalSupply / 1000.
        // Le rate effectif aurait été × 1000.
        // Ici on vérifie que la formule canonique respecte rate × time × shareRatio.
        // Single staker = 100% pool, rate 1e15/s, 10 secondes.
        (uint256 expected, ) = LksRewardSim.earnedAt(
            1000e18, // userShares
            1000e18, // totalSupply
            1e15,
            0,
            0,
            0,
            0,
            10
        );
        // expected = 1e16 (= 10 secondes × 1e15 rate, single staker)
        // PAS 1e19 (= ×1000 du bug V2)
        assertEq(expected, 1e16);
        assertTrue(expected != 1e19, "must not be V2 bug x1000");
    }

    function test_EarnedAt_multiStaker_proportional() public pure {
        // 2 stakers: A=1000, B=2000, totalSupply=3000, 100s, rate 1e15
        // Total reward distributed = 100 * 1e15 = 1e17
        // A gets 1/3 = ~3.33e16, B gets 2/3 = ~6.67e16
        (uint256 earnedA, ) = LksRewardSim.earnedAt(
            1000e18, 3000e18, 1e15, 0, 0, 0, 0, 100
        );
        (uint256 earnedB, ) = LksRewardSim.earnedAt(
            2000e18, 3000e18, 1e15, 0, 0, 0, 0, 100
        );
        // Loss ≤ totalSupply/1e18 wei (rounding ERC4626) ; ici 3000e18 ⇒ ≤ 3000
        assertApproxEqAbs(earnedA + earnedB, 1e17, 3000);
        assertApproxEqRel(earnedA * 2, earnedB, 1e14); // B = 2 * A à 0.01% près
    }

    function testFuzz_RewardSim_neverNegative(
        uint256 userShares,
        uint256 supply,
        uint256 rate,
        uint256 timeElapsed
    ) public pure {
        userShares = bound(userShares, 0, 1e30);
        supply = bound(supply, userShares, 1e30 + userShares);
        rate = bound(rate, 0, 1e20);
        timeElapsed = bound(timeElapsed, 0, 365 days * 100);
        if (supply == 0) return; // skip dégénéré
        (uint256 expected, ) = LksRewardSim.earnedAt(
            userShares, supply, rate, 0, 0, 0, 0, timeElapsed
        );
        // pas négatif (uint), pas absurde (jamais > total reward distributed)
        uint256 totalReward = timeElapsed * rate;
        assertLe(expected, totalReward + 1, "earned <= total distributed (+1 rounding)");
    }
}
