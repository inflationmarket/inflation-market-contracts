// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IPositionManager
 * @notice Interface for managing perpetual positions in the Inflation Market protocol
 * @dev This interface defines the core position management functionality for perpetual futures
 *      trading against inflation indices
 *
 * The PositionManager is the central contract for:
 * - Opening long/short leveraged positions
 * - Closing positions and settling P&L
 * - Managing position collateral (adding/removing margin)
 * - Calculating profit and loss (P&L)
 * - Determining position health and liquidation status
 * - Coordinating with Vault, vAMM, and FundingRateCalculator
 *
 * Key concepts:
 * - **Long Position**: Profit when inflation index rises (betting on higher inflation)
 * - **Short Position**: Profit when inflation index falls (betting on lower inflation)
 * - **Leverage**: Amplifies exposure and both profits/losses (1x to 20x)
 * - **Collateral**: USDC locked in Vault to back the position
 * - **Position Size**: Notional value = collateral × leverage
 * - **Liquidation**: Forced closure when losses approach collateral threshold
 *
 * Security considerations:
 * - Reentrancy protection on all state-changing functions
 * - Slippage protection on position opening
 * - Access control for admin and liquidator roles
 * - Position size limits to prevent excessive exposure
 * - Funding rate integration for perpetual mechanics
 */
interface IPositionManager {
    // ============================================================================
    // STRUCTS
    // ============================================================================

    /**
     * @notice Position data structure
     * @dev Gas-optimized struct with packed storage (5 slots instead of 9)
     *
     * Storage layout (after gas optimization):
     * - SLOT 0: trader (address, 20 bytes) + timestamp (uint96, 12 bytes)
     * - SLOT 1: size (uint128) + collateral (uint128)
     * - SLOT 2: leverage (uint128) + entryPrice (uint128)
     * - SLOT 3: entryFundingIndex (uint128) + liquidationPrice (uint128)
     * - SLOT 4: isLong (bool, 1 byte)
     *
     * @param trader Address of the position owner
     * @param collateral Amount of USDC locked as collateral (in USDC decimals, e.g., 1000e6)
     * @param size Notional position size = collateral × leverage (in USDC)
     * @param entryPrice Mark price at position opening (scaled by 1e18, e.g., 2000e18 = $2000)
     * @param entryFundingRate Cumulative funding index at entry (for calculating funding payments)
     * @param isLong True for long (bull), false for short (bear)
     * @param lastUpdateTimestamp Block timestamp when position was last updated
     * @param leverage Leverage multiplier (scaled by 1e18, e.g., 5e18 = 5x leverage)
     */
    struct Position {
        address trader;
        uint256 collateral;
        uint256 size;
        uint256 entryPrice;
        uint256 entryFundingRate;
        bool isLong;
        uint256 lastUpdateTimestamp;
        uint256 leverage;
    }

    // ============================================================================
    // EVENTS
    // ============================================================================

    /**
     * @notice Emitted when a new position is opened
     * @param positionId Unique identifier for the position (keccak256 hash)
     * @param trader Address of the trader opening the position
     * @param collateral Amount of USDC collateral locked
     * @param size Notional position size (collateral × leverage)
     * @param entryPrice Mark price at position opening
     * @param leverage Leverage multiplier used
     * @param isLong True for long position, false for short
     */
    event PositionOpened(
        bytes32 indexed positionId,
        address indexed trader,
        uint256 collateral,
        uint256 size,
        uint256 entryPrice,
        uint256 leverage,
        bool isLong
    );

    /**
     * @notice Emitted when a position is closed by the trader
     * @param positionId Unique identifier for the position
     * @param trader Address of the trader closing the position
     * @param pnl Profit and loss (positive = profit, negative = loss) in USDC
     * @param closingPrice Mark price at position closing
     */
    event PositionClosed(
        bytes32 indexed positionId,
        address indexed trader,
        int256 pnl,
        uint256 closingPrice
    );

