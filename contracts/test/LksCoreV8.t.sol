// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {LksCoreV8} from "../src/core/LksCoreV8.sol";
import {ILksCoreV8} from "../src/core/ILksCoreV8.sol";
import {ITier1155}  from "../src/tier/ITier1155.sol";

/// @dev Mock Tier1155 minimal pour tester getTier read-through.
contract MockTier1155 {
    mapping(address => mapping(uint256 => bool)) public active;

    function setActive(address user, uint256 tierId, bool v) external {
        active[user][tierId] = v;
    }

    function isActive(address user, uint256 tierId) external view returns (bool) {
        return active[user][tierId];
    }
}

/// @dev Mock qui revert à `isActive` pour tester le try/catch.
contract RevertingTier1155 {
    function isActive(address, uint256) external pure returns (bool) {
        revert("oops");
    }
}

contract LksCoreV8Test is Test {
    LksCoreV8 internal core;
    MockTier1155 internal tier;

    address internal admin    = address(0xA11CE);
    address internal treasury = address(0xBEEF);
    address internal alice    = address(0x1111);
    address internal bob      = address(0x2222);
    address internal carol    = address(0x3333);

    bytes32 internal constant WRITER_ROLE         = keccak256("WRITER_ROLE");
    bytes32 internal constant REGISTRY_ADMIN_ROLE = keccak256("REGISTRY_ADMIN_ROLE");
    bytes32 internal constant PAUSER_ROLE         = keccak256("PAUSER_ROLE");
    bytes32 internal constant UPGRADER_ROLE       = keccak256("UPGRADER_ROLE");
    bytes32 internal constant MODULE_TIER1155     = keccak256("TIER1155");
    bytes32 internal constant MODULE_CONTENT1155  = keccak256("CONTENT1155");

    event TierUpdated(address indexed user, uint8 tier, uint48 expiry);
    event ReputationChanged(address indexed user, uint96 before_, uint96 after_);
    event ModuleRegistered(bytes32 indexed key, address module);
    event ReputationCapSet(address indexed user, uint256 cap);
    event Flagged(address indexed user, bool flagged);
    event TreasuryUpdated(address indexed treasury);

    function setUp() public {
        LksCoreV8 impl = new LksCoreV8();
        bytes memory initData = abi.encodeCall(LksCoreV8.initialize, (admin, treasury));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        core = LksCoreV8(address(proxy));
        tier = new MockTier1155();
    }

    // =========================================================================
    // Initialization — 6 tests
    // =========================================================================

    function test_Init_grantsAdminRoles() public view {
        assertTrue(core.hasRole(0x00, admin));
        assertTrue(core.hasRole(WRITER_ROLE, admin));
        assertTrue(core.hasRole(REGISTRY_ADMIN_ROLE, admin));
        assertTrue(core.hasRole(PAUSER_ROLE, admin));
        assertTrue(core.hasRole(UPGRADER_ROLE, admin));
    }

    function test_Init_setsTreasury() public view {
        assertEq(core.treasury(), treasury);
    }

    function test_Init_emitsTreasuryUpdated() public {
        LksCoreV8 impl = new LksCoreV8();
        vm.expectEmit(true, false, false, true);
        emit TreasuryUpdated(treasury);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(LksCoreV8.initialize, (admin, treasury))
        );
    }

    function test_Init_revertsZeroAdmin() public {
        LksCoreV8 impl = new LksCoreV8();
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(LksCoreV8.initialize, (address(0), treasury))
        );
    }

    function test_Init_revertsZeroTreasury() public {
        LksCoreV8 impl = new LksCoreV8();
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(LksCoreV8.initialize, (admin, address(0)))
        );
    }

    function test_Init_cannotReinitialize() public {
        vm.expectRevert();
        core.initialize(admin, treasury);
    }

    // =========================================================================
    // Constants — 3 tests
    // =========================================================================

    function test_Constants_DEFAULT_REPUTATION_CAP() public view {
        assertEq(core.DEFAULT_REPUTATION_CAP(), 1_000_000);
    }

    function test_Constants_moduleKeys() public view {
        assertEq(core.MODULE_TIER1155(), keccak256("TIER1155"));
        assertEq(core.MODULE_CONTENT1155(), keccak256("CONTENT1155"));
        assertEq(core.MODULE_TIPVAULT(), keccak256("TIPVAULT"));
        assertEq(core.MODULE_BUSINESS(), keccak256("BUSINESS"));
    }

    function test_Constants_roleHashes() public view {
        assertEq(core.WRITER_ROLE(), keccak256("WRITER_ROLE"));
        assertEq(core.REGISTRY_ADMIN_ROLE(), keccak256("REGISTRY_ADMIN_ROLE"));
        assertEq(core.PAUSER_ROLE(), keccak256("PAUSER_ROLE"));
        assertEq(core.UPGRADER_ROLE(), keccak256("UPGRADER_ROLE"));
    }

    // =========================================================================
    // addReputation — 9 tests
    // =========================================================================

    function test_AddRep_increases() public {
        vm.prank(admin);
        core.addReputation(alice, 100);
        assertEq(core.getReputation(alice), 100);
    }

    function test_AddRep_cumulates() public {
        vm.prank(admin);
        core.addReputation(alice, 100);
        vm.prank(admin);
        core.addReputation(alice, 50);
        assertEq(core.getReputation(alice), 150);
    }

    function test_AddRep_emitsEvent() public {
        vm.expectEmit(true, false, false, true, address(core));
        emit ReputationChanged(alice, 0, 100);
        vm.prank(admin);
        core.addReputation(alice, 100);
    }

    function test_AddRep_revertsZeroAmount() public {
        vm.expectRevert(abi.encodeWithSignature("ZeroAmount()"));
        vm.prank(admin);
        core.addReputation(alice, 0);
    }

    function test_AddRep_revertsZeroAddress() public {
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        vm.prank(admin);
        core.addReputation(address(0), 100);
    }

    function test_AddRep_revertsNonWriter() public {
        vm.expectRevert();
        vm.prank(alice);
        core.addReputation(bob, 100);
    }

    function test_AddRep_revertsExceedingCap() public {
        uint96 cap = uint96(core.DEFAULT_REPUTATION_CAP());
        vm.prank(admin);
        core.addReputation(alice, cap);
        vm.expectRevert(
            abi.encodeWithSignature("ReputationCapExceeded(uint96,uint96)", cap, cap)
        );
        vm.prank(admin);
        core.addReputation(alice, 1);
    }

    function test_AddRep_acceptsExactCap() public {
        uint96 cap = uint96(core.DEFAULT_REPUTATION_CAP());
        vm.prank(admin);
        core.addReputation(alice, cap);
        assertEq(core.getReputation(alice), cap);
    }

    function test_AddRep_revertsWhenPaused() public {
        vm.prank(admin);
        core.pause();
        vm.expectRevert();
        vm.prank(admin);
        core.addReputation(alice, 100);
    }

    // =========================================================================
    // slashReputation — 6 tests
    // =========================================================================

    function test_SlashRep_decreases() public {
        vm.prank(admin);
        core.addReputation(alice, 100);
        vm.prank(admin);
        core.slashReputation(alice, 30);
        assertEq(core.getReputation(alice), 70);
    }

    function test_SlashRep_saturatesAtZero() public {
        vm.prank(admin);
        core.addReputation(alice, 100);
        vm.prank(admin);
        core.slashReputation(alice, 999);
        assertEq(core.getReputation(alice), 0);
    }

    function test_SlashRep_emitsEvent() public {
        vm.prank(admin);
        core.addReputation(alice, 100);
        vm.expectEmit(true, false, false, true, address(core));
        emit ReputationChanged(alice, 100, 60);
        vm.prank(admin);
        core.slashReputation(alice, 40);
    }

    function test_SlashRep_revertsZeroAmount() public {
        vm.expectRevert(abi.encodeWithSignature("ZeroAmount()"));
        vm.prank(admin);
        core.slashReputation(alice, 0);
    }

    function test_SlashRep_revertsZeroAddress() public {
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        vm.prank(admin);
        core.slashReputation(address(0), 1);
    }

    function test_SlashRep_revertsNonWriter() public {
        vm.expectRevert();
        vm.prank(alice);
        core.slashReputation(bob, 10);
    }

    // =========================================================================
    // flag — 4 tests
    // =========================================================================

    function test_Flag_setsFlagged() public {
        vm.prank(admin);
        core.flag(alice, true);
        assertTrue(core.isFlagged(alice));
    }

    function test_Flag_unsetsFlagged() public {
        vm.prank(admin);
        core.flag(alice, true);
        vm.prank(admin);
        core.flag(alice, false);
        assertFalse(core.isFlagged(alice));
    }

    function test_Flag_emitsEvent() public {
        vm.expectEmit(true, false, false, true, address(core));
        emit Flagged(alice, true);
        vm.prank(admin);
        core.flag(alice, true);
    }

    function test_Flag_revertsNonWriter() public {
        vm.expectRevert();
        vm.prank(alice);
        core.flag(bob, true);
    }

    function test_Flag_revertsZeroAddress() public {
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        vm.prank(admin);
        core.flag(address(0), true);
    }

    // =========================================================================
    // registerModule / updateModule — 8 tests
    // =========================================================================

    function test_RegisterModule_setsAddress() public {
        vm.prank(admin);
        core.registerModule(MODULE_TIER1155, address(tier));
        assertEq(core.getModule(MODULE_TIER1155), address(tier));
    }

    function test_RegisterModule_emitsEvent() public {
        vm.expectEmit(true, false, false, true, address(core));
        emit ModuleRegistered(MODULE_TIER1155, address(tier));
        vm.prank(admin);
        core.registerModule(MODULE_TIER1155, address(tier));
    }

    function test_RegisterModule_revertsZeroAddress() public {
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        vm.prank(admin);
        core.registerModule(MODULE_TIER1155, address(0));
    }

    function test_RegisterModule_revertsAlreadyRegistered() public {
        vm.prank(admin);
        core.registerModule(MODULE_TIER1155, address(tier));
        vm.expectRevert(
            abi.encodeWithSignature("ModuleAlreadyRegistered(bytes32)", MODULE_TIER1155)
        );
        vm.prank(admin);
        core.registerModule(MODULE_TIER1155, address(0xdead));
    }

    function test_RegisterModule_revertsNonAdmin() public {
        vm.expectRevert();
        vm.prank(alice);
        core.registerModule(MODULE_TIER1155, address(tier));
    }

    function test_UpdateModule_replacesAddress() public {
        vm.prank(admin);
        core.registerModule(MODULE_TIER1155, address(tier));
        MockTier1155 tier2 = new MockTier1155();
        vm.prank(admin);
        core.updateModule(MODULE_TIER1155, address(tier2));
        assertEq(core.getModule(MODULE_TIER1155), address(tier2));
    }

    function test_UpdateModule_revertsNotRegistered() public {
        vm.expectRevert(
            abi.encodeWithSignature("ModuleNotRegistered(bytes32)", MODULE_CONTENT1155)
        );
        vm.prank(admin);
        core.updateModule(MODULE_CONTENT1155, address(tier));
    }

    function test_UpdateModule_revertsZeroAddress() public {
        vm.prank(admin);
        core.registerModule(MODULE_TIER1155, address(tier));
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        vm.prank(admin);
        core.updateModule(MODULE_TIER1155, address(0));
    }

    // =========================================================================
    // setReputationCap — 5 tests
    // =========================================================================

    function test_SetCap_overridesDefault() public {
        vm.prank(admin);
        core.setReputationCap(alice, 5000);
        assertEq(core.reputationCap(alice), 5000);
    }

    function test_SetCap_emitsEvent() public {
        vm.expectEmit(true, false, false, true, address(core));
        emit ReputationCapSet(alice, 5000);
        vm.prank(admin);
        core.setReputationCap(alice, 5000);
    }

    function test_SetCap_zeroFallsBackToDefault() public {
        vm.prank(admin);
        core.setReputationCap(alice, 5000);
        vm.prank(admin);
        core.setReputationCap(alice, 0);
        assertEq(core.reputationCap(alice), core.DEFAULT_REPUTATION_CAP());
    }

    function test_SetCap_revertsAboveUint96() public {
        vm.expectRevert(abi.encodeWithSignature("InvalidConfig()"));
        vm.prank(admin);
        core.setReputationCap(alice, uint256(type(uint96).max) + 1);
    }

    function test_SetCap_revertsZeroAddress() public {
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        vm.prank(admin);
        core.setReputationCap(address(0), 100);
    }

    function test_SetCap_appliesOnAddRep() public {
        vm.prank(admin);
        core.setReputationCap(alice, 50);
        vm.prank(admin);
        core.addReputation(alice, 50);
        vm.expectRevert();
        vm.prank(admin);
        core.addReputation(alice, 1);
    }

    // =========================================================================
    // setTreasury — 3 tests
    // =========================================================================

    function test_SetTreasury_updates() public {
        vm.prank(admin);
        core.setTreasury(carol);
        assertEq(core.treasury(), carol);
    }

    function test_SetTreasury_emitsEvent() public {
        vm.expectEmit(true, false, false, true, address(core));
        emit TreasuryUpdated(carol);
        vm.prank(admin);
        core.setTreasury(carol);
    }

    function test_SetTreasury_revertsZero() public {
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        vm.prank(admin);
        core.setTreasury(address(0));
    }

    function test_SetTreasury_revertsNonAdmin() public {
        vm.expectRevert();
        vm.prank(alice);
        core.setTreasury(carol);
    }

    // =========================================================================
    // pause / unpause — 4 tests
    // =========================================================================

    function test_Pause_setsState() public {
        vm.prank(admin);
        core.pause();
        assertTrue(core.paused());
    }

    function test_Pause_revertsNonPauser() public {
        vm.expectRevert();
        vm.prank(alice);
        core.pause();
    }

    function test_Unpause_restores() public {
        vm.prank(admin);
        core.pause();
        vm.prank(admin);
        core.unpause();
        assertFalse(core.paused());
    }

    function test_Unpause_revertsNonPauser() public {
        vm.prank(admin);
        core.pause();
        vm.expectRevert();
        vm.prank(alice);
        core.unpause();
    }

    // =========================================================================
    // getTier read-through — 7 tests
    // =========================================================================

    function test_GetTier_returnsZeroIfNoTierRegistered() public view {
        assertEq(core.getTier(alice), 0);
    }

    function test_GetTier_returnsZeroIfInactive() public {
        vm.prank(admin);
        core.registerModule(MODULE_TIER1155, address(tier));
        assertEq(core.getTier(alice), 0);
    }

    function test_GetTier_returnsBasic() public {
        vm.prank(admin);
        core.registerModule(MODULE_TIER1155, address(tier));
        tier.setActive(alice, 1, true);
        assertEq(core.getTier(alice), 1);
    }

    function test_GetTier_returnsPremium() public {
        vm.prank(admin);
        core.registerModule(MODULE_TIER1155, address(tier));
        tier.setActive(alice, 2, true);
        assertEq(core.getTier(alice), 2);
    }

    function test_GetTier_returnsPro() public {
        vm.prank(admin);
        core.registerModule(MODULE_TIER1155, address(tier));
        tier.setActive(alice, 3, true);
        assertEq(core.getTier(alice), 3);
    }

    function test_GetTier_returnsHighestActive() public {
        vm.prank(admin);
        core.registerModule(MODULE_TIER1155, address(tier));
        tier.setActive(alice, 1, true);
        tier.setActive(alice, 3, true);
        assertEq(core.getTier(alice), 3);
    }

    function test_GetTier_safeOnRevertingTier() public {
        RevertingTier1155 bad = new RevertingTier1155();
        vm.prank(admin);
        core.registerModule(MODULE_TIER1155, address(bad));
        // try/catch absorbe le revert, tier = 0
        assertEq(core.getTier(alice), 0);
    }

    // =========================================================================
    // getUserState — 3 tests
    // =========================================================================

    function test_GetUserState_emptyUser() public view {
        ILksCoreV8.TierData memory s = core.getUserState(alice);
        assertEq(s.tier, 0);
        assertEq(s.expiry, 0);
        assertEq(s.reputation, 0);
        assertFalse(s.flagged);
    }

    function test_GetUserState_aggregatesAll() public {
        vm.prank(admin);
        core.registerModule(MODULE_TIER1155, address(tier));
        tier.setActive(alice, 2, true);
        vm.prank(admin);
        core.addReputation(alice, 250);
        vm.prank(admin);
        core.flag(alice, true);

        ILksCoreV8.TierData memory s = core.getUserState(alice);
        assertEq(s.tier, 2);
        assertEq(s.reputation, 250);
        assertTrue(s.flagged);
    }

    function test_GetUserState_independentBetweenUsers() public {
        vm.prank(admin);
        core.addReputation(alice, 100);
        ILksCoreV8.TierData memory bs = core.getUserState(bob);
        assertEq(bs.reputation, 0);
    }

    // =========================================================================
    // UUPS upgrade auth — 2 tests
    // =========================================================================

    function test_Upgrade_revertsNonUpgrader() public {
        LksCoreV8 newImpl = new LksCoreV8();
        vm.expectRevert();
        vm.prank(alice);
        core.upgradeToAndCall(address(newImpl), "");
    }

    function test_Upgrade_succeedsUpgraderRole() public {
        LksCoreV8 newImpl = new LksCoreV8();
        vm.prank(admin);
        core.upgradeToAndCall(address(newImpl), "");
        // L'état est conservé
        assertEq(core.treasury(), treasury);
    }

    // =========================================================================
    // Fuzz — 5 tests
    // =========================================================================

    function testFuzz_AddRep_capped(uint96 a, uint96 b) public {
        a = uint96(bound(uint256(a), 1, core.DEFAULT_REPUTATION_CAP()));
        b = uint96(bound(uint256(b), 0, type(uint96).max));

        vm.prank(admin);
        core.addReputation(alice, a);

        if (uint256(a) + uint256(b) > core.DEFAULT_REPUTATION_CAP() || b == 0) {
            vm.expectRevert();
            vm.prank(admin);
            core.addReputation(alice, b);
        } else {
            vm.prank(admin);
            core.addReputation(alice, b);
            assertEq(core.getReputation(alice), uint96(uint256(a) + uint256(b)));
        }
    }

    function testFuzz_Slash_neverNegative(uint96 initial, uint96 delta) public {
        initial = uint96(bound(uint256(initial), 1, core.DEFAULT_REPUTATION_CAP()));
        delta = uint96(bound(uint256(delta), 1, type(uint96).max));

        vm.prank(admin);
        core.addReputation(alice, initial);
        vm.prank(admin);
        core.slashReputation(alice, delta);
        assertLe(core.getReputation(alice), initial);
    }

    function testFuzz_RegisterModule_idempotentOnce(bytes32 key) public {
        vm.assume(key != bytes32(0));
        vm.prank(admin);
        core.registerModule(key, address(tier));
        vm.expectRevert();
        vm.prank(admin);
        core.registerModule(key, address(tier));
    }

    function testFuzz_SetReputationCap_persists(uint96 cap) public {
        vm.prank(admin);
        core.setReputationCap(alice, cap);
        if (cap == 0) {
            assertEq(core.reputationCap(alice), core.DEFAULT_REPUTATION_CAP());
        } else {
            assertEq(core.reputationCap(alice), cap);
        }
    }

    function testFuzz_GetTier_respectsHighestActive(uint8 tierMask) public {
        vm.prank(admin);
        core.registerModule(MODULE_TIER1155, address(tier));
        bool a1 = (tierMask & 1) != 0;
        bool a2 = (tierMask & 2) != 0;
        bool a3 = (tierMask & 4) != 0;
        tier.setActive(alice, 1, a1);
        tier.setActive(alice, 2, a2);
        tier.setActive(alice, 3, a3);

        uint8 expected = a3 ? 3 : (a2 ? 2 : (a1 ? 1 : 0));
        assertEq(core.getTier(alice), expected);
    }
}
