// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test}              from "forge-std/Test.sol";
import {ERC1967Proxy}      from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl}    from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable}          from "@openzeppelin/contracts/utils/Pausable.sol";

import {LksContent1155} from "../src/content/LksContent1155.sol";
import {IContent1155}   from "../src/content/IContent1155.sol";
import {LksFeeSim}      from "./sim/LksFeeSim.sol";
import {
    ZeroAddress, NothingToWithdraw, FeeTooHigh,
    ContentAlreadyRegistered, ContentNotFound, MaxSupplyReached, InvalidRoyaltyBps,
    InsufficientPayment, SoulboundTransferBlocked,
    AccessAlreadyGranted, InvalidSignature, NonceAlreadyUsed, DeadlineExpired, EarnSignerNotSet
} from "../src/shared/LksErrors.sol";

/**
 * @title  LksContent1155.t.sol
 * @notice Tests Ableton-grade pour LksContent1155.
 *         55 unit tests + 5 fuzz tests, tous cross-validés via LksFeeSim
 *         pour les calculs de fee splits et royalty amounts.
 */
contract LksContent1155Test is Test {
    LksContent1155 internal content;

    address internal admin     = makeAddr("admin");
    address internal treasury  = makeAddr("treasury");
    address internal alice     = makeAddr("alice");
    address internal bob       = makeAddr("bob");
    address internal carol     = makeAddr("carol");

    uint256 internal earnSignerPk;
    address internal earnSigner;

    uint16 internal constant DEFAULT_FEE_BPS = 250; // 2.5%
    bytes32 internal constant CID_1 = keccak256("content-1");
    bytes32 internal constant CID_2 = keccak256("content-2");

    event ContentRegistered(
        uint256 indexed tokenId,
        address indexed creator,
        bytes32 contentCid,
        uint128 price,
        uint96 maxSupply,
        uint16 royaltyBps,
        bool soulbound
    );
    event ContentPurchased(
        uint256 indexed tokenId,
        address indexed buyer,
        address indexed creator,
        uint256 creatorShare,
        uint256 platformFee
    );
    event AccessEarned(uint256 indexed tokenId, address indexed user, bytes32 nonce);
    event EarningsWithdrawn(address indexed creator, uint256 amount);
    event PlatformFeeBpsUpdated(uint16 oldBps, uint16 newBps);

    function setUp() public {
        (earnSigner, earnSignerPk) = makeAddrAndKey("earnSigner");

        LksContent1155 impl = new LksContent1155();
        bytes memory data = abi.encodeWithSelector(
            LksContent1155.initialize.selector,
            admin,
            treasury,
            earnSigner,
            DEFAULT_FEE_BPS,
            "https://lks.example/{id}.json"
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), data);
        content = LksContent1155(address(proxy));

        // Pre-fund test users for purchases
        vm.deal(alice, 100 ether);
        vm.deal(bob,   100 ether);
        vm.deal(carol, 100 ether);
    }

    // ─────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────

    function _register(address creator, bytes32 cid, uint128 price, uint96 maxSupply, uint16 royaltyBps, bool soulbound)
        internal
        returns (uint256 tokenId)
    {
        vm.prank(creator);
        tokenId = content.registerContent(cid, price, maxSupply, royaltyBps, soulbound);
    }

    function _signEarn(uint256 tokenId, address user, bytes32 nonce, uint64 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 typehash = keccak256("EarnAuthorization(uint256 tokenId,address user,bytes32 nonce,uint64 deadline)");
        bytes32 structHash = keccak256(abi.encode(typehash, tokenId, user, nonce, deadline));
        bytes32 domainSeparator = _domainSeparator();
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(earnSignerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("LksContent1155")),
                keccak256(bytes("1")),
                block.chainid,
                address(content)
            )
        );
    }

    // ═════════════════════════════════════════════════════════════════
    // Initialize (8 tests)
    // ═════════════════════════════════════════════════════════════════

    function test_Initialize_setsAdmin() public view {
        assertTrue(content.hasRole(0x00, admin));
        assertTrue(content.hasRole(content.FEE_ADMIN_ROLE(), admin));
        assertTrue(content.hasRole(content.PAUSER_ROLE(), admin));
        assertTrue(content.hasRole(content.UPGRADER_ROLE(), admin));
    }

    function test_Initialize_setsTreasury() public view {
        assertEq(content.treasury(), treasury);
    }

    function test_Initialize_setsEarnSigner() public view {
        assertEq(content.earnSigner(), earnSigner);
    }

    function test_Initialize_setsPlatformFeeBps() public view {
        assertEq(content.platformFeeBps(), DEFAULT_FEE_BPS);
    }

    function test_Initialize_revertOnZeroAdmin() public {
        LksContent1155 impl = new LksContent1155();
        bytes memory data = abi.encodeWithSelector(
            LksContent1155.initialize.selector,
            address(0), treasury, earnSigner, DEFAULT_FEE_BPS, ""
        );
        vm.expectRevert(ZeroAddress.selector);
        new ERC1967Proxy(address(impl), data);
    }

    function test_Initialize_revertOnZeroTreasury() public {
        LksContent1155 impl = new LksContent1155();
        bytes memory data = abi.encodeWithSelector(
            LksContent1155.initialize.selector,
            admin, address(0), earnSigner, DEFAULT_FEE_BPS, ""
        );
        vm.expectRevert(ZeroAddress.selector);
        new ERC1967Proxy(address(impl), data);
    }

    function test_Initialize_revertOnFeeTooHigh() public {
        LksContent1155 impl = new LksContent1155();
        bytes memory data = abi.encodeWithSelector(
            LksContent1155.initialize.selector,
            admin, treasury, earnSigner, uint16(3001), ""
        );
        vm.expectRevert(abi.encodeWithSelector(FeeTooHigh.selector, uint16(3001), uint16(3000)));
        new ERC1967Proxy(address(impl), data);
    }

    function test_Initialize_canBeCalledOnce() public {
        vm.expectRevert();
        content.initialize(admin, treasury, earnSigner, DEFAULT_FEE_BPS, "");
    }

    // ═════════════════════════════════════════════════════════════════
    // tokenIdOf (3 tests)
    // ═════════════════════════════════════════════════════════════════

    function test_TokenIdOf_isDeterministic() public view {
        uint256 a = content.tokenIdOf(alice, CID_1);
        uint256 b = content.tokenIdOf(alice, CID_1);
        assertEq(a, b);
    }

    function test_TokenIdOf_differsByCreator() public view {
        assertTrue(content.tokenIdOf(alice, CID_1) != content.tokenIdOf(bob, CID_1));
    }

    function test_TokenIdOf_differsByCid() public view {
        assertTrue(content.tokenIdOf(alice, CID_1) != content.tokenIdOf(alice, CID_2));
    }

    // ═════════════════════════════════════════════════════════════════
    // registerContent (8 tests)
    // ═════════════════════════════════════════════════════════════════

    function test_RegisterContent_setsAllFields() public {
        uint256 tokenId = _register(alice, CID_1, 1 ether, 100, 500, false);
        IContent1155.ContentMeta memory m = content.contentMeta(tokenId);
        assertEq(m.creator, alice);
        assertEq(m.price, 1 ether);
        assertEq(m.maxSupply, uint96(100));
        assertEq(m.royaltyBps, uint16(500));
        assertEq(m.mintCount, uint96(0));
        assertEq(m.contentCid, CID_1);
        assertFalse(m.soulbound);
    }

    function test_RegisterContent_emitsEvent() public {
        uint256 expectedId = content.tokenIdOf(alice, CID_1);
        vm.expectEmit(true, true, false, true);
        emit ContentRegistered(expectedId, alice, CID_1, 1 ether, 100, 500, false);
        vm.prank(alice);
        content.registerContent(CID_1, 1 ether, 100, 500, false);
    }

    function test_RegisterContent_returnsTokenId() public {
        uint256 expected = content.tokenIdOf(alice, CID_1);
        vm.prank(alice);
        uint256 got = content.registerContent(CID_1, 1 ether, 0, 0, false);
        assertEq(got, expected);
    }

    function test_RegisterContent_revertOnDuplicate() public {
        _register(alice, CID_1, 1 ether, 0, 0, false);
        uint256 tokenId = content.tokenIdOf(alice, CID_1);
        vm.expectRevert(abi.encodeWithSelector(ContentAlreadyRegistered.selector, tokenId));
        vm.prank(alice);
        content.registerContent(CID_1, 2 ether, 0, 0, false);
    }

    function test_RegisterContent_revertOnInvalidRoyaltyBps() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidRoyaltyBps.selector, uint16(10001)));
        vm.prank(alice);
        content.registerContent(CID_1, 1 ether, 0, 10001, false);
    }

    function test_RegisterContent_zeroRoyaltyOk() public {
        uint256 tokenId = _register(alice, CID_1, 1 ether, 0, 0, false);
        (address recv, uint256 amt) = content.royaltyInfo(tokenId, 1 ether);
        assertEq(recv, address(0));
        assertEq(amt, 0);
    }

    function test_RegisterContent_setsERC2981Royalty() public {
        uint256 tokenId = _register(alice, CID_1, 1 ether, 0, 750, false);
        (address recv, uint256 amt) = content.royaltyInfo(tokenId, 1 ether);
        assertEq(recv, alice);
        assertEq(amt, LksFeeSim.royaltyAmount(1 ether, 750));
    }

    function test_RegisterContent_revertWhenPaused() public {
        vm.prank(admin);
        content.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(alice);
        content.registerContent(CID_1, 1 ether, 0, 0, false);
    }

    // ═════════════════════════════════════════════════════════════════
    // purchase (12 tests)
    // ═════════════════════════════════════════════════════════════════

    function test_Purchase_mintsToken() public {
        uint256 tokenId = _register(alice, CID_1, 1 ether, 0, 0, false);
        vm.prank(bob);
        content.purchase{value: 1 ether}(tokenId);
        assertEq(content.balanceOf(bob, tokenId), 1);
    }

    function test_Purchase_incrementsMintCount() public {
        uint256 tokenId = _register(alice, CID_1, 1 ether, 0, 0, false);
        vm.prank(bob);
        content.purchase{value: 1 ether}(tokenId);
        vm.prank(carol);
        content.purchase{value: 1 ether}(tokenId);
        assertEq(content.contentMeta(tokenId).mintCount, uint96(2));
    }

    function test_Purchase_creditsCreator_simRef() public {
        uint256 tokenId = _register(alice, CID_1, 1 ether, 0, 0, false);
        (uint256 expectedCreator,) = LksFeeSim.feeSplit(1 ether, DEFAULT_FEE_BPS);
        vm.prank(bob);
        content.purchase{value: 1 ether}(tokenId);
        assertEq(content.pendingEarnings(alice), expectedCreator);
    }

    function test_Purchase_creditsPlatformFees_simRef() public {
        uint256 tokenId = _register(alice, CID_1, 1 ether, 0, 0, false);
        (, uint256 expectedFee) = LksFeeSim.feeSplit(1 ether, DEFAULT_FEE_BPS);
        vm.prank(bob);
        content.purchase{value: 1 ether}(tokenId);
        assertEq(content.accumulatedPlatformFees(), expectedFee);
    }

    function test_Purchase_emitsEvent() public {
        uint256 tokenId = _register(alice, CID_1, 1 ether, 0, 0, false);
        (uint256 cs, uint256 pf) = LksFeeSim.feeSplit(1 ether, DEFAULT_FEE_BPS);
        vm.expectEmit(true, true, true, true);
        emit ContentPurchased(tokenId, bob, alice, cs, pf);
        vm.prank(bob);
        content.purchase{value: 1 ether}(tokenId);
    }

    function test_Purchase_splitsCorrectly_aggregateInvariant() public {
        uint256 tokenId = _register(alice, CID_1, 1 ether, 0, 0, false);
        vm.prank(bob);
        content.purchase{value: 1 ether}(tokenId);
        // Aggregate: creator + fees == amount
        assertEq(content.pendingEarnings(alice) + content.accumulatedPlatformFees(), 1 ether);
        // Contract balance reflects all unwithdrawn ETH
        assertEq(address(content).balance, 1 ether);
    }

    function test_Purchase_revertOnUnknownToken() public {
        uint256 unknownId = 0xdead;
        vm.expectRevert(abi.encodeWithSelector(ContentNotFound.selector, unknownId));
        vm.prank(bob);
        content.purchase{value: 1 ether}(unknownId);
    }

    function test_Purchase_revertOnInsufficientPayment() public {
        uint256 tokenId = _register(alice, CID_1, 1 ether, 0, 0, false);
        vm.expectRevert(abi.encodeWithSelector(InsufficientPayment.selector, 0.5 ether, 1 ether));
        vm.prank(bob);
        content.purchase{value: 0.5 ether}(tokenId);
    }

    function test_Purchase_revertOnExcessPayment() public {
        uint256 tokenId = _register(alice, CID_1, 1 ether, 0, 0, false);
        vm.expectRevert(abi.encodeWithSelector(InsufficientPayment.selector, 1.5 ether, 1 ether));
        vm.prank(bob);
        content.purchase{value: 1.5 ether}(tokenId);
    }

    function test_Purchase_revertOnMaxSupplyReached() public {
        uint256 tokenId = _register(alice, CID_1, 1 ether, 1, 0, false);
        vm.prank(bob);
        content.purchase{value: 1 ether}(tokenId);
        vm.expectRevert(abi.encodeWithSelector(MaxSupplyReached.selector, tokenId, uint96(1)));
        vm.prank(carol);
        content.purchase{value: 1 ether}(tokenId);
    }

    function test_Purchase_unlimitedSupplyAllowed() public {
        uint256 tokenId = _register(alice, CID_1, 0.1 ether, 0, 0, false);
        for (uint256 i = 0; i < 10; ++i) {
            address buyer = address(uint160(0x1000 + i));
            vm.deal(buyer, 1 ether);
            vm.prank(buyer);
            content.purchase{value: 0.1 ether}(tokenId);
        }
        assertEq(content.contentMeta(tokenId).mintCount, uint96(10));
    }

    function test_Purchase_revertOnAlreadyOwned() public {
        uint256 tokenId = _register(alice, CID_1, 1 ether, 0, 0, false);
        vm.prank(bob);
        content.purchase{value: 1 ether}(tokenId);
        vm.expectRevert(abi.encodeWithSelector(AccessAlreadyGranted.selector, tokenId, bob));
        vm.prank(bob);
        content.purchase{value: 1 ether}(tokenId);
    }

    function test_Purchase_revertWhenPaused() public {
        uint256 tokenId = _register(alice, CID_1, 1 ether, 0, 0, false);
        vm.prank(admin);
        content.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(bob);
        content.purchase{value: 1 ether}(tokenId);
    }

    // ═════════════════════════════════════════════════════════════════
    // earnAccess (8 tests)
    // ═════════════════════════════════════════════════════════════════

    function test_EarnAccess_mintsToken() public {
        uint256 tokenId = _register(alice, CID_1, 1 ether, 0, 0, false);
        bytes32 nonce = keccak256("nonce-1");
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes memory sig = _signEarn(tokenId, bob, nonce, deadline);

        vm.prank(bob);
        content.earnAccess(tokenId, nonce, deadline, sig);
        assertEq(content.balanceOf(bob, tokenId), 1);
    }

    function test_EarnAccess_consumesNonce() public {
        uint256 tokenId = _register(alice, CID_1, 1 ether, 0, 0, false);
        bytes32 nonce = keccak256("nonce-1");
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes memory sig = _signEarn(tokenId, bob, nonce, deadline);

        vm.prank(bob);
        content.earnAccess(tokenId, nonce, deadline, sig);
        assertTrue(content.isNonceUsed(nonce));
    }

    function test_EarnAccess_emitsEvent() public {
        uint256 tokenId = _register(alice, CID_1, 1 ether, 0, 0, false);
        bytes32 nonce = keccak256("nonce-1");
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes memory sig = _signEarn(tokenId, bob, nonce, deadline);

        vm.expectEmit(true, true, false, true);
        emit AccessEarned(tokenId, bob, nonce);
        vm.prank(bob);
        content.earnAccess(tokenId, nonce, deadline, sig);
    }

    function test_EarnAccess_revertOnInvalidSig() public {
        uint256 tokenId = _register(alice, CID_1, 1 ether, 0, 0, false);
        bytes32 nonce = keccak256("nonce-1");
        uint64 deadline = uint64(block.timestamp + 1 days);
        // Sign for carol, replay for bob
        bytes memory sig = _signEarn(tokenId, carol, nonce, deadline);

        vm.expectRevert(InvalidSignature.selector);
        vm.prank(bob);
        content.earnAccess(tokenId, nonce, deadline, sig);
    }

    function test_EarnAccess_revertOnReusedNonce() public {
        uint256 tokenId = _register(alice, CID_1, 1 ether, 0, 0, false);
        bytes32 nonce = keccak256("nonce-1");
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes memory sig = _signEarn(tokenId, bob, nonce, deadline);

        vm.prank(bob);
        content.earnAccess(tokenId, nonce, deadline, sig);

        bytes memory sig2 = _signEarn(tokenId, carol, nonce, deadline);
        vm.expectRevert(abi.encodeWithSelector(NonceAlreadyUsed.selector, nonce));
        vm.prank(carol);
        content.earnAccess(tokenId, nonce, deadline, sig2);
    }

    function test_EarnAccess_revertOnExpiredDeadline() public {
        uint256 tokenId = _register(alice, CID_1, 1 ether, 0, 0, false);
        bytes32 nonce = keccak256("nonce-1");
        uint64 deadline = uint64(block.timestamp + 1);
        bytes memory sig = _signEarn(tokenId, bob, nonce, deadline);

        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(DeadlineExpired.selector, deadline, uint64(block.timestamp)));
        vm.prank(bob);
        content.earnAccess(tokenId, nonce, deadline, sig);
    }

    function test_EarnAccess_revertOnSignerNotSet() public {
        vm.prank(admin);
        content.setEarnSigner(address(0));

        uint256 tokenId = _register(alice, CID_1, 1 ether, 0, 0, false);
        bytes32 nonce = keccak256("nonce-1");
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes memory sig = _signEarn(tokenId, bob, nonce, deadline);

        vm.expectRevert(EarnSignerNotSet.selector);
        vm.prank(bob);
        content.earnAccess(tokenId, nonce, deadline, sig);
    }

    function test_EarnAccess_revertOnAlreadyOwned() public {
        uint256 tokenId = _register(alice, CID_1, 1 ether, 0, 0, false);
        // First purchase
        vm.prank(bob);
        content.purchase{value: 1 ether}(tokenId);
        // Now try to earn (should fail)
        bytes32 nonce = keccak256("nonce-1");
        uint64 deadline = uint64(block.timestamp + 1 days);
        bytes memory sig = _signEarn(tokenId, bob, nonce, deadline);

        vm.expectRevert(abi.encodeWithSelector(AccessAlreadyGranted.selector, tokenId, bob));
        vm.prank(bob);
        content.earnAccess(tokenId, nonce, deadline, sig);
    }

    // ═════════════════════════════════════════════════════════════════
    // withdrawEarnings (5 tests)
    // ═════════════════════════════════════════════════════════════════

    function test_WithdrawEarnings_transfersToCreator() public {
        uint256 tokenId = _register(alice, CID_1, 1 ether, 0, 0, false);
        vm.prank(bob);
        content.purchase{value: 1 ether}(tokenId);
        (uint256 expectedCreator,) = LksFeeSim.feeSplit(1 ether, DEFAULT_FEE_BPS);

        uint256 before_ = alice.balance;
        vm.prank(alice);
        content.withdrawEarnings();
        assertEq(alice.balance - before_, expectedCreator);
    }

    function test_WithdrawEarnings_zerosOutBalance() public {
        uint256 tokenId = _register(alice, CID_1, 1 ether, 0, 0, false);
        vm.prank(bob);
        content.purchase{value: 1 ether}(tokenId);
        vm.prank(alice);
        content.withdrawEarnings();
        assertEq(content.pendingEarnings(alice), 0);
    }

    function test_WithdrawEarnings_emitsEvent() public {
        uint256 tokenId = _register(alice, CID_1, 1 ether, 0, 0, false);
        vm.prank(bob);
        content.purchase{value: 1 ether}(tokenId);
        (uint256 cs,) = LksFeeSim.feeSplit(1 ether, DEFAULT_FEE_BPS);
        vm.expectEmit(true, false, false, true);
        emit EarningsWithdrawn(alice, cs);
        vm.prank(alice);
        content.withdrawEarnings();
    }

    function test_WithdrawEarnings_revertOnZero() public {
        vm.expectRevert(NothingToWithdraw.selector);
        vm.prank(alice);
        content.withdrawEarnings();
    }

    function test_WithdrawEarnings_idempotent() public {
        uint256 tokenId = _register(alice, CID_1, 1 ether, 0, 0, false);
        vm.prank(bob);
        content.purchase{value: 1 ether}(tokenId);
        vm.prank(alice);
        content.withdrawEarnings();
        // Second call must revert
        vm.expectRevert(NothingToWithdraw.selector);
        vm.prank(alice);
        content.withdrawEarnings();
    }

    // ═════════════════════════════════════════════════════════════════
    // withdrawPlatformFees (3 tests)
    // ═════════════════════════════════════════════════════════════════

    function test_WithdrawPlatformFees_transfersToTreasury() public {
        uint256 tokenId = _register(alice, CID_1, 1 ether, 0, 0, false);
        vm.prank(bob);
        content.purchase{value: 1 ether}(tokenId);
        (, uint256 expectedFee) = LksFeeSim.feeSplit(1 ether, DEFAULT_FEE_BPS);

        uint256 before_ = treasury.balance;
        content.withdrawPlatformFees();
        assertEq(treasury.balance - before_, expectedFee);
    }

    function test_WithdrawPlatformFees_zerosOutAccumulated() public {
        uint256 tokenId = _register(alice, CID_1, 1 ether, 0, 0, false);
        vm.prank(bob);
        content.purchase{value: 1 ether}(tokenId);
        content.withdrawPlatformFees();
        assertEq(content.accumulatedPlatformFees(), 0);
    }

    function test_WithdrawPlatformFees_revertOnZero() public {
        vm.expectRevert(NothingToWithdraw.selector);
        content.withdrawPlatformFees();
    }

    // ═════════════════════════════════════════════════════════════════
    // Soulbound enforcement (4 tests)
    // ═════════════════════════════════════════════════════════════════

    function test_Soulbound_revertOnTransfer() public {
        uint256 tokenId = _register(alice, CID_1, 1 ether, 0, 0, true);
        vm.prank(bob);
        content.purchase{value: 1 ether}(tokenId);
        vm.expectRevert(SoulboundTransferBlocked.selector);
        vm.prank(bob);
        content.safeTransferFrom(bob, carol, tokenId, 1, "");
    }

    function test_NonSoulbound_allowsTransfer() public {
        uint256 tokenId = _register(alice, CID_1, 1 ether, 0, 0, false);
        vm.prank(bob);
        content.purchase{value: 1 ether}(tokenId);
        vm.prank(bob);
        content.safeTransferFrom(bob, carol, tokenId, 1, "");
        assertEq(content.balanceOf(carol, tokenId), 1);
        assertEq(content.balanceOf(bob, tokenId), 0);
    }

    function test_Soulbound_mintAllowed() public {
        // Already covered by purchase mint, but verify directly
        uint256 tokenId = _register(alice, CID_1, 1 ether, 0, 0, true);
        vm.prank(bob);
        content.purchase{value: 1 ether}(tokenId);
        assertEq(content.balanceOf(bob, tokenId), 1);
    }

    function test_Soulbound_batchTransferReverts() public {
        uint256 tokenId = _register(alice, CID_1, 1 ether, 0, 0, true);
        vm.prank(bob);
        content.purchase{value: 1 ether}(tokenId);
        uint256[] memory ids = new uint256[](1);
        uint256[] memory amts = new uint256[](1);
        ids[0] = tokenId;
        amts[0] = 1;
        vm.expectRevert(SoulboundTransferBlocked.selector);
        vm.prank(bob);
        content.safeBatchTransferFrom(bob, carol, ids, amts, "");
    }

    // ═════════════════════════════════════════════════════════════════
    // Royalty / ERC2981 (3 tests)
    // ═════════════════════════════════════════════════════════════════

    function test_RoyaltyInfo_returnsCreator() public {
        uint256 tokenId = _register(alice, CID_1, 1 ether, 0, 750, false);
        (address recv,) = content.royaltyInfo(tokenId, 1 ether);
        assertEq(recv, alice);
    }

    function test_RoyaltyInfo_calculatesAmount_simRef() public {
        uint256 tokenId = _register(alice, CID_1, 1 ether, 0, 750, false);
        (, uint256 amt) = content.royaltyInfo(tokenId, 5 ether);
        assertEq(amt, LksFeeSim.royaltyAmount(5 ether, 750));
    }

    function test_RoyaltyInfo_zeroForUnknownToken() public view {
        (address recv, uint256 amt) = content.royaltyInfo(0xdead, 1 ether);
        assertEq(recv, address(0));
        assertEq(amt, 0);
    }

    // ═════════════════════════════════════════════════════════════════
    // Admin (5 tests)
    // ═════════════════════════════════════════════════════════════════

    function test_SetPlatformFeeBps_updatesValue() public {
        vm.expectEmit(false, false, false, true);
        emit PlatformFeeBpsUpdated(DEFAULT_FEE_BPS, 500);
        vm.prank(admin);
        content.setPlatformFeeBps(500);
        assertEq(content.platformFeeBps(), 500);
    }

    function test_SetPlatformFeeBps_revertOnTooHigh() public {
        vm.expectRevert(abi.encodeWithSelector(FeeTooHigh.selector, uint16(3001), uint16(3000)));
        vm.prank(admin);
        content.setPlatformFeeBps(3001);
    }

    function test_SetPlatformFeeBps_revertOnUnauthorized() public {
        vm.expectRevert();
        vm.prank(bob);
        content.setPlatformFeeBps(100);
    }

    function test_SetEarnSigner_updatesValue() public {
        vm.prank(admin);
        content.setEarnSigner(carol);
        assertEq(content.earnSigner(), carol);
    }

    function test_SetTreasury_updatesValue() public {
        vm.prank(admin);
        content.setTreasury(carol);
        assertEq(content.treasury(), carol);
    }

    // ═════════════════════════════════════════════════════════════════
    // Pause (2 tests)
    // ═════════════════════════════════════════════════════════════════

    function test_Pause_blocksRegister() public {
        vm.prank(admin);
        content.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(alice);
        content.registerContent(CID_1, 1 ether, 0, 0, false);
    }

    function test_Unpause_restoresFunctionality() public {
        vm.prank(admin);
        content.pause();
        vm.prank(admin);
        content.unpause();
        // Should now succeed
        _register(alice, CID_1, 1 ether, 0, 0, false);
    }

    // ═════════════════════════════════════════════════════════════════
    // supportsInterface (2 tests)
    // ═════════════════════════════════════════════════════════════════

    function test_SupportsInterface_ERC1155() public view {
        assertTrue(content.supportsInterface(0xd9b67a26));
    }

    function test_SupportsInterface_ERC2981() public view {
        assertTrue(content.supportsInterface(0x2a55205a));
    }

    // ═════════════════════════════════════════════════════════════════
    // FUZZ (5 tests)
    // ═════════════════════════════════════════════════════════════════

    /// @notice FUZZ-13 : purchase split exactement = LksFeeSim.feeSplit
    function testFuzz_Purchase_splitMatchesSim(uint128 price, uint16 feeBps) public {
        price  = uint128(bound(price, 1e10, 100 ether));
        feeBps = uint16(bound(feeBps, 0, 3000));

        // Set fee
        vm.prank(admin);
        content.setPlatformFeeBps(feeBps);

        uint256 tokenId = _register(alice, CID_1, price, 0, 0, false);
        vm.deal(bob, price);
        vm.prank(bob);
        content.purchase{value: price}(tokenId);

        (uint256 expectedCreator, uint256 expectedFee) = LksFeeSim.feeSplit(price, feeBps);
        assertEq(content.pendingEarnings(alice), expectedCreator);
        assertEq(content.accumulatedPlatformFees(), expectedFee);
        assertEq(expectedCreator + expectedFee, price);
    }

    /// @notice FUZZ-14 : royaltyInfo bound — royaltyAmount ≤ salePrice
    function testFuzz_RoyaltyInfo_boundedBySalePrice(uint16 royaltyBps, uint256 salePrice) public {
        royaltyBps = uint16(bound(royaltyBps, 0, 10000));
        salePrice  = bound(salePrice, 0, 1e30);

        uint256 tokenId = _register(alice, CID_1, 1 ether, 0, royaltyBps, false);
        (, uint256 amt) = content.royaltyInfo(tokenId, salePrice);
        assertLe(amt, salePrice);
        assertEq(amt, LksFeeSim.royaltyAmount(salePrice, royaltyBps));
    }

    /// @notice FUZZ-15 : mintCount toujours ≤ maxSupply
    function testFuzz_MintCount_boundedByMaxSupply(uint96 maxSupply, uint8 nbBuyers) public {
        maxSupply = uint96(bound(uint256(maxSupply), 1, 50));
        nbBuyers  = uint8(bound(uint256(nbBuyers), 1, 50));

        uint256 tokenId = _register(alice, CID_1, 0.01 ether, maxSupply, 0, false);
        for (uint256 i = 0; i < nbBuyers; ++i) {
            address buyer = address(uint160(0x2000 + i));
            vm.deal(buyer, 1 ether);
            if (i < maxSupply) {
                vm.prank(buyer);
                content.purchase{value: 0.01 ether}(tokenId);
            } else {
                vm.expectRevert(abi.encodeWithSelector(MaxSupplyReached.selector, tokenId, maxSupply));
                vm.prank(buyer);
                content.purchase{value: 0.01 ether}(tokenId);
            }
        }
        uint96 expected = nbBuyers < maxSupply ? nbBuyers : maxSupply;
        assertEq(content.contentMeta(tokenId).mintCount, expected);
    }

    /// @notice FUZZ-16 : withdrawEarnings idempotent — second call always reverts
    function testFuzz_WithdrawEarnings_idempotent(uint8 nbPurchases) public {
        nbPurchases = uint8(bound(uint256(nbPurchases), 1, 30));
        uint256 tokenId = _register(alice, CID_1, 0.1 ether, 0, 0, false);

        for (uint256 i = 0; i < nbPurchases; ++i) {
            address buyer = address(uint160(0x3000 + i));
            vm.deal(buyer, 1 ether);
            vm.prank(buyer);
            content.purchase{value: 0.1 ether}(tokenId);
        }

        (uint256 expectedCs,) = LksFeeSim.feeSplit(0.1 ether, DEFAULT_FEE_BPS);
        uint256 totalCs = expectedCs * nbPurchases;
        assertEq(content.pendingEarnings(alice), totalCs);

        vm.prank(alice);
        content.withdrawEarnings();
        assertEq(content.pendingEarnings(alice), 0);

        vm.expectRevert(NothingToWithdraw.selector);
        vm.prank(alice);
        content.withdrawEarnings();
    }

    /// @notice FUZZ-17 : INV-12 — sum(pendingEarnings) + accumulatedFees == address(content).balance
    function testFuzz_BalanceInvariant(uint8 nbPurchases, uint128 price, uint16 feeBps) public {
        nbPurchases = uint8(bound(uint256(nbPurchases), 1, 20));
        price       = uint128(bound(price, 1e13, 10 ether));
        feeBps      = uint16(bound(feeBps, 0, 3000));

        vm.prank(admin);
        content.setPlatformFeeBps(feeBps);

        uint256 tokenId = _register(alice, CID_1, price, 0, 0, false);

        for (uint256 i = 0; i < nbPurchases; ++i) {
            address buyer = address(uint160(0x4000 + i));
            vm.deal(buyer, uint256(price) * 2);
            vm.prank(buyer);
            content.purchase{value: price}(tokenId);
        }

        uint256 sumOwed = content.pendingEarnings(alice) + content.accumulatedPlatformFees();
        assertEq(sumOwed, address(content).balance);
        assertEq(sumOwed, uint256(price) * nbPurchases);
    }
}
