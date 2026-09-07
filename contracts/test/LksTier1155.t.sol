// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {LksTier1155} from "../src/tier/LksTier1155.sol";
import {ITier1155}   from "../src/tier/ITier1155.sol";
import {LksTierSim}  from "./sim/LksTierSim.sol";

contract LksTier1155Test is Test {
    LksTier1155 internal tier;

    address internal admin    = address(0xA11CE);
    address internal treasury = address(0xBEEF);
    address internal alice    = address(0x1111);
    address internal bob      = address(0x2222);

    uint128 internal constant PRICE_BASIC   = 0.01 ether;
    uint128 internal constant PRICE_PREMIUM = 0.05 ether;
    uint128 internal constant PRICE_PRO     = 0.1 ether;
    uint64  internal constant DURATION      = 30 days;

    bytes32 internal constant TIER_ADMIN_ROLE = keccak256("TIER_ADMIN_ROLE");
    bytes32 internal constant PAUSER_ROLE     = keccak256("PAUSER_ROLE");
    bytes32 internal constant UPGRADER_ROLE   = keccak256("UPGRADER_ROLE");

    event Subscribed(address indexed user, uint256 indexed tierId, uint64 expiresAt, uint256 paid);
    event Cancelled(address indexed user, uint256 indexed tierId, uint256 refunded);
    event TierConfigUpdated(uint256 indexed tierId, ITier1155.TierConfig config);
    event TierActiveSet(uint256 indexed tierId, bool active);

    function setUp() public {
        LksTier1155 impl = new LksTier1155();
        bytes memory initData = abi.encodeCall(LksTier1155.initialize, (admin, treasury, "ipfs://tier/{id}.json"));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        tier = LksTier1155(address(proxy));

        // configurer 3 tiers
        vm.startPrank(admin);
        tier.setTierConfig(tier.TIER_BASIC(),   ITier1155.TierConfig({ price: PRICE_BASIC,   duration: DURATION, maxSupply: 0,    active: true }));
        tier.setTierConfig(tier.TIER_PREMIUM(), ITier1155.TierConfig({ price: PRICE_PREMIUM, duration: DURATION, maxSupply: 100,  active: true }));
        tier.setTierConfig(tier.TIER_PRO(),     ITier1155.TierConfig({ price: PRICE_PRO,     duration: DURATION, maxSupply: 0,    active: true }));
        vm.stopPrank();

        vm.deal(alice, 100 ether);
        vm.deal(bob,   100 ether);
    }

    // =========================================================================
    // Initialization — 6 tests
    // =========================================================================

    function test_Init_grantsRoles() public view {
        assertTrue(tier.hasRole(0x00, admin));
        assertTrue(tier.hasRole(TIER_ADMIN_ROLE, admin));
        assertTrue(tier.hasRole(PAUSER_ROLE, admin));
        assertTrue(tier.hasRole(UPGRADER_ROLE, admin));
    }

    function test_Init_setsTreasury() public view {
        assertEq(tier.treasury(), treasury);
    }

    function test_Init_revertsZeroAdmin() public {
        LksTier1155 impl = new LksTier1155();
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(LksTier1155.initialize, (address(0), treasury, ""))
        );
    }

    function test_Init_revertsZeroTreasury() public {
        LksTier1155 impl = new LksTier1155();
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(LksTier1155.initialize, (admin, address(0), ""))
        );
    }

    function test_Init_cannotReinitialize() public {
        vm.expectRevert();
        tier.initialize(admin, treasury, "");
    }

    function test_TierIds() public view {
        assertEq(tier.TIER_BASIC(), 1);
        assertEq(tier.TIER_PREMIUM(), 2);
        assertEq(tier.TIER_PRO(), 3);
    }

    // =========================================================================
    // setTierConfig — 5 tests
    // =========================================================================

    function test_SetConfig_persistsAllFields() public {
        ITier1155.TierConfig memory cfg = ITier1155.TierConfig({
            price: 0.5 ether, duration: 60 days, maxSupply: 1000, active: true
        });
        vm.prank(admin);
        tier.setTierConfig(1, cfg);
        ITier1155.TierConfig memory got = tier.tierConfig(1);
        assertEq(got.price, cfg.price);
        assertEq(got.duration, cfg.duration);
        assertEq(got.maxSupply, cfg.maxSupply);
        assertTrue(got.active);
    }

    function test_SetConfig_emitsEvent() public {
        ITier1155.TierConfig memory cfg = ITier1155.TierConfig({ price: 1, duration: 1, maxSupply: 0, active: true });
        vm.expectEmit(true, false, false, true, address(tier));
        emit TierConfigUpdated(2, cfg);
        vm.prank(admin);
        tier.setTierConfig(2, cfg);
    }

    function test_SetConfig_revertsTierZero() public {
        ITier1155.TierConfig memory cfg = ITier1155.TierConfig({ price: 1, duration: 1, maxSupply: 0, active: true });
        vm.expectRevert(abi.encodeWithSignature("TierNotFound(uint256)", 0));
        vm.prank(admin);
        tier.setTierConfig(0, cfg);
    }

    function test_SetConfig_revertsTierTooHigh() public {
        ITier1155.TierConfig memory cfg = ITier1155.TierConfig({ price: 1, duration: 1, maxSupply: 0, active: true });
        vm.expectRevert(abi.encodeWithSignature("TierNotFound(uint256)", 4));
        vm.prank(admin);
        tier.setTierConfig(4, cfg);
    }

    function test_SetConfig_revertsNonAdmin() public {
        ITier1155.TierConfig memory cfg = ITier1155.TierConfig({ price: 1, duration: 1, maxSupply: 0, active: true });
        vm.expectRevert();
        vm.prank(alice);
        tier.setTierConfig(1, cfg);
    }

    // =========================================================================
    // setTierActive — 3 tests
    // =========================================================================

    function test_SetActive_disables() public {
        vm.prank(admin);
        tier.setTierActive(1, false);
        assertFalse(tier.tierConfig(1).active);
    }

    function test_SetActive_emitsEvent() public {
        vm.expectEmit(true, false, false, true, address(tier));
        emit TierActiveSet(1, false);
        vm.prank(admin);
        tier.setTierActive(1, false);
    }

    function test_SetActive_revertsNonAdmin() public {
        vm.expectRevert();
        vm.prank(alice);
        tier.setTierActive(1, false);
    }

    // =========================================================================
    // subscribe happy — 8 tests
    // =========================================================================

    function test_Subscribe_mintsToken() public {
        vm.prank(alice);
        tier.subscribe{value: PRICE_BASIC}(1);
        assertEq(tier.balanceOf(alice, 1), 1);
    }

    function test_Subscribe_setsExpiry() public {
        vm.warp(1000);
        vm.prank(alice);
        tier.subscribe{value: PRICE_BASIC}(1);
        assertEq(tier.expiresAt(alice, 1), 1000 + DURATION);
    }

    function test_Subscribe_setsSubscriptionStart() public {
        vm.warp(1000);
        vm.prank(alice);
        tier.subscribe{value: PRICE_BASIC}(1);
        assertEq(tier.subscriptionStart(alice, 1), 1000);
    }

    function test_Subscribe_keepsETHInContract() public {
        uint256 balBefore = address(tier).balance;
        vm.prank(alice);
        tier.subscribe{value: PRICE_BASIC}(1);
        assertEq(address(tier).balance - balBefore, PRICE_BASIC);
    }

    function test_Cancel_forwardsConsumedToTreasury() public {
        vm.warp(1000);
        vm.prank(alice);
        tier.subscribe{value: PRICE_BASIC}(1);
        vm.warp(1000 + DURATION / 2);
        uint256 balBefore = treasury.balance;
        vm.prank(alice);
        tier.cancelAndRefund(1);
        assertEq(treasury.balance - balBefore, PRICE_BASIC / 2); // consumed = paid - refund = 50 %
    }

    function test_Subscribe_emitsEvent() public {
        vm.warp(1000);
        vm.expectEmit(true, true, false, true, address(tier));
        emit Subscribed(alice, 1, 1000 + DURATION, PRICE_BASIC);
        vm.prank(alice);
        tier.subscribe{value: PRICE_BASIC}(1);
    }

    function test_Subscribe_isActiveTrue() public {
        vm.prank(alice);
        tier.subscribe{value: PRICE_BASIC}(1);
        assertTrue(tier.isActive(alice, 1));
    }

    function test_Subscribe_incrementsTotalSupply() public {
        vm.prank(alice);
        tier.subscribe{value: PRICE_BASIC}(1);
        assertEq(tier.totalSupply(1), 1);
    }

    function test_Subscribe_storesPaidAmount() public {
        vm.prank(alice);
        tier.subscribe{value: PRICE_BASIC}(1);
        assertEq(tier.paidAmount(alice, 1), PRICE_BASIC);
    }

    // =========================================================================
    // subscribe extends — 4 tests
    // =========================================================================

    function test_Subscribe_extendsBeforeExpiry() public {
        vm.warp(1000);
        vm.prank(alice);
        tier.subscribe{value: PRICE_BASIC}(1);
        // re-subscribe à mi-période
        vm.warp(1000 + DURATION / 2);
        vm.prank(alice);
        tier.subscribe{value: PRICE_BASIC}(1);

        // expiry = max(currentExpiry, now) + DURATION = (1000+DURATION) + DURATION
        assertEq(tier.expiresAt(alice, 1), 1000 + 2 * DURATION);
    }

    function test_Subscribe_extendsAfterExpiry() public {
        vm.warp(1000);
        vm.prank(alice);
        tier.subscribe{value: PRICE_BASIC}(1);
        // warp past expiry, BUT do not allow burn — extension should still mint anew
        vm.warp(1000 + DURATION + 100);
        vm.prank(alice);
        tier.subscribe{value: PRICE_BASIC}(1);
        // expiry from now (since current was past)
        assertEq(tier.expiresAt(alice, 1), 1000 + DURATION + 100 + DURATION);
    }

    function test_Subscribe_extendDoesNotMintExtraToken() public {
        vm.prank(alice);
        tier.subscribe{value: PRICE_BASIC}(1);
        vm.prank(alice);
        tier.subscribe{value: PRICE_BASIC}(1);
        assertEq(tier.balanceOf(alice, 1), 1);
        assertEq(tier.totalSupply(1), 1);
    }

    function test_Subscribe_extendCumulatesPaidAmount() public {
        vm.prank(alice);
        tier.subscribe{value: PRICE_BASIC}(1);
        vm.prank(alice);
        tier.subscribe{value: PRICE_BASIC}(1);
        assertEq(tier.paidAmount(alice, 1), 2 * PRICE_BASIC);
    }

    // =========================================================================
    // subscribe reverts — 6 tests
    // =========================================================================

    function test_Subscribe_revertsWrongPrice() public {
        vm.expectRevert(abi.encodeWithSignature("InsufficientPayment(uint256,uint256)", PRICE_BASIC + 1, PRICE_BASIC));
        vm.prank(alice);
        tier.subscribe{value: PRICE_BASIC + 1}(1);
    }

    function test_Subscribe_revertsZeroValue() public {
        vm.expectRevert(abi.encodeWithSignature("InsufficientPayment(uint256,uint256)", 0, PRICE_BASIC));
        vm.prank(alice);
        tier.subscribe{value: 0}(1);
    }

    function test_Subscribe_revertsTierInactive() public {
        vm.prank(admin);
        tier.setTierActive(1, false);
        vm.expectRevert(abi.encodeWithSignature("TierNotFound(uint256)", 1));
        vm.prank(alice);
        tier.subscribe{value: PRICE_BASIC}(1);
    }

    function test_Subscribe_revertsTierUnknown() public {
        vm.expectRevert(abi.encodeWithSignature("TierNotFound(uint256)", 5));
        vm.prank(alice);
        tier.subscribe{value: 1}(5);
    }

    function test_Subscribe_revertsWhenPaused() public {
        vm.prank(admin);
        tier.pause();
        vm.expectRevert();
        vm.prank(alice);
        tier.subscribe{value: PRICE_BASIC}(1);
    }

    function test_Subscribe_revertsMaxSupplyReached() public {
        // tier 2 a maxSupply = 100, on configure à maxSupply = 1 pour tester
        vm.prank(admin);
        tier.setTierConfig(2, ITier1155.TierConfig({ price: PRICE_PREMIUM, duration: DURATION, maxSupply: 1, active: true }));
        vm.prank(alice);
        tier.subscribe{value: PRICE_PREMIUM}(2);
        // bob essaie → revert
        vm.expectRevert(abi.encodeWithSignature("TierNotFound(uint256)", 2));
        vm.prank(bob);
        tier.subscribe{value: PRICE_PREMIUM}(2);
    }

    // =========================================================================
    // cancelAndRefund — 8 tests
    // =========================================================================

    function test_Cancel_burnsToken() public {
        vm.prank(alice);
        tier.subscribe{value: PRICE_BASIC}(1);
        vm.prank(alice);
        tier.cancelAndRefund(1);
        assertEq(tier.balanceOf(alice, 1), 0);
        assertEq(tier.totalSupply(1), 0);
    }

    function test_Cancel_refundProportional_halfway() public {
        vm.warp(1000);
        vm.prank(alice);
        tier.subscribe{value: PRICE_BASIC}(1);

        vm.warp(1000 + DURATION / 2);
        uint256 expected = LksTierSim.refund(PRICE_BASIC, 1000, 1000 + DURATION, 1000 + DURATION / 2);
        assertEq(expected, PRICE_BASIC / 2);

        uint256 balBefore = alice.balance;
        vm.prank(alice);
        uint256 refunded = tier.cancelAndRefund(1);
        assertEq(refunded, expected);
        assertEq(alice.balance - balBefore, expected);
    }

    function test_Cancel_fullRefundAtStart() public {
        vm.warp(1000);
        vm.prank(alice);
        tier.subscribe{value: PRICE_BASIC}(1);
        // immédiat (nowTs == start)
        vm.prank(alice);
        uint256 refunded = tier.cancelAndRefund(1);
        assertEq(refunded, PRICE_BASIC);
    }

    function test_Cancel_zeroRefundIfExpired() public {
        vm.warp(1000);
        vm.prank(alice);
        tier.subscribe{value: PRICE_BASIC}(1);
        vm.warp(1000 + DURATION + 100);
        vm.prank(alice);
        uint256 refunded = tier.cancelAndRefund(1);
        assertEq(refunded, 0);
    }

    function test_Cancel_emitsEvent() public {
        vm.warp(1000);
        vm.prank(alice);
        tier.subscribe{value: PRICE_BASIC}(1);
        vm.warp(1000 + DURATION / 2);
        vm.expectEmit(true, true, false, true, address(tier));
        emit Cancelled(alice, 1, PRICE_BASIC / 2);
        vm.prank(alice);
        tier.cancelAndRefund(1);
    }

    function test_Cancel_clearsState() public {
        vm.prank(alice);
        tier.subscribe{value: PRICE_BASIC}(1);
        vm.prank(alice);
        tier.cancelAndRefund(1);
        assertEq(tier.expiresAt(alice, 1), 0);
        assertEq(tier.subscriptionStart(alice, 1), 0);
        assertEq(tier.paidAmount(alice, 1), 0);
    }

    function test_Cancel_revertsNoToken() public {
        vm.expectRevert(abi.encodeWithSignature("TierNotFound(uint256)", 1));
        vm.prank(alice);
        tier.cancelAndRefund(1);
    }

    function test_Cancel_secondCallReverts() public {
        vm.prank(alice);
        tier.subscribe{value: PRICE_BASIC}(1);
        vm.prank(alice);
        tier.cancelAndRefund(1);
        vm.expectRevert(abi.encodeWithSignature("TierNotFound(uint256)", 1));
        vm.prank(alice);
        tier.cancelAndRefund(1);
    }

    // =========================================================================
    // Soulbound enforcement — 4 tests
    // =========================================================================

    function test_Soulbound_safeTransferFromReverts() public {
        vm.prank(alice);
        tier.subscribe{value: PRICE_BASIC}(1);
        vm.expectRevert(abi.encodeWithSignature("SoulboundTransferBlocked()"));
        vm.prank(alice);
        tier.safeTransferFrom(alice, bob, 1, 1, "");
    }

    function test_Soulbound_safeBatchTransferFromReverts() public {
        vm.prank(alice);
        tier.subscribe{value: PRICE_BASIC}(1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1;
        vm.expectRevert(abi.encodeWithSignature("SoulboundTransferBlocked()"));
        vm.prank(alice);
        tier.safeBatchTransferFrom(alice, bob, ids, amounts, "");
    }

    function test_Soulbound_setApprovalForAllStillRevertsTransfer() public {
        vm.prank(alice);
        tier.subscribe{value: PRICE_BASIC}(1);
        vm.prank(alice);
        tier.setApprovalForAll(bob, true);
        vm.expectRevert(abi.encodeWithSignature("SoulboundTransferBlocked()"));
        vm.prank(bob);
        tier.safeTransferFrom(alice, bob, 1, 1, "");
    }

    function test_Soulbound_mintAndBurnAllowed() public {
        // mint via subscribe
        vm.prank(alice);
        tier.subscribe{value: PRICE_BASIC}(1);
        assertEq(tier.balanceOf(alice, 1), 1);
        // burn via cancel
        vm.prank(alice);
        tier.cancelAndRefund(1);
        assertEq(tier.balanceOf(alice, 1), 0);
    }

    // =========================================================================
    // Multi-tier independence — 3 tests
    // =========================================================================

    function test_MultiTier_subscribeAllThree() public {
        vm.prank(alice);
        tier.subscribe{value: PRICE_BASIC}(1);
        vm.prank(alice);
        tier.subscribe{value: PRICE_PREMIUM}(2);
        vm.prank(alice);
        tier.subscribe{value: PRICE_PRO}(3);
        assertEq(tier.balanceOf(alice, 1), 1);
        assertEq(tier.balanceOf(alice, 2), 1);
        assertEq(tier.balanceOf(alice, 3), 1);
    }

    function test_MultiTier_cancelOneKeepsOthers() public {
        vm.prank(alice);
        tier.subscribe{value: PRICE_BASIC}(1);
        vm.prank(alice);
        tier.subscribe{value: PRICE_PREMIUM}(2);
        vm.prank(alice);
        tier.cancelAndRefund(1);
        assertEq(tier.balanceOf(alice, 1), 0);
        assertEq(tier.balanceOf(alice, 2), 1);
    }

    function test_MultiUser_independent() public {
        vm.prank(alice);
        tier.subscribe{value: PRICE_BASIC}(1);
        vm.prank(bob);
        tier.subscribe{value: PRICE_BASIC}(1);
        assertEq(tier.totalSupply(1), 2);
        assertEq(tier.balanceOf(alice, 1), 1);
        assertEq(tier.balanceOf(bob, 1), 1);
    }

    // =========================================================================
    // Pause / unpause — 3 tests
    // =========================================================================

    function test_Pause_blocksSubscribe() public {
        vm.prank(admin);
        tier.pause();
        vm.expectRevert();
        vm.prank(alice);
        tier.subscribe{value: PRICE_BASIC}(1);
    }

    function test_Unpause_restoresSubscribe() public {
        vm.prank(admin);
        tier.pause();
        vm.prank(admin);
        tier.unpause();
        vm.prank(alice);
        tier.subscribe{value: PRICE_BASIC}(1);
        assertEq(tier.balanceOf(alice, 1), 1);
    }

    function test_Pause_doesNotBlockCancel() public {
        vm.prank(alice);
        tier.subscribe{value: PRICE_BASIC}(1);
        vm.prank(admin);
        tier.pause();
        // Cancel doit toujours fonctionner (utilisateur doit pouvoir sortir)
        vm.prank(alice);
        tier.cancelAndRefund(1);
        assertEq(tier.balanceOf(alice, 1), 0);
    }

    // =========================================================================
    // setTreasury / UUPS — 4 tests
    // =========================================================================

    function test_SetTreasury_updates() public {
        vm.prank(admin);
        tier.setTreasury(alice);
        assertEq(tier.treasury(), alice);
    }

    function test_SetTreasury_revertsZero() public {
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        vm.prank(admin);
        tier.setTreasury(address(0));
    }

    function test_Upgrade_revertsNonUpgrader() public {
        LksTier1155 newImpl = new LksTier1155();
        vm.expectRevert();
        vm.prank(alice);
        tier.upgradeToAndCall(address(newImpl), "");
    }

    function test_Upgrade_succeedsAdmin() public {
        LksTier1155 newImpl = new LksTier1155();
        vm.prank(admin);
        tier.upgradeToAndCall(address(newImpl), "");
        assertEq(tier.treasury(), treasury);
    }

    // =========================================================================
    // supportsInterface — 1 test
    // =========================================================================

    function test_SupportsInterface_ERC1155andAccessControl() public view {
        assertTrue(tier.supportsInterface(0xd9b67a26)); // ERC1155
        assertTrue(tier.supportsInterface(0x7965db0b)); // AccessControl
    }

    // =========================================================================
    // Fuzz — 5 tests
    // =========================================================================

    function testFuzz_Subscribe_priceMustEqual(uint256 sentValue) public {
        sentValue = bound(sentValue, 0, 10 ether);
        vm.deal(alice, 10 ether);
        if (sentValue == PRICE_BASIC) {
            vm.prank(alice);
            tier.subscribe{value: sentValue}(1);
            assertTrue(tier.isActive(alice, 1));
        } else {
            vm.expectRevert(abi.encodeWithSignature("InsufficientPayment(uint256,uint256)", sentValue, PRICE_BASIC));
            vm.prank(alice);
            tier.subscribe{value: sentValue}(1);
        }
    }

    function testFuzz_Cancel_refundMatchesSim(uint64 cancelOffset) public {
        cancelOffset = uint64(bound(uint256(cancelOffset), 0, DURATION + 100));
        uint64 startTs = 1000;
        vm.warp(startTs);
        vm.prank(alice);
        tier.subscribe{value: PRICE_BASIC}(1);

        vm.warp(uint256(startTs) + uint256(cancelOffset));
        uint256 expected = LksTierSim.refund(
            PRICE_BASIC,
            startTs,
            startTs + DURATION,
            startTs + cancelOffset
        );
        vm.prank(alice);
        uint256 refunded = tier.cancelAndRefund(1);
        assertEq(refunded, expected);
    }

    function testFuzz_Subscribe_extendDoesNotMintExtra(uint8 numExtensions) public {
        numExtensions = uint8(bound(uint256(numExtensions), 1, 10));
        vm.deal(alice, uint256(numExtensions) * PRICE_BASIC);
        for (uint256 i; i < numExtensions; ++i) {
            vm.prank(alice);
            tier.subscribe{value: PRICE_BASIC}(1);
        }
        assertEq(tier.balanceOf(alice, 1), 1);
        assertEq(tier.totalSupply(1), 1);
        assertEq(tier.paidAmount(alice, 1), uint256(numExtensions) * PRICE_BASIC);
    }

    function testFuzz_Soulbound_neverTransfers(address to, uint8 tierId) public {
        vm.assume(to != address(0) && to != alice);
        tierId = uint8(bound(uint256(tierId), 1, 3));
        uint128 price = tierId == 1 ? PRICE_BASIC : (tierId == 2 ? PRICE_PREMIUM : PRICE_PRO);

        vm.prank(alice);
        tier.subscribe{value: price}(tierId);

        vm.expectRevert(abi.encodeWithSignature("SoulboundTransferBlocked()"));
        vm.prank(alice);
        tier.safeTransferFrom(alice, to, tierId, 1, "");
    }

    function testFuzz_Inv_balanceAtMostOne(uint8 numSubs) public {
        numSubs = uint8(bound(uint256(numSubs), 1, 20));
        vm.deal(alice, uint256(numSubs) * PRICE_BASIC);
        for (uint256 i; i < numSubs; ++i) {
            vm.prank(alice);
            tier.subscribe{value: PRICE_BASIC}(1);
        }
        assertLe(tier.balanceOf(alice, 1), 1);
    }
}
