// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable}       from "@openzeppelin/contracts/utils/Pausable.sol";

import {LksTipVault} from "../src/tips/LksTipVault.sol";
import {ITipVault}   from "../src/tips/ITipVault.sol";
import {LksTipSim}   from "./sim/LksTipSim.sol";

/**
 * @title  LksTipVault — Ableton-grade tests
 * @notice 55 unit tests asserts forts (cross-validés via LksTipSim) + 5 fuzz.
 *         Couvre constructor, tip/withdraw flows, admin (fee/recipient/pause),
 *         CEI invariants, role gates.
 */
contract LksTipVaultTest is Test {
    LksTipVault internal vault;

    address internal admin     = address(0xA11CE);
    address internal feeRecv   = address(0xFEE);
    address internal alice     = address(0x1111);
    address internal bob       = address(0x2222);
    address internal carol     = address(0x3333);

    bytes32 internal constant POST_A = keccak256("post-a");
    bytes32 internal constant POST_B = keccak256("post-b");

    uint16  internal constant FEE_BPS_INITIAL = 250;     // 2.5 %

    bytes32 internal constant FEE_ADMIN_ROLE = keccak256("FEE_ADMIN_ROLE");
    bytes32 internal constant PAUSER_ROLE    = keccak256("PAUSER_ROLE");

    // Mirror events for vm.expectEmit
    event Tipped(bytes32 indexed postId, address indexed author, address indexed tipper, uint256 authorShare, uint256 platformFee);
    event Withdrawn(address indexed author, uint256 amount);
    event PlatformFeesWithdrawn(address indexed recipient, uint256 amount);
    event FeeUpdated(uint16 oldBps, uint16 newBps);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);

    function setUp() public {
        vault = new LksTipVault(admin, FEE_BPS_INITIAL, feeRecv);
        vm.deal(alice, 100 ether);
        vm.deal(bob,   100 ether);
        vm.deal(carol, 100 ether);
    }

    // =========================================================================
    // Constructor — 8 tests
    // =========================================================================

    function test_Constructor_grantsDefaultAdminRole() public view {
        assertTrue(vault.hasRole(0x00, admin)); // DEFAULT_ADMIN_ROLE = 0x00
    }

    function test_Constructor_grantsFeeAdminRole() public view {
        assertTrue(vault.hasRole(FEE_ADMIN_ROLE, admin));
    }

    function test_Constructor_grantsPauserRole() public view {
        assertTrue(vault.hasRole(PAUSER_ROLE, admin));
    }

    function test_Constructor_setsInitialFeeBps() public view {
        assertEq(vault.feeBps(), FEE_BPS_INITIAL);
    }

    function test_Constructor_setsFeeRecipient() public view {
        assertEq(vault.feeRecipient(), feeRecv);
    }

    function test_Constructor_revertsZeroAdmin() public {
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        new LksTipVault(address(0), 250, feeRecv);
    }

    function test_Constructor_revertsZeroRecipient() public {
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        new LksTipVault(admin, 250, address(0));
    }

    function test_Constructor_revertsFeeAboveMax() public {
        vm.expectRevert(abi.encodeWithSignature("FeeTooHigh(uint16,uint16)", 3001, 3000));
        new LksTipVault(admin, 3001, feeRecv);
    }

    // =========================================================================
    // Constants — 2 tests
    // =========================================================================

    function test_Constants_MAX_FEE_BPS() public view {
        assertEq(vault.MAX_FEE_BPS(), 3000);
    }

    function test_Constants_MIN_TIP() public view {
        assertEq(vault.MIN_TIP(), 1e13);
    }

    // =========================================================================
    // tip() happy path — 7 tests
    // =========================================================================

    function test_Tip_creditsAuthorAndPlatformExact() public {
        uint256 amount = 1 ether;
        (uint256 expAuthor, uint256 expFee) = LksTipSim.split(amount, FEE_BPS_INITIAL);

        vm.prank(alice);
        vault.tip{value: amount}(POST_A, bob);

        assertEq(vault.tipsOwed(bob), expAuthor);
        assertEq(vault.platformFees(), expFee);
        assertEq(address(vault).balance, amount);
    }

    function test_Tip_emitsTippedEvent() public {
        uint256 amount = 1 ether;
        (uint256 expAuthor, uint256 expFee) = LksTipSim.split(amount, FEE_BPS_INITIAL);

        vm.expectEmit(true, true, true, true, address(vault));
        emit Tipped(POST_A, bob, alice, expAuthor, expFee);
        vm.prank(alice);
        vault.tip{value: amount}(POST_A, bob);
    }

    function test_Tip_incrementsPostTotals() public {
        vm.prank(alice);
        vault.tip{value: 1 ether}(POST_A, bob);
        vm.prank(carol);
        vault.tip{value: 2 ether}(POST_A, bob);
        assertEq(vault.postTotals(POST_A), 3 ether);
    }

    function test_Tip_zeroFeeBps_authorGetsAll() public {
        vm.prank(admin);
        vault.setFeeBps(0);

        vm.prank(alice);
        vault.tip{value: 1 ether}(POST_A, bob);

        assertEq(vault.tipsOwed(bob), 1 ether);
        assertEq(vault.platformFees(), 0);
    }

    function test_Tip_maxFeeBps_30pct() public {
        vm.prank(admin);
        vault.setFeeBps(3000); // 30 %

        vm.prank(alice);
        vault.tip{value: 10 ether}(POST_A, bob);

        assertEq(vault.platformFees(), 3 ether);
        assertEq(vault.tipsOwed(bob), 7 ether);
    }

    function test_Tip_minTipExact_accepted() public {
        vm.prank(alice);
        vault.tip{value: 1e13}(POST_A, bob);
        assertGt(vault.tipsOwed(bob), 0);
    }

    function test_Tip_largeAmount_noOverflow() public {
        vm.deal(alice, 1000 ether);
        vm.prank(alice);
        vault.tip{value: 1000 ether}(POST_A, bob);
        (uint256 expAuthor, uint256 expFee) = LksTipSim.split(1000 ether, FEE_BPS_INITIAL);
        assertEq(vault.tipsOwed(bob), expAuthor);
        assertEq(vault.platformFees(), expFee);
    }

    // =========================================================================
    // tip() reverts — 4 tests
    // =========================================================================

    function test_Tip_revertsBelowMin() public {
        vm.expectRevert(abi.encodeWithSignature("TipBelowMinimum(uint256,uint256)", 1, 1e13));
        vm.prank(alice);
        vault.tip{value: 1}(POST_A, bob);
    }

    function test_Tip_revertsZeroValue() public {
        vm.expectRevert(abi.encodeWithSignature("TipBelowMinimum(uint256,uint256)", 0, 1e13));
        vm.prank(alice);
        vault.tip{value: 0}(POST_A, bob);
    }

    function test_Tip_revertsZeroAuthor() public {
        vm.expectRevert(abi.encodeWithSignature("NullAuthor()"));
        vm.prank(alice);
        vault.tip{value: 1 ether}(POST_A, address(0));
    }

    function test_Tip_revertsWhenPaused() public {
        vm.prank(admin);
        vault.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(alice);
        vault.tip{value: 1 ether}(POST_A, bob);
    }

    // =========================================================================
    // tip() rounding & multiple — 5 tests
    // =========================================================================

    function test_Tip_roundingFavorsAuthor() public {
        // 7 wei * 250 / 10000 = 0 → fee 0, author 7
        vm.prank(alice);
        vm.expectRevert(); // below MIN_TIP
        vault.tip{value: 7}(POST_A, bob);
        // Use larger amount that rounds: e.g., 10001 wei
        vm.prank(alice);
        vault.tip{value: 1e13 + 1}(POST_A, bob);
        (uint256 expA, uint256 expF) = LksTipSim.split(1e13 + 1, FEE_BPS_INITIAL);
        assertEq(vault.tipsOwed(bob), expA);
        assertEq(vault.platformFees(), expF);
    }

    function test_Tip_TipSplitMatchesSimulator_2_5pct() public {
        uint256 amount = 1 ether;
        (uint256 expA, uint256 expF) = LksTipSim.split(amount, 250);
        vm.prank(alice);
        vault.tip{value: amount}(POST_A, bob);
        assertEq(vault.tipsOwed(bob), expA);
        assertEq(vault.platformFees(), expF);
        assertEq(expA + expF, amount);
    }

    function test_Tip_aggregateMatchesSim_3tips() public {
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 1 ether;
        amounts[1] = 2 ether;
        amounts[2] = 0.5 ether;

        (uint256 expA, uint256 expF) = LksTipSim.aggregate(amounts, FEE_BPS_INITIAL);

        vm.prank(alice);
        vault.tip{value: amounts[0]}(POST_A, bob);
        vm.prank(carol);
        vault.tip{value: amounts[1]}(POST_A, bob);
        vm.prank(alice);
        vault.tip{value: amounts[2]}(POST_B, bob);

        assertEq(vault.tipsOwed(bob), expA);
        assertEq(vault.platformFees(), expF);
    }

    function test_Tip_multipleTippersSamePost_accumulates() public {
        vm.prank(alice);
        vault.tip{value: 1 ether}(POST_A, bob);
        vm.prank(carol);
        vault.tip{value: 1 ether}(POST_A, bob);
        (uint256 e1,) = LksTipSim.split(1 ether, FEE_BPS_INITIAL);
        assertEq(vault.tipsOwed(bob), 2 * e1);
        assertEq(vault.postTotals(POST_A), 2 ether);
    }

    function test_Tip_sameAuthorMultiplePosts_sums() public {
        vm.prank(alice);
        vault.tip{value: 1 ether}(POST_A, bob);
        vm.prank(alice);
        vault.tip{value: 1 ether}(POST_B, bob);
        (uint256 e1,) = LksTipSim.split(1 ether, FEE_BPS_INITIAL);
        assertEq(vault.tipsOwed(bob), 2 * e1);
        assertEq(vault.postTotals(POST_A), 1 ether);
        assertEq(vault.postTotals(POST_B), 1 ether);
    }

    // =========================================================================
    // withdraw() — 7 tests
    // =========================================================================

    function test_Withdraw_transfersExactAmount() public {
        vm.prank(alice);
        vault.tip{value: 1 ether}(POST_A, bob);
        (uint256 owed,) = LksTipSim.split(1 ether, FEE_BPS_INITIAL);

        uint256 balBefore = bob.balance;
        vm.prank(bob);
        vault.withdraw();
        assertEq(bob.balance - balBefore, owed);
    }

    function test_Withdraw_emitsWithdrawnEvent() public {
        vm.prank(alice);
        vault.tip{value: 1 ether}(POST_A, bob);
        (uint256 owed,) = LksTipSim.split(1 ether, FEE_BPS_INITIAL);

        vm.expectEmit(true, false, false, true, address(vault));
        emit Withdrawn(bob, owed);
        vm.prank(bob);
        vault.withdraw();
    }

    function test_Withdraw_zerosTipsOwed() public {
        vm.prank(alice);
        vault.tip{value: 1 ether}(POST_A, bob);
        vm.prank(bob);
        vault.withdraw();
        assertEq(vault.tipsOwed(bob), 0);
    }

    function test_Withdraw_revertsNothingToWithdraw() public {
        vm.expectRevert(abi.encodeWithSignature("NothingToWithdraw()"));
        vm.prank(bob);
        vault.withdraw();
    }

    function test_Withdraw_secondCallReverts() public {
        vm.prank(alice);
        vault.tip{value: 1 ether}(POST_A, bob);
        vm.prank(bob);
        vault.withdraw();
        vm.expectRevert(abi.encodeWithSignature("NothingToWithdraw()"));
        vm.prank(bob);
        vault.withdraw();
    }

    function test_Withdraw_doesNotAffectOtherAuthors() public {
        vm.prank(alice);
        vault.tip{value: 1 ether}(POST_A, bob);
        vm.prank(alice);
        vault.tip{value: 2 ether}(POST_B, carol);

        (uint256 carolOwed,) = LksTipSim.split(2 ether, FEE_BPS_INITIAL);
        vm.prank(bob);
        vault.withdraw();
        assertEq(vault.tipsOwed(carol), carolOwed);
    }

    function test_Withdraw_canCallEvenWhenPaused() public {
        // Pause should NOT block withdraw (only tip)
        vm.prank(alice);
        vault.tip{value: 1 ether}(POST_A, bob);
        vm.prank(admin);
        vault.pause();
        vm.prank(bob);
        vault.withdraw(); // doit passer
        assertEq(vault.tipsOwed(bob), 0);
    }

    // =========================================================================
    // withdrawPlatformFees() — 5 tests
    // =========================================================================

    function test_WithdrawPlatformFees_transfersToRecipient() public {
        vm.prank(alice);
        vault.tip{value: 1 ether}(POST_A, bob);
        (, uint256 fee) = LksTipSim.split(1 ether, FEE_BPS_INITIAL);

        uint256 balBefore = feeRecv.balance;
        vault.withdrawPlatformFees();
        assertEq(feeRecv.balance - balBefore, fee);
    }

    function test_WithdrawPlatformFees_zerosFees() public {
        vm.prank(alice);
        vault.tip{value: 1 ether}(POST_A, bob);
        vault.withdrawPlatformFees();
        assertEq(vault.platformFees(), 0);
    }

    function test_WithdrawPlatformFees_emitsEvent() public {
        vm.prank(alice);
        vault.tip{value: 1 ether}(POST_A, bob);
        (, uint256 fee) = LksTipSim.split(1 ether, FEE_BPS_INITIAL);

        vm.expectEmit(true, false, false, true, address(vault));
        emit PlatformFeesWithdrawn(feeRecv, fee);
        vault.withdrawPlatformFees();
    }

    function test_WithdrawPlatformFees_revertsNothing() public {
        vm.expectRevert(abi.encodeWithSignature("NothingToWithdraw()"));
        vault.withdrawPlatformFees();
    }

    function test_WithdrawPlatformFees_callableByAnyone() public {
        // Pas de role check sur withdrawPlatformFees — destination est fixée par feeRecipient
        vm.prank(alice);
        vault.tip{value: 1 ether}(POST_A, bob);
        vm.prank(carol);
        vault.withdrawPlatformFees();
        assertEq(vault.platformFees(), 0);
    }

    // =========================================================================
    // setFeeBps() — 5 tests
    // =========================================================================

    function test_SetFeeBps_updatesValue() public {
        vm.prank(admin);
        vault.setFeeBps(500);
        assertEq(vault.feeBps(), 500);
    }

    function test_SetFeeBps_emitsEvent() public {
        vm.expectEmit(false, false, false, true, address(vault));
        emit FeeUpdated(FEE_BPS_INITIAL, 500);
        vm.prank(admin);
        vault.setFeeBps(500);
    }

    function test_SetFeeBps_revertsAboveMax() public {
        vm.expectRevert(abi.encodeWithSignature("FeeTooHigh(uint16,uint16)", 3001, 3000));
        vm.prank(admin);
        vault.setFeeBps(3001);
    }

    function test_SetFeeBps_revertsNonAdmin() public {
        vm.expectRevert(); // OZ AccessControlUnauthorizedAccount
        vm.prank(alice);
        vault.setFeeBps(500);
    }

    function test_SetFeeBps_acceptsZero() public {
        vm.prank(admin);
        vault.setFeeBps(0);
        assertEq(vault.feeBps(), 0);
    }

    function test_SetFeeBps_acceptsMax() public {
        vm.prank(admin);
        vault.setFeeBps(3000);
        assertEq(vault.feeBps(), 3000);
    }

    // =========================================================================
    // setFeeRecipient() — 4 tests
    // =========================================================================

    function test_SetFeeRecipient_updatesAddress() public {
        vm.prank(admin);
        vault.setFeeRecipient(carol);
        assertEq(vault.feeRecipient(), carol);
    }

    function test_SetFeeRecipient_emitsEvent() public {
        vm.expectEmit(true, true, false, false, address(vault));
        emit FeeRecipientUpdated(feeRecv, carol);
        vm.prank(admin);
        vault.setFeeRecipient(carol);
    }

    function test_SetFeeRecipient_revertsZero() public {
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        vm.prank(admin);
        vault.setFeeRecipient(address(0));
    }

    function test_SetFeeRecipient_revertsNonAdmin() public {
        vm.expectRevert();
        vm.prank(alice);
        vault.setFeeRecipient(carol);
    }

    // =========================================================================
    // pause() / unpause() — 6 tests
    // =========================================================================

    function test_Pause_setsPausedState() public {
        vm.prank(admin);
        vault.pause();
        assertTrue(vault.paused());
    }

    function test_Pause_blocksTip() public {
        vm.prank(admin);
        vault.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(alice);
        vault.tip{value: 1 ether}(POST_A, bob);
    }

    function test_Pause_revertsNonPauser() public {
        vm.expectRevert();
        vm.prank(alice);
        vault.pause();
    }

    function test_Unpause_restoresTip() public {
        vm.prank(admin);
        vault.pause();
        vm.prank(admin);
        vault.unpause();
        vm.prank(alice);
        vault.tip{value: 1 ether}(POST_A, bob);
        assertGt(vault.tipsOwed(bob), 0);
    }

    function test_Pause_doubleCallReverts() public {
        vm.prank(admin);
        vault.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(admin);
        vault.pause();
    }

    function test_Unpause_revertsWhenNotPaused() public {
        vm.expectRevert(Pausable.ExpectedPause.selector);
        vm.prank(admin);
        vault.unpause();
    }

    // =========================================================================
    // Invariants on-chain — 3 tests
    // =========================================================================

    function test_Inv_balanceEqualsOwedPlusFees_singleTip() public {
        vm.prank(alice);
        vault.tip{value: 1 ether}(POST_A, bob);
        (uint256 owed, uint256 fee) = LksTipSim.split(1 ether, FEE_BPS_INITIAL);
        assertEq(address(vault).balance, owed + fee);
    }

    function test_Inv_balanceEqualsOwedPlusFees_multiTips() public {
        vm.prank(alice);
        vault.tip{value: 1 ether}(POST_A, bob);
        vm.prank(carol);
        vault.tip{value: 2 ether}(POST_B, alice);
        uint256 sum = vault.tipsOwed(bob) + vault.tipsOwed(alice) + vault.platformFees();
        assertEq(address(vault).balance, sum);
    }

    function test_Inv_balanceAfterWithdraw() public {
        vm.prank(alice);
        vault.tip{value: 1 ether}(POST_A, bob);
        vm.prank(bob);
        vault.withdraw();
        assertEq(address(vault).balance, vault.platformFees());
    }

    // =========================================================================
    // Fuzz — 5 tests
    // =========================================================================

    function testFuzz_Tip_splitMatchesSim(uint96 amount) public {
        amount = uint96(bound(uint256(amount), vault.MIN_TIP(), 100 ether));
        vm.deal(alice, amount);
        (uint256 expA, uint256 expF) = LksTipSim.split(amount, FEE_BPS_INITIAL);

        vm.prank(alice);
        vault.tip{value: amount}(POST_A, bob);

        assertEq(vault.tipsOwed(bob), expA);
        assertEq(vault.platformFees(), expF);
        assertEq(expA + expF, amount);
    }

    function testFuzz_Tip_alwaysCreditsAuthor(uint96 amount) public {
        amount = uint96(bound(uint256(amount), vault.MIN_TIP(), 50 ether));
        vm.deal(alice, amount);
        vm.prank(alice);
        vault.tip{value: amount}(POST_A, bob);
        assertGt(vault.tipsOwed(bob), 0);
    }

    function testFuzz_FeeBps_capped(uint16 newBps) public {
        vm.prank(admin);
        if (newBps > 3000) {
            vm.expectRevert(abi.encodeWithSignature("FeeTooHigh(uint16,uint16)", newBps, 3000));
            vault.setFeeBps(newBps);
        } else {
            vault.setFeeBps(newBps);
            assertEq(vault.feeBps(), newBps);
        }
    }

    function testFuzz_Withdraw_clearsBalance(uint96 amount) public {
        amount = uint96(bound(uint256(amount), vault.MIN_TIP(), 50 ether));
        vm.deal(alice, amount);
        vm.prank(alice);
        vault.tip{value: amount}(POST_A, bob);

        vm.prank(bob);
        vault.withdraw();
        assertEq(vault.tipsOwed(bob), 0);
    }

    function testFuzz_Multitip_aggregatesCorrectly(uint96 a, uint96 b, uint96 c) public {
        a = uint96(bound(uint256(a), vault.MIN_TIP(), 10 ether));
        b = uint96(bound(uint256(b), vault.MIN_TIP(), 10 ether));
        c = uint96(bound(uint256(c), vault.MIN_TIP(), 10 ether));

        vm.deal(alice, uint256(a) + uint256(b) + uint256(c));
        vm.prank(alice);
        vault.tip{value: a}(POST_A, bob);
        vm.prank(alice);
        vault.tip{value: b}(POST_A, bob);
        vm.prank(alice);
        vault.tip{value: c}(POST_B, bob);

        uint256[] memory amounts = new uint256[](3);
        amounts[0] = a;
        amounts[1] = b;
        amounts[2] = c;
        (uint256 expA, uint256 expF) = LksTipSim.aggregate(amounts, FEE_BPS_INITIAL);

        assertEq(vault.tipsOwed(bob), expA);
        assertEq(vault.platformFees(), expF);
        assertEq(vault.postTotals(POST_A), uint256(a) + uint256(b));
        assertEq(vault.postTotals(POST_B), c);
    }
}
