// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../src/token/LKSTUpgradeable.sol";
import "../src/token/LKSVUpgradeable.sol";
import "../src/token/LKSVUpgradeableV2.sol";
import "../src/token/LKSVUpgradeableV3.sol";

/**
 * @dev Régression pour le fix V3 (mismatch d'unités rewardPerToken/earned).
 *      Avant V3 : rewardPerToken() divisait par totalAssets() (assets sous-jacents)
 *      alors que earned() multipliait par balanceOf() (shares ERC4626). Avec
 *      _decimalsOffset = 3, totalSupply() ≈ totalAssets() * 1000 au boot, donc le
 *      débit effectif de la reserve était ≈ 1000x le rewardRate configuré.
 */
contract LKSVUpgradeableV3Test is Test {
    LKSTUpgradeable public lkst;
    LKSVUpgradeableV3 public lksv;

    address public admin = address(0xA11CE);
    address public alice = address(0x1111);
    address public bob = address(0x2222);

    uint256 constant STAKE_AMOUNT = 1000 ether;
    uint256 constant REWARD_RATE = 1e15; // 0.001 LKST/s (~86.4 LKST/day)

    function setUp() public {
        LKSTUpgradeable lkstImpl = new LKSTUpgradeable();
        vm.prank(admin);
        ERC1967Proxy lkstProxy = new ERC1967Proxy(
            address(lkstImpl),
            abi.encodeCall(LKSTUpgradeable.initialize, (admin))
        );
        lkst = LKSTUpgradeable(address(lkstProxy));

        LKSVUpgradeableV3 lksvImpl = new LKSVUpgradeableV3();
        vm.prank(admin);
        ERC1967Proxy lksvProxy = new ERC1967Proxy(
            address(lksvImpl),
            abi.encodeCall(LKSVUpgradeable.initialize, (IERC20(address(lkst)), admin))
        );
        lksv = LKSVUpgradeableV3(address(lksvProxy));

        vm.startPrank(admin);
        lkst.transfer(alice, STAKE_AMOUNT * 10);
        lkst.transfer(bob, STAKE_AMOUNT * 10);
        lkst.transfer(admin, 0); // no-op, admin already holds remaining supply
        lkst.approve(address(lksv), type(uint256).max);
        lksv.fundRewards(1_000_000 ether);
        lksv.setRewardRate(REWARD_RATE);
        vm.stopPrank();
    }

    function test_V3_versionString() public {
        assertEq(lksv.version(), "3.0.0");
    }

    /// @notice rewardPerToken() doit être calculé sur totalSupply() (shares), pas totalAssets().
    function test_V3_rewardPerTokenDenominatorIsShares() public {
        vm.startPrank(alice);
        lkst.approve(address(lksv), STAKE_AMOUNT);
        lksv.deposit(STAKE_AMOUNT, alice);
        vm.stopPrank();

        uint256 shares = lksv.balanceOf(alice);
        // Au premier dépôt (decimalsOffset=3), shares ≈ assets * 1000.
        assertGt(shares, STAKE_AMOUNT);

        skip(1 days);

        uint256 elapsed = 1 days;
        uint256 expectedRewardPerToken = (elapsed * REWARD_RATE * lksv.PRECISION()) / shares;
        assertApproxEqAbs(lksv.rewardPerToken(), expectedRewardPerToken, 1);
    }

    /// @notice Le débit effectif de la reserve doit correspondre au rewardRate configuré,
    ///         pas à rewardRate × ratio shares/assets (c'était le bug avant V3).
    function test_V3_effectiveDistributionMatchesConfiguredRate() public {
        vm.startPrank(alice);
        lkst.approve(address(lksv), STAKE_AMOUNT);
        lksv.deposit(STAKE_AMOUNT, alice);
        vm.stopPrank();

        skip(1 days);

        uint256 earned = lksv.earned(alice);
        uint256 expected = 1 days * REWARD_RATE;

        // earned() doit être borné au voisinage de rewardRate*elapsed, PAS
        // rewardRate*elapsed*1000 (ce qu'aurait produit le bug V1/V2 avec offset=3
        // et un seul staker détenant 100% du supply pondéré).
        assertApproxEqRel(earned, expected, 0.01e18); // tolérance 1%
        assertLt(earned, expected * 2); // garde-fou dur contre un facteur ×1000
    }

    /// @notice Deux stakers à parts égales doivent se partager les rewards à parts égales,
    ///         indépendamment du ratio shares/assets hérité de l'offset ERC4626.
    function test_V3_equalStakersSplitRewardsEqually() public {
        vm.startPrank(alice);
        lkst.approve(address(lksv), STAKE_AMOUNT);
        lksv.deposit(STAKE_AMOUNT, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        lkst.approve(address(lksv), STAKE_AMOUNT);
        lksv.deposit(STAKE_AMOUNT, bob);
        vm.stopPrank();

        skip(1 days);

        assertApproxEqAbs(lksv.earned(alice), lksv.earned(bob), 1e12);
    }
}
