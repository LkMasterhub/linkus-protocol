// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable}            from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable}      from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable}          from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {ILksCoreV8} from "./ILksCoreV8.sol";
import {ITier1155}  from "../tier/ITier1155.sol";
import {
    ZeroAddress, ZeroAmount, InvalidConfig,
    ReputationCapExceeded, ModuleAlreadyRegistered, ModuleNotRegistered
} from "../shared/LksErrors.sol";

/**
 * @title  LksCoreV8
 * @notice Hub central V8 : registry des modules, reputation off-chain mirrored,
 *         flag (shadow-ban), `getTier` read-through vers `LksTier1155`.
 *
 *         Volontairement plus minimal que V7 : la logique subscription est
 *         déléguée à `LksTier1155`, l'aggrégation reputation off-chain
 *         (lks-rep crate) est anchorée ici par la governance via WRITER_ROLE.
 *
 * @dev Storage packed : `TierData` = 1 slot (8 + 48 + 96 + 8 = 160 bits).
 *      Mais le champ `tier` n'est PAS stocké — il reflète Tier1155 dynamiquement.
 *      `_userState` ne stocke que `expiry` (synchronisé), `reputation`, `flagged`.
 *      `getUserState` recalcule `tier` à la lecture via `_getTierInternal`.
 */
