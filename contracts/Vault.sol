// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./interfaces/IVault.sol";

/**
 * @title Vault
 * @notice Central collateral treasury for Inflation Market positions. Handles deposits, withdrawals,
 *         margin locking, and protocol fee accounting with strict access control.
 */
contract Vault is
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    IVault
{
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------
    // Roles
    // ------------------------------------------------------------

    bytes32 public constant POSITION_MANAGER_ROLE = keccak256("POSITION_MANAGER_ROLE");

    // ------------------------------------------------------------
    // Collateral state
    // ------------------------------------------------------------

    mapping(address => bool) public supportedCollateral;
    mapping(address => uint256) public collateralDecimals;

    // Total (available + locked) balances per user per token
    mapping(address => mapping(address => uint256)) private _userBalances;
    // Locked collateral per user per token
    mapping(address => mapping(address => uint256)) private _userLocked;
    // Aggregate locked collateral per position identifier
    mapping(bytes32 => uint256) public positionCollateral;

    // Share accounting (simple pro-rata over single collateral asset)
    mapping(address => uint256) private _shareBalances;
    uint256 private _totalShares;

    // ------------------------------------------------------------
    // Protocol parameters
    // ------------------------------------------------------------

    uint256 public tradingFeeRate; // in basis points (1e2) -> 10 = 0.1%
    uint256 public accumulatedFees;
    address public feeRecipient;

    bool public depositsEnabled;
    bool public withdrawalsEnabled;

    // Primary collateral token used for margin operations (lock/unlock/transfer/writeOff)
    address private _primaryCollateral;

    // Track system-wide locked collateral to derive liquidity
    uint256 private _totalLocked;

    // ------------------------------------------------------------
    // Custom Errors
    // ------------------------------------------------------------

    error UnsupportedToken(address token);
    error InvalidAmount();
    error DepositsDisabled();
    error WithdrawalsDisabled();
    error ZeroAddress();
    error FeeLimitExceeded();
    error InsufficientBalance();
    error InsufficientLocked();
    error AccessRestricted();

    event FeesCollected(uint256 amount);

    // ------------------------------------------------------------
    // Initializer
    // ------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the vault.
     * @param admin Address to receive DEFAULT_ADMIN_ROLE.
     * @param feeRecipient_ Destination for collected protocol fees.
     * @param tradingFeeRate_ Initial trading fee rate (basis points, < 1000).
     */
    function initialize(
        address admin,
        address feeRecipient_,
        uint256 tradingFeeRate_
    ) external initializer {
        if (admin == address(0) || feeRecipient_ == address(0)) revert ZeroAddress();
        if (tradingFeeRate_ >= 1_000) revert FeeLimitExceeded();

        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);

        feeRecipient = feeRecipient_;
        tradingFeeRate = tradingFeeRate_;

        depositsEnabled = true;
        withdrawalsEnabled = true;
    }

    // ------------------------------------------------------------
    // External user functions
    // ------------------------------------------------------------

    /**
     * @inheritdoc IVault
     */
    function deposit(address token, uint256 amount)
        external
        override
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        if (!depositsEnabled) revert DepositsDisabled();
        if (!_isSupported(token)) revert UnsupportedToken(token);
        if (amount == 0) revert InvalidAmount();

        shares = _previewShares(token, amount);
        if (shares == 0) {
            shares = amount;
        }

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        _userBalances[msg.sender][token] += amount;
        _shareBalances[msg.sender] += shares;
        _totalShares += shares;

        emit Deposit(msg.sender, token, amount, shares);
    }

    /**
     * @inheritdoc IVault
     */
    function withdraw(address token, uint256 amount)
        external
        override
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        if (!withdrawalsEnabled) revert WithdrawalsDisabled();
        if (!_isSupported(token)) revert UnsupportedToken(token);
        if (amount == 0) revert InvalidAmount();

        uint256 available = availableBalance(msg.sender, token);
        if (available < amount) revert InsufficientBalance();

        shares = _previewShares(token, amount);
        if (shares == 0) revert InvalidAmount();

        uint256 userShares = _shareBalances[msg.sender];
        if (userShares < shares) revert InsufficientBalance();

        uint256 totalAssets = getTotalAssets();
        if (amount > totalAssets - _totalLocked) revert InsufficientBalance();

        _shareBalances[msg.sender] = userShares - shares;
        _totalShares -= shares;
        _userBalances[msg.sender][token] -= amount;

        IERC20(token).safeTransfer(msg.sender, amount);

        emit Withdraw(msg.sender, token, amount, shares);
    }

    // ------------------------------------------------------------
    // Position collateral management
    // ------------------------------------------------------------

    /**
     * @inheritdoc IVault
     */
    function lockCollateral(address user, bytes32 positionId, uint256 amount)
        external
        override
        onlyRole(POSITION_MANAGER_ROLE)
        nonReentrant
        whenNotPaused
    {
        address token = _primaryCollateral;
        if (token == address(0)) revert UnsupportedToken(address(0));
        if (amount == 0) revert InvalidAmount();

        uint256 available = availableBalance(user, token);
        if (available < amount) revert InsufficientBalance();

        _userLocked[user][token] += amount;
        positionCollateral[positionId] += amount;
        _totalLocked += amount;

        emit CollateralLocked(user, positionId, amount);
    }

    /**
     * @inheritdoc IVault
     */
    function unlockCollateral(address user, bytes32 positionId, uint256 amount)
        external
        override
        onlyRole(POSITION_MANAGER_ROLE)
        nonReentrant
        whenNotPaused
    {
        address token = _primaryCollateral;
        if (token == address(0)) revert UnsupportedToken(address(0));
        if (amount == 0) revert InvalidAmount();

        uint256 lockedAmount = _userLocked[user][token];
        if (lockedAmount < amount) revert InsufficientLocked();

        _userLocked[user][token] = lockedAmount - amount;
        _totalLocked -= amount;

        uint256 positionAmount = positionCollateral[positionId];
        if (positionAmount >= amount) {
            positionCollateral[positionId] = positionAmount - amount;
        } else {
            positionCollateral[positionId] = 0;
        }

        emit CollateralUnlocked(user, positionId, amount);
    }

    /**
     * @inheritdoc IVault
     */
    function transferCollateral(address from, address to, uint256 amount)
        external
        override
        onlyRole(POSITION_MANAGER_ROLE)
        nonReentrant
        whenNotPaused
    {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();

        address token = _primaryCollateral;
        if (token == address(0)) revert UnsupportedToken(address(0));

        uint256 balance = _userBalances[from][token];
        if (balance < amount) revert InsufficientBalance();

        _userBalances[from][token] = balance - amount;
        _userBalances[to][token] += amount;

        uint256 lockedAmount = _userLocked[from][token];
        if (lockedAmount >= amount) {
            _userLocked[from][token] = lockedAmount - amount;
            _totalLocked -= amount;
        } else {
            _totalLocked -= lockedAmount;
            _userLocked[from][token] = 0;
        }

        if (to == feeRecipient) {
            accumulatedFees += amount;
            emit FeesCollected(amount);
        }

        emit CollateralTransferred(from, to, amount);
    }

    /**
     * @inheritdoc IVault
     */
    function writeOffCollateral(address user, uint256 amount)
        external
        override
        onlyRole(POSITION_MANAGER_ROLE)
        nonReentrant
        whenNotPaused
    {
        address token = _primaryCollateral;
        if (token == address(0)) revert UnsupportedToken(address(0));
        if (amount == 0) revert InvalidAmount();

        uint256 lockedAmount = _userLocked[user][token];
        if (lockedAmount < amount) revert InsufficientLocked();

        _userLocked[user][token] = lockedAmount - amount;
        _totalLocked -= amount;

        uint256 balance = _userBalances[user][token];
        _userBalances[user][token] = balance - amount;

        emit CollateralWrittenOff(user, amount);
    }

    // ------------------------------------------------------------
    // Admin controls
    // ------------------------------------------------------------

    /**
     * @notice Register a collateral token.
     * @param token ERC20 token address.
     * @param decimals_ Token decimals (for UI reference).
     * @param setAsPrimary Flag to set token as primary collateral for margin operations.
     */
    function addCollateral(address token, uint256 decimals_, bool setAsPrimary)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (token == address(0)) revert ZeroAddress();
        supportedCollateral[token] = true;
        collateralDecimals[token] = decimals_;

        if (setAsPrimary) {
            _primaryCollateral = token;
        }
    }

    /**
     * @notice Remove a collateral token from the allow list.
     * @param token Token address to remove.
     */
    function removeCollateral(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == _primaryCollateral) revert UnsupportedToken(token);
        supportedCollateral[token] = false;
        collateralDecimals[token] = 0;
    }

    /**
     * @notice Update trading fee rate.
     * @param newRate New rate in basis points (< 1000).
     */
    function setTradingFeeRate(uint256 newRate) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newRate >= 1_000) revert FeeLimitExceeded();
        tradingFeeRate = newRate;
    }

    /**
     * @notice Withdraw accumulated protocol fees.
     * @param to Recipient address.
     * @param amount Amount to withdraw.
     */
    function withdrawFees(address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();
        if (amount > accumulatedFees) revert InsufficientBalance();

        address token = _primaryCollateral;
        if (token == address(0)) revert UnsupportedToken(address(0));

        accumulatedFees -= amount;
        _userBalances[feeRecipient][token] =
            _userBalances[feeRecipient][token] >= amount ? _userBalances[feeRecipient][token] - amount : 0;

        IERC20(token).safeTransfer(to, amount);
    }

    /**
     * @notice Toggle deposit capability.
     */
    function setDepositsEnabled(bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        depositsEnabled = enabled;
    }

    /**
     * @notice Toggle withdrawal capability.
     */
    function setWithdrawalsEnabled(bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        withdrawalsEnabled = enabled;
    }

    /**
     * @notice Update fee recipient.
     */
    function setFeeRecipient(address newRecipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newRecipient == address(0)) revert ZeroAddress();
        feeRecipient = newRecipient;
    }

    /**
     * @notice Pause vault operations.
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Resume vault operations.
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ------------------------------------------------------------
    // Views
    // ------------------------------------------------------------

    /**
     * @return Current primary collateral token address.
     */
    function asset() external view returns (address) {
        return _primaryCollateral;
    }

    /**
     * @inheritdoc IVault
     */
    function availableBalance(address user, address token) public view override returns (uint256 balance) {
        if (!_isSupported(token)) return 0;
        uint256 total = _userBalances[user][token];
        uint256 locked = _userLocked[user][token];
        balance = total > locked ? total - locked : 0;
    }

    /**
     * @inheritdoc IVault
     */
    function lockedBalance(address user, address token) external view override returns (uint256 balance) {
        if (!_isSupported(token)) return 0;
        balance = _userLocked[user][token];
    }

    /**
     * @inheritdoc IVault
     */
    function totalBalance(address user, address token) external view override returns (uint256 balance) {
        if (!_isSupported(token)) return 0;
        balance = _userBalances[user][token];
    }

    /**
     * @inheritdoc IVault
     */
    function getAvailableLiquidity() public view override returns (uint256 liquidity) {
        address token = _primaryCollateral;
        if (token == address(0)) return 0;
        uint256 balance = IERC20(token).balanceOf(address(this));
        liquidity = balance > _totalLocked ? balance - _totalLocked : 0;
    }

    /**
     * @inheritdoc IVault
     */
    function getTotalAssets() public view override returns (uint256 assets) {
        address token = _primaryCollateral;
        if (token == address(0)) return 0;
        assets = IERC20(token).balanceOf(address(this));
    }

    /**
     * @inheritdoc IVault
     */
    function convertToShares(uint256 assets) external view override returns (uint256 shares) {
        address token = _primaryCollateral;
        if (token == address(0)) return 0;
        shares = _convertAssetsToShares(assets, getTotalAssets(), _totalShares);
    }

    /**
     * @inheritdoc IVault
     */
    function convertToAssets(uint256 shares) external view override returns (uint256 assets) {
        address token = _primaryCollateral;
        if (token == address(0)) return 0;
        assets = _convertSharesToAssets(shares, getTotalAssets(), _totalShares);
    }

    // ------------------------------------------------------------
    // Internal helpers
    // ------------------------------------------------------------

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    function _isSupported(address token) private view returns (bool) {
        return supportedCollateral[token];
    }

    function _previewShares(address token, uint256 assets) private view returns (uint256) {
        return _convertAssetsToShares(assets, getTotalAssets(), _totalShares);
    }

    function _convertAssetsToShares(
        uint256 assets,
        uint256 totalAssets,
        uint256 totalShares_
    ) private pure returns (uint256 shares) {
        if (totalShares_ == 0 || totalAssets == 0) {
            shares = assets;
        } else {
            shares = (assets * totalShares_) / totalAssets;
        }
    }

    function _convertSharesToAssets(
        uint256 shares,
        uint256 totalAssets,
        uint256 totalShares_
    ) private pure returns (uint256 assets_) {
        if (totalShares_ == 0 || totalAssets == 0) {
            assets_ = shares;
        } else {
            assets_ = (shares * totalAssets) / totalShares_;
        }
    }
}
