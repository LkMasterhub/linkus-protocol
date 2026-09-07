// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/governance/LKSTimelock.sol";

/**
 * @title LKSTimelockTest
 * @notice Tests pour LKSTimelock
 * @dev Test coverage: Schedule, execute, cancel, delays, roles
 */
contract LKSTimelockTest is Test {
    LKSTimelock public timelock;

    address public admin = makeAddr("admin");
    address public proposer = makeAddr("proposer");
    address public executor = makeAddr("executor");
    address public target = makeAddr("target");

    uint256 public constant MIN_DELAY = 2 days;
    bytes32 public constant SALT = keccak256("test");

    event CallScheduled(
        bytes32 indexed id,
        uint256 indexed index,
        address target,
        uint256 value,
        bytes data,
        bytes32 predecessor,
        uint256 delay
    );

    event CallExecuted(bytes32 indexed id, uint256 indexed index, address target, uint256 value, bytes data);

    event CallCancelled(bytes32 indexed id);

    function setUp() public {
        address[] memory proposers = new address[](1);
        proposers[0] = proposer;

        address[] memory executors = new address[](1);
        executors[0] = executor;

        timelock = new LKSTimelock(MIN_DELAY, proposers, executors, admin);

        // Fund timelock
        vm.deal(address(timelock), 10 ether);
    }

    // ========================================================================
    // SCHEDULE TESTS
    // ========================================================================

    function test_Schedule_SUCCESS() public {
        bytes memory data = abi.encodeWithSignature("test()");
        bytes32 id = timelock.hashOperation(target, 0, data, bytes32(0), SALT);

        vm.prank(proposer);
        vm.expectEmit(true, true, false, true);
        emit CallScheduled(id, 0, target, 0, data, bytes32(0), MIN_DELAY);

        bytes32 returnedId = timelock.schedule(target, 0, data, bytes32(0), SALT);

        assertEq(returnedId, id);
        assertTrue(timelock.isOperation(id));
        assertTrue(timelock.isOperationPending(id));
    }

    function test_Schedule_OnlyProposer() public {
        bytes memory data = abi.encodeWithSignature("test()");

        vm.prank(makeAddr("random"));
        vm.expectRevert();
        timelock.schedule(target, 0, data, bytes32(0), SALT);
    }

    function test_Schedule_DuplicateRevert() public {
        bytes memory data = abi.encodeWithSignature("test()");

        vm.startPrank(proposer);

        timelock.schedule(target, 0, data, bytes32(0), SALT);

        bytes32 id = timelock.hashOperation(target, 0, data, bytes32(0), SALT);
        vm.expectRevert(abi.encodeWithSelector(LKSTimelock.OperationAlreadyScheduled.selector, id));
        timelock.schedule(target, 0, data, bytes32(0), SALT);

        vm.stopPrank();
    }

    function test_ScheduleBatch_SUCCESS() public {
        address[] memory targets = new address[](2);
        targets[0] = target;
        targets[1] = target;

        uint256[] memory values = new uint256[](2);
        values[0] = 0;
        values[1] = 1 ether;

        bytes[] memory payloads = new bytes[](2);
        payloads[0] = abi.encodeWithSignature("test1()");
        payloads[1] = abi.encodeWithSignature("test2()");

        vm.prank(proposer);
        bytes32 id = timelock.scheduleBatch(targets, values, payloads, bytes32(0), SALT);

        assertTrue(timelock.isOperationPending(id));
    }

    // ========================================================================
    // EXECUTE TESTS
    // ========================================================================

    function test_Execute_SUCCESS() public {
        // Deploy mock target contract
        MockTarget mockTarget = new MockTarget();

        bytes memory data = abi.encodeWithSignature("setValue(uint256)", 42);

        // Schedule
        vm.prank(proposer);
        timelock.schedule(address(mockTarget), 0, data, bytes32(0), SALT);

        // Wait for timelock
        vm.warp(block.timestamp + MIN_DELAY + 1);

        // Execute
        bytes32 id = timelock.hashOperation(address(mockTarget), 0, data, bytes32(0), SALT);

        vm.prank(executor);
        vm.expectEmit(true, true, false, true);
        emit CallExecuted(id, 0, address(mockTarget), 0, data);

        timelock.execute(address(mockTarget), 0, data, bytes32(0), SALT);

        // Verify execution
        assertEq(mockTarget.value(), 42);
        assertTrue(timelock.isOperationDone(id));
    }

    function test_Execute_NotReady() public {
        bytes memory data = abi.encodeWithSignature("test()");

        vm.prank(proposer);
        bytes32 id = timelock.schedule(target, 0, data, bytes32(0), SALT);

        // Try execute immediately → revert
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(LKSTimelock.OperationNotReady.selector, id));
        timelock.execute(target, 0, data, bytes32(0), SALT);
    }

    function test_Execute_OnlyExecutor() public {
        MockTarget mockTarget = new MockTarget();
        bytes memory data = abi.encodeWithSignature("setValue(uint256)", 42);

        vm.prank(proposer);
        timelock.schedule(address(mockTarget), 0, data, bytes32(0), SALT);

        vm.warp(block.timestamp + MIN_DELAY + 1);

        // Random user cannot execute
        vm.prank(makeAddr("random"));
        vm.expectRevert();
        timelock.execute(address(mockTarget), 0, data, bytes32(0), SALT);
    }

    function test_Execute_WithValue() public {
        MockTarget mockTarget = new MockTarget();
        bytes memory data = abi.encodeWithSignature("receiveEther()");

        vm.prank(proposer);
        timelock.schedule(address(mockTarget), 1 ether, data, bytes32(0), SALT);

        vm.warp(block.timestamp + MIN_DELAY + 1);

        vm.deal(executor, 1 ether);
        vm.prank(executor);
        timelock.execute{value: 1 ether}(address(mockTarget), 1 ether, data, bytes32(0), SALT);

        assertEq(address(mockTarget).balance, 1 ether);
    }

    function test_ExecuteBatch_SUCCESS() public {
        MockTarget mockTarget = new MockTarget();

        address[] memory targets = new address[](2);
        targets[0] = address(mockTarget);
        targets[1] = address(mockTarget);

        uint256[] memory values = new uint256[](2);
        values[0] = 0;
        values[1] = 0;

        bytes[] memory payloads = new bytes[](2);
        payloads[0] = abi.encodeWithSignature("setValue(uint256)", 10);
        payloads[1] = abi.encodeWithSignature("incrementValue()");

        // Schedule batch
        vm.prank(proposer);
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), SALT);

        vm.warp(block.timestamp + MIN_DELAY + 1);

        // Execute batch
        vm.prank(executor);
        timelock.executeBatch(targets, values, payloads, bytes32(0), SALT);

        // Verify both calls executed
        assertEq(mockTarget.value(), 11); // 10 + 1
    }

    // ========================================================================
    // CANCEL TESTS
    // ========================================================================

    function test_Cancel_SUCCESS() public {
        bytes memory data = abi.encodeWithSignature("test()");

        vm.prank(proposer);
        bytes32 id = timelock.schedule(target, 0, data, bytes32(0), SALT);

        // Admin can cancel
        vm.prank(admin);
        vm.expectEmit(true, false, false, false);
        emit CallCancelled(id);

        timelock.cancel(id);

        assertFalse(timelock.isOperation(id));
    }

    function test_Cancel_OnlyCanceller() public {
        bytes memory data = abi.encodeWithSignature("test()");

        vm.prank(proposer);
        bytes32 id = timelock.schedule(target, 0, data, bytes32(0), SALT);

        // Random user cannot cancel
        vm.prank(makeAddr("random"));
        vm.expectRevert();
        timelock.cancel(id);
    }

    // ========================================================================
    // DELAY TESTS
    // ========================================================================

    function test_UpdateDelay_SUCCESS() public {
        uint256 newDelay = 3 days;

        vm.prank(admin);
        timelock.updateDelay(newDelay);

        assertEq(timelock.delay(), newDelay);
    }

    function test_UpdateDelay_MinMax() public {
        vm.startPrank(admin);

        // Too low → revert
        vm.expectRevert(abi.encodeWithSelector(LKSTimelock.InvalidDelay.selector, 1 days));
        timelock.updateDelay(1 days);

        // Too high → revert
        vm.expectRevert(abi.encodeWithSelector(LKSTimelock.InvalidDelay.selector, 31 days));
        timelock.updateDelay(31 days);

        vm.stopPrank();
    }

    function test_ScheduleWithDelay_Custom() public {
        bytes memory data = abi.encodeWithSignature("test()");
        uint256 customDelay = 5 days;

        vm.prank(proposer);
        bytes32 id = timelock.scheduleWithDelay(target, 0, data, bytes32(0), SALT, customDelay);

        uint256 timestamp = timelock.getTimestamp(id);
        assertEq(timestamp, block.timestamp + customDelay);
    }

    // ========================================================================
    // STATE TESTS
    // ========================================================================

    function test_GetOperationState_Lifecycle() public {
        bytes memory data = abi.encodeWithSignature("test()");

        // UNSET
        bytes32 id = timelock.hashOperation(target, 0, data, bytes32(0), SALT);
        assertEq(uint256(timelock.getOperationState(id)), uint256(LKSTimelock.OperationState.UNSET));

        // WAITING
        vm.prank(proposer);
        timelock.schedule(target, 0, data, bytes32(0), SALT);
        assertEq(uint256(timelock.getOperationState(id)), uint256(LKSTimelock.OperationState.WAITING));

        // READY
        vm.warp(block.timestamp + MIN_DELAY + 1);
        assertEq(uint256(timelock.getOperationState(id)), uint256(LKSTimelock.OperationState.READY));

        // DONE
        vm.prank(executor);
        timelock.execute(target, 0, data, bytes32(0), SALT);
        assertEq(uint256(timelock.getOperationState(id)), uint256(LKSTimelock.OperationState.DONE));
    }

    // ========================================================================
    // PREDECESSOR TESTS
    // ========================================================================

    function test_Predecessor_EnforcesOrder() public {
        MockTarget mockTarget = new MockTarget();

        // Operation 1
        bytes memory data1 = abi.encodeWithSignature("setValue(uint256)", 10);
        bytes32 id1 = timelock.hashOperation(address(mockTarget), 0, data1, bytes32(0), SALT);

        vm.prank(proposer);
        timelock.schedule(address(mockTarget), 0, data1, bytes32(0), SALT);

        // Operation 2 (depends on 1)
        bytes memory data2 = abi.encodeWithSignature("incrementValue()");
        bytes32 salt2 = keccak256("test2");
        bytes32 id2 = timelock.hashOperation(address(mockTarget), 0, data2, id1, salt2);

        vm.prank(proposer);
        timelock.schedule(address(mockTarget), 0, data2, id1, salt2);

        vm.warp(block.timestamp + MIN_DELAY + 1);

        // Try execute op2 before op1 → revert
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(LKSTimelock.PredecessorNotExecuted.selector, id1));
        timelock.execute(address(mockTarget), 0, data2, id1, salt2);

        // Execute op1 first
        vm.prank(executor);
        timelock.execute(address(mockTarget), 0, data1, bytes32(0), SALT);

        // Now op2 can execute
        vm.prank(executor);
        timelock.execute(address(mockTarget), 0, data2, id1, salt2);

        assertEq(mockTarget.value(), 11);
    }
}

// ============================================================================
// MOCK TARGET CONTRACT
// ============================================================================

contract MockTarget {
    uint256 public value;

    function setValue(uint256 _value) external {
        value = _value;
    }

    function incrementValue() external {
        value++;
    }

    function receiveEther() external payable {
        // Accept ETH
    }

    receive() external payable {}
}