    /**
     * @notice Emitted when a position is liquidated due to insufficient collateral
     * @param positionId Unique identifier for the position
     * @param trader Address of the trader whose position was liquidated
     * @param liquidator Address of the liquidator who triggered liquidation
     * @param liquidationPrice Mark price at liquidation
     */
    event PositionLiquidated(
        bytes32 indexed positionId,
        address indexed trader,
        address indexed liquidator,
        uint256 liquidationPrice
    );

    /**
     * @notice Emitted when margin is added to an existing position
     * @param positionId Unique identifier for the position
     * @param trader Address of the trader adding margin
     * @param amount Amount of USDC collateral added
     */
    event CollateralAdded(
        bytes32 indexed positionId,
        address indexed trader,
        uint256 amount
    );

    /**
     * @notice Emitted when margin is removed from an existing position
     * @param positionId Unique identifier for the position
     * @param trader Address of the trader removing margin
     * @param amount Amount of USDC collateral removed
     */
    event CollateralRemoved(
        bytes32 indexed positionId,
        address indexed trader,
        uint256 amount
    );

    // ============================================================================
    // FUNCTIONS
    // ============================================================================

    /**
     * @notice Open a new leveraged position
     * @dev Creates a long or short position with specified collateral and leverage
     *
     * Process:
     * 1. Validate collateral amount and leverage
     * 2. Lock collateral in vault
     * 3. Calculate position size (collateral × leverage)
     * 4. Get mark price from vAMM
     * 5. Execute vAMM swap to update market price
     * 6. Calculate liquidation price
     * 7. Generate unique position ID
     * 8. Store position data
     *
     * Requirements:
     * - Collateral must be >= minimum collateral (default 10 USDC)
     * - Leverage must be between MIN_LEVERAGE (1x) and maxLeverage (10x-20x)
     * - User must have sufficient vault balance
     * - Contract must not be paused
     *
     * @param collateral Amount of USDC to use as collateral (e.g., 1000e6 for 1000 USDC)
     * @param leverage Leverage multiplier (e.g., 5e18 for 5x leverage)
     * @param isLong True to open long position, false for short position
     * @return positionId Unique identifier for the created position
     *
     * Example:
     * - openPosition(1000e6, 5e18, true)
     * - Opens 5x long with 1000 USDC collateral
     * - Position size: 5000 USDC notional value
     */
    function openPosition(
        uint256 collateral,
        uint256 leverage,
        bool isLong
    ) external returns (bytes32 positionId);

    /**
     * @notice Close an existing position and settle P&L
     * @dev Only the position owner can close their position
     *
     * Process:
     * 1. Verify caller is position owner
     * 2. Get current mark price
     * 3. Calculate P&L (price change + funding payments)
     * 4. Execute reverse vAMM swap
     * 5. Calculate closing fee
     * 6. Settle final amount to trader (collateral + P&L - fee)
     * 7. Delete position from storage
     *
     * Settlement calculation:
     * - If profitable: finalAmount = collateral + profit - fee
     * - If loss: finalAmount = collateral - loss - fee (minimum 0)
     *
     * Requirements:
     * - Caller must be position owner
     * - Position must exist
     * - Contract must not be paused
     *
     * @param positionId Unique identifier of the position to close
     * @return pnl Total profit or loss (positive = profit, negative = loss)
     *
     * Example:
     * - Position opened with 1000 USDC at entry price 2000
     * - Current price: 2200 (10% increase)
     * - Position size: 5000 USDC (5x leverage)
     * - P&L: +500 USDC (50% return on collateral)
     * - Final settlement: 1000 + 500 - 5 (fee) = 1495 USDC
     */
    function closePosition(bytes32 positionId) external returns (int256 pnl);

    /**
     * @notice Add margin to an existing position to improve health
     * @dev Locks additional collateral and recalculates liquidation price
     *
     * Use cases:
     * - Prevent liquidation when position is losing money
     * - Increase position buffer for volatile markets
     * - Lower effective leverage
     *
     * Requirements:
     * - Caller must be position owner
     * - Position must exist
     * - Amount must be greater than zero
     * - User must have sufficient vault balance
     *
     * @param positionId Unique identifier of the position
     * @param amount Amount of USDC collateral to add
     *
     * Example:
     * - Original collateral: 1000 USDC
     * - Add 500 USDC margin
     * - New collateral: 1500 USDC
     * - Liquidation price moves further away (safer position)
     */
    function addCollateral(bytes32 positionId, uint256 amount) external;

