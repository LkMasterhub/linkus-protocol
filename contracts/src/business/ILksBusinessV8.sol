// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ILksBusinessV8
 * @notice Crowdfunding seul (le content est dans LksContent1155).
 *
 * Différences vs V7 LksBusinessModule :
 * - Plus de contenu / shares / earnContent EIP-712 (déléguées à Content1155)
 * - Storage allégé : 4 mappings au lieu de ~12
 * - Identifiants projets en bytes32 (déterministe par créateur), plus de counter incrémental
 *
 * Pattern projet :
 * - createProject(id, goal, deadline)
 * - fund(id) avec ETH
 * - À deadline : si goal atteint → withdrawFunds(id) par créateur ; sinon refund(id) par contributors
 * - cancelProject(id) admin ou créateur si pas encore de contributions
 *
 * Invariants :
 * - sum(contributions[id][*]) == project.raised pour tout id non-finalized
 * - project.raised <= address(this).balance si non withdrawn
 * - withdrawn[id] empêche double-withdraw
 */
interface ILksBusinessV8 {
    // ─────────────────────────────────────────────────────────────────
    // Types
    // ─────────────────────────────────────────────────────────────────

    enum ProjectStatus {
        NONE,
        ACTIVE,
        FUNDED,
        REFUNDABLE,
        CANCELLED,
        WITHDRAWN
    }

    struct Project {
        address creator;
        uint64 deadline; // unix seconds
        uint128 goal;
        uint128 raised;
        ProjectStatus status;
    }

    // ─────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────

    event ProjectCreated(
        bytes32 indexed projectId,
        address indexed creator,
        uint128 goal,
        uint64 deadline
    );

    event Funded(
        bytes32 indexed projectId,
        address indexed funder,
        uint256 amount,
        uint128 newRaised
    );

    event FundsWithdrawn(
        bytes32 indexed projectId,
        address indexed creator,
        uint256 creatorAmount,
        uint256 platformFee
    );

    event Refunded(bytes32 indexed projectId, address indexed contributor, uint256 amount);

    event ProjectCancelled(bytes32 indexed projectId);

    // ─────────────────────────────────────────────────────────────────
    // Reads
    // ─────────────────────────────────────────────────────────────────

    /// @notice Calcule le projectId déterministe pour (creator, salt).
    function projectIdOf(address creator, bytes32 salt) external pure returns (bytes32);

    /// @notice Projet par ID.
    function project(bytes32 projectId) external view returns (Project memory);

    /// @notice Contribution d'un acteur sur un projet.
    function contribution(bytes32 projectId, address contributor) external view returns (uint256);

    /// @notice Statut calculé : prend en compte deadline + goal vs raised.
    function projectStatus(bytes32 projectId) external view returns (ProjectStatus);

    /// @notice Taux de fee plateforme sur withdraw (bps).
    function platformFeeBps() external view returns (uint16);

    // ─────────────────────────────────────────────────────────────────
    // User flows
    // ─────────────────────────────────────────────────────────────────

    /// @notice Crée un projet. salt permet à un créateur d'avoir plusieurs projets.
    function createProject(bytes32 salt, uint128 goal, uint64 deadline) external returns (bytes32 projectId);

    /// @notice Contribuer ETH à un projet actif.
    function fund(bytes32 projectId) external payable;

    /// @notice Créateur retire les fonds (post-deadline, goal atteint).
    function withdrawFunds(bytes32 projectId) external;

    /// @notice Contributeur récupère sa contribution (post-deadline, goal pas atteint, ou cancelled).
    function refund(bytes32 projectId) external;

    /// @notice Créateur ou admin annule un projet (que si raised == 0 ou ADMIN_ROLE).
    function cancelProject(bytes32 projectId) external;

    // ─────────────────────────────────────────────────────────────────
    // Admin (TIMELOCK)
    // ─────────────────────────────────────────────────────────────────

    function setPlatformFeeBps(uint16 newBps) external;
    function pause() external;
    function unpause() external;
}
