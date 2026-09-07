// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {LksCoreV8}   from "../src/core/LksCoreV8.sol";
import {LksCoreV8V2} from "../src/core/LksCoreV8V2.sol";

/// @dev Mock NFT identité minimal — implémente uniquement `balanceOf`.
contract MockIdentity {
    mapping(address => uint256) public balanceOf;

    function setBalance(address user, uint256 v) external {
        balanceOf[user] = v;
    }
}

/// @dev Mock qui revert dans `balanceOf` (test cross-call resilience).
contract RevertingIdentity {
    function balanceOf(address) external pure returns (uint256) {
        revert("oops");
    }
}

contract LksCoreV8V2Test is Test {
    LksCoreV8V2 internal core;
    MockIdentity internal identity;

    address internal admin    = address(0xA11CE);
    address internal treasury = address(0xBEEF);
    address internal alice    = address(0x1111);
    address internal bob      = address(0x2222);

    bytes32 internal constant MODULE_IDENTITY = keccak256("IDENTITY");
    bytes32 internal constant NODE_ID_ALICE   = bytes32(uint256(0xA11CE_FFEE));
    bytes32 internal constant NODE_ID_BOB     = bytes32(uint256(0xB0BB_DEAD));
    bytes32 internal constant UPGRADER_ROLE   = keccak256("UPGRADER_ROLE");

    event NodeIdBound(address indexed wallet, bytes32 indexed nodeId);
    event NodeIdUnbound(address indexed wallet, bytes32 indexed previousNodeId);

    function setUp() public {
        // Deploy V2 fresh (proxy starts on V2 impl).
        LksCoreV8V2 impl = new LksCoreV8V2();
        bytes memory initData = abi.encodeCall(LksCoreV8.initialize, (admin, treasury));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        core = LksCoreV8V2(address(proxy));

        identity = new MockIdentity();
        vm.prank(admin);
        core.registerModule(MODULE_IDENTITY, address(identity));
    }

    // =========================================================================
    // bindNodeId — happy path + reverts
    // =========================================================================

    function test_bindNodeId_writesMapping() public {
        identity.setBalance(alice, 1);
        vm.prank(alice);
        core.bindNodeId(NODE_ID_ALICE);
        assertEq(core.getNodeId(alice), NODE_ID_ALICE);
        assertTrue(core.hasNodeId(alice));
    }

    function test_bindNodeId_emitsEvent() public {
        identity.setBalance(alice, 1);
        vm.expectEmit(true, true, false, false);
        emit NodeIdBound(alice, NODE_ID_ALICE);
        vm.prank(alice);
        core.bindNodeId(NODE_ID_ALICE);
    }

    function test_bindNodeId_overwritesPrevious() public {
        identity.setBalance(alice, 1);
        vm.startPrank(alice);
        core.bindNodeId(NODE_ID_ALICE);
        core.bindNodeId(NODE_ID_BOB); // rebind
        vm.stopPrank();
        assertEq(core.getNodeId(alice), NODE_ID_BOB);
    }

    function test_bindNodeId_revertsWithoutNFT() public {
        // identity.balanceOf(alice) = 0
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("NotIdentityHolder(address)", alice));
        core.bindNodeId(NODE_ID_ALICE);
    }

    function test_bindNodeId_revertsZeroNodeId() public {
        identity.setBalance(alice, 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        core.bindNodeId(bytes32(0));
    }

    function test_bindNodeId_revertsWhenIdentityModuleMissing() public {
        // Deploy fresh proxy without registering identity module.
        LksCoreV8V2 impl = new LksCoreV8V2();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(LksCoreV8.initialize, (admin, treasury))
        );
        LksCoreV8V2 fresh = LksCoreV8V2(address(proxy));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("NotIdentityHolder(address)", alice));
        fresh.bindNodeId(NODE_ID_ALICE);
    }

    function test_bindNodeId_propagatesIdentityRevert() public {
        // Replace identity module with a reverting one.
        RevertingIdentity bad = new RevertingIdentity();
        vm.prank(admin);
        core.updateModule(MODULE_IDENTITY, address(bad));

        vm.prank(alice);
        vm.expectRevert(); // bubble-up "oops"
        core.bindNodeId(NODE_ID_ALICE);
    }

    function test_bindNodeId_revertsWhenPaused() public {
        identity.setBalance(alice, 1);
        vm.prank(admin);
        core.pause();
        vm.prank(alice);
        vm.expectRevert(); // EnforcedPause()
        core.bindNodeId(NODE_ID_ALICE);
    }

    // =========================================================================
    // unbindNodeId
    // =========================================================================

    function test_unbindNodeId_clearsMapping() public {
        identity.setBalance(alice, 1);
        vm.startPrank(alice);
        core.bindNodeId(NODE_ID_ALICE);
        assertTrue(core.hasNodeId(alice));
        core.unbindNodeId();
        vm.stopPrank();
        assertEq(core.getNodeId(alice), bytes32(0));
        assertFalse(core.hasNodeId(alice));
    }

    function test_unbindNodeId_emitsPreviousNodeId() public {
        identity.setBalance(alice, 1);
        vm.prank(alice);
        core.bindNodeId(NODE_ID_ALICE);

        vm.expectEmit(true, true, false, false);
        emit NodeIdUnbound(alice, NODE_ID_ALICE);
        vm.prank(alice);
        core.unbindNodeId();
    }

    function test_unbindNodeId_idempotentWhenUnset() public {
        // No bind first — unbind on empty mapping should not revert.
        vm.expectEmit(true, true, false, false);
        emit NodeIdUnbound(alice, bytes32(0));
        vm.prank(alice);
        core.unbindNodeId();
    }

    function test_unbindNodeId_doesNotRequireNFT() public {
        // User binds while owning NFT, then loses the NFT (transfers/burns it).
        identity.setBalance(alice, 1);
        vm.prank(alice);
        core.bindNodeId(NODE_ID_ALICE);
        identity.setBalance(alice, 0); // NFT gone

        // Should still be able to clean up.
        vm.prank(alice);
        core.unbindNodeId();
        assertEq(core.getNodeId(alice), bytes32(0));
    }

    // =========================================================================
    // getNodeId / hasNodeId reads
    // =========================================================================

    function test_getNodeId_returnsZeroIfUnbound() public view {
        assertEq(core.getNodeId(alice), bytes32(0));
        assertFalse(core.hasNodeId(alice));
    }

    function test_getNodeId_isolatedPerWallet() public {
        identity.setBalance(alice, 1);
        identity.setBalance(bob, 1);
        vm.prank(alice);
        core.bindNodeId(NODE_ID_ALICE);
        vm.prank(bob);
        core.bindNodeId(NODE_ID_BOB);

        assertEq(core.getNodeId(alice), NODE_ID_ALICE);
        assertEq(core.getNodeId(bob),   NODE_ID_BOB);
    }

    // =========================================================================
    // Storage / upgrade safety
    // =========================================================================

    function test_v1State_preservedAcrossV2Upgrade() public {
        // Deploy V1, write state, upgrade to V2, verify V1 state intact.
        LksCoreV8 v1Impl = new LksCoreV8();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(v1Impl),
            abi.encodeCall(LksCoreV8.initialize, (admin, treasury))
        );
        LksCoreV8 v1 = LksCoreV8(address(proxy));

        // Write some V1 state.
        vm.startPrank(admin);
        v1.registerModule(MODULE_IDENTITY, address(identity));
        v1.addReputation(alice, 42);
        vm.stopPrank();

        // Upgrade to V2 implementation.
        LksCoreV8V2 v2Impl = new LksCoreV8V2();
        vm.prank(admin);
        v1.upgradeToAndCall(address(v2Impl), "");

        // Re-cast and verify V1 state survived + V2 features work.
        LksCoreV8V2 v2 = LksCoreV8V2(address(proxy));
        assertEq(v2.treasury(), treasury);
        assertEq(v2.getReputation(alice), 42);
        assertEq(v2.getModule(MODULE_IDENTITY), address(identity));

        identity.setBalance(alice, 1);
        vm.prank(alice);
        v2.bindNodeId(NODE_ID_ALICE);
        assertEq(v2.getNodeId(alice), NODE_ID_ALICE);
    }

    // =========================================================================
    // Gas budget
    // =========================================================================

    function test_bindNodeId_gasBudget() public {
        identity.setBalance(alice, 1);
        vm.prank(alice);
        uint256 gasBefore = gasleft();
        core.bindNodeId(NODE_ID_ALICE);
        uint256 used = gasBefore - gasleft();
        // Plan target : < 80k. Cold SLOAD (registry+balance) + SSTORE_SET + event.
        assertLt(used, 80_000, "bindNodeId should cost < 80k gas");
    }

    // =========================================================================
    // Fuzz
    // =========================================================================

    function testFuzz_bindNodeId_arbitraryNonZero(bytes32 nodeId, address user) public {
        vm.assume(nodeId != bytes32(0));
        vm.assume(user != address(0));
        identity.setBalance(user, 1);
        vm.prank(user);
        core.bindNodeId(nodeId);
        assertEq(core.getNodeId(user), nodeId);
        assertTrue(core.hasNodeId(user));
    }

    function testFuzz_unbindNodeId_alwaysSucceeds(address user) public {
        vm.assume(user != address(0));
        vm.prank(user);
        core.unbindNodeId();
        assertEq(core.getNodeId(user), bytes32(0));
    }

    function testFuzz_bindThenUnbind_clears(bytes32 nodeId, address user) public {
        vm.assume(nodeId != bytes32(0));
        vm.assume(user != address(0));
        identity.setBalance(user, 1);
        vm.startPrank(user);
        core.bindNodeId(nodeId);
        core.unbindNodeId();
        vm.stopPrank();
        assertEq(core.getNodeId(user), bytes32(0));
    }
}
