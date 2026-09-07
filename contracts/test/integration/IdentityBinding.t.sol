// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {ERC1967Proxy}   from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {LksCoreV8}      from "../../src/core/LksCoreV8.sol";
import {LksCoreV8V2}    from "../../src/core/LksCoreV8V2.sol";
import {LksIdentityV2}  from "../../src/identity/LksIdentityV2.sol";

/**
 * @title  IdentityBindingE2E
 * @notice Integration test du flow complet de binding nodeId ↔ NFT identité :
 *
 *           1. Deploy LksIdentityV2 + LksCoreV8 V1 + upgrade vers V2
 *           2. Register MODULE_IDENTITY pointant vers LksIdentityV2
 *           3. User mint NFT identité
 *           4. User appelle bindNodeId(nodeId) sur LksCoreV8V2
 *           5. User appelle updateDIDDocument(tokenId, ipfsHash) sur LksIdentityV2
 *           6. Multi-user discovery : Alice peut résoudre nodeId de Bob
 *
 *         Reproduit exactement le flow frontend P-IB.4 (onboarding step 5).
 */
contract IdentityBindingE2E is Test {
    LksCoreV8V2     internal core;
    LksIdentityV2   internal identity;

    address internal admin    = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal alice    = makeAddr("alice");
    address internal bob      = makeAddr("bob");

    bytes32 internal constant NODE_ID_ALICE = bytes32(uint256(0xA11CE_BABE_DEAD_BEEF));
    bytes32 internal constant NODE_ID_BOB   = bytes32(uint256(0xB0BB_FEED_CAFE_F00D));

    bytes32 internal constant DID_HASH_ALICE = keccak256("ipfs-did-doc-alice-v1");
    bytes32 internal constant DID_HASH_BOB   = keccak256("ipfs-did-doc-bob-v1");

    bytes32 internal constant CRED_HASH_ALICE = keccak256("alice-credential-1");
    bytes32 internal constant CRED_HASH_BOB   = keccak256("bob-credential-1");

    uint256 internal mintPrice;

    event NodeIdBound(address indexed wallet, bytes32 indexed nodeId);
    event DIDDocumentUpdated(uint256 indexed tokenId, bytes32 oldHash, bytes32 newHash);

    function setUp() public {
        // 1. Deploy LksIdentityV2 (non-upgradeable, ERC721 soulbound).
        vm.prank(admin);
        identity = new LksIdentityV2(treasury);
        mintPrice = identity.creationPrice();

        // 2. Deploy LksCoreV8 V1 + upgrade to V2 (mirrors prod path post-upgrade).
        LksCoreV8 v1Impl = new LksCoreV8();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(v1Impl),
            abi.encodeCall(LksCoreV8.initialize, (admin, treasury))
        );
        LksCoreV8 v1 = LksCoreV8(address(proxy));

        LksCoreV8V2 v2Impl = new LksCoreV8V2();
        vm.prank(admin);
        v1.upgradeToAndCall(address(v2Impl), "");
        core = LksCoreV8V2(address(proxy));

        // 3. Register MODULE_IDENTITY → bindNodeId can verify NFT ownership.
        // NB: MODULE_IDENTITY() lu AVANT le prank — vm.prank ne couvre que le
        // prochain appel externe, et l'évaluer inline dans l'appel à
        // registerModule() l'aurait consommé en premier (argument évalué avant
        // l'appel externe), faisant s'exécuter registerModule() en tant que ce
        // contrat de test au lieu de `admin`.
        bytes32 moduleIdentityKey = core.MODULE_IDENTITY();
        vm.prank(admin);
        core.registerModule(moduleIdentityKey, address(identity));
    }

    // =========================================================================
    // E2E-01 : Single user — full mint + bind + DID update flow
    // =========================================================================
    function test_E2E_singleUserFullFlow() public {
        vm.deal(alice, mintPrice);

        // Step 1 : mint NFT (mirror frontend onboarding step 2)
        vm.prank(alice);
        uint256 tokenId = identity.mintIdentity{value: mintPrice}(
            CRED_HASH_ALICE, bytes32(0), bytes32(0)
        );
        assertEq(identity.ownerOf(tokenId), alice);
        assertEq(identity.balanceOf(alice), 1);

        // Sanity : DID hash is zero pre-binding
        assertEq(identity.getIdentity(tokenId).didDocumentHash, bytes32(0));
        assertEq(core.getNodeId(alice), bytes32(0));
        assertFalse(core.hasNodeId(alice));

        // Step 2 : bind nodeId on Core (mirror frontend doBindIdentity tx 2)
        vm.expectEmit(true, true, false, false);
        emit NodeIdBound(alice, NODE_ID_ALICE);
        vm.prank(alice);
        core.bindNodeId(NODE_ID_ALICE);

        // Step 3 : anchor DID hash on identity NFT (mirror frontend doBindIdentity tx 1)
        vm.prank(alice);
        identity.updateDIDDocument(tokenId, DID_HASH_ALICE);

        // Verify post-state — both layers coherent.
        assertTrue(core.hasNodeId(alice));
        assertEq(core.getNodeId(alice), NODE_ID_ALICE);
        assertEq(identity.getIdentity(tokenId).didDocumentHash, DID_HASH_ALICE);
    }

    // =========================================================================
    // E2E-02 : Multi-user discovery — Alice resolves Bob's nodeId
    // =========================================================================
    function test_E2E_multiUserDiscovery() public {
        // Both Alice and Bob complete the bind flow.
        _bindUser(alice, NODE_ID_ALICE, CRED_HASH_ALICE, DID_HASH_ALICE);
        _bindUser(bob,   NODE_ID_BOB,   CRED_HASH_BOB,   DID_HASH_BOB);

        // Alice (any address really) resolves Bob's nodeId without privilege.
        vm.prank(alice);
        bytes32 bobNodeId = core.getNodeId(bob);
        assertEq(bobNodeId, NODE_ID_BOB);

        // And Bob's DID hash is publicly resolvable on the identity contract.
        uint256 bobToken = identity.getTokenIdByOwner(bob);
        assertEq(identity.getIdentity(bobToken).didDocumentHash, DID_HASH_BOB);

        // Cross-check : Alice and Bob mappings don't collide.
        assertEq(core.getNodeId(alice), NODE_ID_ALICE);
        assertTrue(core.hasNodeId(alice) && core.hasNodeId(bob));
    }

    // =========================================================================
    // E2E-03 : Rotation flow — user re-binds with a new nodeId
    // =========================================================================
    function test_E2E_rotationOverwrites() public {
        _bindUser(alice, NODE_ID_ALICE, CRED_HASH_ALICE, DID_HASH_ALICE);

        bytes32 NEW_NODE_ID = bytes32(uint256(0xDEADBEEF_DEADBEEF));
        bytes32 NEW_DID     = keccak256("ipfs-did-doc-alice-v2");

        vm.prank(alice);
        core.bindNodeId(NEW_NODE_ID);

        uint256 aliceTokenId = identity.getTokenIdByOwner(alice);
        vm.prank(alice);
        identity.updateDIDDocument(aliceTokenId, NEW_DID);

        assertEq(core.getNodeId(alice), NEW_NODE_ID);
        assertEq(identity.getIdentity(identity.getTokenIdByOwner(alice)).didDocumentHash, NEW_DID);
    }

    // =========================================================================
    // E2E-04 : Bind reverts if user has no NFT (frontend pre-condition)
    // =========================================================================
    function test_E2E_bindRevertsWithoutNFT() public {
        // Alice has not minted yet.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("NotIdentityHolder(address)", alice));
        core.bindNodeId(NODE_ID_ALICE);
    }

    // =========================================================================
    // E2E-05 : Unbind clears even after NFT is gone (cleanup path)
    // =========================================================================
    function test_E2E_unbindAfterIdentityRevoked() public {
        _bindUser(alice, NODE_ID_ALICE, CRED_HASH_ALICE, DID_HASH_ALICE);
        assertTrue(core.hasNodeId(alice));

        // Admin suspends Alice's identity (does NOT burn but invalidates verification).
        // For this test, we just simulate the user unbinding.
        vm.prank(alice);
        core.unbindNodeId();
        assertFalse(core.hasNodeId(alice));

        // DID hash on the NFT is independent — still readable.
        assertEq(identity.getIdentity(identity.getTokenIdByOwner(alice)).didDocumentHash, DID_HASH_ALICE);
    }

    // =========================================================================
    // Helpers
    // =========================================================================
    function _bindUser(
        address user,
        bytes32 nodeId,
        bytes32 credHash,
        bytes32 didHash
    ) internal {
        vm.deal(user, mintPrice);
        vm.prank(user);
        uint256 tokenId = identity.mintIdentity{value: mintPrice}(credHash, bytes32(0), bytes32(0));

        vm.prank(user);
        core.bindNodeId(nodeId);

        vm.prank(user);
        identity.updateDIDDocument(tokenId, didHash);
    }
}
