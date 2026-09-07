// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable}              from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable}   from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable}        from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable}            from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC1155Upgradeable}         from "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import {ERC1155SupplyUpgradeable}   from "@openzeppelin/contracts-upgradeable/token/ERC1155/extensions/ERC1155SupplyUpgradeable.sol";
import {ERC2981Upgradeable}         from "@openzeppelin/contracts-upgradeable/token/common/ERC2981Upgradeable.sol";
import {EIP712Upgradeable}          from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {ECDSA}                      from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils}           from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {IContent1155} from "./IContent1155.sol";
import {LksFeeSim}    from "../../test/sim/LksFeeSim.sol";
import {
    ZeroAddress, ZeroAmount, TransferFailed, NothingToWithdraw, FeeTooHigh,
    ContentAlreadyRegistered, ContentNotFound, MaxSupplyReached, InvalidRoyaltyBps,
    InsufficientPayment, SoulboundTransferBlocked,
    AccessAlreadyGranted, InvalidSignature, NonceAlreadyUsed, DeadlineExpired, EarnSignerNotSet
} from "../shared/LksErrors.sol";

/**
 * @title  LksContent1155
 * @notice Content NFTs (ERC1155 + ERC2981 royalties) avec :
 *
 *         - tokenId déterministe = uint256(keccak256(creator, contentCid))
 *         - registerContent (creator-only sur ce tokenId)
 *         - purchase : split msg.value en (creatorShare, platformFee) via LksFeeSim
 *         - earnAccess : mint gratuit autorisé par signature EIP-712 backend
 *         - withdrawEarnings : pull pattern strict (CEI + ReentrancyGuard)
 *         - soulbound optionnel par contenu (revert transfer si meta.soulbound)
 *         - royaltyInfo : ERC2981 standard (marketplace pickup)
 *
 *         Pattern reproduit V8 : zéro back-door admin, errors typées,
 *         events `before/after`, simulator de référence cross-validé.
 *
 * @dev Storage UUPS-safe : __gap[42] réservé après le state.
 *      Pas de référence circulaire avec LksCoreV8 : ce contrat ne lit pas
 *      le tier — toute gating tier-based se fait dans le frontend ou via
 *      un autre module qui appelle Core.getTier().
 */
