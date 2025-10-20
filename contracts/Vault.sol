// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import "./interfaces/IVault.sol";

/**
 * @title Vault
 * @notice Manages collateral and liquidity for the Inflation Market protocol
 * @dev ERC20 vault that issues shares for deposited USDC
 */
contract Vault is
    Initializable,
    ERC20Upgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    IVault
{
    // ============================================================================
    // STATE VARIABLES
    // ============================================================================

    address public asset; // USDC token address
    mapping(address => uint256) public lockedCollateral;
    uint256 public totalLockedCollateral;

    address public positionManager;

    // ============================================================================
    // MODIFIERS
    // ============================================================================

    modifier onlyPositionManager() {
        require(msg.sender == positionManager, "Only PositionManager");
        _;
    }

    // ============================================================================
    // INITIALIZATION
    // ============================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _asset, address _positionManager)
        public
        initializer
    {
        __ERC20_init("Inflation Market Vault", "imVault");
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        require(_asset != address(0), "Invalid asset");
        require(_positionManager != address(0), "Invalid PositionManager");

        asset = _asset;
        positionManager = _positionManager;
    }

    // ============================================================================
    // CORE FUNCTIONS
    // ============================================================================

    /**
     * @notice Deposit USDC and receive vault shares
     * @param amount Amount of USDC to deposit
     * @return shares Amount of vault shares minted
     */
    function deposit(address token, uint256 amount)
        external
        override
        nonReentrant
        returns (uint256 shares)
    {
        require(token == asset, "Unsupported asset");
        require(amount > 0, "Amount must be positive");

        shares = convertToShares(amount);

        // Transfer USDC from user
        require(IERC20Upgradeable(asset).transferFrom(msg.sender, address(this), amount), "Transfer failed");

        // Mint vault shares
        _mint(msg.sender, shares);

        emit Deposit(msg.sender, token, amount, shares);
        return shares;
    }

    /**
     * @notice Withdraw USDC by burning vault shares
     * @param token Address of the token to withdraw
     * @param amount Amount of USDC to withdraw
     * @return shares Amount of vault shares burned
     */
    function withdraw(address token, uint256 amount)
        external
        override
        nonReentrant
        returns (uint256 shares)
    {
        require(token == asset, "Unsupported asset");
        require(amount > 0, "Amount must be positive");

        shares = convertToShares(amount);
        require(shares > 0, "Shares must be positive");
        require(balanceOf(msg.sender) >= shares, "Insufficient shares");

        require(amount <= getAvailableLiquidity(), "Insufficient liquidity");

        // Burn vault shares
        _burn(msg.sender, shares);

        // Transfer USDC to user
        require(IERC20Upgradeable(asset).transfer(msg.sender, amount), "Transfer failed");

        emit Withdraw(msg.sender, token, amount, shares);
        return shares;
    }

    /**
     * @notice Lock collateral for a position (only PositionManager)
     * @param trader Address of the trader
     * @param positionId Position identifier (unused placeholder for compatibility)
     * @param amount Amount of collateral to lock
     */
    function lockCollateral(address trader, bytes32 positionId, uint256 amount)
        external
        override
        onlyPositionManager
    {
        require(amount > 0, "Amount must be positive");

        // Transfer collateral from trader
        require(IERC20Upgradeable(asset).transferFrom(trader, address(this), amount), "Transfer failed");

        lockedCollateral[trader] += amount;
        totalLockedCollateral += amount;

        emit CollateralLocked(trader, positionId, amount);
    }

    /**
     * @notice Unlock collateral back to user (only PositionManager)
     * @param trader Address of the trader
     * @param positionId Position identifier (unused placeholder for compatibility)
     * @param amount Amount of collateral to unlock and transfer
     */
    function unlockCollateral(address trader, bytes32 positionId, uint256 amount)
        external
        override
        onlyPositionManager
    {
        require(amount > 0, "Amount must be positive");

        uint256 lockedAmount = lockedCollateral[trader];
        uint256 deduction = amount <= lockedAmount ? amount : lockedAmount;

        if (deduction > 0) {
            lockedCollateral[trader] = lockedAmount - deduction;
            totalLockedCollateral -= deduction;
        }

        // Transfer collateral to trader
        require(IERC20Upgradeable(asset).transfer(trader, amount), "Transfer failed");

        emit CollateralUnlocked(trader, positionId, amount);
    }

    /**
     * @notice Transfer locked collateral to another address (only PositionManager)
     * @param from Address providing the collateral
     * @param to Recipient address
     * @param amount Amount of collateral to transfer
     */
    function transferCollateral(address from, address to, uint256 amount)
        external
        override
        onlyPositionManager
    {
        require(amount > 0, "Amount must be positive");
        require(to != address(0), "Invalid recipient");

        uint256 lockedAmount = lockedCollateral[from];
        require(lockedAmount >= amount, "Insufficient locked collateral");

        lockedCollateral[from] = lockedAmount - amount;
        totalLockedCollateral -= amount;

        // Transfer collateral to recipient
        require(IERC20Upgradeable(asset).transfer(to, amount), "Transfer failed");

        emit CollateralTransferred(from, to, amount);
    }

    /**
     * @notice Write off locked collateral without transferring tokens (e.g., realized losses)
     */
    function writeOffCollateral(address trader, uint256 amount)
        external
        override
        onlyPositionManager
    {
        require(amount > 0, "Amount must be positive");

        uint256 lockedAmount = lockedCollateral[trader];
        if (lockedAmount == 0) {
            return;
        }

        uint256 deduction = amount <= lockedAmount ? amount : lockedAmount;
        lockedCollateral[trader] = lockedAmount - deduction;
        totalLockedCollateral -= deduction;

        emit CollateralWrittenOff(trader, deduction);
    }

    /**
     * @notice Alias for backwards compatibility to release collateral to trader
     */
    function releaseCollateral(address trader, uint256 amount) external onlyPositionManager {
        uint256 lockedAmount = lockedCollateral[trader];
        uint256 deduction = amount <= lockedAmount ? amount : lockedAmount;

        if (deduction > 0) {
            lockedCollateral[trader] = lockedAmount - deduction;
            totalLockedCollateral -= deduction;
        }

        // Transfer collateral to trader
        require(IERC20Upgradeable(asset).transfer(trader, amount), "Transfer failed");

        emit CollateralUnlocked(trader, bytes32(0), amount);
    }

    // ============================================================================
    // VIEW FUNCTIONS
    // ============================================================================

    /**
     * @notice Get available liquidity for withdrawals
     * @return Available USDC in vault
     */
    function getAvailableLiquidity() public view override returns (uint256) {
        uint256 totalAssets = getTotalAssets();
        return totalAssets > totalLockedCollateral
            ? totalAssets - totalLockedCollateral
            : 0;
    }

    /**
     * @notice Get total assets in vault
     * @return Total USDC in vault
     */
    function getTotalAssets() public view override returns (uint256) {
        return IERC20Upgradeable(asset).balanceOf(address(this));
    }

    /**
     * @notice Convert assets to shares
     * @param assets Amount of assets
     * @return shares Amount of shares
     */
    function convertToShares(uint256 assets)
        public
        view
        override
        returns (uint256 shares)
    {
        uint256 supply = totalSupply();
        if (supply == 0) {
            return assets;
        }
        return (assets * supply) / getTotalAssets();
    }

    /**
     * @notice Convert shares to assets
     * @param shares Amount of shares
     * @return assets Amount of assets
     */
    function convertToAssets(uint256 shares)
        public
        view
        override
        returns (uint256 assets)
    {
        uint256 supply = totalSupply();
        if (supply == 0) {
            return 0;
        }
        return (shares * getTotalAssets()) / supply;
    }

    function availableBalance(address user, address token) external view override returns (uint256) {
        if (token != asset) {
            return 0;
        }

        uint256 unlockedAssets = convertToAssets(balanceOf(user));
        uint256 locked = lockedCollateral[user];
        return unlockedAssets > locked ? unlockedAssets - locked : 0;
    }

    function lockedBalance(address user, address token) external view override returns (uint256) {
        if (token != asset) {
            return 0;
        }
        return lockedCollateral[user];
    }

    function totalBalance(address user, address token) external view override returns (uint256) {
        if (token != asset) {
            return 0;
        }

        uint256 unlockedAssets = convertToAssets(balanceOf(user));
        return unlockedAssets + lockedCollateral[user];
    }

    // ============================================================================
    // ADMIN FUNCTIONS
    // ============================================================================

    function setPositionManager(address _positionManager) external onlyOwner {
        require(_positionManager != address(0), "Invalid address");
        positionManager = _positionManager;
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyOwner
    {}
}

// Mock USDC interface
interface IERC20Upgradeable {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}
