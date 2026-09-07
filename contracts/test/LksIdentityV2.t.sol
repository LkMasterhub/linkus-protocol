// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2, Vm} from "forge-std/Test.sol";
import {LksIdentityV2} from "../src/identity/LksIdentityV2.sol";
import {IERC5192} from "../src/identity/interfaces/IERC5192.sol";

/**
 * @title LksIdentityV2Test
 * @notice Comprehensive test suite for LksIdentityV2 contract
 * @dev Tests all Phase 1 critical features:
 *      - ERC-5192 Soulbound compliance
 *      - Privacy-preserving credentials
 *      - Social recovery mechanism
 *      - Anti-Sybil protection
 *      - Access control
 */
contract LksIdentityV2Test is Test {
    LksIdentityV2 public identity;

    address public deployer = address(0x1);
    address public treasury = address(0x2);
    address public user1 = address(0x3);
    address public user2 = address(0x4);
    address public verifier = address(0x5);
    address public guardian1 = address(0x6);
    address public guardian2 = address(0x7);
    address public guardian3 = address(0x8);

    uint256 public constant CREATION_PRICE = 0.005 ether;
    uint256 public constant VERIFICATION_FEE = 0.001 ether;

    // Test data
    bytes32 credentialHash1 = keccak256("credential1");
    bytes32 credentialsRoot1 = keccak256("root1");
    bytes32 didDocument1 = keccak256("did1");

    event Locked(uint256 indexed tokenId);
    event IdentityMinted(
        uint256 indexed tokenId,
        address indexed owner,
        bytes32 credentialsRoot,
        bytes32 didDocumentHash
    );
    event VerificationUpdated(
        uint256 indexed tokenId,
        LksIdentityV2.VerificationLevel oldLevel,
        LksIdentityV2.VerificationLevel newLevel,
        bytes32 credentialsRoot
    );
    event GuardiansConfigured(
        uint256 indexed tokenId,
        address[] guardians,
        uint256 threshold
    );
    event RecoveryInitiated(
        uint256 indexed tokenId,
        address indexed newOwner,
        uint256 unlockTime
    );
    event RecoveryCompleted(
        uint256 indexed tokenId,
        address indexed oldOwner,
        address indexed newOwner
    );

    function setUp() public {
        vm.startPrank(deployer);
        identity = new LksIdentityV2(treasury);

        // Grant verifier role
        identity.grantRole(identity.VERIFIER_ROLE(), verifier);
        vm.stopPrank();

        // Fund test accounts
        vm.deal(user1, 10 ether);
        vm.deal(user2, 10 ether);
        vm.deal(verifier, 10 ether);
    }

    // ============================================================================
    // DEPLOYMENT TESTS
    // ============================================================================

    function test_Deployment() public {
        assertEq(identity.name(), "LinkUs Identity V2");
        assertEq(identity.symbol(), "LKSID-V2");
        assertEq(identity.protocolTreasury(), treasury);
        assertEq(identity.creationPrice(), CREATION_PRICE);
        assertEq(identity.totalSupply(), 0);
    }

    function test_DeploymentRevertInvalidTreasury() public {
        vm.expectRevert(LksIdentityV2.InvalidTreasury.selector);
        new LksIdentityV2(address(0));
    }

    // ============================================================================
    // ERC-5192 COMPLIANCE TESTS
    // ============================================================================

    function test_ERC5192_SupportsInterface() public {
        // ERC-5192 interface ID: 0xb45a3c0e
        bytes4 erc5192InterfaceId = type(IERC5192).interfaceId;
        assertTrue(identity.supportsInterface(erc5192InterfaceId));

        // Also supports ERC-721
        assertTrue(identity.supportsInterface(0x80ac58cd));
    }

    function test_ERC5192_LockedReturnsTrue() public {
        // Mint identity
        vm.prank(user1);
        uint256 tokenId = identity.mintIdentity{value: CREATION_PRICE}(
            credentialHash1,
            credentialsRoot1,
            didDocument1
        );

        // Verify locked status
        assertTrue(identity.locked(tokenId));
    }

    function test_ERC5192_LockedRevertNonExistent() public {
        vm.expectRevert();
        identity.locked(999);
    }

    function test_ERC5192_EmitsLockedOnMint() public {
        vm.prank(user1);

        // Record logs to check Locked event was emitted
        vm.recordLogs();

        identity.mintIdentity{value: CREATION_PRICE}(
            credentialHash1,
            credentialsRoot1,
            didDocument1
        );

        // Get emitted events
        Vm.Log[] memory entries = vm.getRecordedLogs();

        // Find Locked event (topic0 = keccak256("Locked(uint256)"))
        bytes32 lockedEventSig = keccak256("Locked(uint256)");
        bool lockedEventFound = false;

        for (uint i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == lockedEventSig) {
                lockedEventFound = true;
                // Verify tokenId = 1 (tokenId is in data field, not indexed)
                assertEq(abi.decode(entries[i].data, (uint256)), 1);
                break;
            }
        }

        assertTrue(lockedEventFound, "Locked event not emitted");
    }

    function test_ERC5192_TransferBlocked() public {
        // Mint identity
        vm.prank(user1);
        uint256 tokenId = identity.mintIdentity{value: CREATION_PRICE}(
            credentialHash1,
            credentialsRoot1,
            didDocument1
        );

        // Try to transfer (should revert)
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(LksIdentityV2.SoulboundToken.selector, tokenId));
        identity.transferFrom(user1, user2, tokenId);
    }

    function test_ERC5192_ApproveBlocked() public {
        // Mint identity
        vm.prank(user1);
        uint256 tokenId = identity.mintIdentity{value: CREATION_PRICE}(
            credentialHash1,
            credentialsRoot1,
            didDocument1
        );

        // Try to approve (should revert)
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(LksIdentityV2.SoulboundToken.selector, tokenId));
        identity.approve(user2, tokenId);
    }

    function test_ERC5192_SetApprovalForAllBlocked() public {
        vm.prank(user1);
        vm.expectRevert("Soulbound: approvals disabled");
        identity.setApprovalForAll(user2, true);
    }

    // ============================================================================
    // IDENTITY MINTING TESTS
    // ============================================================================

    function test_MintIdentity_Success() public {
        uint256 treasuryBalanceBefore = treasury.balance;

        vm.prank(user1);

        vm.expectEmit(true, true, false, true);
        emit IdentityMinted(1, user1, credentialsRoot1, didDocument1);

        uint256 tokenId = identity.mintIdentity{value: CREATION_PRICE}(
            credentialHash1,
            credentialsRoot1,
            didDocument1
        );

        // Verify minting
        assertEq(tokenId, 1);
        assertEq(identity.ownerOf(tokenId), user1);
        assertEq(identity.totalSupply(), 1);
        assertEq(identity.getTokenIdByOwner(user1), tokenId);
        assertTrue(identity.hasIdentity(user1));

        // Verify payment to treasury
        assertEq(treasury.balance, treasuryBalanceBefore + CREATION_PRICE);

        // Verify identity data
        LksIdentityV2.Identity memory identityData = identity.getIdentity(tokenId);
        assertEq(identityData.owner, user1);
        assertEq(identityData.credentialsRoot, credentialsRoot1);
        assertEq(identityData.didDocumentHash, didDocument1);
        assertEq(uint8(identityData.verificationLevel), uint8(LksIdentityV2.VerificationLevel.UNVERIFIED));
        assertEq(uint8(identityData.status), uint8(LksIdentityV2.Status.ACTIVE));
    }

    function test_MintIdentity_RevertAlreadyHasIdentity() public {
        // Mint first identity
        vm.prank(user1);
        identity.mintIdentity{value: CREATION_PRICE}(
            credentialHash1,
            credentialsRoot1,
            didDocument1
        );

        // Try to mint second identity (should revert)
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(LksIdentityV2.AlreadyHasIdentity.selector, user1));
        identity.mintIdentity{value: CREATION_PRICE}(
            keccak256("credential2"),
            keccak256("root2"),
            keccak256("did2")
        );
    }

    function test_MintIdentity_RevertCredentialAlreadyUsed() public {
        // Mint first identity
        vm.prank(user1);
        identity.mintIdentity{value: CREATION_PRICE}(
            credentialHash1,
            credentialsRoot1,
            didDocument1
        );

        // Try to mint with same credential hash (should revert)
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(LksIdentityV2.CredentialAlreadyUsed.selector, credentialHash1));
        identity.mintIdentity{value: CREATION_PRICE}(
            credentialHash1,  // Same hash
            keccak256("root2"),
            keccak256("did2")
        );
    }

    function test_MintIdentity_RevertInsufficientPayment() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(
            LksIdentityV2.InsufficientPayment.selector,
            CREATION_PRICE,
            0.001 ether
        ));
        identity.mintIdentity{value: 0.001 ether}(
            credentialHash1,
            credentialsRoot1,
            didDocument1
        );
    }

    // ============================================================================
    // VERIFICATION TESTS
    // ============================================================================

    function test_UpdateVerification_Success() public {
        // Mint identity
        vm.prank(user1);
        uint256 tokenId = identity.mintIdentity{value: CREATION_PRICE}(
            credentialHash1,
            credentialsRoot1,
            didDocument1
        );

        // Update verification
        bytes32 newRoot = keccak256("newRoot");

        vm.prank(verifier);
        vm.expectEmit(true, false, false, true);
        emit VerificationUpdated(
            tokenId,
            LksIdentityV2.VerificationLevel.UNVERIFIED,
            LksIdentityV2.VerificationLevel.EMAIL_VERIFIED,
            newRoot
        );

        identity.updateVerification{value: VERIFICATION_FEE}(
            tokenId,
            LksIdentityV2.VerificationLevel.EMAIL_VERIFIED,
            newRoot
        );

        // Verify update
        LksIdentityV2.Identity memory identityData = identity.getIdentity(tokenId);
        assertEq(uint8(identityData.verificationLevel), uint8(LksIdentityV2.VerificationLevel.EMAIL_VERIFIED));
        assertEq(identityData.credentialsRoot, newRoot);
        assertTrue(identityData.lastVerifiedAt > 0);
    }

    function test_UpdateVerification_OnlyVerifier() public {
        // Mint identity
        vm.prank(user1);
        uint256 tokenId = identity.mintIdentity{value: CREATION_PRICE}(
            credentialHash1,
            credentialsRoot1,
            didDocument1
        );

        // Try to verify without role (should revert)
        vm.prank(user2);
        vm.expectRevert();
        identity.updateVerification{value: VERIFICATION_FEE}(
            tokenId,
            LksIdentityV2.VerificationLevel.EMAIL_VERIFIED,
            keccak256("newRoot")
        );
    }

    function test_VerifyCredential_Success() public {
        // Mint identity with Merkle root
        bytes32 leaf1 = keccak256(abi.encodePacked("email_verified"));
        bytes32 leaf2 = keccak256(abi.encodePacked("kyc_basic"));
        bytes32 merkleRoot = keccak256(abi.encodePacked(leaf1, leaf2));

        vm.prank(user1);
        uint256 tokenId = identity.mintIdentity{value: CREATION_PRICE}(
            credentialHash1,
            merkleRoot,
            didDocument1
        );

        // Create proof for leaf1
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leaf2;

        // Verify credential
        assertTrue(identity.verifyCredential(tokenId, leaf1, proof));
    }

    // ============================================================================
    // SOCIAL RECOVERY TESTS
    // ============================================================================

    function test_ConfigureRecovery_Success() public {
        // Mint identity
        vm.prank(user1);
        uint256 tokenId = identity.mintIdentity{value: CREATION_PRICE}(
            credentialHash1,
            credentialsRoot1,
            didDocument1
        );

        // Configure guardians
        address[] memory guardians = new address[](3);
        guardians[0] = guardian1;
        guardians[1] = guardian2;
        guardians[2] = guardian3;

        vm.prank(user1);
        vm.expectEmit(true, false, false, true);
        emit GuardiansConfigured(tokenId, guardians, 2);

        identity.configureRecovery(tokenId, guardians, 2);

        // Verify config
        LksIdentityV2.RecoveryConfig memory config = identity.getRecoveryConfig(tokenId);
        assertEq(config.guardians.length, 3);
        assertEq(config.threshold, 2);
    }

    function test_ConfigureRecovery_OnlyOwner() public {
        // Mint identity
        vm.prank(user1);
        uint256 tokenId = identity.mintIdentity{value: CREATION_PRICE}(
            credentialHash1,
            credentialsRoot1,
            didDocument1
        );

        // Try to configure as non-owner (should revert)
        address[] memory guardians = new address[](3);
        guardians[0] = guardian1;
        guardians[1] = guardian2;
        guardians[2] = guardian3;

        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(LksIdentityV2.NotIdentityOwner.selector, tokenId, user2));
        identity.configureRecovery(tokenId, guardians, 2);
    }

    function test_InitiateRecovery_Success() public {
        // Mint and configure recovery
        vm.prank(user1);
        uint256 tokenId = identity.mintIdentity{value: CREATION_PRICE}(
            credentialHash1,
            credentialsRoot1,
            didDocument1
        );

        address[] memory guardians = new address[](3);
        guardians[0] = guardian1;
        guardians[1] = guardian2;
        guardians[2] = guardian3;

        vm.prank(user1);
        identity.configureRecovery(tokenId, guardians, 2);

        // Initiate recovery
        vm.prank(guardian1);
        vm.expectEmit(true, true, false, false);
        emit RecoveryInitiated(tokenId, user2, block.timestamp + 7 days);

        identity.initiateRecovery(tokenId, user2);

        // Verify pending recovery
        (address newOwner, uint256 unlockTime, uint256 approvalCount) = identity.getPendingRecovery(tokenId);
        assertEq(newOwner, user2);
        assertEq(unlockTime, block.timestamp + 7 days);
        assertEq(approvalCount, 1);
    }

    function test_CompleteRecovery_Success() public {
        // Mint and configure recovery
        vm.prank(user1);
        uint256 tokenId = identity.mintIdentity{value: CREATION_PRICE}(
            credentialHash1,
            credentialsRoot1,
            didDocument1
        );

        address[] memory guardians = new address[](3);
        guardians[0] = guardian1;
        guardians[1] = guardian2;
        guardians[2] = guardian3;

        vm.prank(user1);
        identity.configureRecovery(tokenId, guardians, 2);

        // Initiate recovery
        vm.prank(guardian1);
        identity.initiateRecovery(tokenId, user2);

        // Approve by second guardian
        vm.prank(guardian2);
        identity.approveRecovery(tokenId);

        // Fast forward past timelock
        vm.warp(block.timestamp + 7 days + 1);

        // Complete recovery
        vm.expectEmit(true, true, true, false);
        emit RecoveryCompleted(tokenId, user1, user2);

        identity.completeRecovery(tokenId);

        // Verify new ownership
        assertEq(identity.ownerOf(tokenId), user2);
        assertEq(identity.getTokenIdByOwner(user2), tokenId);
        assertEq(identity.getTokenIdByOwner(user1), 0);
    }

    function test_CompleteRecovery_RevertBeforeTimelock() public {
        // Setup recovery
        vm.prank(user1);
        uint256 tokenId = identity.mintIdentity{value: CREATION_PRICE}(
            credentialHash1,
            credentialsRoot1,
            didDocument1
        );

        address[] memory guardians = new address[](3);
        guardians[0] = guardian1;
        guardians[1] = guardian2;
        guardians[2] = guardian3;

        vm.prank(user1);
        identity.configureRecovery(tokenId, guardians, 2);

        vm.prank(guardian1);
        identity.initiateRecovery(tokenId, user2);

        vm.prank(guardian2);
        identity.approveRecovery(tokenId);

        // Try to complete before timelock (should revert)
        vm.expectRevert(LksIdentityV2.RecoveryTimelock.selector);
        identity.completeRecovery(tokenId);
    }

    // ============================================================================
    // DID TESTS
    // ============================================================================

    function test_GetDID_Success() public {
        vm.prank(user1);
        uint256 tokenId = identity.mintIdentity{value: CREATION_PRICE}(
            credentialHash1,
            credentialsRoot1,
            didDocument1
        );

        string memory did = identity.getDID(tokenId);

        // Verify DID format: did:lks:sepolia:<contract>:<tokenId>
        assertTrue(bytes(did).length > 0);
        // Should contain "did:lks:sepolia:"
    }

    // ============================================================================
    // ADMIN TESTS
    // ============================================================================

    function test_SuspendIdentity_Success() public {
        vm.prank(user1);
        uint256 tokenId = identity.mintIdentity{value: CREATION_PRICE}(
            credentialHash1,
            credentialsRoot1,
            didDocument1
        );

        vm.prank(deployer);
        identity.suspendIdentity(tokenId, "Fraud investigation");

        LksIdentityV2.Identity memory identityData = identity.getIdentity(tokenId);
        assertEq(uint8(identityData.status), uint8(LksIdentityV2.Status.SUSPENDED));
    }

    function test_SetCreationPrice_Success() public {
        vm.prank(deployer);
        identity.setCreationPrice(0.02 ether);

        assertEq(identity.creationPrice(), 0.02 ether);
    }

    function test_Pause_Success() public {
        vm.prank(deployer);
        identity.pause();

        // Try to mint while paused (should revert)
        vm.prank(user1);
        vm.expectRevert();
        identity.mintIdentity{value: CREATION_PRICE}(
            credentialHash1,
            credentialsRoot1,
            didDocument1
        );
    }

    // ============================================================================
    // METADATA UPDATE TESTS (V2.1)
    // ============================================================================

    event DIDDocumentUpdated(
        uint256 indexed tokenId,
        bytes32 oldHash,
        bytes32 newHash,
        uint256 timestamp
    );

    function test_UpdateDIDDocument_Success() public {
        // 1. Mint identity
        vm.prank(user1);
        uint256 tokenId = identity.mintIdentity{value: CREATION_PRICE}(
            credentialHash1,
            credentialsRoot1,
            didDocument1
        );

        // 2. Prepare new DID document hash
        bytes32 newDIDDocument = keccak256("new-ipfs-root-cid");

        // 3. Update DID document
        vm.prank(user1);
        vm.expectEmit(true, false, false, true);
        emit DIDDocumentUpdated(tokenId, didDocument1, newDIDDocument, block.timestamp);

        identity.updateDIDDocument(tokenId, newDIDDocument);

        // 4. Verify update
        LksIdentityV2.Identity memory identityData = identity.getIdentity(tokenId);
        assertEq(identityData.didDocumentHash, newDIDDocument);
        assertEq(identityData.owner, user1);
        assertEq(uint8(identityData.status), uint8(LksIdentityV2.Status.ACTIVE));
    }

    function test_UpdateDIDDocument_MultipleUpdates() public {
        // Test that owner can update multiple times
        vm.prank(user1);
        uint256 tokenId = identity.mintIdentity{value: CREATION_PRICE}(
            credentialHash1,
            credentialsRoot1,
            didDocument1
        );

        bytes32 update1 = keccak256("update1");
        bytes32 update2 = keccak256("update2");
        bytes32 update3 = keccak256("update3");

        vm.startPrank(user1);

        identity.updateDIDDocument(tokenId, update1);
        LksIdentityV2.Identity memory data1 = identity.getIdentity(tokenId);
        assertEq(data1.didDocumentHash, update1);

        identity.updateDIDDocument(tokenId, update2);
        LksIdentityV2.Identity memory data2 = identity.getIdentity(tokenId);
        assertEq(data2.didDocumentHash, update2);

        identity.updateDIDDocument(tokenId, update3);
        LksIdentityV2.Identity memory data3 = identity.getIdentity(tokenId);
        assertEq(data3.didDocumentHash, update3);

        vm.stopPrank();
    }

    function test_UpdateDIDDocument_RevertNotOwner() public {
        // 1. User1 mints identity
        vm.prank(user1);
        uint256 tokenId = identity.mintIdentity{value: CREATION_PRICE}(
            credentialHash1,
            credentialsRoot1,
            didDocument1
        );

        // 2. User2 tries to update User1's identity (should revert)
        bytes32 maliciousDID = keccak256("malicious-cid");

        vm.prank(user2);
        vm.expectRevert(
            abi.encodeWithSelector(
                LksIdentityV2.NotIdentityOwner.selector,
                tokenId,
                user2
            )
        );
        identity.updateDIDDocument(tokenId, maliciousDID);

        // 3. Verify DID document unchanged
        LksIdentityV2.Identity memory identityData = identity.getIdentity(tokenId);
        assertEq(identityData.didDocumentHash, didDocument1);
    }

    function test_UpdateDIDDocument_RevertSuspended() public {
        // 1. User mints identity
        vm.prank(user1);
        uint256 tokenId = identity.mintIdentity{value: CREATION_PRICE}(
            credentialHash1,
            credentialsRoot1,
            didDocument1
        );

        // 2. Admin suspends identity
        vm.prank(deployer);
        identity.suspendIdentity(tokenId, "Fraud investigation");

        // 3. User tries to update (should revert)
        bytes32 newDID = keccak256("new-cid");

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                LksIdentityV2.IdentityNotActive.selector,
                tokenId
            )
        );
        identity.updateDIDDocument(tokenId, newDID);
    }

    function test_UpdateDIDDocument_RevertRevoked() public {
        // 1. User mints identity
        vm.prank(user1);
        uint256 tokenId = identity.mintIdentity{value: CREATION_PRICE}(
            credentialHash1,
            credentialsRoot1,
            didDocument1
        );

        // 2. Admin revokes identity
        vm.prank(deployer);
        identity.revokeIdentity(tokenId, "Terms violation");

        // 3. User tries to update (should revert)
        bytes32 newDID = keccak256("new-cid");

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                LksIdentityV2.IdentityNotActive.selector,
                tokenId
            )
        );
        identity.updateDIDDocument(tokenId, newDID);
    }

    function test_UpdateDIDDocument_PreservesOtherFields() public {
        // Verify that updating DID document doesn't affect other identity fields
        vm.prank(user1);
        uint256 tokenId = identity.mintIdentity{value: CREATION_PRICE}(
            credentialHash1,
            credentialsRoot1,
            didDocument1
        );

        // Upgrade verification level
        vm.prank(verifier);
        identity.updateVerification{value: VERIFICATION_FEE}(
            tokenId,
            LksIdentityV2.VerificationLevel.EMAIL_VERIFIED,
            credentialsRoot1
        );

        // Get state before update
        LksIdentityV2.Identity memory beforeUpdate = identity.getIdentity(tokenId);

        // Update DID document
        bytes32 newDID = keccak256("new-cid");
        vm.prank(user1);
        identity.updateDIDDocument(tokenId, newDID);

        // Get state after update
        LksIdentityV2.Identity memory afterUpdate = identity.getIdentity(tokenId);

        // Verify only didDocumentHash changed
        assertEq(afterUpdate.didDocumentHash, newDID);
        assertEq(afterUpdate.owner, beforeUpdate.owner);
        assertEq(afterUpdate.credentialsRoot, beforeUpdate.credentialsRoot);
        assertEq(uint8(afterUpdate.verificationLevel), uint8(beforeUpdate.verificationLevel));
        assertEq(uint8(afterUpdate.status), uint8(beforeUpdate.status));
        assertEq(afterUpdate.mintedAt, beforeUpdate.mintedAt);
        assertEq(afterUpdate.lastVerifiedAt, beforeUpdate.lastVerifiedAt);
        assertEq(afterUpdate.nonce, beforeUpdate.nonce);
    }

    function test_UpdateDIDDocument_RevertIdentityNotFound() public {
        // Try to update non-existent identity
        bytes32 newDID = keccak256("new-cid");
        uint256 nonExistentTokenId = 999;

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                LksIdentityV2.NotIdentityOwner.selector,
                nonExistentTokenId,
                user1
            )
        );
        identity.updateDIDDocument(nonExistentTokenId, newDID);
    }
}