contract LksContent1155 is
    IContent1155,
    Initializable,
    ERC1155SupplyUpgradeable,
    ERC2981Upgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    EIP712Upgradeable
{
    using ECDSA for bytes32;

    // ─────────────────────────────────────────────────────────────────
    // Roles
    // ─────────────────────────────────────────────────────────────────

    bytes32 public constant FEE_ADMIN_ROLE = keccak256("FEE_ADMIN_ROLE");
    bytes32 public constant PAUSER_ROLE    = keccak256("PAUSER_ROLE");
    bytes32 public constant UPGRADER_ROLE  = keccak256("UPGRADER_ROLE");

    // ─────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────

    /// @notice Cap maximal du platformFeeBps (3000 = 30%).
    uint16 public constant override MAX_PLATFORM_FEE_BPS = 3000;

    /// @dev EIP-712 typehash : EarnAuthorization(uint256 tokenId,address user,bytes32 nonce,uint64 deadline)
    bytes32 internal constant EARN_TYPEHASH =
        keccak256("EarnAuthorization(uint256 tokenId,address user,bytes32 nonce,uint64 deadline)");

    uint16 internal constant BPS_DENOMINATOR = 10_000;

    // ─────────────────────────────────────────────────────────────────
    // Storage
    // ─────────────────────────────────────────────────────────────────

    /// @dev tokenId => métadonnées
    mapping(uint256 => ContentMeta) internal _meta;
    /// @dev creator => earnings en wei (pull)
    mapping(address => uint256) internal _earnings;
    /// @dev nonce earnAccess => consumed
    mapping(bytes32 => bool) internal _nonceUsed;

    /// @dev fee plateforme courant (bps)
    uint16 internal _platformFeeBps;
    /// @dev signer EIP-712 backend pour earnAccess
    address public earnSigner;
    /// @dev recipient des fees plateforme
    address public treasury;
    /// @dev fees accumulés non encore retirés
    uint256 public accumulatedPlatformFees;

    uint256[42] private __gap;

    // ─────────────────────────────────────────────────────────────────
    // Initializer
    // ─────────────────────────────────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address admin,
        address initialTreasury,
        address initialEarnSigner,
        uint16  initialPlatformFeeBps,
        string memory uri_
    ) external initializer {
        if (admin == address(0))           revert ZeroAddress();
        if (initialTreasury == address(0)) revert ZeroAddress();
        if (initialPlatformFeeBps > MAX_PLATFORM_FEE_BPS) {
            revert FeeTooHigh(initialPlatformFeeBps, MAX_PLATFORM_FEE_BPS);
        }

        __ERC1155_init(uri_);
        __ERC1155Supply_init();
        __ERC2981_init();
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        __EIP712_init("LksContent1155", "1");

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(FEE_ADMIN_ROLE,     admin);
        _grantRole(PAUSER_ROLE,        admin);
        _grantRole(UPGRADER_ROLE,      admin);

        treasury        = initialTreasury;
        earnSigner      = initialEarnSigner;
        _platformFeeBps = initialPlatformFeeBps;
    }

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}

    // ─────────────────────────────────────────────────────────────────
    // Reads
    // ─────────────────────────────────────────────────────────────────

    /// @inheritdoc IContent1155
    function tokenIdOf(address creator, bytes32 contentCid)
        public
        pure
        override
        returns (uint256)
    {
        return uint256(keccak256(abi.encodePacked(creator, contentCid)));
    }

    /// @inheritdoc IContent1155
    function contentMeta(uint256 tokenId) external view override returns (ContentMeta memory) {
        return _meta[tokenId];
    }

    /// @inheritdoc IContent1155
    function pendingEarnings(address creator) external view override returns (uint256) {
        return _earnings[creator];
    }

    /// @inheritdoc IContent1155
    function platformFeeBps() external view override returns (uint16) {
        return _platformFeeBps;
    }

    /// @inheritdoc IContent1155
    function royaltyInfo(uint256 tokenId, uint256 salePrice)
        public
        view
        override(IContent1155, ERC2981Upgradeable)
        returns (address recipient, uint256 royalty)
    {
        return super.royaltyInfo(tokenId, salePrice);
    }

    function isNonceUsed(bytes32 nonce) external view returns (bool) {
        return _nonceUsed[nonce];
    }

    // ─────────────────────────────────────────────────────────────────
    // User flows
    // ─────────────────────────────────────────────────────────────────

    /// @inheritdoc IContent1155
    function registerContent(
        bytes32 contentCid,
        uint128 price,
        uint96 maxSupply,
        uint16 royaltyBps,
        bool soulbound
    ) external override whenNotPaused returns (uint256 tokenId) {
        if (royaltyBps > BPS_DENOMINATOR) revert InvalidRoyaltyBps(royaltyBps);

        tokenId = tokenIdOf(msg.sender, contentCid);

        ContentMeta storage m = _meta[tokenId];
        if (m.creator != address(0)) revert ContentAlreadyRegistered(tokenId);

        m.creator    = msg.sender;
        m.price      = price;
        m.maxSupply  = maxSupply;
        m.royaltyBps = royaltyBps;
        m.contentCid = contentCid;
        m.soulbound  = soulbound;
        // mintCount initialisé à 0

        if (royaltyBps > 0) {
            _setTokenRoyalty(tokenId, msg.sender, royaltyBps);
        }

        emit ContentRegistered(tokenId, msg.sender, contentCid, price, maxSupply, royaltyBps, soulbound);
    }

    /// @inheritdoc IContent1155
    function purchase(uint256 tokenId)
        external
        payable
        override
        whenNotPaused
        nonReentrant
    {
        ContentMeta storage m = _meta[tokenId];
        address creator = m.creator;
        if (creator == address(0))                           revert ContentNotFound(tokenId);
        if (msg.value != uint256(m.price))                   revert InsufficientPayment(msg.value, uint256(m.price));
        if (m.maxSupply > 0 && m.mintCount >= m.maxSupply)   revert MaxSupplyReached(tokenId, m.maxSupply);
        if (balanceOf(msg.sender, tokenId) > 0)              revert AccessAlreadyGranted(tokenId, msg.sender);

        (uint256 creatorShare, uint256 platformFee) = LksFeeSim.feeSplit(msg.value, _platformFeeBps);

        // Effects (CEI)
        m.mintCount += 1;
        _earnings[creator]        += creatorShare;
        accumulatedPlatformFees   += platformFee;

        // Interactions : mint après les effets
        _mint(msg.sender, tokenId, 1, "");

        emit ContentPurchased(tokenId, msg.sender, creator, creatorShare, platformFee);
    }

    /// @inheritdoc IContent1155
    function earnAccess(uint256 tokenId, bytes32 nonce, uint64 deadline, bytes calldata sig)
        external
        override
        whenNotPaused
        nonReentrant
    {
        if (earnSigner == address(0))                revert EarnSignerNotSet();
        if (_nonceUsed[nonce])                       revert NonceAlreadyUsed(nonce);
        if (block.timestamp > deadline)              revert DeadlineExpired(deadline, uint64(block.timestamp));

        ContentMeta storage m = _meta[tokenId];
        if (m.creator == address(0))                         revert ContentNotFound(tokenId);
        if (m.maxSupply > 0 && m.mintCount >= m.maxSupply)   revert MaxSupplyReached(tokenId, m.maxSupply);
        if (balanceOf(msg.sender, tokenId) > 0)              revert AccessAlreadyGranted(tokenId, msg.sender);

        bytes32 structHash = keccak256(abi.encode(EARN_TYPEHASH, tokenId, msg.sender, nonce, deadline));
        bytes32 digest     = _hashTypedDataV4(structHash);
        address recovered  = ECDSA.recover(digest, sig);
        if (recovered != earnSigner) revert InvalidSignature();

        // Effects
        _nonceUsed[nonce] = true;
        m.mintCount += 1;

        // Interactions
        _mint(msg.sender, tokenId, 1, "");

        emit AccessEarned(tokenId, msg.sender, nonce);
    }

    /// @inheritdoc IContent1155
    function withdrawEarnings() external override nonReentrant {
        uint256 amount = _earnings[msg.sender];
        if (amount == 0) revert NothingToWithdraw();

        _earnings[msg.sender] = 0;

        (bool ok, ) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();

        emit EarningsWithdrawn(msg.sender, amount);
    }

    /// @notice Treasury retire les fees plateforme accumulés.
    function withdrawPlatformFees() external nonReentrant {
        uint256 amount = accumulatedPlatformFees;
        if (amount == 0) revert NothingToWithdraw();

        accumulatedPlatformFees = 0;

        (bool ok, ) = treasury.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    // ─────────────────────────────────────────────────────────────────
    // Soulbound enforcement
    // ─────────────────────────────────────────────────────────────────

    /// @dev Override ERC1155 _update : reject transfer si meta.soulbound = true.
    ///      Mint (from=0) et burn (to=0) toujours autorisés.
    function _update(address from, address to, uint256[] memory ids, uint256[] memory values)
        internal
        override(ERC1155SupplyUpgradeable)
    {
        if (from != address(0) && to != address(0)) {
            for (uint256 i = 0; i < ids.length; ++i) {
                if (_meta[ids[i]].soulbound) revert SoulboundTransferBlocked();
            }
        }
        super._update(from, to, ids, values);
    }

    // ─────────────────────────────────────────────────────────────────
    // Admin
    // ─────────────────────────────────────────────────────────────────

    /// @inheritdoc IContent1155
    function setPlatformFeeBps(uint16 newBps) external override onlyRole(FEE_ADMIN_ROLE) {
        if (newBps > MAX_PLATFORM_FEE_BPS) revert FeeTooHigh(newBps, MAX_PLATFORM_FEE_BPS);
        uint16 old = _platformFeeBps;
        _platformFeeBps = newBps;
        emit PlatformFeeBpsUpdated(old, newBps);
    }

    /// @inheritdoc IContent1155
    function setEarnSigner(address newSigner) external override onlyRole(FEE_ADMIN_ROLE) {
        // newSigner == address(0) autorisé (désactive earnAccess)
        earnSigner = newSigner;
    }

    function setTreasury(address newTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newTreasury == address(0)) revert ZeroAddress();
        treasury = newTreasury;
    }

    /// @inheritdoc IContent1155
    function pause() external override onlyRole(PAUSER_ROLE) { _pause(); }

    /// @inheritdoc IContent1155
    function unpause() external override onlyRole(PAUSER_ROLE) { _unpause(); }

    // ─────────────────────────────────────────────────────────────────
    // Interface dispatch
    // ─────────────────────────────────────────────────────────────────

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC1155Upgradeable, ERC2981Upgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
