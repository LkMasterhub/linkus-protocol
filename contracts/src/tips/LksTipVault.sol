// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl}     from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable}          from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard}   from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ITipVault} from "./ITipVault.sol";
import {
    ZeroAddress, NothingToWithdraw, TransferFailed,
    NullAuthor, FeeTooHigh, TipBelowMinimum
} from "../shared/LksErrors.sol";

/**
 * @title  LksTipVault
 * @notice Vault non-upgradeable dédié aux tips ETH du protocole LinkUs.
 *
 *         Pattern : push payable depuis le tipper, pull pour l'auteur via
 *         `withdraw()` (CEI strict, anti-DoS reentrancy).
 *
 *         Invariants protégés (cf. tests/handler) :
 *         - sum(tipsOwed[*]) + platformFees ≤ address(this).balance
 *         - feeBps ≤ MAX_FEE_BPS (3000 = 30 %)
 *         - paused ⇒ tip() revert
 *
 *         Volontairement isolé des contrats sociaux : surface ETH minimale,
 *         pas d'état partagé avec LksSocialModule.
 */
contract LksTipVault is ITipVault, AccessControl, Pausable, ReentrancyGuard {
    // ─────────────────────────────────────────────────────────────────
    // Roles
    // ─────────────────────────────────────────────────────────────────

    bytes32 public constant FEE_ADMIN_ROLE = keccak256("FEE_ADMIN_ROLE");
    bytes32 public constant PAUSER_ROLE    = keccak256("PAUSER_ROLE");

    // ─────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────

    uint16  public constant override MAX_FEE_BPS    = 3000;     // 30 %
    uint256 public constant override MIN_TIP        = 1e13;     // 0.00001 ETH
    uint16  internal constant BPS_DENOMINATOR       = 10_000;

    // ─────────────────────────────────────────────────────────────────
    // Storage
    // ─────────────────────────────────────────────────────────────────

    /// @dev slot 0 : tipsOwed mapping head
    mapping(address => uint256) public override tipsOwed;
    /// @dev slot 1 : postTotals mapping head
    mapping(bytes32 => uint256) public override postTotals;
    /// @dev slot 2 : platformFees cumulés non retirés
    uint256 public override platformFees;
    /// @dev slot 3 : feeBps (2B) + feeRecipient (20B) — packed même slot
    uint16  public override feeBps;
    address public override feeRecipient;

    // ─────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────

    /// @param admin              EOA ou multisig grantee de DEFAULT_ADMIN/FEE_ADMIN/PAUSER.
    /// @param initialFeeBps      Fee initial (≤ MAX_FEE_BPS).
    /// @param initialFeeRecipient Recipient des platformFees (non-zero).
    constructor(address admin, uint16 initialFeeBps, address initialFeeRecipient) {
        if (admin == address(0))                revert ZeroAddress();
        if (initialFeeRecipient == address(0))  revert ZeroAddress();
        if (initialFeeBps > MAX_FEE_BPS)        revert FeeTooHigh(initialFeeBps, MAX_FEE_BPS);

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(FEE_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);

        feeBps       = initialFeeBps;
        feeRecipient = initialFeeRecipient;
    }

    // ─────────────────────────────────────────────────────────────────
    // User flows
    // ─────────────────────────────────────────────────────────────────

    /// @inheritdoc ITipVault
    function tip(bytes32 postId, address author)
        external
        payable
        override
        whenNotPaused
    {
        if (author == address(0))   revert NullAuthor();
        if (msg.value < MIN_TIP)    revert TipBelowMinimum(msg.value, MIN_TIP);

        uint256 fee         = (msg.value * feeBps) / BPS_DENOMINATOR;
        uint256 authorShare = msg.value - fee;

        // CEI : effects only (pas d'external call ici)
        tipsOwed[author]  += authorShare;
        platformFees      += fee;
        postTotals[postId] += msg.value;

        emit Tipped(postId, author, msg.sender, authorShare, fee);
    }

    /// @inheritdoc ITipVault
    function withdraw() external override nonReentrant {
        uint256 amount = tipsOwed[msg.sender];
        if (amount == 0) revert NothingToWithdraw();

        tipsOwed[msg.sender] = 0;                                   // CEI : effects first
        (bool ok, ) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();

        emit Withdrawn(msg.sender, amount);
    }

    // ─────────────────────────────────────────────────────────────────
    // Admin
    // ─────────────────────────────────────────────────────────────────

    /// @inheritdoc ITipVault
    function withdrawPlatformFees() external override nonReentrant {
        uint256 amount = platformFees;
        if (amount == 0) revert NothingToWithdraw();

        address recipient = feeRecipient;
        platformFees = 0;                                           // CEI
        (bool ok, ) = recipient.call{value: amount}("");
        if (!ok) revert TransferFailed();

        emit PlatformFeesWithdrawn(recipient, amount);
    }

    /// @inheritdoc ITipVault
    function setFeeBps(uint16 newBps) external override onlyRole(FEE_ADMIN_ROLE) {
        if (newBps > MAX_FEE_BPS) revert FeeTooHigh(newBps, MAX_FEE_BPS);
        uint16 old = feeBps;
        feeBps = newBps;
        emit FeeUpdated(old, newBps);
    }

    /// @inheritdoc ITipVault
    function setFeeRecipient(address newRecipient) external override onlyRole(FEE_ADMIN_ROLE) {
        if (newRecipient == address(0)) revert ZeroAddress();
        address old = feeRecipient;
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(old, newRecipient);
    }

    /// @inheritdoc ITipVault
    function pause() external override onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @inheritdoc ITipVault
    function unpause() external override onlyRole(PAUSER_ROLE) {
        _unpause();
    }
}
