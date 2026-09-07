// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable}              from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable}   from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable}        from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable}            from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {ILksBusinessV8} from "./ILksBusinessV8.sol";
import {LksFeeSim}      from "../../test/sim/LksFeeSim.sol";
import {
    ZeroAddress, ZeroAmount, TransferFailed, NothingToWithdraw, FeeTooHigh, InvalidConfig,
    ProjectExists, ProjectNotFound, DeadlinePassed, DeadlineNotReached,
    GoalNotReached, GoalAlreadyReached, AlreadyWithdrawn, NothingToRefund, NotProjectCreator
} from "../shared/LksErrors.sol";

/**
 * @title  LksBusinessV8
 * @notice Crowdfunding only — content monétisation est gérée par LksContent1155.
 *
 *         Règles :
 *         - createProject(salt, goal, deadline) : projectId = keccak256(creator, salt)
 *         - fund(id) : pendant que `block.timestamp < deadline` ET status==ACTIVE
 *         - À deadline atteinte :
 *             - raised >= goal → withdrawFunds par créateur (split via LksFeeSim)
 *             - raised <  goal → refund par chaque contributeur (montant exact)
 *         - cancelProject : créateur si raised == 0 ; admin sinon
 *
 *         Pull pattern strict : aucun push d'ETH automatique. Refund + withdraw
 *         passent par appels explicites des bénéficiaires.
 *
 * @dev Storage UUPS-safe : __gap[44] réservé.
 */
