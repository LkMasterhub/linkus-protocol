// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title LKST - LinkUs Shares Token
 * @author LinkUs Protocol
 * @notice Token de gouvernance et d'utilité de LinkUs Protocol
 *
 * Standards:
 * - ERC-20: Token fungible standard
 * - ERC-20 Votes: Gouvernance on-chain avec checkpoints
 * - ERC-20 Permit: Gasless approvals (EIP-2612)
 * - ERC-20 Burnable: Mécanisme deflationary
 * - ERC-20 Pausable: Emergency pause
 *
 * Features:
 * - Supply initial: 1 milliard LKST
 * - Supply max: 10 milliards LKST
 * - Voting power: 1 LKST = 1 vote
 * - Delegation: Transfer voting power sans transfer tokens
 * - Gasless approvals: Signatures off-chain (EIP-2612)
 *
 * Access Control:
 * - MINTER_ROLE: Peut minter jusqu'à MAX_SUPPLY
 * - PAUSER_ROLE: Peut pauser/unpause (emergency)
 * - DEFAULT_ADMIN_ROLE: Peut gérer roles (renonce après setup)
 */
contract LKST is
    ERC20,
    ERC20Burnable,
    ERC20Pausable,
    ERC20Permit,
    ERC20Votes,
    AccessControl
{
    // ============================================================================
    // CONSTANTS
    // ============================================================================

    /// @notice Supply initial (1 milliard LKST)
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10**18;

    /// @notice Supply maximum (10 milliards LKST)
    uint256 public constant MAX_SUPPLY = 10_000_000_000 * 10**18;

    /// @notice Role pour minter des tokens
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @notice Role pour pauser le contrat
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // ============================================================================
    // EVENTS
    // ============================================================================

    /// @notice Émis lors du mint de nouveaux tokens
    event TokensMinted(address indexed to, uint256 amount);

    /// @notice Émis lors du burn de tokens
    event TokensBurned(address indexed from, uint256 amount);

    /// @notice Émis lors du changement de max supply (si nécessaire)
    event MaxSupplyUpdated(uint256 oldMaxSupply, uint256 newMaxSupply);

    // ============================================================================
    // ERRORS
    // ============================================================================

    /// @notice Supply maximum atteint
    error MaxSupplyExceeded(uint256 requested, uint256 available);

    /// @notice Montant invalide (0)
    error InvalidAmount();

    /// @notice Adresse invalide (zero address)
    error InvalidAddress();

    // ============================================================================
    // CONSTRUCTOR
    // ============================================================================

    /**
     * @notice Déploie le token LKST
     * @dev Mint le supply initial au déployeur et setup les roles
     */
    constructor()
        ERC20("LinkUs Shares Token", "LKST")
        ERC20Permit("LinkUs Shares Token")
    {
        // Grant DEFAULT_ADMIN_ROLE au déployeur
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        // Grant MINTER_ROLE et PAUSER_ROLE au déployeur
        _grantRole(MINTER_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);

        // Mint supply initial au déployeur
        _mint(msg.sender, INITIAL_SUPPLY);

        emit TokensMinted(msg.sender, INITIAL_SUPPLY);
    }

    // ============================================================================
    // MINTING FUNCTIONS
    // ============================================================================

    /**
     * @notice Mint des nouveaux tokens (max MAX_SUPPLY)
     * @dev Seulement MINTER_ROLE peut appeler
     * @param to Destinataire des tokens
     * @param amount Montant à minter (18 decimals)
     */
    function mint(address to, uint256 amount)
        external
        onlyRole(MINTER_ROLE)
    {
        if (to == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();

        uint256 newSupply = totalSupply() + amount;
        if (newSupply > MAX_SUPPLY) {
            revert MaxSupplyExceeded(newSupply, MAX_SUPPLY);
        }

        _mint(to, amount);
        emit TokensMinted(to, amount);
    }

    /**
     * @notice Burn des tokens (deflationary mechanism)
     * @dev Hérite de ERC20Burnable (anyone can burn their own)
     * @param amount Montant à burn
     */
    function burn(uint256 amount)
        public
        override
    {
        if (amount == 0) revert InvalidAmount();

        super.burn(amount);
        emit TokensBurned(msg.sender, amount);
    }

    /**
     * @notice Burn des tokens depuis une allowance
     * @param account Compte dont burn les tokens
     * @param amount Montant à burn
     */
    function burnFrom(address account, uint256 amount)
        public
        override
    {
        if (account == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();

        super.burnFrom(account, amount);
        emit TokensBurned(account, amount);
    }

    // ============================================================================
    // PAUSE FUNCTIONS
    // ============================================================================

    /**
     * @notice Pause le contrat (emergency)
     * @dev Seulement PAUSER_ROLE peut appeler
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause le contrat
     * @dev Seulement PAUSER_ROLE peut appeler
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // ============================================================================
    // GOVERNANCE FUNCTIONS (ERC20Votes)
    // ============================================================================

    /**
     * @notice Délègue le voting power à une autre adresse
     * @dev Hérite de ERC20Votes
     * @param delegatee Adresse du délégué
     */
    function delegate(address delegatee) public override {
        if (delegatee == address(0)) revert InvalidAddress();
        super.delegate(delegatee);
    }

    /**
     * @notice Obtient le voting power actuel d'une adresse
     * @param account Adresse à vérifier
     * @return Voting power (nombre de votes)
     */
    function getVotes(address account)
        public
        view
        override
        returns (uint256)
    {
        return super.getVotes(account);
    }

    /**
     * @notice Obtient le voting power à un block passé (checkpoints)
     * @param account Adresse à vérifier
     * @param timepoint Block number
     * @return Voting power au block donné
     */
    function getPastVotes(address account, uint256 timepoint)
        public
        view
        override
        returns (uint256)
    {
        return super.getPastVotes(account, timepoint);
    }

    // ============================================================================
    // OVERRIDES REQUIRED BY SOLIDITY
    // ============================================================================

    /**
     * @dev Hook appelé avant tout transfer
     * @param from Sender
     * @param to Receiver
     * @param value Amount
     */
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20, ERC20Pausable, ERC20Votes)
    {
        super._update(from, to, value);
    }

    /**
     * @dev Nonces pour EIP-2612 permit
     * @param owner Adresse owner
     * @return Nonce actuel
     */
    function nonces(address owner)
        public
        view
        override(ERC20Permit, Nonces)
        returns (uint256)
    {
        return super.nonces(owner);
    }

    // ============================================================================
    // VIEW FUNCTIONS
    // ============================================================================

    /**
     * @notice Obtient le supply disponible pour mint
     * @return Supply restant avant d'atteindre MAX_SUPPLY
     */
    function availableSupply() external view returns (uint256) {
        return MAX_SUPPLY - totalSupply();
    }

    /**
     * @notice Vérifie si une adresse a le MINTER_ROLE
     * @param account Adresse à vérifier
     * @return True si minter
     */
    function isMinter(address account) external view returns (bool) {
        return hasRole(MINTER_ROLE, account);
    }

    /**
     * @notice Vérifie si une adresse a le PAUSER_ROLE
     * @param account Adresse à vérifier
     * @return True si pauser
     */
    function isPauser(address account) external view returns (bool) {
        return hasRole(PAUSER_ROLE, account);
    }

    /**
     * @notice Vérifie si le contrat est pausé
     * @return True si pausé
     */
    function isPaused() external view returns (bool) {
        return paused();
    }
}
