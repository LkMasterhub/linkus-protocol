// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// =============================================================================
// LksErrors.sol — Custom errors centralisées pour tous les contrats V8
//
// Règle V8 (Ableton-grade) : zéro `require(bool, string)`. Toutes les
// conditions d'échec passent par les errors typées définies ici, importées
// via `import {Xxx} from "../shared/LksErrors.sol"` dans chaque contrat.
//
// Avantages :
// - Coût gas : custom errors ~50% moins chères que require strings
// - Audit : selectors uniques traçables, ABI exposée pour les outils
// - Frontend : décodage typé via viem `parseError(data)` → nom + args
// - Maintenance : un seul fichier à mettre à jour
//
// Convention : groupées par contrat consommateur. Le préfixe `Lks` est
// implicite (le namespace est le fichier).
// =============================================================================

// ─────────────────────────────────────────────────────────────────────────
// General — utilisées par plusieurs contrats
// ─────────────────────────────────────────────────────────────────────────

error ZeroAddress();
error ZeroAmount();
error Unauthorized();
error TransferFailed();
error NothingToWithdraw();
error AlreadyInitialized();
error InvalidConfig();
error Paused_();          // suffix _ pour ne pas collision OZ Pausable
error NotPaused_();

// ─────────────────────────────────────────────────────────────────────────
// LksTipVault
// ─────────────────────────────────────────────────────────────────────────

error NullAuthor();
error FeeTooHigh(uint16 bps, uint16 max);
error TipBelowMinimum(uint256 amount, uint256 min);

// ─────────────────────────────────────────────────────────────────────────
// LksCoreV8
// ─────────────────────────────────────────────────────────────────────────

error NotIdentityHolder(address account);
error ReputationCapExceeded(uint96 current, uint96 cap);
error InvalidTier(uint8 tierId);
error ModuleAlreadyRegistered(bytes32 key);
error ModuleNotRegistered(bytes32 key);

// ─────────────────────────────────────────────────────────────────────────
// LksTier1155
// ─────────────────────────────────────────────────────────────────────────

error TierNotFound(uint256 tierId);
error TierAlreadyExpired();
error InsufficientPayment(uint256 sent, uint256 required);
error SoulboundTransferBlocked();
error RefundProportionFailed();

// ─────────────────────────────────────────────────────────────────────────
// LksContent1155
// ─────────────────────────────────────────────────────────────────────────

error ContentAlreadyRegistered(uint256 tokenId);
error ContentNotFound(uint256 tokenId);
error MaxSupplyReached(uint256 tokenId, uint96 maxSupply);
error NotCreator(address sender, address creator);
error InvalidRoyaltyBps(uint16 bps);
error AccessAlreadyGranted(uint256 tokenId, address user);
error InvalidSignature();
error NonceAlreadyUsed(bytes32 nonce);
error DeadlineExpired(uint64 deadline, uint64 nowTs);
error EarnSignerNotSet();

// ─────────────────────────────────────────────────────────────────────────
// LksBusinessV8
// ─────────────────────────────────────────────────────────────────────────

error ProjectExists(bytes32 projectId);
error ProjectNotFound(bytes32 projectId);
error DeadlinePassed();
error DeadlineNotReached();
error GoalNotReached();
error GoalAlreadyReached();
error AlreadyWithdrawn();
error NothingToRefund();
error NotProjectCreator(address sender, address creator);