contract LksBusinessV8 is
    ILksBusinessV8,
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    // ─────────────────────────────────────────────────────────────────
    // Roles
    // ─────────────────────────────────────────────────────────────────

    bytes32 public constant FEE_ADMIN_ROLE = keccak256("FEE_ADMIN_ROLE");
    bytes32 public constant PAUSER_ROLE    = keccak256("PAUSER_ROLE");
    bytes32 public constant UPGRADER_ROLE  = keccak256("UPGRADER_ROLE");

    // ─────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────

    /// @notice Cap du platform fee (3000 bps = 30%).
    uint16 public constant MAX_PLATFORM_FEE_BPS = 3000;

    /// @notice Durée maximale d'un projet (1 an).
    uint64 public constant MAX_DURATION = 365 days;

    /// @notice Durée minimale d'un projet (1 heure).
    uint64 public constant MIN_DURATION = 1 hours;

    // ─────────────────────────────────────────────────────────────────
    // Storage
    // ─────────────────────────────────────────────────────────────────

    /// @dev projectId => Project
    mapping(bytes32 => Project) internal _projects;
    /// @dev (projectId, contributor) => contribution
    mapping(bytes32 => mapping(address => uint256)) internal _contributions;

    uint16 internal _platformFeeBps;
    address public treasury;
    uint256 public accumulatedPlatformFees;

    uint256[44] private __gap;

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
        uint16  initialPlatformFeeBps
    ) external initializer {
        if (admin == address(0))           revert ZeroAddress();
        if (initialTreasury == address(0)) revert ZeroAddress();
        if (initialPlatformFeeBps > MAX_PLATFORM_FEE_BPS) {
            revert FeeTooHigh(initialPlatformFeeBps, MAX_PLATFORM_FEE_BPS);
        }

        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(FEE_ADMIN_ROLE,     admin);
        _grantRole(PAUSER_ROLE,        admin);
        _grantRole(UPGRADER_ROLE,      admin);

        treasury        = initialTreasury;
        _platformFeeBps = initialPlatformFeeBps;
    }

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}

    // ─────────────────────────────────────────────────────────────────
    // Reads
    // ─────────────────────────────────────────────────────────────────

    /// @inheritdoc ILksBusinessV8
    function projectIdOf(address creator, bytes32 salt) public pure override returns (bytes32) {
        return keccak256(abi.encodePacked(creator, salt));
    }

    /// @inheritdoc ILksBusinessV8
    function project(bytes32 projectId) external view override returns (Project memory) {
        return _projects[projectId];
    }

    /// @inheritdoc ILksBusinessV8
    function contribution(bytes32 projectId, address contributor)
        external
        view
        override
        returns (uint256)
    {
        return _contributions[projectId][contributor];
    }

    /// @inheritdoc ILksBusinessV8
    function projectStatus(bytes32 projectId) external view override returns (ProjectStatus) {
        return _statusOf(projectId);
    }

    /// @inheritdoc ILksBusinessV8
    function platformFeeBps() external view override returns (uint16) {
        return _platformFeeBps;
    }

    // ─────────────────────────────────────────────────────────────────
    // User flows
    // ─────────────────────────────────────────────────────────────────

    /// @inheritdoc ILksBusinessV8
    function createProject(bytes32 salt, uint128 goal, uint64 deadline)
        external
        override
        whenNotPaused
        returns (bytes32 projectId)
    {
        if (goal == 0) revert ZeroAmount();
        uint64 nowTs = uint64(block.timestamp);
        if (deadline <= nowTs)                  revert DeadlinePassed();
        uint64 duration = deadline - nowTs;
        if (duration < MIN_DURATION)            revert InvalidConfig();
        if (duration > MAX_DURATION)            revert InvalidConfig();

        projectId = projectIdOf(msg.sender, salt);
        Project storage p = _projects[projectId];
        if (p.creator != address(0))            revert ProjectExists(projectId);

        p.creator   = msg.sender;
        p.deadline  = deadline;
        p.goal      = goal;
        p.raised    = 0;
        p.status    = ProjectStatus.ACTIVE;

        emit ProjectCreated(projectId, msg.sender, goal, deadline);
    }

    /// @inheritdoc ILksBusinessV8
    function fund(bytes32 projectId) external payable override whenNotPaused nonReentrant {
        if (msg.value == 0) revert ZeroAmount();

        Project storage p = _projects[projectId];
        if (p.creator == address(0))            revert ProjectNotFound(projectId);
        if (p.status != ProjectStatus.ACTIVE)   revert ProjectNotFound(projectId);
        if (block.timestamp >= p.deadline)      revert DeadlinePassed();

        // Effects
        uint256 newRaised = uint256(p.raised) + msg.value;
        if (newRaised > type(uint128).max) revert InvalidConfig();
        p.raised = uint128(newRaised);
        _contributions[projectId][msg.sender] += msg.value;

        emit Funded(projectId, msg.sender, msg.value, p.raised);
    }

    /// @inheritdoc ILksBusinessV8
    function withdrawFunds(bytes32 projectId) external override nonReentrant {
        Project storage p = _projects[projectId];
        if (p.creator == address(0))           revert ProjectNotFound(projectId);
        if (msg.sender != p.creator)           revert NotProjectCreator(msg.sender, p.creator);
        if (block.timestamp < p.deadline)      revert DeadlineNotReached();
        if (p.status == ProjectStatus.WITHDRAWN) revert AlreadyWithdrawn();
        if (p.status == ProjectStatus.CANCELLED) revert AlreadyWithdrawn();
        if (p.raised < p.goal)                 revert GoalNotReached();

        uint256 raised_ = uint256(p.raised);
        (uint256 creatorAmount, uint256 platformFee) = LksFeeSim.feeSplit(raised_, _platformFeeBps);

        // Effects (CEI)
        p.status = ProjectStatus.WITHDRAWN;
        accumulatedPlatformFees += platformFee;

        // Interactions
        if (creatorAmount > 0) {
            (bool ok, ) = p.creator.call{value: creatorAmount}("");
            if (!ok) revert TransferFailed();
        }

        emit FundsWithdrawn(projectId, p.creator, creatorAmount, platformFee);
    }

    /// @inheritdoc ILksBusinessV8
    function refund(bytes32 projectId) external override nonReentrant {
        Project storage p = _projects[projectId];
        if (p.creator == address(0))            revert ProjectNotFound(projectId);

        // Refund autorisé si :
        // - status == CANCELLED
        // - OR (deadline passée && raised < goal)
        bool refundable = (p.status == ProjectStatus.CANCELLED)
            || (block.timestamp >= p.deadline && p.raised < p.goal);
        if (!refundable) {
            if (block.timestamp < p.deadline)   revert DeadlineNotReached();
            revert GoalAlreadyReached();
        }

        uint256 amount = _contributions[projectId][msg.sender];
        if (amount == 0) revert NothingToRefund();

        // Effects
        _contributions[projectId][msg.sender] = 0;
        // raised n'est pas décrementé (statut REFUNDABLE/CANCELLED → withdraw bloqué de toute façon)

        // Interactions
        (bool ok, ) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();

        emit Refunded(projectId, msg.sender, amount);
    }

    /// @inheritdoc ILksBusinessV8
    function cancelProject(bytes32 projectId) external override {
        Project storage p = _projects[projectId];
        if (p.creator == address(0))                                       revert ProjectNotFound(projectId);
        if (p.status != ProjectStatus.ACTIVE)                              revert ProjectNotFound(projectId);

        bool isAdmin   = hasRole(DEFAULT_ADMIN_ROLE, msg.sender);
        bool isCreator = msg.sender == p.creator;
        if (!isAdmin && !isCreator) revert NotProjectCreator(msg.sender, p.creator);

        // Le créateur ne peut annuler que si raised == 0 (pas de contributions à rembourser).
        // L'admin peut annuler même avec raised > 0 (refund individuels post-cancel).
        if (!isAdmin && p.raised > 0) revert GoalAlreadyReached();

        p.status = ProjectStatus.CANCELLED;
        emit ProjectCancelled(projectId);
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
    // Admin
    // ─────────────────────────────────────────────────────────────────

    /// @inheritdoc ILksBusinessV8
    function setPlatformFeeBps(uint16 newBps) external override onlyRole(FEE_ADMIN_ROLE) {
        if (newBps > MAX_PLATFORM_FEE_BPS) revert FeeTooHigh(newBps, MAX_PLATFORM_FEE_BPS);
        _platformFeeBps = newBps;
    }

    function setTreasury(address newTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newTreasury == address(0)) revert ZeroAddress();
        treasury = newTreasury;
    }

    /// @inheritdoc ILksBusinessV8
    function pause() external override onlyRole(PAUSER_ROLE) { _pause(); }

    /// @inheritdoc ILksBusinessV8
    function unpause() external override onlyRole(PAUSER_ROLE) { _unpause(); }

    // ─────────────────────────────────────────────────────────────────
    // Internal
    // ─────────────────────────────────────────────────────────────────

    /// @dev Statut calculé qui prend en compte deadline + goal.
    function _statusOf(bytes32 projectId) internal view returns (ProjectStatus) {
        Project storage p = _projects[projectId];
        if (p.creator == address(0))             return ProjectStatus.NONE;
        if (p.status == ProjectStatus.WITHDRAWN) return ProjectStatus.WITHDRAWN;
        if (p.status == ProjectStatus.CANCELLED) return ProjectStatus.CANCELLED;
        if (block.timestamp < p.deadline)        return ProjectStatus.ACTIVE;
        if (p.raised >= p.goal)                  return ProjectStatus.FUNDED;
        return ProjectStatus.REFUNDABLE;
    }
}
