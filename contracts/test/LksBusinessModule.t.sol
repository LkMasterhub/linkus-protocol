// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../src/core/LksCoreUpgradeable.sol";
import "../src/core/ILksCore.sol";
import "../src/business/LksBusinessModule.sol";

contract LksBusinessModuleTest is Test {
    LksCoreUpgradeable public core;
    LksBusinessModule public biz;

    // ============================================================================
    // TEST CONFIG
    // ============================================================================

    address public admin    = address(0xA11CE);
    address public treasury = address(0xBEEF);
    address public alice    = address(0x1111);
    address public bob      = address(0x2222);
    address public charlie  = address(0x3333);
    address public earnSigner;
    uint256 public earnSignerKey;

    uint256 constant TIER_PREMIUM_PRICE = 0.1 ether;

    // EIP-712 constants (must match the contract)
    bytes32 public DOMAIN_SEPARATOR;
    bytes32 constant EARN_AUTHORIZATION_TYPEHASH = keccak256(
        "EarnAuthorization(address user,bytes32 contentId,uint8 condition,uint256 nonce,uint256 deadline)"
    );

    function setUp() public {
        // Setup EIP-712 signer keypair
        (earnSigner, earnSignerKey) = makeAddrAndKey("earnSigner");

        // Deploy LksCore
        LksCoreUpgradeable coreImpl = new LksCoreUpgradeable();
        ERC1967Proxy coreProxy = new ERC1967Proxy(
            address(coreImpl),
            abi.encodeCall(LksCoreUpgradeable.initialize, (admin, treasury))
        );
        core = LksCoreUpgradeable(payable(address(coreProxy)));

        // Deploy LksBusinessModule
        LksBusinessModule bizImpl = new LksBusinessModule();
        ERC1967Proxy bizProxy = new ERC1967Proxy(
            address(bizImpl),
            abi.encodeCall(LksBusinessModule.initialize, (address(core), admin, earnSigner))
        );
        biz = LksBusinessModule(payable(address(bizProxy)));

        // Configure tier PREMIUM in Core (for tier-gating tests)
        vm.startPrank(admin);
        core.setTierConfig(
            ILksCore.AccessTier.PREMIUM,
            ILksCore.TierConfig({
                monthlyPrice: TIER_PREMIUM_PRICE,
                reputationBonus: 500,
                active: true
            })
        );
        core.setTierConfig(
            ILksCore.AccessTier.BASIC,
            ILksCore.TierConfig({
                monthlyPrice: 0.01 ether,
                reputationBonus: 0,
                active: true
            })
        );
        vm.stopPrank();

        // Fund users
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(charlie, 100 ether);

        // Capture domain separator for signature tests
        DOMAIN_SEPARATOR = _computeDomainSeparator(address(biz));
    }

    function _computeDomainSeparator(address verifyingContract) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("LksBusinessModule")),
                keccak256(bytes("1")),
                block.chainid,
                verifyingContract
            )
        );
    }

    function _signEarnAuthorization(
        uint256 signerKey,
        address user,
        bytes32 contentId,
        LksBusinessModule.EarnConditionType condition,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                EARN_AUTHORIZATION_TYPEHASH,
                user,
                contentId,
                uint8(condition),
                nonce,
                deadline
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        return abi.encodePacked(r, s, v);
    }

    // ============================================================================
    // INITIALIZATION
    // ============================================================================

    function test_Init_setsCoreAndSigner() public {
        assertEq(address(biz.coreContract()), address(core));
        assertEq(biz.earnSigner(), earnSigner);
    }

    function test_Init_grantsAdminRoles() public {
        assertTrue(biz.hasRole(biz.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(biz.hasRole(biz.ADMIN_ROLE(), admin));
        assertTrue(biz.hasRole(biz.PAUSER_ROLE(), admin));
        assertTrue(biz.hasRole(biz.UPGRADER_ROLE(), admin));
    }

    function test_Init_setsDefaultConfig() public {
        assertEq(biz.minProjectGoal(), 0.01 ether);
        assertEq(biz.maxProjectDuration(), 90 days);
        assertEq(biz.platformFeeRate(), 500);
    }

    function test_Init_revertIfZeroCore() public {
        LksBusinessModule impl = new LksBusinessModule();
        vm.expectRevert(LksBusinessModule.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(LksBusinessModule.initialize, (address(0), admin, earnSigner))
        );
    }

    function test_Init_cannotBeCalledTwice() public {
        vm.expectRevert();
        biz.initialize(address(core), admin, earnSigner);
    }

    // ============================================================================
    // PROJECTS — CREATE
    // ============================================================================

    function test_CreateProject_success() public {
        vm.prank(alice);
        uint256 projectId = biz.createProject("My Project", bytes32("ipfs-hash"), 1 ether, 30 days);

        assertEq(projectId, 1);
        (, string memory title, , uint256 goal, uint256 funding, , , bool exists, ) = biz.projects(projectId);
        assertTrue(exists);
        assertEq(title, "My Project");
        assertEq(goal, 1 ether);
        assertEq(funding, 0);
    }

    function test_CreateProject_revertIfEmptyTitle() public {
        vm.prank(alice);
        vm.expectRevert(LksBusinessModule.InvalidConfiguration.selector);
        biz.createProject("", bytes32(0), 1 ether, 30 days);
    }

    function test_CreateProject_revertIfGoalTooLow() public {
        vm.prank(alice);
        vm.expectRevert(LksBusinessModule.InvalidConfiguration.selector);
        biz.createProject("T", bytes32(0), 0.001 ether, 30 days);
    }

    function test_CreateProject_revertIfDurationTooLong() public {
        vm.prank(alice);
        vm.expectRevert(LksBusinessModule.InvalidConfiguration.selector);
        biz.createProject("T", bytes32(0), 1 ether, 100 days);
    }

    function test_CreateProject_incrementsTotalProjects() public {
        vm.prank(alice);
        biz.createProject("T1", bytes32(0), 1 ether, 30 days);
        vm.prank(bob);
        biz.createProject("T2", bytes32(0), 1 ether, 30 days);
        assertEq(biz.totalProjects(), 2);
    }

    // ============================================================================
    // PROJECTS — FUND
    // ============================================================================

    function test_FundProject_success() public {
        vm.prank(alice);
        uint256 pid = biz.createProject("P", bytes32(0), 1 ether, 30 days);

        vm.prank(bob);
        biz.fundProject{value: 0.3 ether}(pid);

        assertEq(biz.contributions(pid, bob), 0.3 ether);
    }

    function test_FundProject_reachesGoalMarksFunded() public {
        vm.prank(alice);
        uint256 pid = biz.createProject("P", bytes32(0), 1 ether, 30 days);

        vm.prank(bob);
        biz.fundProject{value: 1 ether}(pid);

        (, , , , , , LksBusinessModule.ProjectStatus status, , ) = biz.projects(pid);
        assertEq(uint8(status), uint8(LksBusinessModule.ProjectStatus.FUNDED));
        assertEq(biz.totalProjectsFunded(), 1);
    }

    function test_FundProject_revertIfExpired() public {
        vm.prank(alice);
        uint256 pid = biz.createProject("P", bytes32(0), 1 ether, 30 days);

        vm.warp(block.timestamp + 31 days);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(LksBusinessModule.ProjectExpired.selector, pid));
        biz.fundProject{value: 0.5 ether}(pid);
    }

    function test_FundProject_revertIfZero() public {
        vm.prank(alice);
        uint256 pid = biz.createProject("P", bytes32(0), 1 ether, 30 days);

        vm.prank(bob);
        vm.expectRevert();
        biz.fundProject{value: 0}(pid);
    }

    function test_FundProject_revertIfNotFound() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(LksBusinessModule.ProjectNotFound.selector, uint256(999)));
        biz.fundProject{value: 0.1 ether}(999);
    }

    // ============================================================================
    // PROJECTS — WITHDRAW
    // ============================================================================

    function test_WithdrawProjectFunds_creatorReceivesMinusFee() public {
        vm.prank(alice);
        uint256 pid = biz.createProject("P", bytes32(0), 1 ether, 30 days);

        vm.prank(bob);
        biz.fundProject{value: 1 ether}(pid);

        uint256 aliceBefore = alice.balance;
        uint256 treasuryBefore = treasury.balance;

        vm.prank(alice);
        biz.withdrawProjectFunds(pid);

        uint256 fee = (1 ether * 500) / 10_000; // 5%
        uint256 creatorNet = 1 ether - fee;
        assertEq(alice.balance - aliceBefore, creatorNet);
        assertEq(treasury.balance - treasuryBefore, fee);
    }

    function test_WithdrawProjectFunds_revertIfNotCreator() public {
        vm.prank(alice);
        uint256 pid = biz.createProject("P", bytes32(0), 1 ether, 30 days);
        vm.prank(bob);
        biz.fundProject{value: 1 ether}(pid);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(LksBusinessModule.NotProjectCreator.selector, pid));
        biz.withdrawProjectFunds(pid);
    }

    function test_WithdrawProjectFunds_revertIfNotFunded() public {
        vm.prank(alice);
        uint256 pid = biz.createProject("P", bytes32(0), 1 ether, 30 days);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LksBusinessModule.ProjectNotActive.selector, pid));
        biz.withdrawProjectFunds(pid);
    }

    // ============================================================================
    // PROJECTS — REFUND
    // ============================================================================

    function test_RefundProject_onCancelledProject() public {
        vm.prank(alice);
        uint256 pid = biz.createProject("P", bytes32(0), 1 ether, 30 days);
        vm.prank(bob);
        biz.fundProject{value: 0.5 ether}(pid);

        vm.prank(alice);
        biz.cancelProject(pid);

        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        biz.refundProject(pid);
        assertEq(bob.balance - bobBefore, 0.5 ether);
    }

    function test_RefundProject_onExpiredNotFunded() public {
        vm.prank(alice);
        uint256 pid = biz.createProject("P", bytes32(0), 10 ether, 30 days);
        vm.prank(bob);
        biz.fundProject{value: 1 ether}(pid);

        vm.warp(block.timestamp + 31 days);

        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        biz.refundProject(pid);
        assertEq(bob.balance - bobBefore, 1 ether);
    }

    function test_RefundProject_revertIfFunded() public {
        vm.prank(alice);
        uint256 pid = biz.createProject("P", bytes32(0), 1 ether, 30 days);
        vm.prank(bob);
        biz.fundProject{value: 1 ether}(pid); // Fully funded

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(LksBusinessModule.RefundNotAvailable.selector, pid));
        biz.refundProject(pid);
    }

    function test_RefundProject_revertIfNoContribution() public {
        vm.prank(alice);
        uint256 pid = biz.createProject("P", bytes32(0), 1 ether, 30 days);
        vm.prank(alice);
        biz.cancelProject(pid);

        vm.prank(charlie);
        vm.expectRevert();
        biz.refundProject(pid);
    }

    // ============================================================================
    // PROJECTS — CANCEL
    // ============================================================================

    function test_CancelProject_byCreator() public {
        vm.prank(alice);
        uint256 pid = biz.createProject("P", bytes32(0), 1 ether, 30 days);

        vm.prank(alice);
        biz.cancelProject(pid);

        (, , , , , , LksBusinessModule.ProjectStatus status, , ) = biz.projects(pid);
        assertEq(uint8(status), uint8(LksBusinessModule.ProjectStatus.CANCELLED));
    }

    function test_CancelProject_byAdmin() public {
        vm.prank(alice);
        uint256 pid = biz.createProject("P", bytes32(0), 1 ether, 30 days);

        vm.prank(admin);
        biz.cancelProject(pid);

        (, , , , , , LksBusinessModule.ProjectStatus status, , ) = biz.projects(pid);
        assertEq(uint8(status), uint8(LksBusinessModule.ProjectStatus.CANCELLED));
    }

    function test_CancelProject_revertIfNotCreatorNotAdmin() public {
        vm.prank(alice);
        uint256 pid = biz.createProject("P", bytes32(0), 1 ether, 30 days);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(LksBusinessModule.NotProjectCreator.selector, pid));
        biz.cancelProject(pid);
    }

    // ============================================================================
    // CONTENT — REGISTER
    // ============================================================================

    function _defaultPaidContent(bytes32 contentId, address creator, uint256 price) internal {
        LksBusinessModule.ContentAccessType[] memory accessTypes = new LksBusinessModule.ContentAccessType[](1);
        accessTypes[0] = LksBusinessModule.ContentAccessType.PAID;
        LksBusinessModule.EarnConditionType[] memory earnConditions = new LksBusinessModule.EarnConditionType[](0);

        vm.prank(creator);
        biz.registerContent(
            contentId,
            accessTypes,
            price,
            0,
            0,
            0,
            earnConditions,
            false,
            ILksCore.AccessTier.NONE
        );
    }

    function test_RegisterContent_success() public {
        bytes32 cid = bytes32("content-1");
        _defaultPaidContent(cid, alice, 0.05 ether);

        LksBusinessModule.ContentConfig memory cfg = biz.getContentConfig(cid);
        assertEq(cfg.creator, alice);
        assertEq(cfg.price, 0.05 ether);
        assertTrue(cfg.isPaid);
        assertTrue(cfg.active);
    }

    function test_RegisterContent_revertIfAlreadyExists() public {
        bytes32 cid = bytes32("content-1");
        _defaultPaidContent(cid, alice, 0.05 ether);

        vm.expectRevert(abi.encodeWithSelector(LksBusinessModule.ContentAlreadyRegistered.selector, cid));
        _defaultPaidContent(cid, alice, 0.05 ether);
    }

    function test_RegisterContent_revertIfNoAccessTypes() public {
        LksBusinessModule.ContentAccessType[] memory empty = new LksBusinessModule.ContentAccessType[](0);
        LksBusinessModule.EarnConditionType[] memory ec = new LksBusinessModule.EarnConditionType[](0);

        vm.prank(alice);
        vm.expectRevert(LksBusinessModule.InvalidConfiguration.selector);
        biz.registerContent(
            bytes32("x"), empty, 0, 0, 0, 0, ec, false, ILksCore.AccessTier.NONE
        );
    }

    // ============================================================================
    // CONTENT — PURCHASE
    // ============================================================================

    function test_PurchaseContent_success() public {
        bytes32 cid = bytes32("c1");
        _defaultPaidContent(cid, alice, 0.05 ether);

        vm.prank(bob);
        biz.purchaseContent{value: 0.05 ether}(cid);

        (bool has, LksBusinessModule.ContentAccessType at, uint256 exp) = biz.checkContentAccess(cid, bob);
        assertTrue(has);
        assertEq(uint8(at), uint8(LksBusinessModule.ContentAccessType.PAID));
        assertEq(exp, 0); // Permanent
        assertEq(biz.creatorEarnings(alice), 0.05 ether);
    }

    function test_PurchaseContent_excessRefunded() public {
        bytes32 cid = bytes32("c1");
        _defaultPaidContent(cid, alice, 0.05 ether);

        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        biz.purchaseContent{value: 0.1 ether}(cid);

        // Net spent = 0.05 ether (excess refunded)
        assertEq(bobBefore - bob.balance, 0.05 ether);
    }

    function test_PurchaseContent_revertIfAlreadyBought() public {
        bytes32 cid = bytes32("c1");
        _defaultPaidContent(cid, alice, 0.05 ether);

        vm.prank(bob);
        biz.purchaseContent{value: 0.05 ether}(cid);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(LksBusinessModule.AlreadyPurchased.selector, cid));
        biz.purchaseContent{value: 0.05 ether}(cid);
    }

    function test_PurchaseContent_revertIfInsufficient() public {
        bytes32 cid = bytes32("c1");
        _defaultPaidContent(cid, alice, 0.05 ether);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(LksBusinessModule.InsufficientPayment.selector, 0.05 ether, 0.01 ether)
        );
        biz.purchaseContent{value: 0.01 ether}(cid);
    }

    function test_PurchaseContent_tierGating_revertIfTooLow() public {
        // Content requires PREMIUM subscription
        LksBusinessModule.ContentAccessType[] memory accessTypes = new LksBusinessModule.ContentAccessType[](1);
        accessTypes[0] = LksBusinessModule.ContentAccessType.PAID;
        LksBusinessModule.EarnConditionType[] memory ec = new LksBusinessModule.EarnConditionType[](0);

        vm.prank(alice);
        biz.registerContent(
            bytes32("gated"),
            accessTypes,
            0.05 ether,
            0,
            0,
            0,
            ec,
            true,
            ILksCore.AccessTier.PREMIUM
        );

        // Bob has no subscription → should revert
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                LksBusinessModule.TierTooLow.selector,
                ILksCore.AccessTier.PREMIUM,
                ILksCore.AccessTier.NONE
            )
        );
        biz.purchaseContent{value: 0.05 ether}(bytes32("gated"));
    }

    function test_PurchaseContent_tierGating_successIfMet() public {
        LksBusinessModule.ContentAccessType[] memory accessTypes = new LksBusinessModule.ContentAccessType[](1);
        accessTypes[0] = LksBusinessModule.ContentAccessType.PAID;
        LksBusinessModule.EarnConditionType[] memory ec = new LksBusinessModule.EarnConditionType[](0);

        vm.prank(alice);
        biz.registerContent(
            bytes32("gated"),
            accessTypes,
            0.05 ether,
            0,
            0,
            0,
            ec,
            true,
            ILksCore.AccessTier.PREMIUM
        );

        // Bob subscribes to PREMIUM
        vm.prank(bob);
        core.subscribe{value: TIER_PREMIUM_PRICE}(ILksCore.AccessTier.PREMIUM);

        // Now purchase works
        vm.prank(bob);
        biz.purchaseContent{value: 0.05 ether}(bytes32("gated"));

        (bool has, , ) = biz.checkContentAccess(bytes32("gated"), bob);
        assertTrue(has);
    }

    // ============================================================================
    // CONTENT — RENT
    // ============================================================================

    function test_RentContent_success() public {
        LksBusinessModule.ContentAccessType[] memory accessTypes = new LksBusinessModule.ContentAccessType[](1);
        accessTypes[0] = LksBusinessModule.ContentAccessType.RENTAL;
        LksBusinessModule.EarnConditionType[] memory ec = new LksBusinessModule.EarnConditionType[](0);

        vm.prank(alice);
        biz.registerContent(
            bytes32("rental"),
            accessTypes,
            0,
            0.02 ether,
            7 days,
            0,
            ec,
            false,
            ILksCore.AccessTier.NONE
        );

        vm.prank(bob);
        biz.rentContent{value: 0.02 ether}(bytes32("rental"));

        (bool has, LksBusinessModule.ContentAccessType at, uint256 exp) = biz.checkContentAccess(
            bytes32("rental"),
            bob
        );
        assertTrue(has);
        assertEq(uint8(at), uint8(LksBusinessModule.ContentAccessType.RENTAL));
        assertEq(exp, block.timestamp + 7 days);
    }

    function test_RentContent_expiresAfterDuration() public {
        LksBusinessModule.ContentAccessType[] memory accessTypes = new LksBusinessModule.ContentAccessType[](1);
        accessTypes[0] = LksBusinessModule.ContentAccessType.RENTAL;
        LksBusinessModule.EarnConditionType[] memory ec = new LksBusinessModule.EarnConditionType[](0);

        vm.prank(alice);
        biz.registerContent(
            bytes32("rental"), accessTypes, 0, 0.02 ether, 7 days, 0, ec, false, ILksCore.AccessTier.NONE
        );
        vm.prank(bob);
        biz.rentContent{value: 0.02 ether}(bytes32("rental"));

        vm.warp(block.timestamp + 8 days);

        (bool has, , ) = biz.checkContentAccess(bytes32("rental"), bob);
        assertFalse(has);
    }

    // ============================================================================
    // CONTENT — EARN WITH EIP-712 SIGNATURE
    // ============================================================================

    function _registerEarnableContent(bytes32 cid) internal {
        LksBusinessModule.ContentAccessType[] memory accessTypes = new LksBusinessModule.ContentAccessType[](1);
        accessTypes[0] = LksBusinessModule.ContentAccessType.EARNED;
        LksBusinessModule.EarnConditionType[] memory ec = new LksBusinessModule.EarnConditionType[](1);
        ec[0] = LksBusinessModule.EarnConditionType.COMPLETE_QUIZ;

        vm.prank(alice);
        biz.registerContent(cid, accessTypes, 0, 0, 0, 0, ec, false, ILksCore.AccessTier.NONE);
    }

    function test_EarnContent_validSignature() public {
        bytes32 cid = bytes32("earn-1");
        _registerEarnableContent(cid);

        uint256 deadline = block.timestamp + 1 days;
        uint256 nonce = biz.earnNonces(bob);
        bytes memory sig = _signEarnAuthorization(
            earnSignerKey,
            bob,
            cid,
            LksBusinessModule.EarnConditionType.COMPLETE_QUIZ,
            nonce,
            deadline
        );

        vm.prank(bob);
        biz.earnContent(cid, LksBusinessModule.EarnConditionType.COMPLETE_QUIZ, deadline, sig);

        (bool has, LksBusinessModule.ContentAccessType at, ) = biz.checkContentAccess(cid, bob);
        assertTrue(has);
        assertEq(uint8(at), uint8(LksBusinessModule.ContentAccessType.EARNED));
    }

    function test_EarnContent_revertIfInvalidSigner() public {
        bytes32 cid = bytes32("earn-2");
        _registerEarnableContent(cid);

        uint256 deadline = block.timestamp + 1 days;
        uint256 nonce = biz.earnNonces(bob);

        // Sign with WRONG key
        (, uint256 wrongKey) = makeAddrAndKey("wrong");
        bytes memory badSig = _signEarnAuthorization(
            wrongKey,
            bob,
            cid,
            LksBusinessModule.EarnConditionType.COMPLETE_QUIZ,
            nonce,
            deadline
        );

        vm.prank(bob);
        vm.expectRevert(LksBusinessModule.InvalidSignature.selector);
        biz.earnContent(cid, LksBusinessModule.EarnConditionType.COMPLETE_QUIZ, deadline, badSig);
    }

    function test_EarnContent_revertIfExpired() public {
        bytes32 cid = bytes32("earn-3");
        _registerEarnableContent(cid);

        uint256 deadline = block.timestamp - 1; // Already expired
        uint256 nonce = biz.earnNonces(bob);
        bytes memory sig = _signEarnAuthorization(
            earnSignerKey,
            bob,
            cid,
            LksBusinessModule.EarnConditionType.COMPLETE_QUIZ,
            nonce,
            deadline
        );

        vm.prank(bob);
        vm.expectRevert(LksBusinessModule.EarnSignatureExpired.selector);
        biz.earnContent(cid, LksBusinessModule.EarnConditionType.COMPLETE_QUIZ, deadline, sig);
    }

    function test_EarnContent_revertIfReplay() public {
        // La replay protection repose sur le nonce EIP-712 incrémenté par l'appel précédent.
        // Quand la même signature est re-soumise, le nonce on-chain est maintenant N+1 alors que
        // la signature encode N → le digest diffère → ECDSA.recover renvoie une adresse ≠ earnSigner
        // → revert InvalidSignature. C'est plus strict que AlreadyPurchased.
        bytes32 cid = bytes32("earn-4");
        _registerEarnableContent(cid);

        uint256 deadline = block.timestamp + 1 days;
        uint256 nonce = biz.earnNonces(bob);
        bytes memory sig = _signEarnAuthorization(
            earnSignerKey,
            bob,
            cid,
            LksBusinessModule.EarnConditionType.COMPLETE_QUIZ,
            nonce,
            deadline
        );

        vm.prank(bob);
        biz.earnContent(cid, LksBusinessModule.EarnConditionType.COMPLETE_QUIZ, deadline, sig);
        assertEq(biz.earnNonces(bob), nonce + 1);

        // Replay doit échouer via InvalidSignature (pas AlreadyPurchased)
        vm.prank(bob);
        vm.expectRevert(LksBusinessModule.InvalidSignature.selector);
        biz.earnContent(cid, LksBusinessModule.EarnConditionType.COMPLETE_QUIZ, deadline, sig);
    }

    // ============================================================================
    // CONTENT — WITHDRAW CREATOR EARNINGS
    // ============================================================================

    function test_WithdrawCreatorEarnings_success() public {
        bytes32 cid = bytes32("c");
        _defaultPaidContent(cid, alice, 0.05 ether);

        vm.prank(bob);
        biz.purchaseContent{value: 0.05 ether}(cid);

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        biz.withdrawCreatorEarnings();

        assertEq(alice.balance - aliceBefore, 0.05 ether);
        assertEq(biz.creatorEarnings(alice), 0);
    }

    function test_WithdrawCreatorEarnings_revertIfNothing() public {
        vm.prank(alice);
        vm.expectRevert(LksBusinessModule.NothingToWithdraw.selector);
        biz.withdrawCreatorEarnings();
    }

    // ============================================================================
    // TEMPORARY SHARES
    // ============================================================================

    function test_CreateTemporaryShare_freeShare() public {
        vm.prank(alice);
        bytes32 shareHash = biz.createTemporaryShare(
            bytes32("file"),
            bob,
            3 days,
            false,
            0
        );

        (bytes32 fh, address sw, uint256 exp, bool paid, , ) = biz.temporaryShares(shareHash);
        assertEq(fh, bytes32("file"));
        assertEq(sw, bob);
        assertEq(exp, block.timestamp + 3 days);
        assertFalse(paid);
    }

    function test_CreateTemporaryShare_paidShare() public {
        vm.prank(alice);
        bytes32 shareHash = biz.createTemporaryShare{value: 0.01 ether}(
            bytes32("file"),
            bob,
            3 days,
            true,
            0.01 ether
        );

        (, , , bool paid, uint256 price, ) = biz.temporaryShares(shareHash);
        assertTrue(paid);
        assertEq(price, 0.01 ether);
    }

    function test_CreateTemporaryShare_revertIfZeroShared() public {
        vm.prank(alice);
        vm.expectRevert(LksBusinessModule.ZeroAddress.selector);
        biz.createTemporaryShare(bytes32("file"), address(0), 3 days, false, 0);
    }

    function test_CreateTemporaryShare_revertIfZeroDuration() public {
        vm.prank(alice);
        vm.expectRevert(LksBusinessModule.InvalidConfiguration.selector);
        biz.createTemporaryShare(bytes32("file"), bob, 0, false, 0);
    }

    // ============================================================================
    // ADMIN
    // ============================================================================

    function test_SetEarnSigner_onlyAdmin() public {
        vm.prank(alice);
        vm.expectRevert();
        biz.setEarnSigner(bob);
    }

    function test_SetEarnSigner_updates() public {
        vm.prank(admin);
        biz.setEarnSigner(bob);
        assertEq(biz.earnSigner(), bob);
    }

    function test_SetProjectConfig_updates() public {
        vm.prank(admin);
        biz.setProjectConfig(0.1 ether, 60 days, 1000);
        assertEq(biz.minProjectGoal(), 0.1 ether);
        assertEq(biz.maxProjectDuration(), 60 days);
        assertEq(biz.platformFeeRate(), 1000);
    }

    function test_SetProjectConfig_revertIfFeeTooHigh() public {
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                LksBusinessModule.FeeRateTooHigh.selector,
                3001,
                3000
            )
        );
        biz.setProjectConfig(0.01 ether, 90 days, 3001);
    }

    function test_Pause_blocksCreateProject() public {
        vm.prank(admin);
        biz.pause();

        vm.prank(alice);
        vm.expectRevert();
        biz.createProject("P", bytes32(0), 1 ether, 30 days);
    }

    function test_Pause_allowsWithdrawCreatorEarnings() public {
        // Withdraw should work even when paused (unpausable)
        bytes32 cid = bytes32("c");
        _defaultPaidContent(cid, alice, 0.05 ether);
        vm.prank(bob);
        biz.purchaseContent{value: 0.05 ether}(cid);

        vm.prank(admin);
        biz.pause();

        vm.prank(alice);
        biz.withdrawCreatorEarnings(); // should NOT revert
    }

    // ============================================================================
    // SECURITY (fuzzing / reentrancy)
    // ============================================================================

    function testFuzz_CreateProject_variousGoals(uint256 fundingGoal, uint256 duration) public {
        fundingGoal = bound(fundingGoal, 0.01 ether, 1000 ether);
        duration = bound(duration, 1, 90 days);

        vm.prank(alice);
        uint256 pid = biz.createProject("P", bytes32(0), fundingGoal, duration);
        assertGt(pid, 0);
    }

    function testFuzz_FundProject_amounts(uint256 amount) public {
        amount = bound(amount, 1, 10 ether);

        vm.prank(alice);
        uint256 pid = biz.createProject("P", bytes32(0), 100 ether, 30 days);

        vm.deal(bob, amount);
        vm.prank(bob);
        biz.fundProject{value: amount}(pid);

        assertEq(biz.contributions(pid, bob), amount);
    }
}
