// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IVault
 * @notice Interface for managing collateral and liquidity in the Inflation Market protocol
 * @dev This interface defines the core vault functionality for handling user deposits,
 *      withdrawals, and collateral management for perpetual positions
 *
 * The Vault serves as the central custodian for all protocol funds:
 * - Holds user deposits (USDC collateral)
 * - Manages locked collateral for open positions
 * - Handles profit/loss settlements
 * - Distributes protocol fees
 * - Tracks liquidity availability
 *
 * Security considerations:
 * - Only authorized contracts (PositionManager) can lock/unlock collateral
 * - All transfers must maintain accounting invariants
 * - Reentrancy protection required on all state-changing functions
 */
interface IVault {
    // ============================================================================
    // EVENTS
    // ============================================================================

    /**
     * @notice Emitted when a user deposits tokens into the vault
     * @param user Address of the user making the deposit
     * @param token Address of the token being deposited (e.g., USDC)
     * @param amount Amount of tokens deposited
     * @param shares Amount of vault shares minted to user
     */
    event Deposit(address indexed user, address indexed token, uint256 amount, uint256 shares);

    /**
     * @notice Emitted when a user withdraws tokens from the vault
     * @param user Address of the user making the withdrawal
     * @param token Address of the token being withdrawn
     * @param amount Amount of tokens withdrawn
     * @param shares Amount of vault shares burned from user
     */
    event Withdraw(address indexed user, address indexed token, uint256 amount, uint256 shares);

    /**
     * @notice Emitted when collateral is locked for a position
     * @param user Address of the trader whose collateral is locked
     * @param positionId Unique identifier for the position
     * @param amount Amount of collateral locked
     */
    event CollateralLocked(address indexed user, bytes32 indexed positionId, uint256 amount);

    /**
     * @notice Emitted when collateral is unlocked from a position
     * @param user Address of the trader whose collateral is unlocked
     * @param positionId Unique identifier for the position
     * @param amount Amount of collateral unlocked
     */
    event CollateralUnlocked(address indexed user, bytes32 indexed positionId, uint256 amount);

    /**
     * @notice Emitted when collateral is transferred between users
     * @param from Address sending the collateral
     * @param to Address receiving the collateral
     * @param amount Amount of collateral transferred
     */
    event CollateralTransferred(address indexed from, address indexed to, uint256 amount);
    event CollateralWrittenOff(address indexed user, uint256 amount);

    // ============================================================================
    // DEPOSIT & WITHDRAWAL FUNCTIONS
    // ============================================================================

    /**
     * @notice Deposit tokens into the vault and receive vault shares
     * @dev Tokens must be approved for transfer before calling this function
     *
     * Process:
     * 1. Transfer tokens from user to vault
     * 2. Calculate shares based on current vault exchange rate
     * 3. Mint shares to user
     * 4. Update total assets and accounting
     *
     * Requirements:
     * - Amount must be greater than zero
     * - User must have approved vault for token transfer
     * - User must have sufficient token balance
     * - Token must be supported by the vault
     *
     * @param token Address of the token to deposit (e.g., USDC address)
     * @param amount Amount of tokens to deposit (in token decimals, e.g., 1000e6 for 1000 USDC)
     * @return shares Amount of vault shares minted to the user
     *
     * Example:
     * - User deposits 1000 USDC
     * - Current exchange rate: 1 share = 1.05 USDC (vault has profits)
     * - User receives: 1000 / 1.05 = 952.38 shares
     */
    function deposit(address token, uint256 amount) external returns (uint256 shares);

    /**
     * @notice Withdraw tokens from the vault by burning vault shares
     * @dev User must have sufficient unlocked shares to withdraw
     *
     * Process:
     * 1. Calculate token amount based on current exchange rate
     * 2. Burn user's shares
     * 3. Transfer tokens from vault to user
     * 4. Update total assets and accounting
     *
     * Requirements:
     * - Amount must be greater than zero
     * - User must have sufficient available (unlocked) shares
     * - Vault must have sufficient liquid assets
     * - Cannot withdraw shares that are backing locked collateral
     *
     * @param token Address of the token to withdraw
     * @param amount Amount of tokens to withdraw (not shares - the actual token amount)
     * @return shares Amount of vault shares burned from the user
     *
     * Example:
     * - User requests to withdraw 1000 USDC
     * - Current exchange rate: 1 share = 1.05 USDC
     * - Shares burned: 1000 / 1.05 = 952.38 shares
     * - User receives: 1000 USDC
     */
    function withdraw(address token, uint256 amount) external returns (uint256 shares);

    // ============================================================================
    // COLLATERAL MANAGEMENT FUNCTIONS
    // ============================================================================

    /**
     * @notice Lock collateral for a trading position
     * @dev Called by PositionManager when opening a position or adding margin
     *
     * Process:
     * 1. Verify user has sufficient available balance
     * 2. Move collateral from available to locked state
     * 3. Associate locked amount with specific position ID
     * 4. Update accounting: availableBalance -= amount, lockedBalance += amount
     *
     * Requirements:
     * - Caller must be authorized (only PositionManager)
     * - User must have sufficient available balance
     * - Amount must be greater than zero
     * - Position ID must be valid
     *
     * @param user Address of the trader whose collateral is being locked
     * @param positionId Unique identifier for the position (generated by PositionManager)
     * @param amount Amount of collateral to lock (in token decimals)
     *
     * Example:
     * - User has 5000 USDC available balance
     * - Opens 5x leveraged position with 1000 USDC collateral
     * - lockCollateral(user, positionId, 1000e6) is called
     * - User's available: 5000 → 4000 USDC
     * - User's locked: 0 → 1000 USDC
     */
    function lockCollateral(address user, bytes32 positionId, uint256 amount) external;