contract LksCoreV8 is
    ILksCoreV8,
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    // ─────────────────────────────────────────────────────────────────
    // Roles
    // ─────────────────────────────────────────────────────────────────

    bytes32 public constant WRITER_ROLE         = keccak256("WRITER_ROLE");
    bytes32 public constant REGISTRY_ADMIN_ROLE = keccak256("REGISTRY_ADMIN_ROLE");
    bytes32 public constant PAUSER_ROLE         = keccak256("PAUSER_ROLE");
    bytes32 public constant UPGRADER_ROLE       = keccak256("UPGRADER_ROLE");

    // ─────────────────────────────────────────────────────────────────
    // Module keys (canoniques V8)
    // ─────────────────────────────────────────────────────────────────

    bytes32 public constant MODULE_TIER1155    = keccak256("TIER1155");
    bytes32 public constant MODULE_CONTENT1155 = keccak256("CONTENT1155");
    bytes32 public constant MODULE_TIPVAULT    = keccak256("TIPVAULT");
    bytes32 public constant MODULE_BUSINESS    = keccak256("BUSINESS");
    bytes32 public constant MODULE_GOVERNANCE  = keccak256("GOVERNANCE");
    bytes32 public constant MODULE_IDENTITY    = keccak256("IDENTITY");

    // ─────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────

    /// @notice Cap par défaut si aucun cap custom n'est set (1M points).
    uint256 public constant DEFAULT_REPUTATION_CAP = 1_000_000;

    // ─────────────────────────────────────────────────────────────────
    // Storage
    // ─────────────────────────────────────────────────────────────────

    /// @dev `tier` n'est PAS persisté — recalculé via Tier1155.
    mapping(address => TierData) internal _userState;
    /// @dev registry module key → contrat
    mapping(bytes32 => address)  internal _registry;
    /// @dev cap personnalisé par user (0 = utiliser DEFAULT_REPUTATION_CAP)
    mapping(address => uint256)  internal _repCap;
    /// @inheritdoc ILksCoreV8
    address public override treasury;

    /// @dev Réservé pour upgrade futur (UUPS storage gap).
    uint256[45] private __gap;

    // ─────────────────────────────────────────────────────────────────
    // Initializer
    // ─────────────────────────────────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializer du proxy UUPS.
    function initialize(address admin, address initialTreasury) external initializer {
        if (admin == address(0))           revert ZeroAddress();
        if (initialTreasury == address(0)) revert ZeroAddress();

        __AccessControl_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE,    admin);
        _grantRole(REGISTRY_ADMIN_ROLE,   admin);
        _grantRole(WRITER_ROLE,           admin);
        _grantRole(PAUSER_ROLE,           admin);
        _grantRole(UPGRADER_ROLE,         admin);

        treasury = initialTreasury;
        emit TreasuryUpdated(initialTreasury);
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}

    // ─────────────────────────────────────────────────────────────────
    // Reads
    // ─────────────────────────────────────────────────────────────────

    /// @inheritdoc ILksCoreV8
    function getTier(address user) external view override returns (uint8) {
        return _getTierInternal(user);
    }

    /// @inheritdoc ILksCoreV8
    function getReputation(address user) external view override returns (uint96) {
        return _userState[user].reputation;
    }

    /// @inheritdoc ILksCoreV8
    function getUserState(address user) external view override returns (TierData memory) {
        TierData memory s = _userState[user];
        s.tier = _getTierInternal(user);
        return s;
    }

    /// @inheritdoc ILksCoreV8
    function getModule(bytes32 key) external view override returns (address) {
        return _registry[key];
    }

    /// @inheritdoc ILksCoreV8
    function reputationCap(address user) external view override returns (uint256) {
        return _repCapOf(user);
    }

    /// @notice True si l'utilisateur est flagged (shadow-ban).
    function isFlagged(address user) external view returns (bool) {
        return _userState[user].flagged;
    }

    // ─────────────────────────────────────────────────────────────────
    // Writes (WRITER_ROLE)
    // ─────────────────────────────────────────────────────────────────

    /// @inheritdoc ILksCoreV8
    function addReputation(address user, uint96 delta)
        external
        override
        whenNotPaused
        onlyRole(WRITER_ROLE)
    {
        if (user == address(0)) revert ZeroAddress();
        if (delta == 0)         revert ZeroAmount();

        TierData storage s = _userState[user];
        uint96 before_ = s.reputation;
        uint256 cap    = _repCapOf(user);
        uint256 next   = uint256(before_) + uint256(delta);

        if (next > cap) {
            uint96 capped96 = cap > type(uint96).max ? type(uint96).max : uint96(cap);
            revert ReputationCapExceeded(before_, capped96);
        }

        s.reputation = uint96(next);
        emit ReputationChanged(user, before_, uint96(next));
    }

    /// @inheritdoc ILksCoreV8
    function slashReputation(address user, uint96 delta)
        external
        override
        whenNotPaused
        onlyRole(WRITER_ROLE)
    {
        if (user == address(0)) revert ZeroAddress();
        if (delta == 0)         revert ZeroAmount();

        TierData storage s = _userState[user];
        uint96 before_ = s.reputation;
        uint96 after_  = before_ > delta ? before_ - delta : 0;
        s.reputation = after_;
        emit ReputationChanged(user, before_, after_);
    }

    /// @inheritdoc ILksCoreV8
    function flag(address user, bool value) external override onlyRole(WRITER_ROLE) {
        if (user == address(0)) revert ZeroAddress();
        _userState[user].flagged = value;
        emit Flagged(user, value);
    }

    // ─────────────────────────────────────────────────────────────────
    // Admin
    // ─────────────────────────────────────────────────────────────────

    /// @inheritdoc ILksCoreV8
    function registerModule(bytes32 key, address module)
        external
        override
        onlyRole(REGISTRY_ADMIN_ROLE)
    {
        if (module == address(0))           revert ZeroAddress();
        if (_registry[key] != address(0))   revert ModuleAlreadyRegistered(key);
        _registry[key] = module;
        emit ModuleRegistered(key, module);
    }

    /// @notice Remplace un module existant. Réservé timelock — strictement
    ///         encadré par REGISTRY_ADMIN_ROLE.
    function updateModule(bytes32 key, address module)
        external
        onlyRole(REGISTRY_ADMIN_ROLE)
    {
        if (module == address(0))             revert ZeroAddress();
        if (_registry[key] == address(0))     revert ModuleNotRegistered(key);
        _registry[key] = module;
        emit ModuleRegistered(key, module);
    }

    /// @inheritdoc ILksCoreV8
    function setReputationCap(address user, uint256 cap)
        external
        override
        onlyRole(REGISTRY_ADMIN_ROLE)
    {
        if (user == address(0))         revert ZeroAddress();
        if (cap > type(uint96).max)     revert InvalidConfig();
        _repCap[user] = cap;
        emit ReputationCapSet(user, cap);
    }

    /// @inheritdoc ILksCoreV8
    function setTreasury(address newTreasury) external override onlyRole(REGISTRY_ADMIN_ROLE) {
        if (newTreasury == address(0)) revert ZeroAddress();
        treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }

    /// @inheritdoc ILksCoreV8
    function pause() external override onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @inheritdoc ILksCoreV8
    function unpause() external override onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // ─────────────────────────────────────────────────────────────────
    // Internal
    // ─────────────────────────────────────────────────────────────────

    function _repCapOf(address user) internal view returns (uint256) {
        uint256 c = _repCap[user];
        return c == 0 ? DEFAULT_REPUTATION_CAP : c;
    }

    /// @dev Read-through Tier1155.isActive avec try/catch (anti-revert cascade).
    ///      Retourne 0 si Tier1155 non enregistré ou si tous les calls ratent.
    function _getTierInternal(address user) internal view returns (uint8) {
        address t1155 = _registry[MODULE_TIER1155];
        if (t1155 == address(0)) return 0;
        if (_isActive(t1155, user, 3)) return 3;
        if (_isActive(t1155, user, 2)) return 2;
        if (_isActive(t1155, user, 1)) return 1;
        return 0;
    }

    function _isActive(address t1155, address user, uint256 tierId) internal view returns (bool) {
        try ITier1155(t1155).isActive(user, tierId) returns (bool active) {
            return active;
        } catch {
            return false;
        }
    }
}
