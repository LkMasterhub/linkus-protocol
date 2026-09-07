// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ITipVault
 * @notice Vault dédié aux tips ETH off-LksSocialModule.
 *
 * Pattern : push payable depuis l'utilisateur, pull pour l'auteur. Isolation
 * voulue pour minimiser la surface d'attaque ETH (ce contrat ne fait QUE
 * gérer les tips, aucune autre logique social).
 *
 * Invariants protégés :
 * - sum(tipsOwed[*]) + platformFees == address(this).balance
 * - feeBps <= MAX_FEE_BPS (3000 = 30%)
 * - paused => tip() revert
 */
interface ITipVault {
    // ─────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────

    /// @notice Émis sur chaque tip réussi.
    event Tipped(
        bytes32 indexed postId,
        address indexed author,
        address indexed tipper,
        uint256 authorShare,
        uint256 platformFee
    );

    /// @notice Émis quand un auteur retire ses tips accumulés.
    event Withdrawn(address indexed author, uint256 amount);

    /// @notice Émis quand le recipient retire les fees plateforme.
    event PlatformFeesWithdrawn(address indexed recipient, uint256 amount);

    /// @notice Émis sur changement de paramètre fee (governance only).
    event FeeUpdated(uint16 oldBps, uint16 newBps);

    /// @notice Émis sur changement de feeRecipient.
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);

    // ─────────────────────────────────────────────────────────────────
    // Reads
    // ─────────────────────────────────────────────────────────────────

    /// @notice Tips en attente de retrait pour un auteur.
    function tipsOwed(address author) external view returns (uint256);

    /// @notice Total de fees plateforme accumulées (non retirées).
    function platformFees() external view returns (uint256);

    /// @notice Total cumulé des tips reçus pour un post (lifetime).
    function postTotals(bytes32 postId) external view returns (uint256);

    /// @notice Taux de fee plateforme (bps, ex: 250 = 2.5%).
    function feeBps() external view returns (uint16);

    /// @notice Recipient des fees plateforme.
    function feeRecipient() external view returns (address);

    /// @notice Cap maximal du feeBps (constante, 3000 = 30%).
    function MAX_FEE_BPS() external view returns (uint16);

    /// @notice Tip minimum accepté (constante, anti-spam).
    function MIN_TIP() external view returns (uint256);

    // ─────────────────────────────────────────────────────────────────
    // User flows
    // ─────────────────────────────────────────────────────────────────

    /// @notice Tip un post : msg.value est split en authorShare + platformFee.
    /// @param postId Hash du post (off-chain ou on-chain).
    /// @param author Adresse créditée pour les tips.
    function tip(bytes32 postId, address author) external payable;

    /// @notice Retirer les tips accumulés (CEI pull pattern).
    function withdraw() external;

    // ─────────────────────────────────────────────────────────────────
    // Admin (timelock-gated en prod)
    // ─────────────────────────────────────────────────────────────────

    /// @notice Retirer les fees plateforme accumulées.
    function withdrawPlatformFees() external;

    /// @notice Modifier le taux de fee. Revert si > MAX_FEE_BPS.
    function setFeeBps(uint16 newBps) external;

    /// @notice Modifier le recipient des fees.
    function setFeeRecipient(address newRecipient) external;

    /// @notice Mettre en pause les tips (admin emergency).
    function pause() external;

    /// @notice Lever la pause.
    function unpause() external;
}
