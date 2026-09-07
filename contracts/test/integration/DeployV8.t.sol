// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2}      from "forge-std/Test.sol";
import {ERC1967Proxy}        from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {LksTipVault}         from "../../src/tips/LksTipVault.sol";
import {LksCoreV8}           from "../../src/core/LksCoreV8.sol";
import {LksTier1155}         from "../../src/tier/LksTier1155.sol";
import {ITier1155}           from "../../src/tier/ITier1155.sol";
import {LksContent1155}      from "../../src/content/LksContent1155.sol";
import {LksBusinessV8}       from "../../src/business/LksBusinessV8.sol";
import {ILksBusinessV8}      from "../../src/business/ILksBusinessV8.sol";

/// @title  DeployV8Smoke — Phase 4 V8 integration test
/// @notice Reproduit `script/DeployV8.s.sol` puis exécute un cycle complet :
///         deploy → tip → withdraw → subscribe → purchase → fund → refund.
///
///         Ce test garantit qu'aucun contrat V8 ne casse en composition une
///         fois wirés via le registry, que les transferts ETH circulent
///         correctement, et que les invariants comptables tiennent en
///         conditions réelles d'utilisation.
contract DeployV8Smoke is Test {
    // Deploy outputs
    LksTipVault       internal tipVault;
    LksCoreV8         internal core;
    LksTier1155       internal tier;
    LksContent1155    internal content;
    LksBusinessV8     internal biz;

    address internal admin    = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal earnSigner = makeAddr("earnSigner");
    address internal alice    = makeAddr("alice");
    address internal bob      = makeAddr("bob");
    address internal carol    = makeAddr("carol");

    uint16  internal constant FEE_BPS = 250;        // 2.5 %
    uint256 internal constant TIP_AMOUNT = 1 ether;
    uint256 internal constant CONTENT_PRICE = 0.5 ether;
    uint128 internal constant CROWDFUND_GOAL = 5 ether;

    function setUp() public {
        _deployStack();
        _configureTiers();
    }

    // -------------------------------------------------------------------------
    // Deployment (mirror DeployV8.s.sol exactly)
    // -------------------------------------------------------------------------
    function _deployStack() internal {
        // 1. TipVault (non-upgradeable)
        tipVault = new LksTipVault(admin, FEE_BPS, treasury);

        // 2. Core (UUPS)
        LksCoreV8 coreImpl = new LksCoreV8();
        bytes memory coreInit = abi.encodeWithSelector(
            LksCoreV8.initialize.selector, admin, treasury
        );
        core = LksCoreV8(address(new ERC1967Proxy(address(coreImpl), coreInit)));

        // 3. Tier1155 (UUPS)
        LksTier1155 tierImpl = new LksTier1155();
        bytes memory tierInit = abi.encodeWithSelector(
            LksTier1155.initialize.selector,
            admin, treasury, "https://lks.example/tier/{id}.json"
        );
        tier = LksTier1155(address(new ERC1967Proxy(address(tierImpl), tierInit)));

        // 4. Content1155 (UUPS)
        LksContent1155 contentImpl = new LksContent1155();
        bytes memory contentInit = abi.encodeWithSelector(
            LksContent1155.initialize.selector,
            admin, treasury, earnSigner, FEE_BPS,
            "https://lks.example/content/{id}.json"
        );
        content = LksContent1155(address(new ERC1967Proxy(address(contentImpl), contentInit)));

        // 5. BusinessV8 (UUPS)
        LksBusinessV8 bizImpl = new LksBusinessV8();
        bytes memory bizInit = abi.encodeWithSelector(
            LksBusinessV8.initialize.selector, admin, treasury, FEE_BPS
        );
        biz = LksBusinessV8(address(new ERC1967Proxy(address(bizImpl), bizInit)));

        // 6. Wire registry (admin must call)
        vm.startPrank(admin);
        core.registerModule(core.MODULE_TIPVAULT(),    address(tipVault));
        core.registerModule(core.MODULE_TIER1155(),    address(tier));
        core.registerModule(core.MODULE_CONTENT1155(), address(content));
        core.registerModule(core.MODULE_BUSINESS(),    address(biz));
        vm.stopPrank();
    }

    function _configureTiers() internal {
        vm.startPrank(admin);
        tier.setTierConfig(
            1,
            ITier1155.TierConfig({price: 0.1 ether, duration: 30 days, maxSupply: 0, active: true})
        );
        tier.setTierConfig(
            2,
            ITier1155.TierConfig({price: 0.5 ether, duration: 30 days, maxSupply: 100, active: true})
        );
        vm.stopPrank();
    }

    // =========================================================================
    // SMOKE-01 : Deployment + wiring sanity
    // =========================================================================
    function test_Smoke_DeploymentWired() public view {
        assertEq(core.getModule(core.MODULE_TIPVAULT()),    address(tipVault));
        assertEq(core.getModule(core.MODULE_TIER1155()),    address(tier));
        assertEq(core.getModule(core.MODULE_CONTENT1155()), address(content));
        assertEq(core.getModule(core.MODULE_BUSINESS()),    address(biz));
        // Treasury propagé partout
        assertEq(tipVault.feeRecipient(), treasury);
        assertEq(tier.treasury(),         treasury);
        assertEq(content.treasury(),      treasury);
        assertEq(biz.treasury(),          treasury);
    }

    // =========================================================================
    // SMOKE-02 : Full E2E cycle
    // =========================================================================
    function test_Smoke_FullCycle() public {
        // ---------------- TIP FLOW ----------------
        vm.deal(alice, 10 ether);
        bytes32 postId = keccak256("post-1");
        vm.prank(alice);
        tipVault.tip{value: TIP_AMOUNT}(postId, bob);

        uint256 expectedFee     = (TIP_AMOUNT * FEE_BPS) / 10_000;
        uint256 expectedAuthor  = TIP_AMOUNT - expectedFee;
        assertEq(tipVault.tipsOwed(bob),    expectedAuthor);
        assertEq(tipVault.platformFees(),   expectedFee);

        // Bob withdraws
        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        tipVault.withdraw();
        assertEq(bob.balance, bobBefore + expectedAuthor);
        assertEq(tipVault.tipsOwed(bob), 0);

        // ---------------- TIER SUBSCRIBE ----------------
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        tier.subscribe{value: 0.5 ether}(2);
        assertEq(tier.balanceOf(alice, 2), 1);
        assertEq(core.getTier(alice), 2, "core read-through tier");

        // ---------------- CONTENT PURCHASE ----------------
        bytes32 cid = keccak256("content-1");
        vm.prank(carol); // carol is creator
        uint256 tokenId = content.registerContent(
            cid,
            uint128(CONTENT_PRICE),
            100,                     // maxSupply
            500,                     // 5% royalty
            true                     // soulbound
        );
        assertGt(tokenId, 0);

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        content.purchase{value: CONTENT_PRICE}(tokenId);
        assertEq(content.balanceOf(alice, tokenId), 1);

        uint256 expectedContentFee = (CONTENT_PRICE * FEE_BPS) / 10_000;
        uint256 expectedCreatorAmt = CONTENT_PRICE - expectedContentFee;
        assertEq(content.pendingEarnings(carol),       expectedCreatorAmt);
        assertEq(content.accumulatedPlatformFees(),    expectedContentFee);

        // Carol withdraws earnings
        uint256 carolBefore = carol.balance;
        vm.prank(carol);
        content.withdrawEarnings();
        assertEq(carol.balance, carolBefore + expectedCreatorAmt);

        // ---------------- CROWDFUND FUND + REFUND ----------------
        bytes32 salt = keccak256("project-1");
        vm.prank(carol);
        bytes32 projectId = biz.createProject(
            salt,
            CROWDFUND_GOAL,
            uint64(block.timestamp + 7 days)
        );

        // Bob funds 1 ether (under-goal so we'll refund post-deadline)
        vm.deal(bob, 10 ether);
        vm.prank(bob);
        biz.fund{value: 1 ether}(projectId);
        assertEq(biz.contribution(projectId, bob), 1 ether);

        // Time-warp past deadline without reaching goal
        vm.warp(block.timestamp + 8 days);

        // Bob refunds
        uint256 bobBeforeRefund = bob.balance;
        vm.prank(bob);
        biz.refund(projectId);
        assertEq(bob.balance, bobBeforeRefund + 1 ether);
        assertEq(biz.contribution(projectId, bob), 0);
    }

    // =========================================================================
    // SMOKE-03 : Multiple actors, cross-contract balance accounting
    // =========================================================================
    function test_Smoke_BalanceAccountingAcrossContracts() public {
        // 3 tip events
        vm.deal(alice, 10 ether);
        vm.deal(bob,   10 ether);

        vm.prank(alice);  tipVault.tip{value: 1 ether}(keccak256("p1"), carol);
        vm.prank(bob);    tipVault.tip{value: 0.5 ether}(keccak256("p2"), carol);
        vm.prank(alice);  tipVault.tip{value: 0.3 ether}(keccak256("p3"), bob);

        uint256 totalTips = 1 ether + 0.5 ether + 0.3 ether;
        assertEq(address(tipVault).balance, totalTips);

        uint256 totalPlatform = (totalTips * FEE_BPS) / 10_000;
        assertEq(tipVault.platformFees(), totalPlatform);

        // 1 content purchase (different contract — fees stay separate)
        bytes32 cid = keccak256("content-multi");
        vm.prank(carol);
        uint256 tokenId = content.registerContent(cid, uint128(CONTENT_PRICE), 0, 0, false);
        vm.prank(alice);
        content.purchase{value: CONTENT_PRICE}(tokenId);

        // TipVault et Content1155 ont des fees indépendants malgré treasury commun
        uint256 expectedContentFee = (CONTENT_PRICE * FEE_BPS) / 10_000;
        assertEq(content.accumulatedPlatformFees(), expectedContentFee);
        // TipVault inchangé par le purchase
        assertEq(tipVault.platformFees(), totalPlatform);
    }

    // =========================================================================
    // SMOKE-04 : Treasury withdraw flows from all 3 contracts
    // =========================================================================
    function test_Smoke_TreasuryConsolidation() public {
        // Génère des fees dans les 3 contrats (Tip, Content, Business)
        vm.deal(alice, 100 ether);

        vm.prank(alice); tipVault.tip{value: 1 ether}(keccak256("p1"), bob);

        vm.prank(carol);
        uint256 tokenId = content.registerContent(keccak256("c1"), uint128(CONTENT_PRICE), 0, 0, false);
        vm.prank(alice);
        content.purchase{value: CONTENT_PRICE}(tokenId);

        // Project funded above goal → withdraw possible
        bytes32 salt = keccak256("p-fund");
        vm.prank(carol);
        bytes32 projectId = biz.createProject(salt, uint128(CROWDFUND_GOAL), uint64(block.timestamp + 7 days));
        vm.prank(alice);
        biz.fund{value: CROWDFUND_GOAL}(projectId);
        vm.warp(block.timestamp + 8 days);
        vm.prank(carol);
        biz.withdrawFunds(projectId);

        // 3 withdrawPlatformFees → treasury reçoit le cumul attendu
        uint256 t0 = treasury.balance;
        vm.prank(treasury); tipVault.withdrawPlatformFees();
        vm.prank(admin);    content.withdrawPlatformFees();
        vm.prank(admin);    biz.withdrawPlatformFees();
        uint256 received = treasury.balance - t0;

        uint256 tipFee     = (uint256(1 ether) * FEE_BPS) / 10_000;
        uint256 contentFee = (CONTENT_PRICE * FEE_BPS) / 10_000;
        uint256 cfFee      = (uint256(CROWDFUND_GOAL) * FEE_BPS) / 10_000;
        assertEq(received, tipFee + contentFee + cfFee, "treasury consolidation off");
    }
}
