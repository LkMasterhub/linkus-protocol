// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title LKSVUpgradeable - LinkUs Staking Vault (UUPS Upgradeable)
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
 * - UUPS Upgradeable pattern
 */
contract LKSVUpgradeable is
    Initializable,
    ERC20Upgradeable,
    ERC4626Upgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    // ============================================================================
    // STATE VARIABLES
    // ============================================================================

    /// @notice Token LKST (asset)
    IERC20 public lkstToken;

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

    event Staked(address indexed user, uint256 assets, uint256 shares);
    event Withdrawn(address indexed user, uint256 assets, uint256 shares);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardRateUpdated(uint256 oldRate, uint256 newRate);
    event RewardsFunded(uint256 amount, uint256 newReserve);
    event EmergencyWithdraw(address indexed token, uint256 amount);

    // ============================================================================
    // ERRORS
    // ============================================================================

    error InvalidRewardRate(uint256 rate);
    error InvalidAmount();
    error InsufficientRewardReserve(uint256 required, uint256 available);
    error InvalidAddress();
    error ExceedsSurplus(uint256 requested, uint256 available);

    // ============================================================================
    // MODIFIERS
    // ============================================================================

    modifier updateReward(address account) virtual {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = block.timestamp;

        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    // ============================================================================
    // CONSTRUCTOR & INITIALIZER
    // ============================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialise le vault LKSV
     * @param _lkstToken Adresse du token LKST
     * @param _owner Adresse du propriétaire
     */
    function initialize(IERC20 _lkstToken, address _owner) public initializer {
        if (address(_lkstToken) == address(0)) revert InvalidAddress();
        if (_owner == address(0)) revert InvalidAddress();

        __ERC20_init("Staked LinkUs Token", "sLKST");
        __ERC4626_init(_lkstToken);
        __Ownable_init(_owner);
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        lkstToken = _lkstToken;
        // LKS-LKSV-01 fix : rewardRate initialisé à 0 pour éviter de drainer la rewardReserve
        // dès le premier stake. Doit être set explicitement par le timelock après fundRewards.
        rewardRate = 0;
        lastUpdateTime = block.timestamp;
    }

    // ============================================================================
    // UUPS UPGRADE AUTHORIZATION
    // ============================================================================

    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyOwner
    {}

    // ============================================================================
    // STAKING FUNCTIONS (ERC-4626 overrides)
    // ============================================================================

    function deposit(uint256 assets, address receiver)
        public
        virtual
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

    function mint(uint256 shares, address receiver)
        public
        virtual
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

    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    )
        public
        virtual
        override
        nonReentrant
        updateReward(owner)
        returns (uint256 shares)
    {
        if (assets == 0) revert InvalidAmount();
        if (receiver == address(0)) revert InvalidAddress();

        _claimRewards(owner);
        shares = super.withdraw(assets, receiver, owner);
        emit Withdrawn(owner, assets, shares);
    }

    function redeem(
        uint256 shares,
        address receiver,
        address owner
    )
        public
        virtual
        override
        nonReentrant
        updateReward(owner)
        returns (uint256 assets)
    {
        if (shares == 0) revert InvalidAmount();
        if (receiver == address(0)) revert InvalidAddress();

        _claimRewards(owner);
        assets = super.redeem(shares, receiver, owner);
        emit Withdrawn(owner, assets, shares);
    }

    // ============================================================================
    // REWARD FUNCTIONS
    // ============================================================================

    function rewardPerToken() public view virtual returns (uint256) {
        uint256 _totalAssets = totalAssets();
        if (_totalAssets == 0) {
            return rewardPerTokenStored;
        }

        uint256 timeElapsed = block.timestamp - lastUpdateTime;
        uint256 newRewards = timeElapsed * rewardRate;

        return rewardPerTokenStored + (newRewards * PRECISION / _totalAssets);
    }

    function earned(address account) public view virtual returns (uint256) {
        uint256 userShares = balanceOf(account);
        uint256 rewardDelta = rewardPerToken() - userRewardPerTokenPaid[account];

        return (userShares * rewardDelta / PRECISION) + rewards[account];
    }

    function claimRewards() external nonReentrant updateReward(msg.sender) {
        _claimRewards(msg.sender);
    }

    function _claimRewards(address account) internal {
        uint256 reward = rewards[account];
        if (reward > 0) {
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

    function fundRewards(uint256 amount) external onlyOwner {
        if (amount == 0) revert InvalidAmount();

        lkstToken.safeTransferFrom(msg.sender, address(this), amount);
        rewardReserve += amount;

        emit RewardsFunded(amount, rewardReserve);
    }

    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        if (token == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();

        if (token == address(lkstToken)) {
            uint256 surplus = rewardReserve;
            if (amount > surplus) {
                revert ExceedsSurplus(amount, surplus);
            }
            rewardReserve -= amount;
        }

        IERC20(token).safeTransfer(msg.sender, amount);
        emit EmergencyWithdraw(token, amount);
    }

    // ============================================================================
    // ERC-4626 OVERRIDES
    // ============================================================================

    function totalAssets() public view override returns (uint256) {
        uint256 vaultBalance = lkstToken.balanceOf(address(this));
        if (vaultBalance > rewardReserve) {
            return vaultBalance - rewardReserve;
        }
        return 0;
    }

    function decimals() public view override(ERC20Upgradeable, ERC4626Upgradeable) returns (uint8) {
        return super.decimals();
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return 3;
    }

    // ============================================================================
    // VIEW FUNCTIONS
    // ============================================================================

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
        votingPower = balance * 150 / 100;
    }

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

        if (_totalAssets > 0) {
            uint256 yearlyRewards = rewardRate * 365 days;
            _apy = (yearlyRewards * 100 * PRECISION) / _totalAssets;
        } else {
            _apy = 0;
        }
    }

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

    function hasRewardReserveFor(uint256 duration)
        external
        view
        returns (bool)
    {
        uint256 requiredRewards = duration * rewardRate;
        return rewardReserve >= requiredRewards;
    }

    // ============================================================================
    // STORAGE GAP
    // ============================================================================

    uint256[50] private __gap;
}
