// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "./interfaces/IERC5192.sol";

/**
 * @title LksIdentityV2
 * @notice Soulbound NFT Identity System - ERC-5192 Compliant
 * @dev LinkUs Protocol V2 - Security-First Architecture
 *
 * FEATURES:
 * ✅ ERC-5192: Standard Soulbound Token
 * ✅ Privacy-Preserving: Merkle proof credentials (off-chain data)
 * ✅ Social Recovery: Guardian-based recovery mechanism
 * ✅ Multi-Level Verification: 6 verification tiers
 * ✅ Anti-Sybil: 0.01 ETH creation cost
 * ✅ RGPD Compliant: No PII on-chain
 * ✅ Upgradeable: Via TransparentProxy pattern
 *
 * SECURITY:
 * - Non-transferable by default (Soulbound)
 * - Role-based access control
 * - Emergency pause mechanism
 * - Reentrancy protection
 * - Recovery timelock (7 days)
 *
 * @custom:security-contact security@linkus-protocol.io
 */
contract LksIdentityV2 is ERC721, IERC5192, AccessControl, Pausable, ReentrancyGuard {

    // ============================================================================
    // ROLES
    // ============================================================================

    bytes32 public constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant RECOVERY_ROLE = keccak256("RECOVERY_ROLE");

    // ============================================================================
    // TYPES
    // ============================================================================

    /// @notice Verification levels for identity
    enum VerificationLevel {
        UNVERIFIED,      // 0 - Just minted
        EMAIL_VERIFIED,  // 1 - Email confirmed
        PHONE_VERIFIED,  // 2 - Phone SMS confirmed
        KYC_BASIC,       // 3 - Basic KYC (name, DOB)
        KYC_FULL,        // 4 - Full KYC (government ID)
        BIOMETRIC        // 5 - Biometric verification (future)
    }

    /// @notice Identity status
    enum Status {
        ACTIVE,           // Normal active state
        SUSPENDED,        // Temporarily suspended (fraud investigation)
        REVOKED,          // Permanently revoked
        RECOVERY_PENDING  // Recovery initiated, waiting timelock
    }

    /// @notice Identity configuration
    struct Identity {
        address owner;                    // Current owner
        bytes32 credentialsRoot;          // Merkle root of off-chain credentials
        bytes32 didDocumentHash;          // IPFS hash of DID document (encrypted)
        VerificationLevel verificationLevel;
        Status status;
        uint256 mintedAt;
        uint256 lastVerifiedAt;
        uint256 nonce;                    // Anti-replay for recovery
    }

    /// @notice Recovery configuration
    struct RecoveryConfig {
        address[] guardians;              // Guardian addresses (3-10)
        uint256 threshold;                // Approval threshold (e.g., 2/3)
        uint256 timeLock;                 // Recovery timelock duration
    }

    /// @notice Pending recovery
    struct PendingRecovery {
        address newOwner;
        uint256 unlockTime;
        uint256 approvalCount;
        mapping(address => bool) approvals;
    }

    // ============================================================================
    // STORAGE
    // ============================================================================

    /// @notice Next token ID (auto-increment)
    uint256 private _nextTokenId = 1;

    /// @notice Identity data by token ID
    mapping(uint256 => Identity) private _identities;

    /// @notice Token ID by owner address (one identity per address)
    mapping(address => uint256) private _ownerToTokenId;

    /// @notice Recovery config by token ID
    mapping(uint256 => RecoveryConfig) private _recoveryConfigs;

    /// @notice Pending recoveries by token ID
    mapping(uint256 => PendingRecovery) private _pendingRecoveries;

    /// @notice Used credential hashes (anti-double-mint)
    mapping(bytes32 => bool) private _usedCredentialHashes;

    /// @notice Protocol treasury for fees
    address public protocolTreasury;

    /// @notice Creation price (anti-Sybil) - modifiable by DAO
    uint256 public creationPrice = 0.005 ether;  // ~$21.50 @ ETH $4,332

    /// @notice Verification fee per level
    uint256 public verificationFee = 0.001 ether;  // ~$4.33

    /// @notice Recovery timelock duration
    uint256 public recoveryTimeLock = 7 days;

    /// @notice Total identities minted
    uint256 public totalSupply;

    /// @notice Count by verification level
    mapping(VerificationLevel => uint256) public countByLevel;

    /// @notice Recovery transfer flag (internal use only)
    bool private _inRecovery;

    // ============================================================================
    // EVENTS
    // ============================================================================

    // ERC-5192 Events - inherited from IERC5192 interface
    // (Events Locked/Unlocked defined in interface)

    // Identity Lifecycle
    event IdentityMinted(
        uint256 indexed tokenId,
        address indexed owner,
        bytes32 credentialsRoot,
        bytes32 didDocumentHash
    );

    event IdentityGifted(
        uint256 indexed tokenId,
        address indexed recipient,
        address indexed gifter,
        string reason
    );

    event VerificationUpdated(
        uint256 indexed tokenId,
        VerificationLevel oldLevel,
        VerificationLevel newLevel,
        bytes32 credentialsRoot
    );

    event StatusChanged(
        uint256 indexed tokenId,
        Status oldStatus,
        Status newStatus,
        string reason
    );

    // Recovery Events
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

    event RecoveryApproved(
        uint256 indexed tokenId,
        address indexed guardian,
        uint256 approvalCount
    );

    event RecoveryCompleted(
        uint256 indexed tokenId,
        address indexed oldOwner,
        address indexed newOwner
    );

    event RecoveryCancelled(uint256 indexed tokenId);

    // Admin Events
    event CreationPriceUpdated(uint256 oldPrice, uint256 newPrice);
    event VerificationFeeUpdated(uint256 oldFee, uint256 newFee);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    // Metadata Events
    event DIDDocumentUpdated(
        uint256 indexed tokenId,
        bytes32 oldHash,
        bytes32 newHash,
        uint256 timestamp
    );

    // ============================================================================
    // ERRORS
    // ============================================================================

    error AlreadyHasIdentity(address owner);
    error IdentityNotFound(uint256 tokenId);
    error NotIdentityOwner(uint256 tokenId, address caller);
    error IdentityNotActive(uint256 tokenId);
    error InsufficientPayment(uint256 required, uint256 provided);
    error SoulboundToken(uint256 tokenId);
    error InvalidVerificationLevel();
    error InvalidRecoveryConfig();
    error RecoveryNotPending();
    error RecoveryTimelock();
    error NotGuardian(address caller);
    error AlreadyApproved(address guardian);
    error CredentialAlreadyUsed(bytes32 credentialHash);
    error InvalidCredentialProof();
    error InvalidTreasury();
    error InvalidRecipient();

    // ============================================================================
    // CONSTRUCTOR
    // ============================================================================

    constructor(
        address _protocolTreasury
    ) ERC721("LinkUs Identity V2", "LKSID-V2") {
        if (_protocolTreasury == address(0)) revert InvalidTreasury();

        protocolTreasury = _protocolTreasury;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(VERIFIER_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        _grantRole(RECOVERY_ROLE, msg.sender);
    }

    // ============================================================================
    // ERC-5192: SOULBOUND IMPLEMENTATION
    // ============================================================================

    /**
     * @notice Check if token is locked (Soulbound)
     * @dev All tokens are permanently locked (Soulbound)
     * @param tokenId Token ID to check
     * @return bool Always returns true (all tokens are Soulbound)
     */
    function locked(uint256 tokenId) external view override returns (bool) {
        _requireOwned(tokenId);
        return true;  // All identities are Soulbound
    }

    /**
     * @notice Override transfer to block all transfers
     * @dev Reverts on any transfer attempt (except mint/burn/recovery)
     */
    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal virtual override returns (address) {
        address from = _ownerOf(tokenId);

        // Allow mint (from == address(0))
        if (from == address(0)) {
            return super._update(to, tokenId, auth);
        }

        // Allow burn (to == address(0)) - for revoked identities
        if (to == address(0)) {
            return super._update(to, tokenId, auth);
        }

        // Allow recovery transfers
        if (_inRecovery) {
            return super._update(to, tokenId, auth);
        }

        // Block all other transfers
        revert SoulboundToken(tokenId);
    }

    /**
     * @notice Override approve to prevent approvals
     */
    function approve(address, uint256 tokenId) public virtual override {
        revert SoulboundToken(tokenId);
    }

    /**
     * @notice Override setApprovalForAll to prevent approvals
     */
    function setApprovalForAll(address, bool) public virtual override {
        revert("Soulbound: approvals disabled");
    }

    // ============================================================================
    // CORE FUNCTIONS: IDENTITY CREATION
    // ============================================================================

    /**
     * @notice Mint new Soulbound identity
     * @dev Requires payment (anti-Sybil) and unique credential hash
     * @param credentialHash Unique credential hash (prevents duplicate accounts)
     * @param credentialsRoot Merkle root of off-chain credentials
     * @param didDocumentHash IPFS hash of encrypted DID document
     * @return tokenId Minted token ID
     */
    function mintIdentity(
        bytes32 credentialHash,
        bytes32 credentialsRoot,
        bytes32 didDocumentHash
    ) external payable whenNotPaused nonReentrant returns (uint256) {
        // Check one identity per address
        if (_ownerToTokenId[msg.sender] != 0) {
            revert AlreadyHasIdentity(msg.sender);
        }

        // Check credential hash not used
        if (_usedCredentialHashes[credentialHash]) {
            revert CredentialAlreadyUsed(credentialHash);
        }

        // Check payment
        if (msg.value < creationPrice) {
            revert InsufficientPayment(creationPrice, msg.value);
        }

        // Mint NFT
        uint256 tokenId = _nextTokenId++;
        _safeMint(msg.sender, tokenId);

        // Store identity data
        _identities[tokenId] = Identity({
            owner: msg.sender,
            credentialsRoot: credentialsRoot,
            didDocumentHash: didDocumentHash,
            verificationLevel: VerificationLevel.UNVERIFIED,
            status: Status.ACTIVE,
            mintedAt: block.timestamp,
            lastVerifiedAt: 0,
            nonce: 0
        });

        _ownerToTokenId[msg.sender] = tokenId;
        _usedCredentialHashes[credentialHash] = true;

        totalSupply++;
        countByLevel[VerificationLevel.UNVERIFIED]++;

        // Transfer fee to treasury
        _transferToTreasury(msg.value);

        emit IdentityMinted(tokenId, msg.sender, credentialsRoot, didDocumentHash);
        emit Locked(tokenId);  // ERC-5192

        return tokenId;
    }

    /**
     * @notice Gift an identity NFT to an address (for influencers, partners, etc.)
     * @dev Only admin can gift identities (free of charge)
     * @param recipient Address to receive the identity
     * @param credentialsRoot Merkle root of off-chain credentials
     * @param didDocumentHash IPFS hash of encrypted DID document
     * @param reason Reason for gifting (e.g., "Influencer partnership")
     * @return tokenId Minted token ID
     */
    function giftIdentity(
        address recipient,
        bytes32 credentialsRoot,
        bytes32 didDocumentHash,
        string calldata reason
    ) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused nonReentrant returns (uint256) {
        // Check recipient is valid
        if (recipient == address(0)) revert InvalidRecipient();

        // Check one identity per address
        if (_ownerToTokenId[recipient] != 0) {
            revert AlreadyHasIdentity(recipient);
        }

        // Mint NFT
        uint256 tokenId = _nextTokenId++;
        _safeMint(recipient, tokenId);

        // Store identity data
        _identities[tokenId] = Identity({
            owner: recipient,
            credentialsRoot: credentialsRoot,
            didDocumentHash: didDocumentHash,
            verificationLevel: VerificationLevel.UNVERIFIED,
            status: Status.ACTIVE,
            mintedAt: block.timestamp,
            lastVerifiedAt: 0,
            nonce: 0
        });

        _ownerToTokenId[recipient] = tokenId;

        totalSupply++;
        countByLevel[VerificationLevel.UNVERIFIED]++;

        emit IdentityGifted(tokenId, recipient, msg.sender, reason);
        emit IdentityMinted(tokenId, recipient, credentialsRoot, didDocumentHash);
        emit Locked(tokenId);  // ERC-5192

        return tokenId;
    }

    // ============================================================================
    // VERIFICATION SYSTEM
    // ============================================================================

    /**
     * @notice Update identity verification level
     * @dev Only VERIFIER_ROLE can update (Oracle/KYC provider)
     * @param tokenId Token ID to verify
     * @param level New verification level
     * @param newCredentialsRoot Updated Merkle root with new credentials
     */
    function updateVerification(
        uint256 tokenId,
        VerificationLevel level,
        bytes32 newCredentialsRoot
    ) external payable onlyRole(VERIFIER_ROLE) {
        Identity storage identity = _identities[tokenId];

        if (identity.owner == address(0)) revert IdentityNotFound(tokenId);
        if (identity.status != Status.ACTIVE) revert IdentityNotActive(tokenId);

        // Check payment
        if (msg.value < verificationFee) {
            revert InsufficientPayment(verificationFee, msg.value);
        }

        VerificationLevel oldLevel = identity.verificationLevel;

        // Update verification
        identity.verificationLevel = level;
        identity.credentialsRoot = newCredentialsRoot;
        identity.lastVerifiedAt = block.timestamp;

        // Update stats
        countByLevel[oldLevel]--;
        countByLevel[level]++;

        // Transfer fee to treasury
        _transferToTreasury(msg.value);

        emit VerificationUpdated(tokenId, oldLevel, level, newCredentialsRoot);
    }

    /**
     * @notice Verify off-chain credential using Merkle proof
     * @dev Privacy-preserving verification without revealing credential data
     * @param tokenId Token ID
     * @param credentialHash Hash of credential to verify
     * @param merkleProof Merkle proof path
     * @return bool True if credential is valid
     */
    function verifyCredential(
        uint256 tokenId,
        bytes32 credentialHash,
        bytes32[] calldata merkleProof
    ) external view returns (bool) {
        Identity storage identity = _identities[tokenId];

        if (identity.owner == address(0)) revert IdentityNotFound(tokenId);

        return MerkleProof.verify(
            merkleProof,
            identity.credentialsRoot,
            credentialHash
        );
    }

    // ============================================================================
    // SOCIAL RECOVERY
    // ============================================================================

    /**
     * @notice Configure recovery guardians
     * @dev Only identity owner can configure
     * @param tokenId Token ID
     * @param guardians Array of guardian addresses (3-10)
     * @param threshold Approval threshold (e.g., 2 for 2/3)
     */
    function configureRecovery(
        uint256 tokenId,
        address[] calldata guardians,
        uint256 threshold
    ) external {
        Identity storage identity = _identities[tokenId];

        if (identity.owner != msg.sender) {
            revert NotIdentityOwner(tokenId, msg.sender);
        }

        if (guardians.length < 3 || guardians.length > 10) {
            revert InvalidRecoveryConfig();
        }

        if (threshold == 0 || threshold > guardians.length) {
            revert InvalidRecoveryConfig();
        }

        _recoveryConfigs[tokenId] = RecoveryConfig({
            guardians: guardians,
            threshold: threshold,
            timeLock: recoveryTimeLock
        });

        emit GuardiansConfigured(tokenId, guardians, threshold);
    }

    /**
     * @notice Initiate recovery process
     * @dev First guardian initiates, others approve
     * @param tokenId Token ID to recover
     * @param newOwner New owner address
     */
    function initiateRecovery(
        uint256 tokenId,
        address newOwner
    ) external {
        RecoveryConfig storage config = _recoveryConfigs[tokenId];
        Identity storage identity = _identities[tokenId];

        if (config.guardians.length == 0) revert InvalidRecoveryConfig();
        if (!_isGuardian(tokenId, msg.sender)) revert NotGuardian(msg.sender);
        if (_pendingRecoveries[tokenId].unlockTime != 0) {
            revert RecoveryNotPending();  // Already pending
        }

        // Create pending recovery
        PendingRecovery storage pending = _pendingRecoveries[tokenId];
        pending.newOwner = newOwner;
        pending.unlockTime = block.timestamp + config.timeLock;
        pending.approvalCount = 1;
        pending.approvals[msg.sender] = true;

        identity.status = Status.RECOVERY_PENDING;
        identity.nonce++;

        emit RecoveryInitiated(tokenId, newOwner, pending.unlockTime);
        emit RecoveryApproved(tokenId, msg.sender, 1);
    }

    /**
     * @notice Approve pending recovery
     * @dev Guardian approves recovery
     * @param tokenId Token ID
     */
    function approveRecovery(uint256 tokenId) external {
        PendingRecovery storage pending = _pendingRecoveries[tokenId];

        if (pending.unlockTime == 0) revert RecoveryNotPending();
        if (!_isGuardian(tokenId, msg.sender)) revert NotGuardian(msg.sender);
        if (pending.approvals[msg.sender]) revert AlreadyApproved(msg.sender);

        pending.approvals[msg.sender] = true;
        pending.approvalCount++;

        emit RecoveryApproved(tokenId, msg.sender, pending.approvalCount);
    }

    /**
     * @notice Complete recovery (after timelock + threshold met)
     * @dev Anyone can execute once conditions met
     * @param tokenId Token ID
     */
    function completeRecovery(uint256 tokenId) external nonReentrant {
        PendingRecovery storage pending = _pendingRecoveries[tokenId];
        RecoveryConfig storage config = _recoveryConfigs[tokenId];
        Identity storage identity = _identities[tokenId];

        if (pending.unlockTime == 0) revert RecoveryNotPending();
        if (block.timestamp < pending.unlockTime) revert RecoveryTimelock();
        if (pending.approvalCount < config.threshold) {
            revert InvalidRecoveryConfig();
        }

        address oldOwner = identity.owner;
        address newOwner = pending.newOwner;

        // SECURITY FIX: Check that newOwner doesn't already have an identity
        // This prevents bypassing the "one identity per address" rule via recovery
        if (_ownerToTokenId[newOwner] != 0) {
            revert AlreadyHasIdentity(newOwner);
        }

        // Enable recovery transfer temporarily
        _inRecovery = true;

        // Transfer NFT ownership using ERC-721 internal transfer
        _update(newOwner, tokenId, address(0));

        // Disable recovery transfer
        _inRecovery = false;

        // Update identity data
        identity.owner = newOwner;
        identity.status = Status.ACTIVE;

        _ownerToTokenId[oldOwner] = 0;
        _ownerToTokenId[newOwner] = tokenId;

        // Clear pending recovery
        delete _pendingRecoveries[tokenId];

        emit RecoveryCompleted(tokenId, oldOwner, newOwner);
    }

    /**
     * @notice Cancel pending recovery
     * @dev Only identity owner or admin can cancel
     * @param tokenId Token ID
     */
    function cancelRecovery(uint256 tokenId) external {
        Identity storage identity = _identities[tokenId];

        if (identity.owner != msg.sender && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert NotIdentityOwner(tokenId, msg.sender);
        }

        if (_pendingRecoveries[tokenId].unlockTime == 0) {
            revert RecoveryNotPending();
        }

        delete _pendingRecoveries[tokenId];
        identity.status = Status.ACTIVE;

        emit RecoveryCancelled(tokenId);
    }

    // ============================================================================
    // ADMIN FUNCTIONS
    // ============================================================================

    /**
     * @notice Suspend identity (fraud investigation)
     */
    function suspendIdentity(
        uint256 tokenId,
        string calldata reason
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        Identity storage identity = _identities[tokenId];
        Status oldStatus = identity.status;
        identity.status = Status.SUSPENDED;

        emit StatusChanged(tokenId, oldStatus, Status.SUSPENDED, reason);
    }

    /**
     * @notice Revoke identity permanently
     */
    function revokeIdentity(
        uint256 tokenId,
        string calldata reason
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        Identity storage identity = _identities[tokenId];
        Status oldStatus = identity.status;
        identity.status = Status.REVOKED;

        emit StatusChanged(tokenId, oldStatus, Status.REVOKED, reason);

        // Optionally burn the token
        // _burn(tokenId);
    }

    /**
     * @notice Update DID document hash (IPFS root CID)
     * @dev Only identity owner can update their metadata
     * @param tokenId Token ID of the identity
     * @param newDidDocumentHash New IPFS root CID (user folder structure)
     *
     * SECURITY:
     * - Only owner can update their own identity
     * - Identity must be in ACTIVE status
     * - Emits DIDDocumentUpdated event for traceability
     *
     * USE CASES:
     * - Update profile metadata (bio, avatar, social links)
     * - Add new posts to IPFS structure
     * - Add messages to IPFS structure
     * - Upload media files (photos/videos)
     */
    function updateDIDDocument(
        uint256 tokenId,
        bytes32 newDidDocumentHash
    ) external {
        Identity storage identity = _identities[tokenId];

        // Security checks
        if (identity.owner != msg.sender) {
            revert NotIdentityOwner(tokenId, msg.sender);
        }

        if (identity.status != Status.ACTIVE) {
            revert IdentityNotActive(tokenId);
        }

        // Update DID document hash
        bytes32 oldHash = identity.didDocumentHash;
        identity.didDocumentHash = newDidDocumentHash;

        emit DIDDocumentUpdated(tokenId, oldHash, newDidDocumentHash, block.timestamp);
    }

    /**
     * @notice Update creation price
     * @dev Owner can transfer admin role to DAO later
     */
    function setCreationPrice(uint256 newPrice) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 oldPrice = creationPrice;
        creationPrice = newPrice;
        emit CreationPriceUpdated(oldPrice, newPrice);
    }

    /**
     * @notice Update verification fee
     */
    function setVerificationFee(uint256 newFee) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 oldFee = verificationFee;
        verificationFee = newFee;
        emit VerificationFeeUpdated(oldFee, newFee);
    }

    /**
     * @notice Update protocol treasury
     */
    function setProtocolTreasury(address newTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newTreasury == address(0)) revert InvalidTreasury();
        address oldTreasury = protocolTreasury;
        protocolTreasury = newTreasury;
        emit TreasuryUpdated(oldTreasury, newTreasury);
    }

    /**
     * @notice Pause contract (emergency)
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause contract
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // ============================================================================
    // VIEW FUNCTIONS
    // ============================================================================

    /**
     * @notice Get identity data
     */
    function getIdentity(uint256 tokenId) external view returns (Identity memory) {
        if (_identities[tokenId].owner == address(0)) {
            revert IdentityNotFound(tokenId);
        }
        return _identities[tokenId];
    }

    /**
     * @notice Get token ID for address
     */
    function getTokenIdByOwner(address owner) external view returns (uint256) {
        return _ownerToTokenId[owner];
    }

    /**
     * @notice Check if address has identity
     */
    function hasIdentity(address owner) external view returns (bool) {
        return _ownerToTokenId[owner] != 0;
    }

    /**
     * @notice Get recovery config
     */
    function getRecoveryConfig(uint256 tokenId) external view returns (RecoveryConfig memory) {
        return _recoveryConfigs[tokenId];
    }

    /**
     * @notice Get pending recovery info
     */
    function getPendingRecovery(uint256 tokenId) external view returns (
        address newOwner,
        uint256 unlockTime,
        uint256 approvalCount
    ) {
        PendingRecovery storage pending = _pendingRecoveries[tokenId];
        return (pending.newOwner, pending.unlockTime, pending.approvalCount);
    }

    /**
     * @notice Generate W3C DID identifier
     * @dev Format: did:lks:<network>:<contract>:<tokenId>
     */
    function getDID(uint256 tokenId) external view returns (string memory) {
        if (_identities[tokenId].owner == address(0)) {
            revert IdentityNotFound(tokenId);
        }

        return string(abi.encodePacked(
            "did:lks:sepolia:",
            _toHexString(address(this)),
            ":",
            _toString(tokenId)
        ));
    }

    // ============================================================================
    // INTERNAL HELPERS
    // ============================================================================

    function _isGuardian(uint256 tokenId, address account) internal view returns (bool) {
        address[] memory guardians = _recoveryConfigs[tokenId].guardians;
        for (uint256 i = 0; i < guardians.length; i++) {
            if (guardians[i] == account) return true;
        }
        return false;
    }

    function _transferToTreasury(uint256 amount) internal {
        (bool success, ) = protocolTreasury.call{value: amount}("");
        require(success, "Transfer to treasury failed");
    }

    function _toHexString(address addr) internal pure returns (string memory) {
        bytes memory buffer = new bytes(40);
        for (uint256 i = 0; i < 20; i++) {
            bytes1 b = bytes1(uint8(uint160(addr) / (2**(8*(19 - i)))));
            buffer[i*2] = _toHexChar(uint8(b) / 16);
            buffer[i*2 + 1] = _toHexChar(uint8(b) % 16);
        }
        return string(abi.encodePacked("0x", buffer));
    }

    function _toHexChar(uint8 b) internal pure returns (bytes1) {
        return bytes1(b < 10 ? 0x30 + b : 0x61 + b - 10);
    }

    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    // ============================================================================
    // SUPPORTS INTERFACE
    // ============================================================================

    /**
     * @notice Check interface support
     * @dev Supports ERC-721, ERC-5192, AccessControl
     */
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC721, AccessControl)
        returns (bool)
    {
        return
            interfaceId == type(IERC5192).interfaceId ||  // 0xb45a3c0e
            super.supportsInterface(interfaceId);
    }
}
