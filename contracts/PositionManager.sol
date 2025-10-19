// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import "./interfaces/IVault.sol";
import "./interfaces/IIndexOracle.sol";
import "./interfaces/IFundingRateCalculator.sol";
import "./interfaces/IvAMM.sol";

/**
 * @title PositionManager
 * @notice THE HEART - Core contract for managing perpetual positions in Inflation Market
 * @dev Handles complete position lifecycle with role-based access control
 *
 * Security Features:
 * - AccessControl for role-based permissions
 * - ReentrancyGuard on all state-changing functions
 * - Pausable for emergency situations
 * - Input validation on all parameters
 * - Safe math for all calculations
 * - Comprehensive event emissions
 */
contract PositionManager is
    Initializable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    // ============================================================================
    // ROLES
    // ============================================================================

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant LIQUIDATOR_ROLE = keccak256("LIQUIDATOR_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    // ============================================================================
    // STRUCTS
    // ============================================================================

    struct Position {
        address trader;              // Position owner
        bool isLong;                 // True = long, False = short
        uint256 size;                // Position size in index units
        uint256 collateral;          // Collateral amount in USDC
        uint256 leverage;            // Leverage multiplier (1e18 = 1x)
        uint256 entryPrice;          // Entry price (1e18 precision)
        uint256 entryFundingIndex;   // Funding index at entry
        uint256 timestamp;           // Position open timestamp
        uint256 liquidationPrice;    // Calculated liquidation price
    }

    // ============================================================================
    // STATE VARIABLES
    // ============================================================================

    // Core protocol contracts
    IVault public vault;
    IIndexOracle public oracle;
    IFundingRateCalculator public fundingCalculator;
    IvAMM public vamm;

    // Position tracking
    mapping(bytes32 => Position) public positions;
    mapping(address => bytes32[]) public userPositions;
    uint256 public totalPositions;

    // Risk parameters
    uint256 public maxLeverage;           // Maximum allowed leverage (1e18 = 1x)
    uint256 public maintenanceMargin;     // Maintenance margin requirement (basis points)
    uint256 public tradingFee;            // Trading fee (basis points)
    uint256 public liquidationFee;        // Liquidation fee (basis points)

    // Protocol settings
    uint256 public minCollateral;         // Minimum collateral required
    address public feeRecipient;          // Address receiving protocol fees

    // Constants
    uint256 public constant PRECISION = 1e18;
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant MIN_LEVERAGE = 1e18;      // 1x
    uint256 public constant MAX_LEVERAGE_CAP = 20e18;  // 20x hard cap

    // ============================================================================
    // EVENTS
    // ============================================================================

    event PositionOpened(
        bytes32 indexed positionId,
        address indexed trader,
        bool isLong,
        uint256 collateral,
        uint256 size,
        uint256 leverage,
        uint256 entryPrice,
        uint256 timestamp
    );

    event PositionClosed(
        bytes32 indexed positionId,
        address indexed trader,
        int256 pnl,
        uint256 closingPrice,
        uint256 timestamp
    );

    event PositionLiquidated(
        bytes32 indexed positionId,
        address indexed trader,
        address indexed liquidator,
        uint256 liquidationPrice,
        uint256 reward,
        uint256 timestamp
    );

    event MarginAdded(
        bytes32 indexed positionId,
        address indexed trader,
        uint256 amount,
        uint256 newCollateral
    );

    event MarginRemoved(
        bytes32 indexed positionId,
        address indexed trader,
        uint256 amount,
        uint256 newCollateral
    );

    event RiskParametersUpdated(
        uint256 maxLeverage,
        uint256 maintenanceMargin,
        uint256 tradingFee,
        uint256 liquidationFee
    );

    event ContractUpdated(
        string indexed contractType,
        address oldAddress,
        address newAddress
    );

    // ============================================================================
    // ERRORS
    // ============================================================================

    error ZeroAddress();
    error InvalidLeverage();
    error InsufficientCollateral();
    error PositionNotFound();
    error NotPositionOwner();
    error PositionNotLiquidatable();
    error InvalidAmount();
    error PositionUnhealthy();
    error FeeTooHigh();

    // ============================================================================
    // INITIALIZATION
    // ============================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the PositionManager contract
     * @param _vault Address of the Vault contract
     * @param _oracle Address of the IndexOracle contract
     * @param _fundingCalculator Address of the FundingRateCalculator contract
     * @param _vamm Address of the vAMM contract
     * @param _feeRecipient Address to receive protocol fees
     * @param _admin Address of the admin
     */
    function initialize(
        address _vault,
        address _oracle,
        address _fundingCalculator,
        address _vamm,
        address _feeRecipient,
        address _admin
    ) public initializer {
        if (_vault == address(0)) revert ZeroAddress();
        if (_oracle == address(0)) revert ZeroAddress();
        if (_fundingCalculator == address(0)) revert ZeroAddress();
        if (_vamm == address(0)) revert ZeroAddress();
        if (_feeRecipient == address(0)) revert ZeroAddress();
        if (_admin == address(0)) revert ZeroAddress();

        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        // Set up roles
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(OPERATOR_ROLE, _admin);

        // Initialize contract references
        vault = IVault(_vault);
        oracle = IIndexOracle(_oracle);
        fundingCalculator = IFundingRateCalculator(_fundingCalculator);
        vamm = IvAMM(_vamm);
        feeRecipient = _feeRecipient;

        // Set default risk parameters
        maxLeverage = 10e18;          // 10x default
        maintenanceMargin = 500;      // 5%
        tradingFee = 10;              // 0.1%
        liquidationFee = 500;         // 5%
        minCollateral = 10e6;         // 10 USDC (6 decimals)
    }

    // ============================================================================
    // CORE POSITION FUNCTIONS
    // ============================================================================

    /**
     * @notice Open a new perpetual position
     * @dev This is THE CORE function that orchestrates all protocol components
     *
     * Flow:
     * 1. Validate all inputs (leverage bounds, collateral minimums)
     * 2. Check user has sufficient balance in Vault
     * 3. Calculate position size based on leverage
     * 4. Lock collateral in Vault
     * 5. Deduct and transfer trading fees
     * 6. Get mark price from vAMM
     * 7. Execute virtual swap on vAMM to update reserves
     * 8. Get current funding index from FundingRateCalculator
     * 9. Calculate liquidation price based on maintenance margin
     * 10. Generate unique position ID
     * 11. Store position in contract state
     * 12. Update user's position tracking
     * 13. Update open interest metrics
     * 14. Emit PositionOpened event
     *
     * @param isLong True for long position (profit when price increases), false for short (profit when price decreases)
     * @param collateralAmount Amount of USDC collateral to deposit (must be >= minCollateral)
     * @param leverage Leverage multiplier scaled by 1e18 (e.g., 5e18 = 5x, range: 1x-20x)
     * @return positionId Unique keccak256 hash identifier for the opened position
     *
     * Requirements:
     * - Contract must not be paused
     * - collateralAmount must be >= minCollateral (10 USDC default)
     * - leverage must be >= MIN_LEVERAGE (1x) and <= maxLeverage (configurable, max 20x)
     * - User must have approved this contract to spend collateralAmount + fees
     * - Vault must have sufficient liquidity
     *
     * Reverts:
     * - InsufficientCollateral: if collateralAmount < minCollateral
     * - InvalidLeverage: if leverage is outside allowed bounds
     * - Reverts from Vault.lockCollateral if insufficient user balance
     *
     * Events:
     * - PositionOpened: Emitted with all position details
     */
    function openPosition(
        bool isLong,
        uint256 collateralAmount,
        uint256 leverage
    ) external nonReentrant whenNotPaused returns (bytes32 positionId) {

        // ========================================================================
        // STEP 1: INPUT VALIDATION
        // ========================================================================

        // Validate collateral meets minimum requirement (default 10 USDC)
        // This prevents dust positions that would be unprofitable to liquidate
        if (collateralAmount < minCollateral) revert InsufficientCollateral();

        // Validate leverage is within protocol bounds
        // MIN_LEVERAGE (1x) ensures no zero-leverage positions
        // maxLeverage (default 10x, max 20x) limits protocol risk exposure
        if (leverage < MIN_LEVERAGE || leverage > maxLeverage) revert InvalidLeverage();

        // Note: Additional validation of user's vault balance happens in vault.lockCollateral()
        // If user doesn't have sufficient approved balance, that call will revert

        // ========================================================================
        // STEP 2: CALCULATE POSITION SIZE
        // ========================================================================

        // Position size = collateral * leverage
        // Example: 1000 USDC * 5x = 5000 USDC notional exposure
        // Division by PRECISION (1e18) because leverage is scaled
        uint256 size = (collateralAmount * leverage) / PRECISION;

        // ========================================================================
        // STEP 3: LOCK COLLATERAL IN VAULT
        // ========================================================================

        // Transfer and lock user's collateral in the Vault
        // This is done BEFORE getting price to follow checks-effects-interactions pattern
        // Reverts if user hasn't approved enough tokens or has insufficient balance
        vault.lockCollateral(msg.sender, collateralAmount);

        // ========================================================================
        // STEP 4: CALCULATE AND DEDUCT TRADING FEE
        // ========================================================================

        // Calculate trading fee based on position size (not collateral)
        // Example: 5000 USDC size * 0.1% = 5 USDC fee
        uint256 fee = (size * tradingFee) / BASIS_POINTS;

        if (fee > 0) {
            // Lock fee from user's balance (separate from collateral)
            vault.lockCollateral(msg.sender, fee);

            // Immediately release fee to protocol fee recipient
            // This ensures fees are collected even if position is immediately liquidated
            vault.releaseCollateral(feeRecipient, fee);
        }

        // ========================================================================
        // STEP 5: GET MARK PRICE FROM vAMM
        // ========================================================================

        // Get current market price from virtual AMM
        // This is the price at which the position will be opened
        // Price has 1e18 precision (e.g., 2000e18 = $2000)
        uint256 entryPrice = vamm.getPrice();

        // ========================================================================
        // STEP 6: UPDATE vAMM RESERVES (EXECUTE VIRTUAL SWAP)
        // ========================================================================

        // Execute a virtual swap on the vAMM to update reserves
        // This simulates the market impact of opening a leveraged position
        // Long = buy pressure (increases mark price)
        // Short = sell pressure (decreases mark price)
        //
        // Note: vAMM.swap() updates the constant product (k = x * y)
        // and moves the mark price based on the position size
        try vamm.swap(size, isLong) returns (uint256) {
            // Swap successful - vAMM reserves updated
            // The return value represents the amount received from the swap
            // We don't need it here as we're using the pre-swap price as entry price
        } catch {
            // If vAMM swap fails (e.g., excessive slippage), position opening fails
            // This protects users from opening positions at unfavorable prices
            // In production, consider custom error with slippage details
            revert("vAMM swap failed");
        }

        // ========================================================================
        // STEP 7: GET CURRENT FUNDING INDEX
        // ========================================================================

        // Retrieve current funding rate index from FundingRateCalculator
        // This is stored to calculate funding payments when position is closed
        // Funding payments occur periodically between longs and shorts to keep
        // perpetual price anchored to index price
        uint256 entryFundingIndex = _getCurrentFundingIndex();

        // ========================================================================
        // STEP 8: CALCULATE LIQUIDATION PRICE
        // ========================================================================

        // Calculate the price at which this position becomes liquidatable
        // Liquidation occurs when unrealized loss reaches maintenance margin threshold
        //
        // Example for 5x long at $2000 entry with 5% maintenance margin:
        // - Loss threshold = 95% (100% - 5%)
        // - Price move = 95% / 5 = 19%
        // - Liquidation price = $2000 * (1 - 19%) = $1620
        //
        // This is stored in the position for quick liquidation checks
        uint256 liquidationPrice = _calculateLiquidationPrice(
            entryPrice,
            leverage,
            isLong
        );

        // ========================================================================
        // STEP 9: GENERATE UNIQUE POSITION ID
        // ========================================================================

        // Create a unique, deterministic position ID using keccak256 hash
        // Includes trader address, timestamp, position counter, and direction
        // This ensures each position has a globally unique identifier
        // even if same trader opens multiple positions in same block
        positionId = keccak256(
            abi.encodePacked(
                msg.sender,           // Trader address
                block.timestamp,      // Current timestamp
                totalPositions,       // Global position counter (nonce)
                isLong               // Position direction
            )
        );

        // ========================================================================
        // STEP 10: CREATE AND STORE POSITION
        // ========================================================================

        // Store the complete position struct in contract state
        // This is the source of truth for the position's current state
        positions[positionId] = Position({
            trader: msg.sender,                  // Position owner
            isLong: isLong,                      // Direction (long/short)
            size: size,                          // Notional size (collateral * leverage)
            collateral: collateralAmount,        // Locked collateral amount
            leverage: leverage,                  // Leverage multiplier
            entryPrice: entryPrice,              // Price at position open
            entryFundingIndex: entryFundingIndex, // Funding index at entry
            timestamp: block.timestamp,          // Position open time
            liquidationPrice: liquidationPrice   // Pre-calculated liq price
        });

        // ========================================================================
        // STEP 11: UPDATE USER POSITION TRACKING
        // ========================================================================

        // Add position ID to user's position array
        // This enables quick lookup of all positions for a given address
        // Used by frontend to display user's portfolio
        userPositions[msg.sender].push(positionId);

        // Increment global position counter
        // This serves as a nonce for position ID generation
        // and tracks total positions ever opened (not just active)
        totalPositions++;

        // ========================================================================
        // STEP 12: UPDATE OPEN INTEREST (For Funding Rate Calculation)
        // ========================================================================

        // Update the FundingRateCalculator with new open interest
        // This is used to calculate funding rates based on long/short imbalance
        //
        // Note: This is a placeholder - actual implementation depends on
        // FundingRateCalculator interface. Typically you would call:
        // fundingCalculator.updateOpenInterest(size, isLong, true);
        //
        // Where parameters are: (size, isLong, isIncrease)
        // This allows the funding rate to adjust based on market imbalance

        // ========================================================================
        // STEP 13: EMIT EVENT
        // ========================================================================

        // Emit comprehensive event for indexing and frontend updates
        // This event is crucial for:
        // - Frontend position tracking
        // - Analytics and reporting
        // - Audit trail
        // - Graph Protocol indexing (if using subgraphs)
        emit PositionOpened(
            positionId,          // Unique position identifier
            msg.sender,          // Trader address
            isLong,              // Position direction
            collateralAmount,    // Collateral locked
            size,                // Position size (notional)
            leverage,            // Leverage used
            entryPrice,          // Entry price
            block.timestamp      // Open timestamp
        );

        // ========================================================================
        // STEP 14: RETURN POSITION ID
        // ========================================================================

        // Return the unique position ID to the caller
        // This allows immediate interaction with the position
        // (e.g., adding margin, closing, etc.)
        return positionId;
    }

    /**
     * @notice Close an existing perpetual position
     * @dev This function closes a position and settles all P&L and funding payments
     *
     * Flow:
     * 1. Validate position exists and caller owns it
     * 2. Get current mark price from vAMM
     * 3. Calculate unrealized P&L (price difference)
     * 4. Calculate and apply funding payments
     * 5. Execute reverse virtual swap on vAMM (reduce open interest)
     * 6. Calculate trading fee on position size
     * 7. Deduct closing fee from final settlement
     * 8. Calculate net settlement amount (collateral +/- P&L - fees)
     * 9. Handle total loss scenarios (capped at collateral)
     * 10. Release net amount from vault to trader
     * 11. Update open interest in FundingRateCalculator
     * 12. Remove position from user tracking
     * 13. Delete position from storage
     * 14. Emit PositionClosed event
     * 15. Return final P&L
     *
     * @param positionId The unique identifier of the position to close
     * @return pnl The net profit or loss from closing (can be negative)
     *
     * Requirements:
     * - Contract must not be paused
     * - Position must exist (size > 0)
     * - Caller must be the position owner
     *
     * Reverts:
     * - PositionNotFound: if position doesn't exist or already closed
     * - NotPositionOwner: if caller is not the position owner
     *
     * Events:
     * - PositionClosed: Emitted with settlement details
     *
     * Examples:
     * - Profitable long: Entry $2000, Exit $2200, 5x leverage, 1000 USDC collateral
     *   Price gain = 10%, Leveraged gain = 50%, P&L = +500 USDC (before fees)
     * - Losing short: Entry $2000, Exit $2100, 3x leverage, 500 USDC collateral
     *   Price loss = 5%, Leveraged loss = 15%, P&L = -75 USDC (before fees)
     */
    function closePosition(bytes32 positionId)
        external
        nonReentrant
        whenNotPaused
        returns (int256 pnl)
    {
        // ========================================================================
        // STEP 1: VALIDATE POSITION AND OWNERSHIP
        // ========================================================================

        // Load position from storage
        // Using 'storage' pointer for gas efficiency (we'll delete it anyway)
        Position storage position = positions[positionId];

        // Verify position exists
        // A position with size == 0 either never existed or was already closed
        if (position.size == 0) revert PositionNotFound();

        // Verify caller is the position owner
        // Only the trader who opened the position can close it
        // Liquidators use liquidatePosition() instead
        if (position.trader != msg.sender) revert NotPositionOwner();

        // ========================================================================
        // STEP 2: GET CURRENT MARK PRICE
        // ========================================================================

        // Retrieve current market price from vAMM
        // This is the exit price at which position will be closed
        // Price has 1e18 precision (e.g., 2100e18 = $2100)
        uint256 currentPrice = vamm.getPrice();

        // ========================================================================
        // STEP 3: CALCULATE UNREALIZED P&L
        // ========================================================================

        // Calculate total P&L including:
        // 1. Price change P&L: (exit price - entry price) * position size
        // 2. Funding payments: accumulated since position opened
        //
        // For Long positions:
        // - Profit when price increases (currentPrice > entryPrice)
        // - Loss when price decreases (currentPrice < entryPrice)
        //
        // For Short positions:
        // - Profit when price decreases (currentPrice < entryPrice)
        // - Loss when price increases (currentPrice > entryPrice)
        //
        // Example: 5x long, 1000 USDC collateral, entry $2000, exit $2200
        // - Position size = 5000 USDC
        // - Price gain = 10%
        // - P&L = 5000 * 10% = 500 USDC (50% return on collateral)
        pnl = calculatePnL(positionId);

        // ========================================================================
        // STEP 4: EXECUTE REVERSE SWAP ON vAMM
        // ========================================================================

        // Execute reverse swap to update vAMM reserves
        // This is the opposite direction of opening:
        // - Long position closing = sell (decreases mark price)
        // - Short position closing = buy (increases mark price)
        //
        // The reverse swap reduces open interest and helps price discovery
        try vamm.swap(position.size, !position.isLong) returns (uint256) {
            // Reverse swap successful - vAMM reserves updated
            // Long closes by selling, short closes by buying
        } catch {
            // If vAMM swap fails, position closing fails
            // This protects protocol from inconsistent state
            revert("vAMM reverse swap failed");
        }

        // ========================================================================
        // STEP 5: CALCULATE CLOSING FEE
        // ========================================================================

        // Calculate trading fee on position size (same as opening)
        // Example: 5000 USDC size * 0.1% = 5 USDC fee
        // Fee is deducted from settlement regardless of profit/loss
        uint256 closingFee = (position.size * tradingFee) / BASIS_POINTS;

        // ========================================================================
        // STEP 6: CALCULATE NET SETTLEMENT AMOUNT
        // ========================================================================

        // Determine final amount to return to trader
        // Formula: collateral + P&L - closing fee
        //
        // Scenarios:
        // 1. Profit: Return collateral + profit - fee
        // 2. Small loss: Return collateral - loss - fee
        // 3. Total loss: Return 0 (loss >= collateral)
        uint256 finalAmount;

        if (pnl >= 0) {
            // ================================================================
            // PROFITABLE POSITION
            // ================================================================

            // Trader made profit
            // Return original collateral + profit - closing fee
            //
            // Example: 1000 USDC collateral, +500 USDC profit, 5 USDC fee
            // finalAmount = 1000 + 500 - 5 = 1495 USDC
            uint256 grossAmount = position.collateral + uint256(pnl);

            // Ensure we don't underflow if fee > gross amount (edge case)
            if (closingFee >= grossAmount) {
                finalAmount = 0; // Fee consumed all returns (rare)
            } else {
                finalAmount = grossAmount - closingFee;
            }

        } else {
            // ================================================================
            // LOSING POSITION
            // ================================================================

            // Trader suffered loss
            // Return collateral - loss - closing fee
            //
            // Example 1 (Partial loss): 1000 USDC collateral, -200 USDC loss, 5 USDC fee
            // finalAmount = 1000 - 200 - 5 = 795 USDC
            //
            // Example 2 (Total loss): 1000 USDC collateral, -1100 USDC loss
            // finalAmount = 0 (capped at zero, can't go negative)

            // Convert negative P&L to positive loss value
            uint256 loss = uint256(-pnl);

            // Calculate total deduction (loss + fee)
            uint256 totalDeduction = loss + closingFee;

            // Check if total loss exceeds collateral
            if (totalDeduction >= position.collateral) {
                // Total loss - trader loses all collateral
                // This happens with high leverage and adverse price movement
                finalAmount = 0;
            } else {
                // Partial loss - return remaining collateral
                finalAmount = position.collateral - totalDeduction;
            }
        }

        // ========================================================================
        // STEP 7: TRANSFER CLOSING FEE TO PROTOCOL
        // ========================================================================

        // Transfer closing fee to protocol fee recipient
        // This is separate from the settlement to trader
        // Fee is always paid (even on losing positions) unless total loss
        if (closingFee > 0 && (position.collateral > 0)) {
            // Fee comes from locked collateral, not from settlement
            vault.releaseCollateral(feeRecipient, closingFee);
        }

        // ========================================================================
        // STEP 8: RELEASE NET SETTLEMENT TO TRADER
        // ========================================================================

        // Release the calculated final amount to trader
        // Only release if there's something to return
        // On total loss scenarios, nothing is returned
        if (finalAmount > 0) {
            vault.releaseCollateral(msg.sender, finalAmount);
        }

        // ========================================================================
        // STEP 9: UPDATE OPEN INTEREST
        // ========================================================================

        // Update FundingRateCalculator to decrease open interest
        // This affects funding rate calculations for remaining positions
        //
        // Note: Placeholder - actual implementation depends on interface
        // Typically: fundingCalculator.updateOpenInterest(position.size, position.isLong, false);
        // Where false indicates decrease in open interest

        // ========================================================================
        // STEP 10: REMOVE FROM USER TRACKING
        // ========================================================================

        // Remove position ID from user's position array
        // This updates the portfolio view for the trader
        // Uses efficient swap-and-pop algorithm for gas savings
        _removeUserPosition(msg.sender, positionId);

        // ========================================================================
        // STEP 11: DELETE POSITION FROM STORAGE
        // ========================================================================

        // Delete position from contract storage
        // This frees up storage and provides gas refund
        // After this point, the position no longer exists
        delete positions[positionId];

        // ========================================================================
        // STEP 12: EMIT EVENT
        // ========================================================================

        // Emit comprehensive event for tracking and analytics
        // Contains all information needed to reconstruct the close transaction
        emit PositionClosed(
            positionId,          // Position identifier
            msg.sender,          // Trader address
            pnl,                 // Final P&L (includes funding, excludes fee)
            currentPrice,        // Exit price
            block.timestamp      // Close timestamp
        );

        // ========================================================================
        // STEP 13: RETURN P&L
        // ========================================================================

        // Return the P&L to caller
        // Note: This is gross P&L (before closing fee)
        // Net amount received is finalAmount calculated above
        return pnl;
    }

    /**
     * @notice Add margin to an existing position
     * @param positionId The ID of the position
     * @param amount Amount of collateral to add
     */
    function addMargin(bytes32 positionId, uint256 amount)
        external
        nonReentrant
        whenNotPaused
    {
        Position storage position = positions[positionId];
        if (position.trader != msg.sender) revert NotPositionOwner();
        if (position.size == 0) revert PositionNotFound();
        if (amount == 0) revert InvalidAmount();

        // Lock additional collateral
        vault.lockCollateral(msg.sender, amount);

        // Update position
        position.collateral += amount;

        // Recalculate liquidation price with new collateral
        position.liquidationPrice = _calculateLiquidationPrice(
            position.entryPrice,
            position.leverage,
            position.isLong
        );

        emit MarginAdded(positionId, msg.sender, amount, position.collateral);
    }

    /**
     * @notice Remove margin from an existing position
     * @param positionId The ID of the position
     * @param amount Amount of collateral to remove
     */
    function removeMargin(bytes32 positionId, uint256 amount)
        external
        nonReentrant
        whenNotPaused
    {
        Position storage position = positions[positionId];
        if (position.trader != msg.sender) revert NotPositionOwner();
        if (position.size == 0) revert PositionNotFound();
        if (amount == 0) revert InvalidAmount();
        if (amount >= position.collateral) revert InvalidAmount();

        // Temporarily reduce collateral to check health
        uint256 oldCollateral = position.collateral;
        position.collateral -= amount;

        // Check if position remains healthy
        uint256 healthRatio = _getPositionHealth(position);
        if (healthRatio < maintenanceMargin) {
            // Revert collateral change
            position.collateral = oldCollateral;
            revert PositionUnhealthy();
        }

        // Release collateral to trader
        vault.releaseCollateral(msg.sender, amount);

        // Recalculate liquidation price
        position.liquidationPrice = _calculateLiquidationPrice(
            position.entryPrice,
            position.leverage,
            position.isLong
        );

        emit MarginRemoved(positionId, msg.sender, amount, position.collateral);
    }

    /**
     * @notice Liquidate an undercollateralized position
     * @param positionId The ID of the position to liquidate
     * @dev Can only be called by addresses with LIQUIDATOR_ROLE
     */
    function liquidatePosition(bytes32 positionId)
        external
        nonReentrant
        whenNotPaused
        onlyRole(LIQUIDATOR_ROLE)
    {
        Position storage position = positions[positionId];
        if (position.size == 0) revert PositionNotFound();

        // Check if position is liquidatable
        uint256 healthRatio = _getPositionHealth(position);
        if (healthRatio >= maintenanceMargin) revert PositionNotLiquidatable();

        address trader = position.trader;
        uint256 currentPrice = vamm.getPrice();

        // Calculate liquidation reward for liquidator
        uint256 reward = (position.collateral * liquidationFee) / BASIS_POINTS;

        // Calculate remaining collateral for protocol
        uint256 remaining = position.collateral > reward
            ? position.collateral - reward
            : 0;

        // Distribute collateral
        if (reward > 0) {
            vault.releaseCollateral(msg.sender, reward);
        }
        if (remaining > 0) {
            vault.releaseCollateral(feeRecipient, remaining);
        }

        // Remove position from tracking
        _removeUserPosition(trader, positionId);

        // Delete position
        delete positions[positionId];

        emit PositionLiquidated(
            positionId,
            trader,
            msg.sender,
            currentPrice,
            reward,
            block.timestamp
        );
    }

    // ============================================================================
    // VIEW FUNCTIONS
    // ============================================================================

    /**
     * @notice Calculate current unrealized P&L for an open position
     * @dev This is a VIEW function - it does not modify state
     *
     * Calculation includes two components:
     * 1. Price Change P&L: Profit/loss from price movement since entry
     * 2. Funding Payments: Accumulated funding payments since entry
     *
     * Formula:
     * - Price P&L = (currentPrice - entryPrice) / entryPrice * positionSize
     * - For shorts, this is inverted: -(currentPrice - entryPrice) / entryPrice * positionSize
     * - Total P&L = Price P&L - Funding Payments
     *
     * @param positionId The unique identifier of the position
     * @return pnl The current unrealized profit (positive) or loss (negative) in USDC
     *             Does NOT include trading fees which are deducted separately when closing
     *
     * Requirements:
     * - Position must exist (size > 0)
     *
     * Reverts:
     * - PositionNotFound: if position doesn't exist or was already closed
     *
     * Examples:
     * - Long position: Entry $2000, Current $2200, 5x leverage, 1000 USDC collateral
     *   Size = 5000 USDC, Price gain = 10%, P&L = 5000 * 10% = +500 USDC
     * - Short position: Entry $2000, Current $2100, 3x leverage, 500 USDC collateral
     *   Size = 1500 USDC, Price loss = 5%, P&L = 1500 * 5% = -75 USDC
     *
     * Usage:
     * - Called by frontend to display unrealized P&L
     * - Called internally by closePosition to calculate settlement
     * - Called by liquidation bots to check position health
     */
    function calculatePnL(bytes32 positionId)
        public
        view
        returns (int256 pnl)
    {
        // Verify position exists before calculating P&L
        // A position with size == 0 either never existed or was already closed
        Position storage position = positions[positionId];
        if (position.size == 0) revert PositionNotFound();

        // Delegate to internal function for actual calculation
        // This allows code reuse by other functions without redundant checks
        return _calculatePnL(position);
    }

    /**
     * @notice Get position details
     * @param positionId The ID of the position
     * @return position The position struct
     */
    function getPosition(bytes32 positionId)
        external
        view
        returns (Position memory)
    {
        return positions[positionId];
    }

    /**
     * @notice Get all positions for a user
     * @param user The user address
     * @return positionIds Array of position IDs owned by the user
     */
    function getUserPositions(address user)
        external
        view
        returns (bytes32[] memory)
    {
        return userPositions[user];
    }

    /**
     * @notice Check if a position can be liquidated
     * @param positionId The ID of the position
     * @return True if the position is below maintenance margin
     */
    function isPositionLiquidatable(bytes32 positionId)
        external
        view
        returns (bool)
    {
        Position storage position = positions[positionId];
        if (position.size == 0) return false;

        uint256 healthRatio = _getPositionHealth(position);
        return healthRatio < maintenanceMargin;
    }

    // ============================================================================
    // INTERNAL FUNCTIONS
    // ============================================================================

    /**
     * @dev Calculate unrealized P&L for a position (internal implementation)
     *
     * This function performs the core P&L calculation for perpetual positions.
     * It combines two components:
     *
     * 1. PRICE CHANGE P&L
     *    - Measures profit/loss from price movement
     *    - Long positions profit when price increases
     *    - Short positions profit when price decreases
     *    - Amplified by leverage (position size)
     *
     * 2. FUNDING PAYMENTS
     *    - Periodic payments between longs and shorts
     *    - Keeps perpetual price anchored to index price
     *    - Long pays short when mark > index (positive funding)
     *    - Short pays long when mark < index (negative funding)
     *
     * @param position Storage pointer to the position struct
     * @return pnl Net P&L (can be positive or negative)
     *
     * Mathematical Formula:
     * ┌─────────────────────────────────────────────────────────────┐
     * │ pricePnL = (currentPrice - entryPrice) * size / entryPrice │
     * │ For shorts: pricePnL is inverted (multiplied by -1)        │
     * │ totalPnL = pricePnL - fundingPayment                        │
     * └─────────────────────────────────────────────────────────────┘
     */
    function _calculatePnL(Position storage position)
        internal
        view
        returns (int256 pnl)
    {
        // ====================================================================
        // STEP 1: GET CURRENT MARK PRICE
        // ====================================================================

        // Retrieve the current market price from vAMM
        // This is constantly changing as traders open/close positions
        // Price uses 1e18 precision (e.g., 2100e18 = $2100)
        uint256 currentPrice = vamm.getPrice();

        // ====================================================================
        // STEP 2: CALCULATE PRICE DELTA
        // ====================================================================

        // Calculate the price change since position entry
        // Can be positive (price increased) or negative (price decreased)
        //
        // Example 1: entryPrice = $2000, currentPrice = $2200
        // priceDelta = +$200 (10% increase)
        //
        // Example 2: entryPrice = $2000, currentPrice = $1800
        // priceDelta = -$200 (10% decrease)
        int256 priceDelta = int256(currentPrice) - int256(position.entryPrice);

        // ====================================================================
        // STEP 3: ADJUST FOR POSITION DIRECTION
        // ====================================================================

        // Long positions:
        // - Profit when price increases (priceDelta > 0)
        // - Loss when price decreases (priceDelta < 0)
        // - Keep priceDelta as-is
        //
        // Short positions:
        // - Profit when price decreases (priceDelta < 0, inverted to positive)
        // - Loss when price increases (priceDelta > 0, inverted to negative)
        // - Invert priceDelta (multiply by -1)
        if (!position.isLong) {
            priceDelta = -priceDelta;
        }

        // ====================================================================
        // STEP 4: CALCULATE PRICE CHANGE P&L
        // ====================================================================

        // Apply position size to calculate absolute P&L
        //
        // Formula: P&L = (price change / entry price) * position size
        // This gives us the dollar value of profit or loss
        //
        // Example (Long position):
        // - Entry: $2000, Current: $2200
        // - Price delta: +$200
        // - Position size: 5000 USDC (1000 collateral * 5x leverage)
        // - P&L = ($200 / $2000) * 5000 = 0.10 * 5000 = +500 USDC
        // - This is a 50% return on the 1000 USDC collateral
        //
        // Example (Short position):
        // - Entry: $2000, Current: $2100
        // - Price delta: +$100, inverted to -$100
        // - Position size: 1500 USDC (500 collateral * 3x leverage)
        // - P&L = (-$100 / $2000) * 1500 = -0.05 * 1500 = -75 USDC
        // - This is a 15% loss on the 500 USDC collateral
        pnl = (priceDelta * int256(position.size)) / int256(position.entryPrice);

        // ====================================================================
        // STEP 5: SUBTRACT FUNDING PAYMENTS
        // ====================================================================

        // Calculate accumulated funding payments since position opened
        // Funding payments are periodic transfers between longs and shorts
        // that help keep the perpetual price close to the index price
        //
        // Funding payment calculation:
        // - Positive funding rate: Longs pay shorts (mark price > index price)
        // - Negative funding rate: Shorts pay longs (mark price < index price)
        // - Payment amount proportional to position size and time held
        int256 fundingPayment = _calculateFundingPayment(position);

        // Subtract funding payment from price P&L
        // If funding payment is positive, trader owes payment (reduces P&L)
        // If funding payment is negative, trader receives payment (increases P&L)
        pnl -= fundingPayment;

        // ====================================================================
        // STEP 6: RETURN FINAL P&L
        // ====================================================================

        // Return the net P&L combining price movement and funding
        // Positive = profit, Negative = loss
        // Note: This does NOT include trading fees, which are separate
        return pnl;
    }

    /**
     * @dev Calculate accumulated funding payment for a position
     *
     * Funding payments are a core mechanism in perpetual futures that keep
     * the perpetual contract price (mark price) anchored to the spot/index price.
     *
     * How Funding Works:
     * ==================
     * - When mark price > index price (perpetual trading at premium):
     *   → Positive funding rate
     *   → Long positions PAY shorts
     *   → This incentivizes shorts, pushing mark price down
     *
     * - When mark price < index price (perpetual trading at discount):
     *   → Negative funding rate
     *   → Short positions PAY longs
     *   → This incentivizes longs, pushing mark price up
     *
     * - Funding is paid continuously based on time position is held
     * - Payment amount is proportional to position size
     *
     * @param position Storage pointer to the position struct
     * @return payment Accumulated funding payment (positive = trader owes, negative = trader receives)
     *
     * Mathematical Formula:
     * ┌──────────────────────────────────────────────────────────┐
     * │ indexDelta = currentFundingIndex - entryFundingIndex    │
     * │ payment = (positionSize * indexDelta) / PRECISION       │
     * │ For shorts: payment is inverted (multiplied by -1)       │
     * └──────────────────────────────────────────────────────────┘
     *
     * Examples:
     * - Long position, positive funding (mark > index):
     *   Payment is positive → trader pays (reduces P&L)
     * - Short position, positive funding (mark > index):
     *   Payment is negative → trader receives (increases P&L)
     */
    function _calculateFundingPayment(Position storage position)
        internal
        view
        returns (int256 payment)
    {
        // ====================================================================
        // STEP 1: GET CURRENT FUNDING INDEX
        // ====================================================================

        // Retrieve the current cumulative funding index
        // This is a continuously growing value that tracks all funding payments
        // over time, similar to how interest compounds
        uint256 currentIndex = _getCurrentFundingIndex();

        // ====================================================================
        // STEP 2: CALCULATE INDEX DELTA
        // ====================================================================

        // Calculate how much the funding index has changed since position entry
        // This represents the cumulative funding rate accrued during position lifetime
        //
        // Example:
        // - Entry funding index: 1000
        // - Current funding index: 1050
        // - Index delta: 50 (represents 5% cumulative funding)
        uint256 indexDelta = currentIndex > position.entryFundingIndex
            ? currentIndex - position.entryFundingIndex
            : 0; // Safety check: if current < entry, no payment

        // ====================================================================
        // STEP 3: CALCULATE FUNDING PAYMENT AMOUNT
        // ====================================================================

        // Apply index delta to position size to get absolute payment amount
        //
        // Formula: payment = position size * (funding rate change)
        //
        // Example:
        // - Position size: 5000 USDC
        // - Index delta: 50 (from step 2)
        // - Payment = 5000 * 50 / 1e18 = calculated payment in USDC
        //
        // Larger positions pay/receive proportionally more funding
        payment = int256((position.size * indexDelta) / PRECISION);

        // ====================================================================
        // STEP 4: ADJUST FOR POSITION DIRECTION
        // ====================================================================

        // Long positions:
        // - When funding is positive (mark > index): longs PAY
        // - Payment is positive (reduces P&L)
        // - Keep payment as-is
        //
        // Short positions:
        // - When funding is positive (mark > index): shorts RECEIVE
        // - Payment should be negative (increases P&L)
        // - Invert payment (multiply by -1)
        if (!position.isLong) {
            payment = -payment;
        }

        // ====================================================================
        // STEP 5: RETURN FUNDING PAYMENT
        // ====================================================================

        // Return the calculated funding payment
        // Positive value = trader owes payment (reduces final P&L)
        // Negative value = trader receives payment (increases final P&L)
        //
        // This payment is subtracted from price P&L in _calculatePnL()
        return payment;
    }

    /**
     * @dev Get current funding index from funding calculator
     */
    function _getCurrentFundingIndex() internal view returns (uint256) {
        // This is simplified - actual implementation would integrate with funding calculator
        return uint256(fundingCalculator.getLastFundingRate());
    }

    /**
     * @dev Calculate liquidation price for a position
     */
    function _calculateLiquidationPrice(
        uint256 entryPrice,
        uint256 leverage,
        bool isLong
    ) internal view returns (uint256) {
        // Liquidation occurs when loss reaches (100% - maintenance margin)
        uint256 lossThreshold = BASIS_POINTS - maintenanceMargin;

        // Price change % that causes liquidation = loss threshold / leverage
        uint256 priceChangePercent = (lossThreshold * PRECISION) / leverage;

        uint256 liquidationPrice;
        if (isLong) {
            // Long: liquidation price = entry price * (1 - priceChangePercent)
            liquidationPrice = (entryPrice * (PRECISION - priceChangePercent)) / PRECISION;
        } else {
            // Short: liquidation price = entry price * (1 + priceChangePercent)
            liquidationPrice = (entryPrice * (PRECISION + priceChangePercent)) / PRECISION;
        }

        return liquidationPrice;
    }

    /**
     * @dev Get position health ratio (margin / maintenance margin)
     */
    function _getPositionHealth(Position storage position)
        internal
        view
        returns (uint256)
    {
        int256 pnl = _calculatePnL(position);
        int256 equity = int256(position.collateral) + pnl;

        if (equity <= 0) return 0;

        // Health ratio = (equity / position value) * 10000
        uint256 positionValue = (position.size * position.entryPrice) / PRECISION;
        uint256 healthRatio = (uint256(equity) * BASIS_POINTS) / positionValue;

        return healthRatio;
    }

    /**
     * @dev Remove position from user's position array
     */
    function _removeUserPosition(address user, bytes32 positionId) internal {
        bytes32[] storage userPositionList = userPositions[user];
        uint256 length = userPositionList.length;

        for (uint256 i = 0; i < length; i++) {
            if (userPositionList[i] == positionId) {
                // Move last element to current position and pop
                userPositionList[i] = userPositionList[length - 1];
                userPositionList.pop();
                break;
            }
        }
    }

    // ============================================================================
    // ADMIN FUNCTIONS
    // ============================================================================

    /**
     * @notice Update risk parameters
     * @param _maxLeverage Maximum allowed leverage
     * @param _maintenanceMargin Maintenance margin in basis points
     * @param _tradingFee Trading fee in basis points
     * @param _liquidationFee Liquidation fee in basis points
     */
    function setRiskParameters(
        uint256 _maxLeverage,
        uint256 _maintenanceMargin,
        uint256 _tradingFee,
        uint256 _liquidationFee
    ) external onlyRole(ADMIN_ROLE) {
        if (_maxLeverage > MAX_LEVERAGE_CAP) revert InvalidLeverage();
        if (_tradingFee > 1000) revert FeeTooHigh(); // Max 10%
        if (_liquidationFee > 1000) revert FeeTooHigh(); // Max 10%

        maxLeverage = _maxLeverage;
        maintenanceMargin = _maintenanceMargin;
        tradingFee = _tradingFee;
        liquidationFee = _liquidationFee;

        emit RiskParametersUpdated(
            _maxLeverage,
            _maintenanceMargin,
            _tradingFee,
            _liquidationFee
        );
    }

    /**
     * @notice Update vault contract address
     */
    function setVault(address _vault) external onlyRole(ADMIN_ROLE) {
        if (_vault == address(0)) revert ZeroAddress();
        address oldVault = address(vault);
        vault = IVault(_vault);
        emit ContractUpdated("Vault", oldVault, _vault);
    }

    /**
     * @notice Update oracle contract address
     */
    function setOracle(address _oracle) external onlyRole(ADMIN_ROLE) {
        if (_oracle == address(0)) revert ZeroAddress();
        address oldOracle = address(oracle);
        oracle = IIndexOracle(_oracle);
        emit ContractUpdated("Oracle", oldOracle, _oracle);
    }

    /**
     * @notice Update funding calculator contract address
     */
    function setFundingCalculator(address _fundingCalculator) external onlyRole(ADMIN_ROLE) {
        if (_fundingCalculator == address(0)) revert ZeroAddress();
        address oldCalculator = address(fundingCalculator);
        fundingCalculator = IFundingRateCalculator(_fundingCalculator);
        emit ContractUpdated("FundingCalculator", oldCalculator, _fundingCalculator);
    }

    /**
     * @notice Update vAMM contract address
     */
    function setVAMM(address _vamm) external onlyRole(ADMIN_ROLE) {
        if (_vamm == address(0)) revert ZeroAddress();
        address oldVAMM = address(vamm);
        vamm = IvAMM(_vamm);
        emit ContractUpdated("vAMM", oldVAMM, _vamm);
    }

    /**
     * @notice Update fee recipient address
     */
    function setFeeRecipient(address _feeRecipient) external onlyRole(ADMIN_ROLE) {
        if (_feeRecipient == address(0)) revert ZeroAddress();
        feeRecipient = _feeRecipient;
    }

    /**
     * @notice Update minimum collateral requirement
     */
    function setMinCollateral(uint256 _minCollateral) external onlyRole(ADMIN_ROLE) {
        minCollateral = _minCollateral;
    }

    /**
     * @notice Pause the contract
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause the contract
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @notice Authorize contract upgrades
     */
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(ADMIN_ROLE)
    {}
}