    /**
     * @notice Remove margin from an existing position
     * @dev Unlocks collateral if position remains healthy after removal
     *
     * Requirements:
     * - Caller must be position owner
     * - Position must exist
     * - Amount must be greater than zero and less than current collateral
     * - Position must remain above maintenance margin after removal
     *
     * @param positionId Unique identifier of the position
     * @param amount Amount of USDC collateral to remove
     *
     * Example:
     * - Current collateral: 1500 USDC
     * - Position health: 150% (healthy)
     * - Remove 300 USDC margin
     * - New health: 120% (still above 110% maintenance margin)
     * - Successfully unlocks 300 USDC to available balance
     */
    function removeCollateral(bytes32 positionId, uint256 amount) external;

    /**
     * @notice Liquidate an undercollateralized position
     * @dev Can only be called by addresses with LIQUIDATOR_ROLE
     *
     * Liquidation occurs when:
     * - Position health drops below maintenance margin (default 5%)
     * - Unrealized losses approach total collateral
     *
     * Process:
     * 1. Verify position is liquidatable
     * 2. Calculate liquidation reward for liquidator (5% of collateral)
     * 3. Close position at current mark price
     * 4. Transfer reward to liquidator
     * 5. Remaining collateral to insurance fund/protocol
     *
     * Requirements:
     * - Caller must have LIQUIDATOR_ROLE
     * - Position must be below liquidation threshold
     *
     * @param positionId Unique identifier of the position to liquidate
     */
    function liquidatePosition(bytes32 positionId) external;

    /**
     * @notice Get full position details
     * @dev Returns complete position data structure
     *
     * @param positionId Unique identifier of the position
     * @return position Complete Position struct with all fields
     */
    function getPosition(bytes32 positionId) external view returns (Position memory position);

    /**
     * @notice Calculate current profit and loss for a position
     * @dev Includes both price change P&L and funding payments
     *
     * Calculation:
     * 1. Price change P&L = (current price - entry price) × position size
     * 2. For shorts, invert the sign
     * 3. Subtract funding payments (longs pay when funding positive, shorts receive)
     *
     * @param positionId Unique identifier of the position
     * @return pnl Current unrealized P&L (positive = profit, negative = loss)
     *
     * Example:
     * - Long position: entry 2000, current 2100, size 5000 USDC
     * - Price P&L: (2100 - 2000) / 2000 × 5000 = +250 USDC
     * - Funding payment: -10 USDC (paid to shorts)
     * - Total P&L: +240 USDC
     */
    function calculatePnL(bytes32 positionId) external view returns (int256 pnl);

    /**
     * @notice Get position health ratio
     * @dev Health ratio = (collateral + unrealized P&L) / position size × 100
     *
     * Interpretation:
     * - 100% = Breakeven (equity equals collateral)
     * - > 100% = Profitable or healthy position
     * - < 5% (maintenance margin) = Liquidatable
     *
     * @param positionId Unique identifier of the position
     * @return healthRatio Position health as a percentage (in basis points)
     *
     * Example:
     * - Collateral: 1000 USDC
     * - Unrealized P&L: +200 USDC
     * - Position size: 5000 USDC
     * - Health: (1000 + 200) / 5000 × 10000 = 2400 (24%)
     */
    function getPositionHealth(bytes32 positionId) external view returns (uint256 healthRatio);

    /**
     * @notice Check if a position can be liquidated
     * @dev Returns true if position health is below maintenance margin threshold
     *
     * @param positionId Unique identifier of the position
     * @return liquidatable True if position is liquidatable, false otherwise
     */
    function isLiquidatable(bytes32 positionId) external view returns (bool liquidatable);

    /**
     * @notice Check if a position can be liquidated (alternative naming)
     * @dev Identical to isLiquidatable() - provided for compatibility
     *
     * @param positionId Unique identifier of the position
     * @return liquidatable True if position is liquidatable, false otherwise
     */
    function isPositionLiquidatable(bytes32 positionId) external view returns (bool liquidatable);
}
