// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test}              from "forge-std/Test.sol";
import {ERC1967Proxy}      from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Pausable}          from "@openzeppelin/contracts/utils/Pausable.sol";

import {LksBusinessV8}  from "../src/business/LksBusinessV8.sol";
import {ILksBusinessV8} from "../src/business/ILksBusinessV8.sol";
import {LksFeeSim}      from "./sim/LksFeeSim.sol";
import {
    ZeroAddress, ZeroAmount, NothingToWithdraw, FeeTooHigh, InvalidConfig,
    ProjectExists, ProjectNotFound, DeadlinePassed, DeadlineNotReached,
    GoalNotReached, GoalAlreadyReached, AlreadyWithdrawn, NothingToRefund, NotProjectCreator
} from "../src/shared/LksErrors.sol";

/**
 * @title  LksBusinessV8.t.sol
 * @notice 55+ tests + 5 fuzz cross-validés via LksFeeSim.feeSplit.
 */
contract LksBusinessV8Test is Test {
    LksBusinessV8 internal biz;

    address internal admin    = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal alice    = makeAddr("alice");
    address internal bob      = makeAddr("bob");
    address internal carol    = makeAddr("carol");
    address internal dave     = makeAddr("dave");

    uint16  internal constant DEFAULT_FEE_BPS = 250;     // 2.5%
    bytes32 internal constant SALT_1 = keccak256("salt-1");
    bytes32 internal constant SALT_2 = keccak256("salt-2");

    event ProjectCreated(bytes32 indexed projectId, address indexed creator, uint128 goal, uint64 deadline);
    event Funded(bytes32 indexed projectId, address indexed funder, uint256 amount, uint128 newRaised);
    event FundsWithdrawn(bytes32 indexed projectId, address indexed creator, uint256 creatorAmount, uint256 platformFee);
    event Refunded(bytes32 indexed projectId, address indexed contributor, uint256 amount);
    event ProjectCancelled(bytes32 indexed projectId);

    function setUp() public {
        LksBusinessV8 impl = new LksBusinessV8();
        bytes memory data = abi.encodeWithSelector(
            LksBusinessV8.initialize.selector, admin, treasury, DEFAULT_FEE_BPS
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), data);
        biz = LksBusinessV8(address(proxy));

        vm.deal(alice, 1000 ether);
        vm.deal(bob,   1000 ether);
        vm.deal(carol, 1000 ether);
        vm.deal(dave,  1000 ether);
    }

    // ─────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────

    function _create(address creator, bytes32 salt, uint128 goal, uint64 duration)
        internal
        returns (bytes32 projectId)
    {
        uint64 deadline = uint64(block.timestamp) + duration;
        vm.prank(creator);
        projectId = biz.createProject(salt, goal, deadline);
    }

    // ═════════════════════════════════════════════════════════════════
    // Initialize (7 tests)
    // ═════════════════════════════════════════════════════════════════

    function test_Initialize_setsAdmin() public view {
        assertTrue(biz.hasRole(0x00, admin));
        assertTrue(biz.hasRole(biz.FEE_ADMIN_ROLE(), admin));
        assertTrue(biz.hasRole(biz.PAUSER_ROLE(), admin));
        assertTrue(biz.hasRole(biz.UPGRADER_ROLE(), admin));
    }

    function test_Initialize_setsTreasury() public view {
        assertEq(biz.treasury(), treasury);
    }

    function test_Initialize_setsPlatformFeeBps() public view {
        assertEq(biz.platformFeeBps(), DEFAULT_FEE_BPS);
    }

    function test_Initialize_revertOnZeroAdmin() public {
        LksBusinessV8 impl = new LksBusinessV8();
        bytes memory data = abi.encodeWithSelector(
            LksBusinessV8.initialize.selector, address(0), treasury, DEFAULT_FEE_BPS
        );
        vm.expectRevert(ZeroAddress.selector);
        new ERC1967Proxy(address(impl), data);
    }

    function test_Initialize_revertOnZeroTreasury() public {
        LksBusinessV8 impl = new LksBusinessV8();
        bytes memory data = abi.encodeWithSelector(
            LksBusinessV8.initialize.selector, admin, address(0), DEFAULT_FEE_BPS
        );
        vm.expectRevert(ZeroAddress.selector);
        new ERC1967Proxy(address(impl), data);
    }

    function test_Initialize_revertOnFeeTooHigh() public {
        LksBusinessV8 impl = new LksBusinessV8();
        bytes memory data = abi.encodeWithSelector(
            LksBusinessV8.initialize.selector, admin, treasury, uint16(3001)
        );
        vm.expectRevert(abi.encodeWithSelector(FeeTooHigh.selector, uint16(3001), uint16(3000)));
        new ERC1967Proxy(address(impl), data);
    }

    function test_Initialize_canBeCalledOnce() public {
        vm.expectRevert();
        biz.initialize(admin, treasury, DEFAULT_FEE_BPS);
    }

    // ═════════════════════════════════════════════════════════════════
    // projectIdOf (3 tests)
    // ═════════════════════════════════════════════════════════════════

    function test_ProjectIdOf_isDeterministic() public view {
        assertEq(biz.projectIdOf(alice, SALT_1), biz.projectIdOf(alice, SALT_1));
    }

    function test_ProjectIdOf_differsByCreator() public view {
        assertTrue(biz.projectIdOf(alice, SALT_1) != biz.projectIdOf(bob, SALT_1));
    }

    function test_ProjectIdOf_differsBySalt() public view {
        assertTrue(biz.projectIdOf(alice, SALT_1) != biz.projectIdOf(alice, SALT_2));
    }

    // ═════════════════════════════════════════════════════════════════
    // createProject (10 tests)
    // ═════════════════════════════════════════════════════════════════

    function test_CreateProject_setsAllFields() public {
        bytes32 id = _create(alice, SALT_1, 10 ether, 7 days);
        ILksBusinessV8.Project memory p = biz.project(id);
        assertEq(p.creator, alice);
        assertEq(uint256(p.deadline), block.timestamp + 7 days);
        assertEq(uint256(p.goal), 10 ether);
        assertEq(uint256(p.raised), 0);
        assertEq(uint256(p.status), uint256(ILksBusinessV8.ProjectStatus.ACTIVE));
    }

    function test_CreateProject_emitsEvent() public {
        bytes32 expectedId = biz.projectIdOf(alice, SALT_1);
        uint64 deadline = uint64(block.timestamp) + 7 days;
        vm.expectEmit(true, true, false, true);
        emit ProjectCreated(expectedId, alice, 10 ether, deadline);
        vm.prank(alice);
        biz.createProject(SALT_1, 10 ether, deadline);
    }

    function test_CreateProject_returnsId() public {
        uint64 deadline = uint64(block.timestamp) + 7 days;
        vm.prank(alice);
        bytes32 got = biz.createProject(SALT_1, 10 ether, deadline);
        assertEq(got, biz.projectIdOf(alice, SALT_1));
    }

    function test_CreateProject_revertOnZeroGoal() public {
        vm.expectRevert(ZeroAmount.selector);
        vm.prank(alice);
        biz.createProject(SALT_1, 0, uint64(block.timestamp) + 7 days);
    }

    function test_CreateProject_revertOnDeadlinePast() public {
        vm.warp(1000);
        vm.expectRevert(DeadlinePassed.selector);
        vm.prank(alice);
        biz.createProject(SALT_1, 10 ether, 999);
    }

    function test_CreateProject_revertOnDurationTooShort() public {
        vm.expectRevert(InvalidConfig.selector);
        vm.prank(alice);
        biz.createProject(SALT_1, 10 ether, uint64(block.timestamp) + 30 minutes);
    }

    function test_CreateProject_revertOnDurationTooLong() public {
        vm.expectRevert(InvalidConfig.selector);
        vm.prank(alice);
        biz.createProject(SALT_1, 10 ether, uint64(block.timestamp) + 366 days);
    }

    function test_CreateProject_revertOnDuplicate() public {
        _create(alice, SALT_1, 10 ether, 7 days);
        bytes32 id = biz.projectIdOf(alice, SALT_1);
        vm.expectRevert(abi.encodeWithSelector(ProjectExists.selector, id));
        vm.prank(alice);
        biz.createProject(SALT_1, 5 ether, uint64(block.timestamp) + 7 days);
    }

    function test_CreateProject_differentSaltsAllowed() public {
        _create(alice, SALT_1, 10 ether, 7 days);
        _create(alice, SALT_2, 5 ether, 7 days);
        // Both exist
        assertEq(uint256(biz.projectStatus(biz.projectIdOf(alice, SALT_1))), uint256(ILksBusinessV8.ProjectStatus.ACTIVE));
        assertEq(uint256(biz.projectStatus(biz.projectIdOf(alice, SALT_2))), uint256(ILksBusinessV8.ProjectStatus.ACTIVE));
    }

    function test_CreateProject_revertWhenPaused() public {
        vm.prank(admin);
        biz.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(alice);
        biz.createProject(SALT_1, 10 ether, uint64(block.timestamp) + 7 days);
    }

    // ═════════════════════════════════════════════════════════════════
    // fund (10 tests)
    // ═════════════════════════════════════════════════════════════════

    function test_Fund_incrementsRaised() public {
        bytes32 id = _create(alice, SALT_1, 10 ether, 7 days);
        vm.prank(bob);
        biz.fund{value: 1 ether}(id);
        assertEq(uint256(biz.project(id).raised), 1 ether);
    }

    function test_Fund_aggregatesContributions() public {
        bytes32 id = _create(alice, SALT_1, 10 ether, 7 days);
        vm.prank(bob);
        biz.fund{value: 1 ether}(id);
        vm.prank(bob);
        biz.fund{value: 2 ether}(id);
        assertEq(biz.contribution(id, bob), 3 ether);
        assertEq(uint256(biz.project(id).raised), 3 ether);
    }

    function test_Fund_multipleContributors() public {
        bytes32 id = _create(alice, SALT_1, 10 ether, 7 days);
        vm.prank(bob);
        biz.fund{value: 1 ether}(id);
        vm.prank(carol);
        biz.fund{value: 2 ether}(id);
        assertEq(biz.contribution(id, bob), 1 ether);
        assertEq(biz.contribution(id, carol), 2 ether);
        assertEq(uint256(biz.project(id).raised), 3 ether);
    }

    function test_Fund_emitsEvent() public {
        bytes32 id = _create(alice, SALT_1, 10 ether, 7 days);
        vm.expectEmit(true, true, false, true);
        emit Funded(id, bob, 1 ether, 1 ether);
        vm.prank(bob);
        biz.fund{value: 1 ether}(id);
    }

    function test_Fund_revertOnZero() public {
        bytes32 id = _create(alice, SALT_1, 10 ether, 7 days);
        vm.expectRevert(ZeroAmount.selector);
        vm.prank(bob);
        biz.fund{value: 0}(id);
    }

    function test_Fund_revertOnUnknown() public {
        bytes32 unknown = keccak256("nope");
        vm.expectRevert(abi.encodeWithSelector(ProjectNotFound.selector, unknown));
        vm.prank(bob);
        biz.fund{value: 1 ether}(unknown);
    }

    function test_Fund_revertAfterDeadline() public {
        bytes32 id = _create(alice, SALT_1, 10 ether, 7 days);
        vm.warp(block.timestamp + 8 days);
        vm.expectRevert(DeadlinePassed.selector);
        vm.prank(bob);
        biz.fund{value: 1 ether}(id);
    }

    function test_Fund_revertAfterCancelled() public {
        bytes32 id = _create(alice, SALT_1, 10 ether, 7 days);
        vm.prank(alice);
        biz.cancelProject(id);
        vm.expectRevert(abi.encodeWithSelector(ProjectNotFound.selector, id));
        vm.prank(bob);
        biz.fund{value: 1 ether}(id);
    }

    function test_Fund_revertWhenPaused() public {
        bytes32 id = _create(alice, SALT_1, 10 ether, 7 days);
        vm.prank(admin);
        biz.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(bob);
        biz.fund{value: 1 ether}(id);
    }

    function test_Fund_overGoalAccepted() public {
        bytes32 id = _create(alice, SALT_1, 10 ether, 7 days);
        vm.prank(bob);
        biz.fund{value: 15 ether}(id);
        assertEq(uint256(biz.project(id).raised), 15 ether);
    }

    // ═════════════════════════════════════════════════════════════════
    // withdrawFunds (10 tests)
    // ═════════════════════════════════════════════════════════════════

    function test_Withdraw_transfersToCreator_simRef() public {
        bytes32 id = _create(alice, SALT_1, 10 ether, 7 days);
        vm.prank(bob);
        biz.fund{value: 12 ether}(id);
        vm.warp(block.timestamp + 8 days);

        (uint256 expectedCreator,) = LksFeeSim.feeSplit(12 ether, DEFAULT_FEE_BPS);
        uint256 before_ = alice.balance;
        vm.prank(alice);
        biz.withdrawFunds(id);
        assertEq(alice.balance - before_, expectedCreator);
    }

    function test_Withdraw_creditsPlatformFees_simRef() public {
        bytes32 id = _create(alice, SALT_1, 10 ether, 7 days);
        vm.prank(bob);
        biz.fund{value: 12 ether}(id);
        vm.warp(block.timestamp + 8 days);

        (, uint256 expectedFee) = LksFeeSim.feeSplit(12 ether, DEFAULT_FEE_BPS);
        vm.prank(alice);
        biz.withdrawFunds(id);
        assertEq(biz.accumulatedPlatformFees(), expectedFee);
    }

    function test_Withdraw_setsStatusWithdrawn() public {
        bytes32 id = _create(alice, SALT_1, 10 ether, 7 days);
        vm.prank(bob);
        biz.fund{value: 12 ether}(id);
        vm.warp(block.timestamp + 8 days);
        vm.prank(alice);
        biz.withdrawFunds(id);
        assertEq(uint256(biz.project(id).status), uint256(ILksBusinessV8.ProjectStatus.WITHDRAWN));
        assertEq(uint256(biz.projectStatus(id)), uint256(ILksBusinessV8.ProjectStatus.WITHDRAWN));
    }

    function test_Withdraw_emitsEvent() public {
        bytes32 id = _create(alice, SALT_1, 10 ether, 7 days);
        vm.prank(bob);
        biz.fund{value: 12 ether}(id);
        vm.warp(block.timestamp + 8 days);
        (uint256 ca, uint256 pf) = LksFeeSim.feeSplit(12 ether, DEFAULT_FEE_BPS);
        vm.expectEmit(true, true, false, true);
        emit FundsWithdrawn(id, alice, ca, pf);
        vm.prank(alice);
        biz.withdrawFunds(id);
    }

    function test_Withdraw_revertOnUnknown() public {
        bytes32 unknown = keccak256("nope");
        vm.expectRevert(abi.encodeWithSelector(ProjectNotFound.selector, unknown));
        biz.withdrawFunds(unknown);
    }

    function test_Withdraw_revertOnNotCreator() public {
        bytes32 id = _create(alice, SALT_1, 10 ether, 7 days);
        vm.prank(bob);
        biz.fund{value: 12 ether}(id);
        vm.warp(block.timestamp + 8 days);
        vm.expectRevert(abi.encodeWithSelector(NotProjectCreator.selector, bob, alice));
        vm.prank(bob);
        biz.withdrawFunds(id);
    }

    function test_Withdraw_revertBeforeDeadline() public {
        bytes32 id = _create(alice, SALT_1, 10 ether, 7 days);
        vm.prank(bob);
        biz.fund{value: 12 ether}(id);
        vm.expectRevert(DeadlineNotReached.selector);
        vm.prank(alice);
        biz.withdrawFunds(id);
    }

    function test_Withdraw_revertOnGoalNotReached() public {
        bytes32 id = _create(alice, SALT_1, 10 ether, 7 days);
        vm.prank(bob);
        biz.fund{value: 5 ether}(id);
        vm.warp(block.timestamp + 8 days);
        vm.expectRevert(GoalNotReached.selector);
        vm.prank(alice);
        biz.withdrawFunds(id);
    }

    function test_Withdraw_revertOnDoubleWithdraw() public {
        bytes32 id = _create(alice, SALT_1, 10 ether, 7 days);
        vm.prank(bob);
        biz.fund{value: 12 ether}(id);
        vm.warp(block.timestamp + 8 days);
        vm.prank(alice);
        biz.withdrawFunds(id);
        vm.expectRevert(AlreadyWithdrawn.selector);
        vm.prank(alice);
        biz.withdrawFunds(id);
    }

    function test_Withdraw_revertOnCancelled() public {
        bytes32 id = _create(alice, SALT_1, 10 ether, 7 days);
        vm.prank(bob);
        biz.fund{value: 12 ether}(id);
        // Admin cancels (since raised > 0)
        vm.prank(admin);
        biz.cancelProject(id);
        vm.warp(block.timestamp + 8 days);
        vm.expectRevert(AlreadyWithdrawn.selector);
        vm.prank(alice);
        biz.withdrawFunds(id);
    }

    // ═════════════════════════════════════════════════════════════════
    // refund (8 tests)
    // ═════════════════════════════════════════════════════════════════

    function test_Refund_transfersExactAmount() public {
        bytes32 id = _create(alice, SALT_1, 10 ether, 7 days);
        vm.prank(bob);
        biz.fund{value: 3 ether}(id);
        vm.warp(block.timestamp + 8 days);
        // Goal not reached → REFUNDABLE
        uint256 before_ = bob.balance;
        vm.prank(bob);
        biz.refund(id);
        assertEq(bob.balance - before_, 3 ether);
    }

    function test_Refund_zerosOutContribution() public {
        bytes32 id = _create(alice, SALT_1, 10 ether, 7 days);
        vm.prank(bob);
        biz.fund{value: 3 ether}(id);
        vm.warp(block.timestamp + 8 days);
        vm.prank(bob);
        biz.refund(id);
        assertEq(biz.contribution(id, bob), 0);
    }

    function test_Refund_emitsEvent() public {
        bytes32 id = _create(alice, SALT_1, 10 ether, 7 days);
        vm.prank(bob);
        biz.fund{value: 3 ether}(id);
        vm.warp(block.timestamp + 8 days);
        vm.expectEmit(true, true, false, true);
        emit Refunded(id, bob, 3 ether);
        vm.prank(bob);
        biz.refund(id);
    }

    function test_Refund_afterCancelAllowedEvenBeforeDeadline() public {
        bytes32 id = _create(alice, SALT_1, 10 ether, 7 days);
        vm.prank(bob);
        biz.fund{value: 3 ether}(id);
        vm.prank(admin);
        biz.cancelProject(id);
        // Refund OK before deadline because status == CANCELLED
        vm.prank(bob);
        biz.refund(id);
        assertEq(biz.contribution(id, bob), 0);
    }

    function test_Refund_revertBeforeDeadlineWhenActive() public {
        bytes32 id = _create(alice, SALT_1, 10 ether, 7 days);
        vm.prank(bob);
        biz.fund{value: 3 ether}(id);
        vm.expectRevert(DeadlineNotReached.selector);
        vm.prank(bob);
        biz.refund(id);
    }

    function test_Refund_revertWhenGoalReached() public {
        bytes32 id = _create(alice, SALT_1, 10 ether, 7 days);
        vm.prank(bob);
        biz.fund{value: 12 ether}(id);
        vm.warp(block.timestamp + 8 days);
        vm.expectRevert(GoalAlreadyReached.selector);
        vm.prank(bob);
        biz.refund(id);
    }

    function test_Refund_revertOnDoubleRefund() public {
        bytes32 id = _create(alice, SALT_1, 10 ether, 7 days);
        vm.prank(bob);
        biz.fund{value: 3 ether}(id);
        vm.warp(block.timestamp + 8 days);
        vm.prank(bob);
        biz.refund(id);
        vm.expectRevert(NothingToRefund.selector);
        vm.prank(bob);
        biz.refund(id);
    }

    function test_Refund_revertOnNonContributor() public {
        bytes32 id = _create(alice, SALT_1, 10 ether, 7 days);
        vm.prank(bob);
        biz.fund{value: 3 ether}(id);
        vm.warp(block.timestamp + 8 days);
        vm.expectRevert(NothingToRefund.selector);
        vm.prank(carol);
        biz.refund(id);
    }

    // ═════════════════════════════════════════════════════════════════
    // cancelProject (5 tests)
    // ═════════════════════════════════════════════════════════════════

    function test_Cancel_creatorWhenNoContributions() public {
        bytes32 id = _create(alice, SALT_1, 10 ether, 7 days);
        vm.expectEmit(true, false, false, false);
        emit ProjectCancelled(id);
        vm.prank(alice);
        biz.cancelProject(id);
        assertEq(uint256(biz.projectStatus(id)), uint256(ILksBusinessV8.ProjectStatus.CANCELLED));
    }

    function test_Cancel_creatorRevertWhenContributions() public {
        bytes32 id = _create(alice, SALT_1, 10 ether, 7 days);
        vm.prank(bob);
        biz.fund{value: 1 ether}(id);
        vm.expectRevert(GoalAlreadyReached.selector);
        vm.prank(alice);
        biz.cancelProject(id);
    }

    function test_Cancel_adminWithContributions() public {
        bytes32 id = _create(alice, SALT_1, 10 ether, 7 days);
        vm.prank(bob);
        biz.fund{value: 1 ether}(id);
        vm.prank(admin);
        biz.cancelProject(id);
        assertEq(uint256(biz.projectStatus(id)), uint256(ILksBusinessV8.ProjectStatus.CANCELLED));
    }

    function test_Cancel_revertOnNonCreatorNonAdmin() public {
        bytes32 id = _create(alice, SALT_1, 10 ether, 7 days);
        vm.expectRevert(abi.encodeWithSelector(NotProjectCreator.selector, bob, alice));
        vm.prank(bob);
        biz.cancelProject(id);
    }

    function test_Cancel_revertOnAlreadyCancelled() public {
        bytes32 id = _create(alice, SALT_1, 10 ether, 7 days);
        vm.prank(alice);
        biz.cancelProject(id);
        vm.expectRevert(abi.encodeWithSelector(ProjectNotFound.selector, id));
        vm.prank(alice);
        biz.cancelProject(id);
    }

    // ═════════════════════════════════════════════════════════════════
    // withdrawPlatformFees (3 tests)
    // ═════════════════════════════════════════════════════════════════

    function test_WithdrawPlatformFees_transfersToTreasury() public {
        bytes32 id = _create(alice, SALT_1, 10 ether, 7 days);
        vm.prank(bob);
        biz.fund{value: 12 ether}(id);
        vm.warp(block.timestamp + 8 days);
        vm.prank(alice);
        biz.withdrawFunds(id);
        (, uint256 expectedFee) = LksFeeSim.feeSplit(12 ether, DEFAULT_FEE_BPS);

        uint256 before_ = treasury.balance;
        biz.withdrawPlatformFees();
        assertEq(treasury.balance - before_, expectedFee);
    }

    function test_WithdrawPlatformFees_zerosOut() public {
        bytes32 id = _create(alice, SALT_1, 10 ether, 7 days);
        vm.prank(bob);
        biz.fund{value: 12 ether}(id);
        vm.warp(block.timestamp + 8 days);
        vm.prank(alice);
        biz.withdrawFunds(id);
        biz.withdrawPlatformFees();
        assertEq(biz.accumulatedPlatformFees(), 0);
    }

    function test_WithdrawPlatformFees_revertOnZero() public {
        vm.expectRevert(NothingToWithdraw.selector);
        biz.withdrawPlatformFees();
    }

    // ═════════════════════════════════════════════════════════════════
    // Status calculation (4 tests)
    // ═════════════════════════════════════════════════════════════════

    function test_Status_NoneForUnknown() public view {
        assertEq(uint256(biz.projectStatus(keccak256("nope"))), uint256(ILksBusinessV8.ProjectStatus.NONE));
    }

    function test_Status_ActiveBeforeDeadline() public {
        bytes32 id = _create(alice, SALT_1, 10 ether, 7 days);
        assertEq(uint256(biz.projectStatus(id)), uint256(ILksBusinessV8.ProjectStatus.ACTIVE));
    }

    function test_Status_FundedAfterDeadlineGoalReached() public {
        bytes32 id = _create(alice, SALT_1, 10 ether, 7 days);
        vm.prank(bob);
        biz.fund{value: 12 ether}(id);
        vm.warp(block.timestamp + 8 days);
        assertEq(uint256(biz.projectStatus(id)), uint256(ILksBusinessV8.ProjectStatus.FUNDED));
    }

    function test_Status_RefundableAfterDeadlineGoalNotReached() public {
        bytes32 id = _create(alice, SALT_1, 10 ether, 7 days);
        vm.prank(bob);
        biz.fund{value: 5 ether}(id);
        vm.warp(block.timestamp + 8 days);
        assertEq(uint256(biz.projectStatus(id)), uint256(ILksBusinessV8.ProjectStatus.REFUNDABLE));
    }

    // ═════════════════════════════════════════════════════════════════
    // Admin (4 tests)
    // ═════════════════════════════════════════════════════════════════

    function test_SetPlatformFeeBps_updatesValue() public {
        vm.prank(admin);
        biz.setPlatformFeeBps(500);
        assertEq(biz.platformFeeBps(), 500);
    }

    function test_SetPlatformFeeBps_revertOnTooHigh() public {
        vm.expectRevert(abi.encodeWithSelector(FeeTooHigh.selector, uint16(3001), uint16(3000)));
        vm.prank(admin);
        biz.setPlatformFeeBps(3001);
    }

    function test_SetPlatformFeeBps_revertOnUnauthorized() public {
        vm.expectRevert();
        vm.prank(bob);
        biz.setPlatformFeeBps(100);
    }

    function test_SetTreasury_updatesValue() public {
        vm.prank(admin);
        biz.setTreasury(carol);
        assertEq(biz.treasury(), carol);
    }

    // ═════════════════════════════════════════════════════════════════
    // FUZZ (5 tests)
    // ═════════════════════════════════════════════════════════════════

    /// @notice FUZZ-17 : withdraw split exact = LksFeeSim.feeSplit
    function testFuzz_Withdraw_splitMatchesSim(uint128 raised, uint16 feeBps) public {
        raised = uint128(bound(raised, 1 ether, 100 ether));
        feeBps = uint16(bound(feeBps, 0, 3000));

        vm.prank(admin);
        biz.setPlatformFeeBps(feeBps);

        bytes32 id = _create(alice, SALT_1, 1, 7 days); // goal=1 wei → easily reached
        vm.deal(bob, uint256(raised) + 1 ether);
        vm.prank(bob);
        biz.fund{value: raised}(id);
        vm.warp(block.timestamp + 8 days);

        (uint256 expectedCreator, uint256 expectedFee) = LksFeeSim.feeSplit(raised, feeBps);
        uint256 before_ = alice.balance;
        vm.prank(alice);
        biz.withdrawFunds(id);

        assertEq(alice.balance - before_, expectedCreator);
        assertEq(biz.accumulatedPlatformFees(), expectedFee);
        assertEq(expectedCreator + expectedFee, raised);
    }

    /// @notice FUZZ-18 : refund full après échec
    function testFuzz_Refund_fullAmount(uint96 nbContributors, uint128 amountEach) public {
        nbContributors = uint96(bound(uint256(nbContributors), 1, 20));
        amountEach     = uint128(bound(amountEach, 1e15, 1 ether));

        bytes32 id = _create(alice, SALT_1, 1000 ether, 7 days); // unreachable goal
        for (uint256 i = 0; i < nbContributors; ++i) {
            address c = address(uint160(0x5000 + i));
            vm.deal(c, uint256(amountEach) * 2);
            vm.prank(c);
            biz.fund{value: amountEach}(id);
        }
        vm.warp(block.timestamp + 8 days);

        for (uint256 i = 0; i < nbContributors; ++i) {
            address c = address(uint160(0x5000 + i));
            uint256 before_ = c.balance;
            vm.prank(c);
            biz.refund(id);
            assertEq(c.balance - before_, amountEach);
            assertEq(biz.contribution(id, c), 0);
        }
    }

    /// @notice FUZZ-19 : raised == sum(contributions[*]) always
    function testFuzz_RaisedEqualsContributions(uint8 nbContributors, uint128 baseAmount) public {
        nbContributors = uint8(bound(uint256(nbContributors), 1, 20));
        baseAmount     = uint128(bound(baseAmount, 1e15, 1 ether));

        bytes32 id = _create(alice, SALT_1, 1, 7 days);
        uint256 sum = 0;
        for (uint256 i = 0; i < nbContributors; ++i) {
            address c = address(uint160(0x6000 + i));
            uint256 amt = uint256(baseAmount) + (i * 1e15);
            vm.deal(c, amt + 1 ether);
            vm.prank(c);
            biz.fund{value: amt}(id);
            sum += amt;
        }
        assertEq(uint256(biz.project(id).raised), sum);
    }

    /// @notice FUZZ-20 : withdraw idempotent — second call reverts AlreadyWithdrawn
    function testFuzz_Withdraw_idempotent(uint128 raised) public {
        raised = uint128(bound(raised, 2 ether, 50 ether));
        bytes32 id = _create(alice, SALT_1, 1 ether, 7 days);
        vm.deal(bob, uint256(raised) + 1 ether);
        vm.prank(bob);
        biz.fund{value: raised}(id);
        vm.warp(block.timestamp + 8 days);

        vm.prank(alice);
        biz.withdrawFunds(id);
        vm.expectRevert(AlreadyWithdrawn.selector);
        vm.prank(alice);
        biz.withdrawFunds(id);
    }

    /// @notice FUZZ-21 : INV-13 invariant — raised - sum(refunds) ≤ contract balance
    function testFuzz_BalanceInvariant(uint8 nbRefund, uint128 amountEach) public {
        nbRefund   = uint8(bound(uint256(nbRefund), 1, 10));
        amountEach = uint128(bound(amountEach, 1e15, 1 ether));

        bytes32 id = _create(alice, SALT_1, 1000 ether, 7 days);
        for (uint256 i = 0; i < nbRefund; ++i) {
            address c = address(uint160(0x7000 + i));
            vm.deal(c, uint256(amountEach) * 2);
            vm.prank(c);
            biz.fund{value: amountEach}(id);
        }
        vm.warp(block.timestamp + 8 days);

        uint256 totalRefunded = 0;
        for (uint256 i = 0; i < nbRefund / 2; ++i) {
            address c = address(uint160(0x7000 + i));
            vm.prank(c);
            biz.refund(id);
            totalRefunded += amountEach;
        }
        uint256 expected = uint256(amountEach) * nbRefund - totalRefunded;
        assertEq(address(biz).balance, expected);
    }
}
