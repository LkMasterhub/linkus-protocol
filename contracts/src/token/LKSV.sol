// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title LKSV - LinkUs Staking Vault
 * @author LinkUs Protocol
 * @notice ERC-4626 Tokenized Vault pour staking LKST avec rewards
 *
 * Architecture:
 * - Asset: LKST token
 * - Shares: sLKST (staked LKST)
 * - Rewards: Distribution continue de LKST
 * - APY: Variable selon reward rate
 *
 * Features:
 * - Deposit LKST → Receive sLKST shares
 * - sLKST tradable (yield-bearing token)
 * - Rewards accumulés automatiquement
 * - Claim rewards séparément
 * - Protection inflation attack (virtual offset)
 *
 * Mécanisme Rewards:
 * - rewardRate: LKST distribués par seconde
 * - Rewards proportionnels au stake
 * - Accumulation continue (par seconde)
 * - Claim sans unstake
 *
 * Security:
 * - ReentrancyGuard sur toutes fonctions state-changing
 * - Virtual offset protection (ERC-4626 v5.1)
 * - Owner controls reward rate
 */
contract LKSV is ERC4626, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============================================================================
    // STATE VARIABLES
    // ============================================================================

    /// @notice Token LKST (asset)
    IERC20 public immutable lkstToken;

    /// @notice Reward rate (LKST par seconde distribués)
    uint256 public rewardRate;

    /// @notice Timestamp dernière update rewards
    uint256 public lastUpdateTime;

    /// @notice Rewards accumulés par token (scaled 1e18)
    uint256 public rewardPerTokenStored;

    /// @notice Rewards déjà payés par user
    mapping(address => uint256) public userRewardPerTokenPaid;

    /// @notice Rewards accumulés non claim par user
    mapping(address => uint256) public rewards;

    /// @notice Total rewards distribués depuis création
    uint256 public totalRewardsDistributed;

    /// @notice Reserve de rewards (LKST alloués aux rewards)
    uint256 public rewardReserve;

    // ============================================================================
    // CONSTANTS
    // ============================================================================

    /// @notice Precision pour calculs (1e18)
    uint256 public constant PRECISION = 1e18;

    /// @notice Minimum reward rate (1 LKST/jour ≈ 0.0000115 LKST/s)
    uint256 public constant MIN_REWARD_RATE = 11574074074074; // ~1 LKST/day

    /// @notice Maximum reward rate (1M LKST/jour ≈ 11.57 LKST/s)
    uint256 public constant MAX_REWARD_RATE = 11574074074074074074; // ~1M LKST/day

    // ============================================================================
    // EVENTS
    // ============================================================================

    /// @notice Émis lors d'un stake (deposit)
    event Staked(address indexed user, uint256 assets, uint256 shares);

    /// @notice Émis lors d'un unstake (withdraw/redeem)
    event Withdrawn(address indexed user, uint256 assets, uint256 shares);

    /// @notice Émis lors du claim rewards
    event RewardPaid(address indexed user, uint256 reward);

    /// @notice Émis lors du changement reward rate
    event RewardRateUpdated(uint256 oldRate, uint256 newRate);

    /// @notice Émis lors de l'ajout de rewards au vault
    event RewardsFunded(uint256 amount, uint256 newReserve);

    /// @notice Émis lors du retrait emergency par owner
    event EmergencyWithdraw(address indexed token, uint256 amount);

    // ============================================================================
    // ERRORS
    // ============================================================================

    /// @notice Reward rate invalide (trop bas ou trop haut)
    error InvalidRewardRate(uint256 rate);

    /// @notice Montant invalide (0)
    error InvalidAmount();

    /// @notice Reserve insuffisante pour rewards
    error InsufficientRewardReserve(uint256 required, uint256 available);

    /// @notice Adresse invalide (zero address)
    error InvalidAddress();

    /// @notice Tentative de retirer plus que le surplus disponible
    error ExceedsSurplus(uint256 requested, uint256 available);

    // ============================================================================
    // MODIFIERS
    // ============================================================================

    /**
     * @notice Met à jour les rewards avant modification state
     * @param account Adresse user à update (address(0) si aucun)
     */
    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = block.timestamp;

        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    // ============================================================================
    // CONSTRUCTOR
    // ============================================================================

    /**
     * @notice Déploie le vault LKSV
     * @param _lkstToken Adresse du token LKST
     */
    constructor(IERC20 _lkstToken)
        ERC20("Staked LinkUs Token", "sLKST")
        ERC4626(_lkstToken)
        Ownable(msg.sender)
    {
        if (address(_lkstToken) == address(0)) revert InvalidAddress();

        lkstToken = _lkstToken;
        rewardRate = 1e18; // 1 LKST/seconde par défaut
        lastUpdateTime = block.timestamp;
    }

    // ============================================================================
    // STAKING FUNCTIONS (ERC-4626 overrides)
    // ============================================================================

    /**
     * @notice Deposit LKST et reçoit sLKST shares
     * @param assets Montant LKST à déposer
     * @param receiver Adresse qui reçoit les shares
     * @return shares Nombre de sLKST reçus
     */
    function deposit(uint256 assets, address receiver)
        public
        override
        nonReentrant
        updateReward(receiver)
        returns (uint256 shares)
    {
        if (assets == 0) revert InvalidAmount();
        if (receiver == address(0)) revert InvalidAddress();

        shares = super.deposit(assets, receiver);
        emit Staked(receiver, assets, shares);
    }

    /**
     * @notice Mint des sLKST shares en déposant LKST
     * @param shares Nombre de sLKST à mint
     * @param receiver Adresse qui reçoit les shares
     * @return assets Montant LKST déposé
     */
    function mint(uint256 shares, address receiver)
        public
        override
        nonReentrant
        updateReward(receiver)
        returns (uint256 assets)
    {
        if (shares == 0) revert InvalidAmount();
        if (receiver == address(0)) revert InvalidAddress();

        assets = super.mint(shares, receiver);
        emit Staked(receiver, assets, shares);
    }

    /**
     * @notice Withdraw LKST en brûlant sLKST shares
     * @param assets Montant LKST à withdraw
     * @param receiver Adresse qui reçoit les LKST
     * @param owner Propriétaire des shares
     * @return shares Nombre de sLKST brûlés
     */
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    )
        public
        override
        nonReentrant
        updateReward(owner)
        returns (uint256 shares)
    {
        if (assets == 0) revert InvalidAmount();
        if (receiver == address(0)) revert InvalidAddress();

        // SECURITY FIX: Claim rewards BEFORE external transfer (checks-effects-interactions)
        _claimRewards(owner);

        shares = super.withdraw(assets, receiver, owner);

        emit Withdrawn(owner, assets, shares);
    }

    /**
     * @notice Redeem sLKST shares pour recevoir LKST
     * @param shares Nombre de sLKST à redeem
     * @param receiver Adresse qui reçoit les LKST
     * @param owner Propriétaire des shares
     * @return assets Montant LKST reçu
     */
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    )
        public
        override
        nonReentrant
        updateReward(owner)
        returns (uint256 assets)
    {
        if (shares == 0) revert InvalidAmount();
        if (receiver == address(0)) revert InvalidAddress();

        // SECURITY FIX: Claim rewards BEFORE external transfer (checks-effects-interactions)
        _claimRewards(owner);

        assets = super.redeem(shares, receiver, owner);

        emit Withdrawn(owner, assets, shares);
    }

    // ============================================================================
    // REWARD FUNCTIONS
    // ============================================================================

    /**
     * @notice Calcule rewards par token (scaled 1e18)
     * @return Rewards accumulés par token
     */
    function rewardPerToken() public view returns (uint256) {
        uint256 _totalAssets = totalAssets();
        if (_totalAssets == 0) {
            return rewardPerTokenStored;
        }

        uint256 timeElapsed = block.timestamp - lastUpdateTime;
        uint256 newRewards = timeElapsed * rewardRate;

        return rewardPerTokenStored + (newRewards * PRECISION / _totalAssets);
    }

    /**
     * @notice Calcule rewards earned par user
     * @param account Adresse user
     * @return Rewards accumulés non claim
     */
    function earned(address account) public view returns (uint256) {
        uint256 userShares = balanceOf(account);
        uint256 rewardDelta = rewardPerToken() - userRewardPerTokenPaid[account];

        return (userShares * rewardDelta / PRECISION) + rewards[account];
    }

    /**
     * @notice Claim rewards accumulés
     * @dev Peut être appelé sans unstake
     */
    function claimRewards() external nonReentrant updateReward(msg.sender) {
        _claimRewards(msg.sender);
    }

    /**
     * @notice Claim rewards interne
     * @param account Adresse user
     */
    function _claimRewards(address account) internal {
        uint256 reward = rewards[account];
        if (reward > 0) {
            // SECURITY FIX: Check underflow before subtraction
            if (rewardReserve < reward) {
                revert InsufficientRewardReserve(reward, rewardReserve);
            }

            rewards[account] = 0;
            totalRewardsDistributed += reward;
            rewardReserve -= reward;

            lkstToken.safeTransfer(account, reward);
            emit RewardPaid(account, reward);
        }
    }

    // ============================================================================
    // ADMIN FUNCTIONS
    // ============================================================================

    /**
     * @notice Change le reward rate
     * @dev Seulement owner
     * @param _rewardRate Nouveau reward rate (LKST/seconde)
     */
    function setRewardRate(uint256 _rewardRate)
        external
        onlyOwner
        updateReward(address(0))
    {
        if (_rewardRate < MIN_REWARD_RATE || _rewardRate > MAX_REWARD_RATE) {
            revert InvalidRewardRate(_rewardRate);
        }

        uint256 oldRate = rewardRate;
        rewardRate = _rewardRate;

        emit RewardRateUpdated(oldRate, _rewardRate);
    }

    /**
     * @notice Ajoute des LKST à la reserve de rewards
     * @dev Seulement owner, transfer LKST au vault
     * @param amount Montant LKST à ajouter
     */
    function fundRewards(uint256 amount)
        external
        onlyOwner
    {
        if (amount == 0) revert InvalidAmount();

        lkstToken.safeTransferFrom(msg.sender, address(this), amount);
        rewardReserve += amount;

        emit RewardsFunded(amount, rewardReserve);
    }

    /**
     * @notice Retire des tokens du vault (emergency only)
     * @dev Seulement owner - SÉCURISÉ: ne peut retirer que le surplus (rewards non stakés)
     * @param token Adresse token à withdraw
     * @param amount Montant à withdraw
     */
    function emergencyWithdraw(address token, uint256 amount)
        external
        onlyOwner
    {
        if (token == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();

        // SECURITY FIX: Pour LKST, limiter au surplus (rewards reserve uniquement)
        // Cela empêche le rug pull des assets stakés par les users
        if (token == address(lkstToken)) {
            uint256 surplus = rewardReserve;
            if (amount > surplus) {
                revert ExceedsSurplus(amount, surplus);
            }
            // Réduire la reserve de rewards
            rewardReserve -= amount;
        }

        IERC20(token).safeTransfer(msg.sender, amount);
        emit EmergencyWithdraw(token, amount);
    }

    // ============================================================================
    // ERC-4626 OVERRIDES (Critical for correct share calculation)
    // ============================================================================

    /**
     * @notice Override totalAssets pour exclure la réserve de rewards
     * @dev CRITIQUE: La réserve de rewards NE DOIT PAS être comptée dans les assets
     *      car elle n'appartient pas aux stakers mais est destinée aux rewards.
     *      Sans cet override, fundRewards() casserait le ratio shares/assets.
     * @return Total LKST stakés (excluant la réserve de rewards)
     */
    function totalAssets() public view override returns (uint256) {
        uint256 vaultBalance = lkstToken.balanceOf(address(this));
        // Soustraire la réserve de rewards pour obtenir uniquement les assets stakés
        if (vaultBalance > rewardReserve) {
            return vaultBalance - rewardReserve;
        }
        return 0;
    }

    /**
     * @notice Virtual offset pour protection inflation attack
     * @dev Offset de 3 décimales = protection forte
     * @return Offset (3)
     */
    function _decimalsOffset() internal pure override returns (uint8) {
        return 3;
    }

    // ============================================================================
    // VIEW FUNCTIONS
    // ============================================================================

    /**
     * @notice Obtient les infos complètes d'un user
     * @param account Adresse user
     * @return balance sLKST shares possédés
     * @return staked LKST staké (assets)
     * @return pendingRewards Rewards non claim
     * @return votingPower Voting power (shares avec boost)
     */
    function getUserInfo(address account)
        external
        view
        returns (
            uint256 balance,
            uint256 staked,
            uint256 pendingRewards,
            uint256 votingPower
        )
    {
        balance = balanceOf(account);
        staked = convertToAssets(balance);
        pendingRewards = earned(account);
        votingPower = balance * 150 / 100; // Boost 50% pour voting
    }

    /**
     * @notice Obtient les métriques du vault
     * @return _totalAssets Total LKST dans vault
     * @return _totalSupply Total sLKST shares
     * @return _exchangeRate Taux assets/shares (scaled 1e18)
     * @return _rewardRate Reward rate actuel
     * @return _rewardReserve Reserve de rewards
     * @return _apy APY estimé (scaled 1e18, ex: 20e18 = 20%)
     */
    function getVaultMetrics()
        external
        view
        returns (
            uint256 _totalAssets,
            uint256 _totalSupply,
            uint256 _exchangeRate,
            uint256 _rewardRate,
            uint256 _rewardReserve,
            uint256 _apy
        )
    {
        _totalAssets = totalAssets();
        _totalSupply = totalSupply();
        _exchangeRate = _totalSupply > 0
            ? (_totalAssets * PRECISION / _totalSupply)
            : PRECISION;
        _rewardRate = rewardRate;
        _rewardReserve = rewardReserve;

        // APY = (rewardRate * 365 days) / totalAssets * 100
        if (_totalAssets > 0) {
            uint256 yearlyRewards = rewardRate * 365 days;
            _apy = (yearlyRewards * 100 * PRECISION) / _totalAssets;
        } else {
            _apy = 0;
        }
    }

    /**
     * @notice Estime rewards pour une période donnée
     * @param account Adresse user
     * @param duration Durée en secondes
     * @return Rewards estimés
     */
    function estimateRewards(address account, uint256 duration)
        external
        view
        returns (uint256)
    {
        uint256 userShares = balanceOf(account);
        if (userShares == 0) return 0;

        uint256 _totalAssets = totalAssets();
        if (_totalAssets == 0) return 0;

        uint256 futureRewards = duration * rewardRate;
        uint256 userPortion = (userShares * futureRewards) / _totalAssets;

        return earned(account) + userPortion;
    }

    /**
     * @notice Vérifie si vault a assez de rewards pour période
     * @param duration Durée en secondes
     * @return True si reserve suffisante
     */
    function hasRewardReserveFor(uint256 duration)
        external
        view
        returns (bool)
    {
        uint256 requiredRewards = duration * rewardRate;
        return rewardReserve >= requiredRewards;
    }
}
