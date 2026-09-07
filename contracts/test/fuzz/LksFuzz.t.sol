// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test}              from "forge-std/Test.sol";
import {ERC1967Proxy}      from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {LksTipVault}       from "../../src/tips/LksTipVault.sol";
import {LksCoreV8}         from "../../src/core/LksCoreV8.sol";
import {LksTier1155}       from "../../src/tier/LksTier1155.sol";
import {ITier1155}         from "../../src/tier/ITier1155.sol";
import {LksContent1155}    from "../../src/content/LksContent1155.sol";
import {IContent1155}      from "../../src/content/IContent1155.sol";
import {LksBusinessV8}     from "../../src/business/LksBusinessV8.sol";
import {LksFeeSim}         from "../sim/LksFeeSim.sol";
import {LksTipSim}         from "../sim/LksTipSim.sol";
import {SoulboundTransferBlocked} from "../../src/shared/LksErrors.sol";

/**
 * @title  LksFuzzTest
 * @notice FUZZ-22 à FUZZ-25 : invariants cross-contract V8.
 *
 *         Stack complet (Core + Tier + Content + TipVault + Business) déployé
 *         dans setUp et wiré via LksCoreV8.registerModule. Cross-validations
 *         systématiquement contre les simulators de référence.
 */
contract LksFuzzTest is Test {
    LksTipVault    internal tipVault;
    LksCoreV8      internal core;
    LksTier1155    internal tier;
    LksContent1155 internal content;
    LksBusinessV8  internal biz;

    address internal admin     = makeAddr("admin");
    address internal treasury  = makeAddr("treasury");
    address internal earnSig   = makeAddr("earnSigner");

    address internal alice     = makeAddr("alice");
    address internal bob       = makeAddr("bob");
    address internal carol     = makeAddr("carol");

    bytes32 internal constant CID_1 = keccak256("cid-1");
    bytes32 internal constant CID_2 = keccak256("cid-2");

    function setUp() public {
        // 1. TipVault (non-upgradeable)
        tipVault = new LksTipVault(admin, 250, treasury);

        // 2. Core
        LksCoreV8 coreImpl = new LksCoreV8();
        bytes memory coreData = abi.encodeWithSelector(
            LksCoreV8.initialize.selector, admin, treasury
        );
        core = LksCoreV8(address(new ERC1967Proxy(address(coreImpl), coreData)));

        // 3. Tier1155
        LksTier1155 tierImpl = new LksTier1155();
        bytes memory tierData = abi.encodeWithSelector(
            LksTier1155.initialize.selector, admin, treasury, "https://lks.example/tier/{id}.json"
        );
        tier = LksTier1155(address(new ERC1967Proxy(address(tierImpl), tierData)));

        // 4. Content1155
        LksContent1155 contentImpl = new LksContent1155();
        bytes memory contentData = abi.encodeWithSelector(
            LksContent1155.initialize.selector, admin, treasury, earnSig, uint16(250), ""
        );
        content = LksContent1155(address(new ERC1967Proxy(address(contentImpl), contentData)));

        // 5. BusinessV8
        LksBusinessV8 bizImpl = new LksBusinessV8();
        bytes memory bizData = abi.encodeWithSelector(
            LksBusinessV8.initialize.selector, admin, treasury, uint16(250)
        );
        biz = LksBusinessV8(address(new ERC1967Proxy(address(bizImpl), bizData)));

        // Wire registry + tier configs
        vm.startPrank(admin);
        core.registerModule(core.MODULE_TIPVAULT(),    address(tipVault));
        core.registerModule(core.MODULE_TIER1155(),    address(tier));
        core.registerModule(core.MODULE_CONTENT1155(), address(content));
        core.registerModule(core.MODULE_BUSINESS(),    address(biz));

        tier.setTierConfig(1, ITier1155.TierConfig({price: 0.1 ether, duration: 30 days, maxSupply: 0, active: true}));
        tier.setTierConfig(2, ITier1155.TierConfig({price: 0.5 ether, duration: 30 days, maxSupply: 0, active: true}));
        tier.setTierConfig(3, ITier1155.TierConfig({price: 1.0 ether, duration: 30 days, maxSupply: 0, active: true}));
        vm.stopPrank();

        vm.deal(alice, 100 ether);
        vm.deal(bob,   100 ether);
        vm.deal(carol, 100 ether);
    }

    // ═════════════════════════════════════════════════════════════════
    // FUZZ-22 : Core.getTier reflète Tier1155 state (read-through cohérent)
    // ═════════════════════════════════════════════════════════════════

    /// @notice Core.getTier retourne toujours le tier actif le plus élevé.
    function testFuzz_22_CoreGetTier_reflectsTier1155(uint8 tierToBuy, bool buyExtra) public {
        tierToBuy = uint8(bound(uint256(tierToBuy), 1, 3));
        ITier1155.TierConfig memory cfg = tier.tierConfig(tierToBuy);

        vm.prank(alice);
        tier.subscribe{value: cfg.price}(tierToBuy);

        // Without owning a higher tier, getTier == tierToBuy
        assertEq(core.getTier(alice), tierToBuy);

        // Optionally buy a different tier and re-check max
        if (buyExtra && tierToBuy < 3) {
            uint8 higher = tierToBuy + 1;
            ITier1155.TierConfig memory cfg2 = tier.tierConfig(higher);
            vm.prank(alice);
            tier.subscribe{value: cfg2.price}(higher);
            assertEq(core.getTier(alice), higher);
        }
    }

    /// @notice Tier expire → Core.getTier retombe au niveau inférieur ou 0
    function testFuzz_22_CoreGetTier_decaysOnExpiry(uint8 tierToBuy, uint64 jumpAhead) public {
        tierToBuy = uint8(bound(uint256(tierToBuy), 1, 3));
        jumpAhead = uint64(bound(uint256(jumpAhead), 31 days, 365 days));

        ITier1155.TierConfig memory cfg = tier.tierConfig(tierToBuy);
        vm.prank(alice);
        tier.subscribe{value: cfg.price}(tierToBuy);
        assertEq(core.getTier(alice), tierToBuy);

        // Warp past expiry — getTier doit retomber à 0
        vm.warp(block.timestamp + jumpAhead);
        assertEq(core.getTier(alice), 0);
    }

    // ═════════════════════════════════════════════════════════════════
    // FUZZ-23 : TipVault + Content1155 accounting indépendants
    // ═════════════════════════════════════════════════════════════════

    /// @notice TipVault.platformFees et Content1155.accumulatedPlatformFees
    ///         sont strictement séparés malgré un même treasury.
    function testFuzz_23_TipAndContentFees_areIndependent(uint128 tipAmount, uint128 purchasePrice) public {
        tipAmount     = uint128(bound(tipAmount,     tipVault.MIN_TIP(), 10 ether));
        purchasePrice = uint128(bound(purchasePrice, 0.001 ether,        10 ether));

        // 1. Alice tip Bob
        vm.deal(alice, tipAmount);
        vm.prank(alice);
        tipVault.tip{value: tipAmount}(CID_1, bob);

        (uint256 expectedAuthor, uint256 expectedTipFee) = LksTipSim.split(tipAmount, tipVault.feeBps());
        assertEq(tipVault.platformFees(),     expectedTipFee);
        assertEq(tipVault.tipsOwed(bob),      expectedAuthor);

        // 2. Carol register + Bob purchase content
        vm.prank(carol);
        uint256 tokenId = content.registerContent(CID_2, purchasePrice, 100, 0, false);

        vm.deal(bob, purchasePrice);
        vm.prank(bob);
        content.purchase{value: purchasePrice}(tokenId);

        (uint256 expectedCreator, uint256 expectedContentFee) = LksFeeSim.feeSplit(purchasePrice, content.platformFeeBps());

        // 3. Les deux pots de fees sont distincts
        assertEq(content.accumulatedPlatformFees(), expectedContentFee);
        assertEq(tipVault.platformFees(),           expectedTipFee);
        assertEq(content.pendingEarnings(carol),    expectedCreator);
        assertEq(tipVault.tipsOwed(bob),            expectedAuthor);

        // 4. Balances physiques séparées
        assertEq(address(tipVault).balance, tipAmount);
        assertEq(address(content).balance,  purchasePrice);
    }

    // ═════════════════════════════════════════════════════════════════
    // FUZZ-24 : Soulbound enforcement uniforme Tier1155 + Content1155
    // ═════════════════════════════════════════════════════════════════

    /// @notice Tier1155 est TOUJOURS soulbound (peu importe le tierId).
    function testFuzz_24_Tier1155_alwaysSoulbound(uint8 tierToBuy) public {
        tierToBuy = uint8(bound(uint256(tierToBuy), 1, 3));
        ITier1155.TierConfig memory cfg = tier.tierConfig(tierToBuy);

        vm.prank(alice);
        tier.subscribe{value: cfg.price}(tierToBuy);

        vm.expectRevert(SoulboundTransferBlocked.selector);
        vm.prank(alice);
        tier.safeTransferFrom(alice, bob, tierToBuy, 1, "");
    }

    /// @notice Content1155 enforce soulbound seulement si meta.soulbound==true.
    function testFuzz_24_Content1155_soulboundConditional(uint128 price, bool soulbound) public {
        price = uint128(bound(price, 0.001 ether, 5 ether));

        vm.prank(carol);
        uint256 tokenId = content.registerContent(CID_1, price, 0, 0, soulbound);

        vm.deal(alice, price);
        vm.prank(alice);
        content.purchase{value: price}(tokenId);

        if (soulbound) {
            vm.expectRevert(SoulboundTransferBlocked.selector);
            vm.prank(alice);
            content.safeTransferFrom(alice, bob, tokenId, 1, "");
            assertEq(content.balanceOf(alice, tokenId), 1);
            assertEq(content.balanceOf(bob,   tokenId), 0);
        } else {
            vm.prank(alice);
            content.safeTransferFrom(alice, bob, tokenId, 1, "");
            assertEq(content.balanceOf(alice, tokenId), 0);
            assertEq(content.balanceOf(bob,   tokenId), 1);
        }
    }

    // ═════════════════════════════════════════════════════════════════
    // FUZZ-25 : Business + Content accounting indépendants
    // ═════════════════════════════════════════════════════════════════

    /// @notice Withdrawal d'un projet financé et purchase content sont
    ///         comptabilisés indépendamment, même treasury commun.
    function testFuzz_25_BusinessAndContentFees_areIndependent(
        uint128 fundAmount,
        uint128 contentPrice
    ) public {
        fundAmount   = uint128(bound(fundAmount,   1 ether,      50 ether));
        contentPrice = uint128(bound(contentPrice, 0.001 ether,  10 ether));

        // 1. Alice crée un projet, Bob fund au-delà du goal
        vm.prank(alice);
        bytes32 projectId = biz.createProject(bytes32(uint256(0xDEAD)), 1 ether, uint64(block.timestamp) + 7 days);

        vm.deal(bob, fundAmount);
        vm.prank(bob);
        biz.fund{value: fundAmount}(projectId);

        // 2. Carol register content, Alice purchase
        vm.prank(carol);
        uint256 tokenId = content.registerContent(CID_2, contentPrice, 100, 0, false);

        vm.deal(alice, contentPrice);
        vm.prank(alice);
        content.purchase{value: contentPrice}(tokenId);

        // 3. Alice withdraw funds après deadline
        vm.warp(block.timestamp + 8 days);
        vm.prank(alice);
        biz.withdrawFunds(projectId);

        // 4. Verify fees split selon LksFeeSim
        (uint256 expectedCreatorBiz, uint256 expectedFeeBiz)         = LksFeeSim.feeSplit(fundAmount,   biz.platformFeeBps());
        (uint256 expectedCreatorCont, uint256 expectedFeeCont)       = LksFeeSim.feeSplit(contentPrice, content.platformFeeBps());

        assertEq(biz.accumulatedPlatformFees(),     expectedFeeBiz);
        assertEq(content.accumulatedPlatformFees(), expectedFeeCont);
        assertEq(content.pendingEarnings(carol),    expectedCreatorCont);

        // Alice a reçu son withdrawFunds direct (pas de pull pour le créateur)
        // → la balance contract biz a déjà décrémenté
        assertEq(address(biz).balance,     expectedFeeBiz);
        assertEq(address(content).balance, contentPrice);
        assertGe(alice.balance,            expectedCreatorBiz); // au moins ça (peut être plus)
    }

    /// @notice Multi-contributors → withdraw + refund + cross-contract balance integrity
    function testFuzz_25_MultiContributorWithdraw(uint128 a, uint128 b, uint128 c) public {
        a = uint128(bound(a, 0.5 ether, 5 ether));
        b = uint128(bound(b, 0.5 ether, 5 ether));
        c = uint128(bound(c, 0.5 ether, 5 ether));

        vm.prank(alice);
        bytes32 projectId = biz.createProject(bytes32(uint256(0xCAFE)), 1 ether, uint64(block.timestamp) + 7 days);

        vm.deal(bob, a);   vm.prank(bob);   biz.fund{value: a}(projectId);
        vm.deal(carol, b); vm.prank(carol); biz.fund{value: b}(projectId);
        // Alice contributes too
        vm.deal(alice, c); vm.prank(alice); biz.fund{value: c}(projectId);

        uint256 raised = uint256(a) + uint256(b) + uint256(c);
        assertEq(uint256(biz.project(projectId).raised), raised);

        vm.warp(block.timestamp + 8 days);
        vm.prank(alice);
        biz.withdrawFunds(projectId);

        (, uint256 fee) = LksFeeSim.feeSplit(raised, biz.platformFeeBps());
        assertEq(biz.accumulatedPlatformFees(), fee);
        assertEq(address(biz).balance, fee);
    }
}
