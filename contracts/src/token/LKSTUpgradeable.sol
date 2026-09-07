// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title LKSTUpgradeable - LinkUs Shares Token (UUPS Upgradeable)
 * @author LinkUs Protocol
 * @notice Token de gouvernance et d'utilité de LinkUs Protocol
 *
 * Standards:
 * - ERC-20: Token fungible standard
 * - ERC-20 Votes: Gouvernance on-chain avec checkpoints
 * - ERC-20 Permit: Gasless approvals (EIP-2612)
 * - ERC-20 Burnable: Mécanisme deflationary
 * - ERC-20 Pausable: Emergency pause
 * - UUPS: Upgradeable proxy pattern
 *
 * Features:
 * - Supply initial: 1 milliard LKST
 * - Supply max: 10 milliards LKST
 * - Voting power: 1 LKST = 1 vote
 * - Delegation: Transfer voting power sans transfer tokens
 * - Gasless approvals: Signatures off-chain (EIP-2612)
 */
contract LKSTUpgradeable is
    Initializable,
    ERC20Upgradeable,
    ERC20BurnableUpgradeable,
    ERC20PausableUpgradeable,
    ERC20PermitUpgradeable,
    ERC20VotesUpgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable
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

    /// @notice Role pour upgrader le contrat
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // ============================================================================
    // EVENTS
    // ============================================================================

    /// @notice Émis lors du mint de nouveaux tokens
    event TokensMinted(address indexed to, uint256 amount);

    /// @notice Émis lors du burn de tokens
    event TokensBurned(address indexed from, uint256 amount);

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
    // STORAGE GAP (for future upgrades)
    // ============================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============================================================================
    // INITIALIZER
    // ============================================================================

    /**
     * @notice Initialise le token LKST
     * @dev Remplace le constructeur pour les proxies UUPS
     * @param treasury Adresse qui reçoit le supply initial
     */
    function initialize(address treasury) public initializer {
        if (treasury == address(0)) revert InvalidAddress();

        __ERC20_init("LinkUs Shares Token", "LKST");
        __ERC20Burnable_init();
        __ERC20Pausable_init();
        __ERC20Permit_init("LinkUs Shares Token");
        __ERC20Votes_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();

        // Grant roles au treasury (deployer)
        _grantRole(DEFAULT_ADMIN_ROLE, treasury);
        _grantRole(MINTER_ROLE, treasury);
        _grantRole(PAUSER_ROLE, treasury);
        _grantRole(UPGRADER_ROLE, treasury);

        // Mint supply initial
        _mint(treasury, INITIAL_SUPPLY);

        emit TokensMinted(treasury, INITIAL_SUPPLY);
    }

    // ============================================================================
    // MINTING FUNCTIONS
    // ============================================================================

    /**
     * @notice Mint des nouveaux tokens (max MAX_SUPPLY)
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
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause le contrat
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // ============================================================================
    // GOVERNANCE FUNCTIONS (ERC20Votes)
    // ============================================================================

    /**
     * @notice Délègue le voting power à une autre adresse
     * @param delegatee Adresse du délégué
     */
    function delegate(address delegatee) public override {
        if (delegatee == address(0)) revert InvalidAddress();
        super.delegate(delegatee);
    }

    // ============================================================================
    // UUPS UPGRADE AUTHORIZATION
    // ============================================================================

    /**
     * @notice Autorise les upgrades du contrat
     * @dev Seulement UPGRADER_ROLE peut upgrader
     */
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(UPGRADER_ROLE)
    {}

    // ============================================================================
    // OVERRIDES REQUIRED BY SOLIDITY
    // ============================================================================

    function _update(address from, address to, uint256 value)
        internal
        override(ERC20Upgradeable, ERC20PausableUpgradeable, ERC20VotesUpgradeable)
    {
        super._update(from, to, value);
    }

    function nonces(address owner)
        public
        view
        override(ERC20PermitUpgradeable, NoncesUpgradeable)
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
     */
    function isMinter(address account) external view returns (bool) {
        return hasRole(MINTER_ROLE, account);
    }

    /**
     * @notice Vérifie si une adresse a le PAUSER_ROLE
     */
    function isPauser(address account) external view returns (bool) {
        return hasRole(PAUSER_ROLE, account);
    }

    /**
     * @notice Vérifie si le contrat est pausé
     */
    function isPaused() external view returns (bool) {
        return paused();
    }

    /**
     * @notice Storage gap pour futures upgrades
     */
    uint256[50] private __gap;
}
