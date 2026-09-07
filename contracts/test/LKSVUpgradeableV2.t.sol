// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../src/token/LKSTUpgradeable.sol";
import "../src/token/LKSVUpgradeable.sol";
import "../src/token/LKSVUpgradeableV2.sol";

/**
 * @dev Tests minimaux pour LKSVUpgradeableV2 et le fix LKS-LKSV-01.
 *      Couvre : déploiement via proxy, rewardRate=0 au départ, fixRewardReserve/setRewardReserve.
 */
contract LKSVUpgradeableV2Test is Test {
    LKSTUpgradeable public lkst;
    LKSVUpgradeableV2 public lksv;

    address public admin = address(0xA11CE);
    address public alice = address(0x1111);

    uint256 constant STAKE_AMOUNT = 1000 ether;

    function setUp() public {
        // Deploy LKST
        LKSTUpgradeable lkstImpl = new LKSTUpgradeable();
        vm.prank(admin);
        ERC1967Proxy lkstProxy = new ERC1967Proxy(
            address(lkstImpl),
            abi.encodeCall(LKSTUpgradeable.initialize, (admin))
        );
        lkst = LKSTUpgradeable(address(lkstProxy));

        // Deploy LKSV V2 directly (not V1 first)
        LKSVUpgradeableV2 lksvImpl = new LKSVUpgradeableV2();
        vm.prank(admin);
        ERC1967Proxy lksvProxy = new ERC1967Proxy(
            address(lksvImpl),
            abi.encodeCall(LKSVUpgradeable.initialize, (IERC20(address(lkst)), admin))
        );
        lksv = LKSVUpgradeableV2(address(lksvProxy));

        // Fund alice with LKST
        vm.prank(admin);
        lkst.transfer(alice, STAKE_AMOUNT * 10);
    }

    // ============================================================================
    // LKS-LKSV-01 FIX : rewardRate initialisé à 0
    // ============================================================================

    function test_LKS_LKSV_01_rewardRateInitializedToZero() public {
        // Avant le fix : rewardRate = 1e18 (1 LKST/s) = drain immédiat de la reserve
        // Après le fix : rewardRate = 0 → pas de distribution sans action explicite
        assertEq(lksv.rewardRate(), 0);
    }

    // ============================================================================
    // V2 VERSION
    // ============================================================================

    function test_V2_versionString() public {
        assertEq(lksv.version(), "2.0.0");
    }

    // ============================================================================
    // V2 FIX REWARD RESERVE
    // ============================================================================

    function test_SetRewardReserve_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        lksv.setRewardReserve(1 ether);
    }

    function test_SetRewardReserve_updatesState() public {
        // Send LKST directly to vault (simulate legacy mistake)
        vm.prank(admin);
        lkst.transfer(address(lksv), 100 ether);

        vm.prank(admin);
        lksv.setRewardReserve(100 ether);

        assertEq(lksv.rewardReserve(), 100 ether);
    }

    function test_SetRewardReserve_revertIfExceedsBalance() public {
        vm.prank(admin);
        vm.expectRevert("Amount exceeds contract balance");
        lksv.setRewardReserve(1000 ether);
    }

    function test_FixRewardReserve_incrementsReserve() public {
        // Send LKST directly then fix the reserve
        vm.prank(admin);
        lkst.transfer(address(lksv), 50 ether);

        vm.prank(admin);
        lksv.fixRewardReserve(50 ether);

        assertEq(lksv.rewardReserve(), 50 ether);
    }

    // ============================================================================
    // V1 FUNCTIONALITY (inherited)
    // ============================================================================

    function test_Inheritance_stakeWorks() public {
        vm.startPrank(alice);
        lkst.approve(address(lksv), STAKE_AMOUNT);
        uint256 shares = lksv.deposit(STAKE_AMOUNT, alice);
        vm.stopPrank();

        assertGt(shares, 0);
        assertEq(lksv.balanceOf(alice), shares);
    }
}
