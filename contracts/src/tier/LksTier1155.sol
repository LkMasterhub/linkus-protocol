// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable}            from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable}      from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable}          from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC1155Upgradeable}       from "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import {ERC1155SupplyUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC1155/extensions/ERC1155SupplyUpgradeable.sol";

import {ITier1155} from "./ITier1155.sol";
import {LksTierSim} from "../../test/sim/LksTierSim.sol";
import {
    ZeroAddress, TransferFailed,
    TierNotFound, InsufficientPayment, SoulboundTransferBlocked
} from "../shared/LksErrors.sol";

/**
 * @title  LksTier1155
 * @notice Subscription tiers en ERC1155 soulbound (BASIC/PREMIUM/PRO).
 *
 *         - tokenId ∈ {1=BASIC, 2=PREMIUM, 3=PRO}
 *         - 1 token max par (user, tierId) — re-subscribe étend l'expiry sans mint
 *         - safeTransferFrom revert toujours (soulbound)
 *         - cancelAndRefund : burn + refund proportionnel (formule LksTierSim)
 *         - msg.value doit égaler EXACTEMENT config.price (no excess)
 *
 * @dev Storage UUPS-safe : __gap[44] réservé après le state.
 */
contract LksTier1155 is
    ITier1155,
    Initializable,
    ERC1155SupplyUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    // ─────────────────────────────────────────────────────────────────
    // Roles
    // ─────────────────────────────────────────────────────────────────

    bytes32 public constant TIER_ADMIN_ROLE = keccak256("TIER_ADMIN_ROLE");
    bytes32 public constant PAUSER_ROLE     = keccak256("PAUSER_ROLE");
    bytes32 public constant UPGRADER_ROLE   = keccak256("UPGRADER_ROLE");

    // ─────────────────────────────────────────────────────────────────
    // Tier IDs
    // ─────────────────────────────────────────────────────────────────

    uint256 public constant override TIER_BASIC   = 1;
    uint256 public constant override TIER_PREMIUM = 2;
    uint256 public constant override TIER_PRO     = 3;

    // ─────────────────────────────────────────────────────────────────
    // Storage
    // ─────────────────────────────────────────────────────────────────

    /// @dev tierId => config
    mapping(uint256 => TierConfig) internal _configs;

    /// @dev (user, tierId) => unix expiry seconds (0 = never subscribed)
    mapping(address => mapping(uint256 => uint64)) internal _expires;

    /// @dev (user, tierId) => start timestamp of current paid period
    mapping(address => mapping(uint256 => uint64)) internal _starts;

    /// @dev (user, tierId) => cumulative wei paid for current period (reset on cancel)
    mapping(address => mapping(uint256 => uint128)) internal _paid;

    /// @dev recipient des paiements subscription (DAO / treasury)
    address public treasury;

    uint256[44] private __gap;

    // ─────────────────────────────────────────────────────────────────
    // Initializer
    // ─────────────────────────────────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin, address initialTreasury, string memory uri_) external initializer {
        if (admin == address(0))           revert ZeroAddress();
        if (initialTreasury == address(0)) revert ZeroAddress();

        __ERC1155_init(uri_);
        __ERC1155Supply_init();
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(TIER_ADMIN_ROLE,    admin);
        _grantRole(PAUSER_ROLE,        admin);
        _grantRole(UPGRADER_ROLE,      admin);

        treasury = initialTreasury;
    }

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}

    // ─────────────────────────────────────────────────────────────────
    // Reads
    // ─────────────────────────────────────────────────────────────────

    /// @inheritdoc ITier1155
    function isActive(address user, uint256 tierId) external view override returns (bool) {
        return _expires[user][tierId] > block.timestamp;
    }

    /// @inheritdoc ITier1155
    function expiresAt(address user, uint256 tierId) external view override returns (uint64) {
        return _expires[user][tierId];
    }

    /// @inheritdoc ITier1155
    function tierConfig(uint256 tierId) external view override returns (TierConfig memory) {
        return _configs[tierId];
    }

    /// @inheritdoc ITier1155
    function totalSupply(uint256 tierId)
        public
        view
        override(ITier1155, ERC1155SupplyUpgradeable)
        returns (uint256)
    {
        return super.totalSupply(tierId);
    }

    /// @notice Montant payé cumulé pour la période en cours.
    function paidAmount(address user, uint256 tierId) external view returns (uint128) {
        return _paid[user][tierId];
    }

    /// @notice Timestamp de début de la période en cours (= expiresAt - duration_total_payée).
    function subscriptionStart(address user, uint256 tierId) external view returns (uint64) {
        return _starts[user][tierId];
    }

    // ─────────────────────────────────────────────────────────────────
    // User flows
    // ─────────────────────────────────────────────────────────────────

    /// @inheritdoc ITier1155
    function subscribe(uint256 tierId) external payable override whenNotPaused nonReentrant {
        TierConfig memory cfg = _configs[tierId];
        if (!cfg.active)                    revert TierNotFound(tierId);
        if (cfg.duration == 0)              revert TierNotFound(tierId);
        if (msg.value != cfg.price)         revert InsufficientPayment(msg.value, cfg.price);
        if (cfg.maxSupply > 0 && balanceOf(msg.sender, tierId) == 0
            && super.totalSupply(tierId) >= cfg.maxSupply) {
            revert TierNotFound(tierId);
        }

        uint64 currentExpiry = _expires[msg.sender][tierId];
        uint64 nowTs         = uint64(block.timestamp);
        uint64 newExpiry     = LksTierSim.newExpiry(currentExpiry, nowTs, cfg.duration);

        // Mint le token si pas encore détenu (garantit balanceOf ≤ 1)
        if (balanceOf(msg.sender, tierId) == 0) {
            _mint(msg.sender, tierId, 1, "");
            _starts[msg.sender][tierId] = nowTs;
            _paid[msg.sender][tierId]   = uint128(msg.value);
        } else {
            _paid[msg.sender][tierId] += uint128(msg.value);
        }

        _expires[msg.sender][tierId] = newExpiry;

        // Note : msg.value reste dans le contrat. Le treasury reçoit la part
        // consommée au moment du cancelAndRefund (ou via reclaimExpired post-MVP).
        emit Subscribed(msg.sender, tierId, newExpiry, msg.value);
    }

    /// @inheritdoc ITier1155
    function cancelAndRefund(uint256 tierId) external override nonReentrant returns (uint256 refunded) {
        if (balanceOf(msg.sender, tierId) == 0) revert TierNotFound(tierId);

        uint128 paid_       = _paid[msg.sender][tierId];
        uint64  start_      = _starts[msg.sender][tierId];
        uint64  expiry_     = _expires[msg.sender][tierId];
        uint64  nowTs       = uint64(block.timestamp);

        refunded = LksTierSim.refund(paid_, start_, expiry_, nowTs);
        uint256 consumed = uint256(paid_) - refunded;

        // Effects (CEI)
        _burn(msg.sender, tierId, 1);
        _expires[msg.sender][tierId] = 0;
        _starts[msg.sender][tierId]  = 0;
        _paid[msg.sender][tierId]    = 0;

        // Interactions
        if (refunded > 0) {
            (bool ok, ) = msg.sender.call{value: refunded}("");
            if (!ok) revert TransferFailed();
        }
        if (consumed > 0) {
            (bool ok2, ) = treasury.call{value: consumed}("");
            if (!ok2) revert TransferFailed();
        }

        emit Cancelled(msg.sender, tierId, refunded);
    }

    // ─────────────────────────────────────────────────────────────────
    // Soulbound enforcement
    // ─────────────────────────────────────────────────────────────────

    /// @dev Override OZ ERC1155 _update : reject tout transfer entre EOA.
    ///      Mint (from=0) et burn (to=0) restent autorisés.
    function _update(address from, address to, uint256[] memory ids, uint256[] memory values)
        internal
        override(ERC1155SupplyUpgradeable)
    {
        if (from != address(0) && to != address(0)) revert SoulboundTransferBlocked();
        super._update(from, to, ids, values);
    }

    // ─────────────────────────────────────────────────────────────────
    // Admin
    // ─────────────────────────────────────────────────────────────────

    /// @inheritdoc ITier1155
    function setTierConfig(uint256 tierId, TierConfig calldata config)
        external
        override
        onlyRole(TIER_ADMIN_ROLE)
    {
        if (tierId == 0 || tierId > TIER_PRO) revert TierNotFound(tierId);
        _configs[tierId] = config;
        emit TierConfigUpdated(tierId, config);
    }

    /// @inheritdoc ITier1155
    function setTierActive(uint256 tierId, bool active) external override onlyRole(TIER_ADMIN_ROLE) {
        _configs[tierId].active = active;
        emit TierActiveSet(tierId, active);
    }

    function setTreasury(address newTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newTreasury == address(0)) revert ZeroAddress();
        treasury = newTreasury;
    }

    /// @inheritdoc ITier1155
    function pause() external override onlyRole(PAUSER_ROLE) { _pause(); }

    /// @inheritdoc ITier1155
    function unpause() external override onlyRole(PAUSER_ROLE) { _unpause(); }

    // ─────────────────────────────────────────────────────────────────
    // Interface dispatch
    // ─────────────────────────────────────────────────────────────────

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC1155Upgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