    /**
     * @notice Unlock collateral from a trading position
     * @dev Called by PositionManager when closing a position or removing margin
     *
     * Process:
     * 1. Verify collateral is locked for this position
     * 2. Move collateral from locked to available state
     * 3. Remove position ID association
     * 4. Update accounting: lockedBalance -= amount, availableBalance += amount
     *
     * Requirements:
     * - Caller must be authorized (only PositionManager)
     * - Position must have sufficient locked collateral
     * - Amount must be greater than zero
     *
     * @param user Address of the trader whose collateral is being unlocked
     * @param positionId Unique identifier for the position
     * @param amount Amount of collateral to unlock (in token decimals)
     *
     * Example:
     * - User closes position with 1000 USDC locked collateral
     * - Position had +200 USDC profit
     * - unlockCollateral(user, positionId, 1200e6) is called
     * - User's locked: 1000 → 0 USDC
     * - User's available: 4000 → 5200 USDC
     */
    function unlockCollateral(address user, bytes32 positionId, uint256 amount) external;

    /**
     * @notice Transfer collateral between users (for settlements)
     * @dev Called by PositionManager for profit/loss settlements and liquidations
     *
     * Process:
     * 1. Verify sender has sufficient available balance
     * 2. Deduct amount from sender's balance
     * 3. Add amount to recipient's balance
     * 4. Update accounting for both parties
     *
     * Use cases:
     * - Liquidation rewards: Transfer collateral from liquidated position to liquidator
     * - Protocol fees: Transfer collateral to fee recipient
     * - P&L settlement: Transfer profits from vault reserves to trader
     *
     * Requirements:
     * - Caller must be authorized (only PositionManager)
     * - Sender must have sufficient available balance
     * - Amount must be greater than zero
     * - Recipient address must be valid (not zero address)
     *
     * @param from Address sending the collateral
     * @param to Address receiving the collateral
     * @param amount Amount of collateral to transfer (in token decimals)
     *
     * Example:
     * - Position gets liquidated with 1000 USDC collateral
     * - Liquidator receives 50 USDC reward (5% of collateral)
     * - transferCollateral(trader, liquidator, 50e6) is called
     * - Remaining 950 USDC goes to protocol/insurance fund
     */
    function transferCollateral(address from, address to, uint256 amount) external;

    /**
     * @notice Reduce locked collateral without transferring tokens (used for realized losses)
     * @param user Trader whose locked collateral should be reduced
     * @param amount Amount to write off
     */
    function writeOffCollateral(address user, uint256 amount) external;

    // ============================================================================
    // VIEW FUNCTIONS
    // ============================================================================

    /**
     * @notice Get available (unlocked) balance for a user and token
     * @dev Returns the amount that can be used to open new positions or withdraw
     *
     * Calculation:
     * availableBalance = totalDeposits - lockedCollateral - pendingWithdrawals
     *
     * This represents funds that are:
     * - Not locked in open positions
     * - Not pending withdrawal
     * - Immediately available for trading or withdrawal
     *
     * @param user Address of the user to check
     * @param token Address of the token (e.g., USDC)
     * @return balance Available balance in token decimals
     *
     * Example:
     * - User deposited 10,000 USDC
     * - Has 3,000 USDC locked in positions
     * - Returns: 7,000 USDC available
     */
    function availableBalance(address user, address token) external view returns (uint256 balance);

    /**
     * @notice Get total locked collateral for a user
     * @dev Returns the sum of all collateral locked across all open positions
     *
     * @param user Address of the user to check
     * @param token Address of the token
     * @return balance Total locked balance in token decimals
     */
    function lockedBalance(address user, address token) external view returns (uint256 balance);

    /**
     * @notice Get total balance (available + locked) for a user
     * @dev Returns the complete balance including both available and locked funds
     *
     * @param user Address of the user to check
     * @param token Address of the token
     * @return balance Total balance in token decimals
     */
    function totalBalance(address user, address token) external view returns (uint256 balance);

    /**
     * @notice Get total liquidity available in the vault
     * @dev Returns the amount of liquid assets available for withdrawals and settlements
     *
     * Calculation:
     * availableLiquidity = totalAssets - totalLockedCollateral
     *
     * This represents the vault's ability to:
     * - Process user withdrawals
     * - Pay out winning positions
     * - Handle liquidations
     *
     * @return liquidity Total available liquidity in base token (USDC)
     */
    function getAvailableLiquidity() external view returns (uint256 liquidity);

    /**
     * @notice Get total assets held by the vault
     * @dev Includes all deposited funds, locked collateral, and accumulated profits
     *
     * @return assets Total assets under management in base token (USDC)
     */
    function getTotalAssets() external view returns (uint256 assets);

    /**
     * @notice Convert token amount to vault shares
     * @dev Uses current exchange rate (assets per share)
     *
     * Formula: shares = assets * totalShares / totalAssets
     *
     * @param assets Amount of tokens to convert
     * @return shares Equivalent amount in vault shares
     */
    function convertToShares(uint256 assets) external view returns (uint256 shares);

    /**
     * @notice Convert vault shares to token amount
     * @dev Uses current exchange rate (assets per share)
     *
     * Formula: assets = shares * totalAssets / totalShares
     *
     * @param shares Amount of vault shares to convert
     * @return assets Equivalent amount in tokens
     */
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
}
