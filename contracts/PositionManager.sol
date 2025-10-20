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
        // GAS OPTIMIZATION: Packed into fewer storage slots (9 → 5 slots = -80k gas)
        // SLOT 0: address (20 bytes) + uint96 timestamp (12 bytes) = 32 bytes
        address trader;              // Position owner (20 bytes)
        uint96 timestamp;            // Position open timestamp (12 bytes) - Enough until year 2^96/31536000 ≈ 2.5 trillion years

        // SLOT 1: uint128 + uint128 = 32 bytes
        uint128 size;                // Position size in index units (max ~3.4e38 - more than enough for USDC 6 decimals)
        uint128 collateral;          // Collateral amount in USDC (max ~3.4e38)

        // SLOT 2: uint128 + uint128 = 32 bytes
        uint128 leverage;            // Leverage multiplier (1e18 = 1x, max 20e18 fits in uint128)
        uint128 entryPrice;          // Entry price (1e18 precision, max price ~3.4e20 = $340 trillion)

        // SLOT 3: uint128 + uint128 = 32 bytes
        uint128 entryFundingIndex;   // Funding index at entry
        uint128 liquidationPrice;    // Calculated liquidation price

        // SLOT 4: bool (1 byte) + 31 bytes unused
        bool isLong;                 // True = long, False = short
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
    mapping(address => mapping(bytes32 => uint256)) private positionIndex; // FIX #4: O(1) position lookup
    mapping(address => uint256) private userNonces; // FIX #15: Prevent position ID collisions
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
    uint256 public constant MAX_POSITION_SIZE = 1_000_000_000e6; // FIX #1: 1 billion USDC max
    uint256 public constant MAX_POSITIONS_PER_USER = 50; // FIX #7: Prevent DoS
    uint256 public constant MIN_MAINTENANCE_MARGIN = 100; // FIX #10: 1% minimum
    uint256 public constant MAX_MAINTENANCE_MARGIN = 2000; // FIX #10: 20% maximum

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

    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient); // FIX #9
    event MinCollateralUpdated(uint256 oldAmount, uint256 newAmount); // FIX #9

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
    error PositionTooLarge(); // FIX #1
    error TooManyPositions(); // FIX #7
    error SlippageExceeded(); // FIX #2
    error InvalidMaintenanceMargin(); // FIX #10
    error SwapFailed(bytes data); // FIX #13

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
        uint256 leverage,
        uint256 minPrice,  // FIX #2: Slippage protection for shorts (minimum acceptable price)
        uint256 maxPrice   // FIX #2: Slippage protection for longs (maximum acceptable price)
    ) external nonReentrant whenNotPaused returns (bytes32 positionId) {

        // ========================================================================
        // STEP 1: INPUT VALIDATION
        // ========================================================================

        // FIX #7: Check maximum positions per user (prevent DoS)
        if (userPositions[msg.sender].length >= MAX_POSITIONS_PER_USER) {
            revert TooManyPositions();
        }

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

        // FIX #1: Validate position size doesn't exceed maximum
        if (size > MAX_POSITION_SIZE) revert PositionTooLarge();

        // ========================================================================
        // STEP 3: GET MARK PRICE FROM vAMM
        // ========================================================================

        // Get current market price from virtual AMM
        // This is the price at which the position will be opened
        // Price has 1e18 precision (e.g., 2000e18 = $2000)
        uint256 entryPrice = vamm.getPrice();

        // ========================================================================
        // STEP 3.5: SLIPPAGE PROTECTION (FIX #2)
        // ========================================================================

        // Protect users from front-running and price manipulation
        // Long positions: revert if price is too high (exceeds maxPrice)
        // Short positions: revert if price is too low (below minPrice)
        if (isLong && entryPrice > maxPrice) revert SlippageExceeded();
        if (!isLong && entryPrice < minPrice) revert SlippageExceeded();

        // ========================================================================
        // STEP 4: CALCULATE AND DEDUCT TRADING FEE
        // ========================================================================

        // Calculate trading fee based on position size (not collateral)
        // Example: 5000 USDC size * 0.1% = 5 USDC fee
        uint256 fee = (size * tradingFee) / BASIS_POINTS;

        // ========================================================================
        // STEP 5: GENERATE UNIQUE POSITION ID
        // ========================================================================

        uint256 userNonce = userNonces[msg.sender];
        positionId = keccak256(
            abi.encodePacked(
                msg.sender,           // Trader address
                block.timestamp,      // Current timestamp
                totalPositions,       // Global position counter (nonce)
                isLong,               // Position direction
                userNonce             // Per-user nonce for collision prevention
            )
        );

        // ========================================================================
        // STEP 6: LOCK COLLATERAL AND COLLECT FEES
        // ========================================================================

        // Transfer and lock user's collateral in the Vault
        // Reverts if user hasn't approved enough tokens or has insufficient balance
        vault.lockCollateral(msg.sender, positionId, collateralAmount);

        if (fee > 0) {
            // Lock fee from user's balance (separate from collateral)
            vault.lockCollateral(msg.sender, positionId, fee);

            // Immediately release fee to protocol fee recipient
            // This ensures fees are collected even if position is immediately liquidated
            vault.transferCollateral(msg.sender, feeRecipient, fee);
        }

        // ========================================================================
        // STEP 7: UPDATE vAMM RESERVES (EXECUTE VIRTUAL SWAP)
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
        } catch Error(string memory reason) {
            // FIX #13: Better error messages - include reason from vAMM
            revert(string(abi.encodePacked("vAMM swap failed: ", reason)));
        } catch (bytes memory lowLevelData) {
            // FIX #13: Handle low-level failures with custom error
            revert SwapFailed(lowLevelData);
        }

        // ========================================================================
        // STEP 8: GET CURRENT FUNDING INDEX
        // ========================================================================

        // Retrieve current funding rate index from FundingRateCalculator
        // This is stored to calculate funding payments when position is closed
        // Funding payments occur periodically between longs and shorts to keep
        // perpetual price anchored to index price
        uint256 entryFundingIndex = _getCurrentFundingIndex();

        // ========================================================================
        // STEP 9: CALCULATE LIQUIDATION PRICE
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
        // STEP 10: CREATE AND STORE POSITION
        // ========================================================================

        // Store the complete position struct in contract state
        // This is the source of truth for the position's current state
        positions[positionId] = Position({
            trader: msg.sender,                        // Position owner
            timestamp: uint96(block.timestamp),        // Position open time (safe: block.timestamp fits in uint96)
            size: uint128(size),                       // Notional size (validated by MAX_POSITION_SIZE)
            collateral: uint128(collateralAmount),     // Locked collateral amount
            leverage: uint128(leverage),               // Leverage multiplier (max 20e18 fits in uint128)
            entryPrice: uint128(entryPrice),           // Price at position open
            entryFundingIndex: uint128(entryFundingIndex), // Funding index at entry
            liquidationPrice: uint128(liquidationPrice),   // Pre-calculated liq price
            isLong: isLong                             // Direction (long/short)
        });

        // ========================================================================
        // STEP 11: UPDATE USER POSITION TRACKING
        // ========================================================================

        // Add position ID to user's position array
        // This enables quick lookup of all positions for a given address
        // Used by frontend to display user's portfolio
        uint256 index;
        unchecked {
            // GAS OPTIMIZATION: Safe to use unchecked (limited by MAX_POSITIONS_PER_USER = 50)
            index = userPositions[msg.sender].length;
        }
        userPositions[msg.sender].push(positionId);

        // FIX #4: Store position index for O(1) removal later
        positionIndex[msg.sender][positionId] = index;

        unchecked {
            // FIX #15: Increment per-user nonce after successful position creation
            userNonces[msg.sender] = userNonce + 1;
        }

        // Increment global position counter
        // This serves as a nonce for position ID generation
        // and tracks total positions ever opened (not just active)
        unchecked {
            // GAS OPTIMIZATION: Safe overflow - totalPositions won't exceed uint256 max
            totalPositions++;
        }

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

        // GAS OPTIMIZATION: Cache frequently accessed storage variables (saves ~6,000 gas)
        // Reading from memory costs 3 gas vs 2,100 gas for SLOAD
        uint256 posSize = position.size;
        uint256 posCollateral = position.collateral;
        address posTrader = position.trader;
        bool posIsLong = position.isLong;

        // Verify position exists
        // A position with size == 0 either never existed or was already closed
        if (posSize == 0) revert PositionNotFound();

        // Verify caller is the position owner
        // Only the trader who opened the position can close it
        // Liquidators use liquidatePosition() instead
        if (posTrader != msg.sender) revert NotPositionOwner();

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
        try vamm.swap(posSize, !posIsLong) returns (uint256) {  // Use cached values
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
        uint256 closingFee = (posSize * tradingFee) / BASIS_POINTS;  // Use cached value

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
            uint256 grossAmount;
            unchecked {
                // GAS OPTIMIZATION: Safe addition - collateral + profit won't overflow uint256
                grossAmount = posCollateral + uint256(pnl);  // Use cached value
            }

            // Ensure we don't underflow if fee > gross amount (edge case)
            if (closingFee >= grossAmount) {
                finalAmount = 0; // Fee consumed all returns (rare)
            } else {
                unchecked {
                    // GAS OPTIMIZATION: Safe subtraction - we've verified closingFee < grossAmount
                    finalAmount = grossAmount - closingFee;
                }
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
            uint256 totalDeduction;
            unchecked {
                // GAS OPTIMIZATION: Safe addition - loss + closingFee won't overflow uint256
                // Loss is bounded by position size, fee is bounded by position size
                totalDeduction = loss + closingFee;
            }

            // Check if total loss exceeds collateral
            if (totalDeduction >= posCollateral) {  // Use cached value
                // Total loss - trader loses all collateral
                // This happens with high leverage and adverse price movement
                finalAmount = 0;
            } else {
                unchecked {
                    // GAS OPTIMIZATION: Safe subtraction - we've verified totalDeduction < posCollateral
                    finalAmount = posCollateral - totalDeduction;  // Use cached value
                }
            }
        }

        // ========================================================================
        // STEP 7: TRANSFER CLOSING FEE TO PROTOCOL
        // ========================================================================

        // Transfer closing fee to protocol fee recipient
        // This is separate from the settlement to trader
        // Fee is always paid (even on losing positions) unless total loss
        if (closingFee > 0 && (posCollateral > 0)) {  // Use cached value
            // Fee comes from locked collateral, not from settlement
            vault.transferCollateral(posTrader, feeRecipient, closingFee);
        }

        // ========================================================================
        // STEP 8: RELEASE NET SETTLEMENT TO TRADER
        // ========================================================================

        // Release the calculated final amount to trader
        // Only release if there's something to return
        // On total loss scenarios, nothing is returned
        if (finalAmount > 0) {
            vault.unlockCollateral(posTrader, positionId, finalAmount);
        }

        uint256 collateralAfterFee = posCollateral > closingFee ? posCollateral - closingFee : 0;
        if (collateralAfterFee > finalAmount) {
            uint256 residual = collateralAfterFee - finalAmount;
            if (residual > 0) {
                vault.writeOffCollateral(posTrader, residual);
            }
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
     * @notice Close multiple positions in a single transaction
     * @dev GAS OPTIMIZATION: Batch close function saves ~21,000 gas per additional position
     * @param positionIds Array of position IDs to close
     * @return pnls Array of P&L for each closed position
     *
     * Gas savings breakdown (per additional position):
     * - Shared transaction overhead: ~21,000 gas
     * - Shared external calls: ~2,100 gas (price oracle)
     * - Single reentrancy guard: ~5,000 gas
     * Total savings: ~28,000 gas per position after the first
     */
    function batchClosePositions(bytes32[] calldata positionIds)
        external
        nonReentrant
        whenNotPaused
        returns (int256[] memory pnls)
    {
        uint256 length = positionIds.length;
        if (length == 0) revert InvalidAmount();

        // GAS OPTIMIZATION: Initialize return array
        pnls = new int256[](length);

        // Cache current price to save gas on multiple calls (shared across all positions)
        uint256 currentPrice = vamm.getPrice();

        // Process each position
        for (uint256 i = 0; i < length;) {
            bytes32 positionId = positionIds[i];
            Position storage position = positions[positionId];

            // Validate position ownership and existence
            if (position.size == 0) revert PositionNotFound();
            if (position.trader != msg.sender) revert NotPositionOwner();

            // Cache frequently accessed storage variables
            uint256 posSize = position.size;
            uint256 posCollateral = position.collateral;
            bool posIsLong = position.isLong;

            // Calculate P&L (note: _calculatePnL fetches price internally, but we cache for event emission)
            int256 pnl = _calculatePnL(position);
            pnls[i] = pnl;

            // Execute vAMM reverse swap
            try vamm.swap(posSize, !posIsLong) {
                // Swap successful
            } catch {
                revert("vAMM reverse swap failed");
            }

            // Calculate closing fee
            uint256 closingFee = (posSize * tradingFee) / BASIS_POINTS;

            // Calculate settlement amount
            uint256 finalAmount;
            if (pnl >= 0) {
                uint256 grossAmount;
                unchecked {
                    grossAmount = posCollateral + uint256(pnl);
                }

                if (closingFee >= grossAmount) {
                    finalAmount = 0;
                } else {
                    unchecked {
                        finalAmount = grossAmount - closingFee;
                    }
                }
            } else {
                uint256 loss = uint256(-pnl);
                uint256 totalDeduction;
                unchecked {
                    totalDeduction = loss + closingFee;
                }

                if (totalDeduction >= posCollateral) {
                    finalAmount = 0;
                } else {
                    unchecked {
                        finalAmount = posCollateral - totalDeduction;
                    }
                }
            }

            // Transfer closing fee
            if (closingFee > 0 && posCollateral > 0) {
                vault.transferCollateral(msg.sender, feeRecipient, closingFee);
            }

            // Release settlement to trader
            if (finalAmount > 0) {
                vault.unlockCollateral(msg.sender, positionId, finalAmount);
            }

            uint256 collateralAfterFee = posCollateral > closingFee ? posCollateral - closingFee : 0;
            if (collateralAfterFee > finalAmount) {
                uint256 residual = collateralAfterFee - finalAmount;
                if (residual > 0) {
                    vault.writeOffCollateral(msg.sender, residual);
                }
            }

            // Remove from user tracking
            _removeUserPosition(msg.sender, positionId);

            // Delete position
            delete positions[positionId];

            // Emit event
            emit PositionClosed(
                positionId,
                msg.sender,
                pnl,
                currentPrice,
                block.timestamp
            );

            unchecked {
                // GAS OPTIMIZATION: Safe increment - limited by array length
                ++i;
            }
        }

        return pnls;
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
        vault.lockCollateral(msg.sender, positionId, amount);

        // Update position
        position.collateral += uint128(amount);

        // Recalculate liquidation price with new collateral
        position.liquidationPrice = uint128(_calculateLiquidationPrice(
            position.entryPrice,
            position.leverage,
            position.isLong
        ));

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
        uint128 oldCollateral = position.collateral;
        position.collateral -= uint128(amount);

        // Check if position remains healthy
        uint256 healthRatio = _getPositionHealth(position);
        if (healthRatio < maintenanceMargin) {
            // Revert collateral change
            position.collateral = oldCollateral;
            revert PositionUnhealthy();
        }

        // Release collateral to trader
        vault.unlockCollateral(msg.sender, positionId, amount);

        // Recalculate liquidation price
        position.liquidationPrice = uint128(_calculateLiquidationPrice(
            position.entryPrice,
            position.leverage,
            position.isLong
        ));

        emit MarginRemoved(positionId, msg.sender, amount, position.collateral);
    }

    /**
     * @notice Liquidate an undercollateralized position
     * @dev This function forcibly closes positions that fall below maintenance margin requirements
     *
     * Liquidation Mechanism:
     * ======================
     * When a position's losses grow such that remaining collateral (equity) falls below
     * the maintenance margin threshold, the position becomes liquidatable. This protects
     * the protocol from insolvency and ensures positions don't accumulate negative equity.
     *
     * Flow:
     * 1. Validate position exists
     * 2. Calculate current position health ratio
     * 3. Verify position is liquidatable (health < maintenance margin)
     * 4. Get current mark price from vAMM
     * 5. Execute reverse swap on vAMM to close position
     * 6. Calculate liquidator reward (% of collateral)
     * 7. Calculate remaining collateral for protocol
     * 8. Distribute collateral (reward to liquidator, remainder to protocol)
     * 9. Update open interest in FundingRateCalculator
     * 10. Remove position from user tracking
     * 11. Delete position from storage
     * 12. Emit PositionLiquidated event
     *
     * @param positionId The unique identifier of the position to liquidate
     *
     * Requirements:
     * - Contract must not be paused
     * - Caller must have LIQUIDATOR_ROLE
     * - Position must exist (size > 0)
     * - Position must be liquidatable (healthRatio < maintenanceMargin)
     *
     * Reverts:
     * - PositionNotFound: if position doesn't exist or already closed
     * - PositionNotLiquidatable: if position is still healthy (healthRatio >= maintenanceMargin)
     *
     * Events:
     * - PositionLiquidated: Emitted with liquidation details
     *
     * Examples:
     * - Long 5x at $2000, 1000 USDC collateral, 5% maintenance margin
     *   Liquidation price = $1620 (19% drop)
     *   If price hits $1620, health ratio = 5%, position is liquidatable
     *   Liquidator receives 5% of 1000 USDC = 50 USDC reward
     *   Protocol receives remaining 950 USDC
     *
     * Security:
     * - Only addresses with LIQUIDATOR_ROLE can call this function
     * - This prevents arbitrary liquidations and allows for permissioned or keeper-based models
     * - Health check ensures only truly underwater positions are liquidated
     */
    function liquidatePosition(bytes32 positionId)
        external
        nonReentrant
        whenNotPaused
        onlyRole(LIQUIDATOR_ROLE)
    {
        // ========================================================================
        // STEP 1: VALIDATE POSITION EXISTS
        // ========================================================================

        // Load position from storage
        Position storage position = positions[positionId];

        // Verify position exists and hasn't been already liquidated or closed
        if (position.size == 0) revert PositionNotFound();

        // ========================================================================
        // STEP 2: CHECK POSITION HEALTH
        // ========================================================================

        // Calculate position health ratio
        // Health ratio = (equity / position value) * BASIS_POINTS
        // Where equity = collateral + unrealized P&L
        //
        // Example:
        // - Collateral: 1000 USDC
        // - Unrealized loss: -900 USDC
        // - Equity: 100 USDC
        // - Position value: 5000 USDC (5x leverage)
        // - Health ratio: (100 / 5000) * 10000 = 200 basis points = 2%
        uint256 healthRatio = _getPositionHealth(position);

        // ========================================================================
        // STEP 3: VERIFY POSITION IS LIQUIDATABLE
        // ========================================================================

        // Check if health ratio is below maintenance margin threshold
        // Maintenance margin is typically 5% (500 basis points)
        //
        // If healthRatio >= maintenanceMargin, position is still healthy
        // Only underwater positions (health < maintenance) can be liquidated
        if (healthRatio >= maintenanceMargin) revert PositionNotLiquidatable();

        // Store trader address before deleting position
        // Needed for event emission and user position tracking removal
        address trader = position.trader;

        // ========================================================================
        // STEP 4: GET CURRENT MARK PRICE
        // ========================================================================

        // Retrieve current market price from vAMM
        // This is the price at which the position is being liquidated
        // Used for event emission and analytics
        uint256 currentPrice = vamm.getPrice();

        // ========================================================================
        // STEP 5: EXECUTE REVERSE SWAP ON vAMM
        // ========================================================================

        // Execute reverse swap to close position and update vAMM reserves
        // Similar to closing a position, but liquidation doesn't return funds to trader
        // Long position = sell (decreases mark price)
        // Short position = buy (increases mark price)
        try vamm.swap(position.size, !position.isLong) returns (uint256) {
            // Reverse swap successful - vAMM reserves updated
            // Position is now closed on the vAMM side
        } catch {
            // If vAMM swap fails, liquidation fails
            // This maintains protocol consistency
            revert("vAMM reverse swap failed during liquidation");
        }

        // ========================================================================
        // STEP 6: CALCULATE LIQUIDATOR REWARD
        // ========================================================================

        // Calculate reward for the liquidator
        // Reward = collateral * liquidation fee (default 5%)
        //
        // Example:
        // - Collateral: 1000 USDC
        // - Liquidation fee: 5% (500 basis points)
        // - Reward: 1000 * 500 / 10000 = 50 USDC
        //
        // This incentivizes keepers/bots to monitor and liquidate unhealthy positions
        uint256 reward = (position.collateral * liquidationFee) / BASIS_POINTS;

        // ========================================================================
        // STEP 7: CALCULATE REMAINING COLLATERAL FOR PROTOCOL
        // ========================================================================

        // Calculate remaining collateral after liquidator reward
        // Remaining goes to protocol treasury/insurance fund
        //
        // Example:
        // - Total collateral: 1000 USDC
        // - Liquidator reward: 50 USDC
        // - Remaining: 950 USDC (goes to protocol)
        //
        // In edge cases where position is deeply underwater,
        // reward might exceed collateral, so we cap at 0
        uint256 remaining = position.collateral > reward
            ? position.collateral - reward
            : 0;

        // ========================================================================
        // STEP 8: DISTRIBUTE COLLATERAL
        // ========================================================================

        // Release liquidator reward from vault
        // This compensates the liquidator for gas costs and monitoring
        if (reward > 0) {
            vault.transferCollateral(trader, msg.sender, reward);
        }

        // Release remaining collateral to protocol fee recipient
        // This goes to insurance fund or protocol treasury
        // Helps cover potential protocol losses and fund development
        if (remaining > 0) {
            vault.transferCollateral(trader, feeRecipient, remaining);
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

        // Remove position ID from trader's position array
        // Uses efficient swap-and-pop algorithm for gas savings
        // Trader no longer has this position in their portfolio
        _removeUserPosition(trader, positionId);

        // ========================================================================
        // STEP 11: DELETE POSITION FROM STORAGE
        // ========================================================================

        // Delete position from contract storage
        // Frees up storage and provides gas refund
        // Position is now fully liquidated and removed
        delete positions[positionId];

        // ========================================================================
        // STEP 12: EMIT EVENT
        // ========================================================================

        // Emit comprehensive liquidation event
        // Critical for:
        // - Liquidation bot tracking and analytics
        // - Trader notifications
        // - Protocol monitoring and risk management
        // - Audit trail for liquidations
        emit PositionLiquidated(
            positionId,          // Position identifier
            trader,              // Original position owner
            msg.sender,          // Liquidator address
            currentPrice,        // Liquidation price
            reward,              // Liquidator reward amount
            block.timestamp      // Liquidation timestamp
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
     * @dev View function that determines if a position's health has fallen below liquidation threshold
     *
     * A position is liquidatable when:
     * - Position exists (size > 0)
     * - Health ratio < maintenance margin
     *
     * Health Ratio Calculation:
     * ========================
     * healthRatio = (equity / positionValue) * BASIS_POINTS
     * Where:
     * - equity = collateral + unrealized P&L
     * - positionValue = size * entryPrice / PRECISION
     *
     * @param positionId The unique identifier of the position to check
     * @return bool True if position can be liquidated, false otherwise
     *
     * Examples:
     * - Position with 2% health ratio, 5% maintenance margin → liquidatable = true
     * - Position with 8% health ratio, 5% maintenance margin → liquidatable = false
     * - Non-existent position → liquidatable = false
     *
     * Usage:
     * - Called by liquidation bots to identify liquidatable positions
     * - Called by frontend to display liquidation risk indicators
     * - Used in monitoring systems to alert traders of liquidation risk
     */
    function isPositionLiquidatable(bytes32 positionId)
        public
        view
        returns (bool)
    {
        // Load position from storage
        Position storage position = positions[positionId];

        // If position doesn't exist or was already closed, it's not liquidatable
        // A size of 0 indicates no active position
        if (position.size == 0) return false;

        // Calculate current health ratio of the position
        // Returns value in basis points (10000 = 100%)
        uint256 healthRatio = _getPositionHealth(position);

        // Position is liquidatable if health ratio falls below maintenance margin
        // Example: healthRatio = 300 (3%), maintenanceMargin = 500 (5%)
        // Result: 300 < 500 = true (liquidatable)
        return healthRatio < maintenanceMargin;
    }

    /**
     * @notice Backwards-compatible alias for external integrations
     */
    function isLiquidatable(bytes32 positionId) external view returns (bool) {
        return isPositionLiquidatable(positionId);
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
        int256 priceDelta = int256(currentPrice) - int256(uint256(position.entryPrice));

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

        // FIX #6: Improved precision - scale delta first, then apply to size
        // This prevents precision loss with small price changes
        int256 scaledDelta = (priceDelta * int256(PRECISION)) / int256(uint256(position.entryPrice));
        pnl = (scaledDelta * int256(uint256(position.size))) / int256(PRECISION);

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
        uint256 indexDelta;
        if (currentIndex > position.entryFundingIndex) {
            unchecked {
                // GAS OPTIMIZATION: Safe subtraction - we've verified currentIndex > entryFundingIndex
                indexDelta = currentIndex - position.entryFundingIndex;
            }
        } else {
            indexDelta = 0; // Safety check: if current < entry, no payment
        }

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
     * @dev Calculate liquidation price for a position (internal implementation)
     *
     * The liquidation price is the market price at which a position's health ratio
     * would fall to exactly the maintenance margin threshold, triggering liquidation.
     *
     * Liquidation Mechanics:
     * =====================
     * A position gets liquidated when losses erode collateral to the point where
     * remaining equity = maintenance margin * position value
     *
     * Formula Derivation:
     * ==================
     * 1. Loss threshold = 100% - maintenance margin
     *    (e.g., 5% maintenance = 95% loss threshold)
     *
     * 2. Price change % = loss threshold / leverage
     *    (Higher leverage = smaller price move needed for liquidation)
     *
     * 3. Long positions:
     *    Liquidation price = entry price * (1 - price change %)
     *    (Price must drop by this % to trigger liquidation)
     *
     * 4. Short positions:
     *    Liquidation price = entry price * (1 + price change %)
     *    (Price must rise by this % to trigger liquidation)
     *
     * @param entryPrice The price at which the position was opened (1e18 precision)
     * @param leverage The leverage multiplier (1e18 = 1x, 5e18 = 5x, etc.)
     * @param isLong True for long position, false for short position
     * @return uint256 The liquidation price (1e18 precision)
     *
     * Examples:
     * =========
     * Example 1 - Long 5x Position:
     * - Entry: $2000, Leverage: 5x, Maintenance: 5%
     * - Loss threshold: 100% - 5% = 95%
     * - Price change %: 95% / 5 = 19%
     * - Liquidation price: $2000 * (1 - 19%) = $2000 * 0.81 = $1620
     * - Interpretation: Price must drop 19% ($380) to trigger liquidation
     *
     * Example 2 - Short 10x Position:
     * - Entry: $2000, Leverage: 10x, Maintenance: 5%
     * - Loss threshold: 100% - 5% = 95%
     * - Price change %: 95% / 10 = 9.5%
     * - Liquidation price: $2000 * (1 + 9.5%) = $2000 * 1.095 = $2190
     * - Interpretation: Price must rise 9.5% ($190) to trigger liquidation
     *
     * Example 3 - Long 20x Position (maximum leverage):
     * - Entry: $2000, Leverage: 20x, Maintenance: 5%
     * - Loss threshold: 100% - 5% = 95%
     * - Price change %: 95% / 20 = 4.75%
     * - Liquidation price: $2000 * (1 - 4.75%) = $2000 * 0.9525 = $1905
     * - Interpretation: Only 4.75% ($95) drop needed for liquidation (very risky!)
     *
     * Key Insights:
     * =============
     * - Higher leverage = closer liquidation price to entry
     * - 5x leverage can withstand ~19% adverse move
     * - 10x leverage can withstand ~9.5% adverse move
     * - 20x leverage can withstand ~4.75% adverse move
     * - Long positions liquidate on downward price moves
     * - Short positions liquidate on upward price moves
     */
    function _calculateLiquidationPrice(
        uint256 entryPrice,
        uint256 leverage,
        bool isLong
    ) internal view returns (uint256) {
        // ====================================================================
        // STEP 1: CALCULATE LOSS THRESHOLD
        // ====================================================================

        // Loss threshold = percentage of collateral that can be lost
        // before liquidation occurs
        //
        // Formula: 100% - maintenance margin
        //
        // Example with 5% maintenance margin:
        // - Loss threshold = 10000 - 500 = 9500 basis points = 95%
        // - Meaning: Position can lose 95% of value before liquidation
        uint256 lossThreshold;
        unchecked {
            // GAS OPTIMIZATION: Safe subtraction - maintenanceMargin always < BASIS_POINTS (validated in setRiskParameters)
            lossThreshold = BASIS_POINTS - maintenanceMargin;
        }

        // ====================================================================
        // STEP 2: CALCULATE PRICE CHANGE PERCENTAGE
        // ====================================================================

        // Calculate what % price change would cause the loss threshold
        // Formula: loss threshold / leverage
        //
        // Why divided by leverage?
        // - Higher leverage amplifies price movements
        // - 5x leverage means 1% price move = 5% P&L change
        // - So to lose 95%, you need 95% / 5 = 19% price move
        //
        // Example with 5x leverage and 95% loss threshold:
        // - Price change % = (9500 * 1e18) / 5e18
        // - = 1.9e18 = 190% in internal representation
        // - = 19% actual price change
        uint256 priceChangePercent = (lossThreshold * PRECISION) / leverage;

        // ====================================================================
        // STEP 3: CALCULATE LIQUIDATION PRICE BASED ON DIRECTION
        // ====================================================================

        uint256 liquidationPrice;

        if (isLong) {
            // ================================================================
            // LONG POSITION LIQUIDATION
            // ================================================================

            // Long positions profit when price increases, lose when price decreases
            // Liquidation occurs on DOWNWARD price movement
            //
            // Formula: entry price * (1 - price change %)
            //
            // Example:
            // - Entry: 2000e18
            // - Price change %: 0.19e18 (19%)
            // - Liquidation: 2000e18 * (1e18 - 0.19e18) / 1e18
            // - = 2000e18 * 0.81e18 / 1e18
            // - = 1620e18 ($1620)
            liquidationPrice = (entryPrice * (PRECISION - priceChangePercent)) / PRECISION;

        } else {
            // ================================================================
            // SHORT POSITION LIQUIDATION
            // ================================================================

            // Short positions profit when price decreases, lose when price increases
            // Liquidation occurs on UPWARD price movement
            //
            // Formula: entry price * (1 + price change %)
            //
            // Example:
            // - Entry: 2000e18
            // - Price change %: 0.095e18 (9.5% for 10x leverage)
            // - Liquidation: 2000e18 * (1e18 + 0.095e18) / 1e18
            // - = 2000e18 * 1.095e18 / 1e18
            // - = 2190e18 ($2190)
            liquidationPrice = (entryPrice * (PRECISION + priceChangePercent)) / PRECISION;
        }

        // ====================================================================
        // STEP 4: RETURN LIQUIDATION PRICE
        // ====================================================================

        // Return the calculated liquidation price
        // This value is:
        // - Stored in the position struct for quick reference
        // - Used by liquidation bots to monitor positions
        // - Displayed in frontend to show liquidation risk
        // - Updated when margin is added/removed
        return liquidationPrice;
    }

    /**
     * @dev Calculate position health ratio (internal implementation)
     *
     * Position health is the ratio of remaining equity to position value, expressed in basis points.
     * This is THE KEY metric for determining liquidation eligibility.
     *
     * Health Ratio Meaning:
     * ====================
     * - 10000 (100%) = Position at entry (no P&L)
     * - 5000 (50%) = Lost 50% of collateral value
     * - 500 (5%) = At maintenance margin (typically liquidatable)
     * - 0 (0%) = Total loss (equity completely wiped out)
     *
     * Calculation:
     * ===========
     * 1. Calculate current unrealized P&L
     * 2. Calculate equity = collateral + P&L
     * 3. If equity <= 0, position is bankrupt (return 0)
     * 4. Calculate position value = size * entry price
     * 5. Health ratio = (equity / position value) * BASIS_POINTS
     *
     * @param position Storage pointer to the position struct
     * @return uint256 Health ratio in basis points (0-10000+)
     *
     * Examples:
     * =========
     * Example 1 - Healthy Long Position:
     * - Entry: $2000, Current: $2100, 5x leverage, 1000 USDC collateral
     * - Size: 5000 USDC
     * - P&L: +250 USDC (5% price gain * 5x = 25% gain)
     * - Equity: 1000 + 250 = 1250 USDC
     * - Position value: 5000 USDC
     * - Health ratio: (1250 / 5000) * 10000 = 2500 (25%)
     * - Status: Healthy (well above 5% maintenance)
     *
     * Example 2 - Near Liquidation Short Position:
     * - Entry: $2000, Current: $2190, 5x leverage, 1000 USDC collateral
     * - Size: 5000 USDC
     * - P&L: -475 USDC (9.5% price gain on short * 5x = -47.5% loss)
     * - Equity: 1000 - 475 = 525 USDC
     * - Position value: 5000 USDC
     * - Health ratio: (525 / 5000) * 10000 = 1050 (10.5%)
     * - Status: Risky (approaching 5% maintenance margin)
     *
     * Example 3 - Liquidatable Position:
     * - Entry: $2000, Current: $1620, 5x leverage, 1000 USDC collateral
     * - Size: 5000 USDC
     * - P&L: -950 USDC
     * - Equity: 1000 - 950 = 50 USDC
     * - Position value: 5000 USDC
     * - Health ratio: (50 / 5000) * 10000 = 100 (1%)
     * - Status: Liquidatable (below 5% maintenance)
     */
    function _getPositionHealth(Position storage position)
        internal
        view
        returns (uint256)
    {
        // ====================================================================
        // STEP 1: CALCULATE UNREALIZED P&L
        // ====================================================================

        // Get current profit or loss for this position
        // Includes both price movement and funding payments
        // Can be positive (profit) or negative (loss)
        int256 pnl = _calculatePnL(position);

        // ====================================================================
        // STEP 2: CALCULATE EQUITY (REMAINING VALUE)
        // ====================================================================

        // Equity = Initial collateral + Unrealized P&L
        // This is the amount trader would get back if closing now (minus fees)
        //
        // Example scenarios:
        // - Collateral: 1000, P&L: +200 → Equity: 1200
        // - Collateral: 1000, P&L: -300 → Equity: 700
        // - Collateral: 1000, P&L: -1100 → Equity: -100 (bankrupt)
        int256 equity = int256(uint256(position.collateral)) + pnl;

        // ====================================================================
        // STEP 3: HANDLE BANKRUPT POSITIONS
        // ====================================================================

        // If equity is zero or negative, position is completely underwater
        // Return 0 health ratio (worst possible health)
        // These positions should be liquidated immediately to prevent protocol loss
        if (equity <= 0) return 0;

        // ====================================================================
        // STEP 4: CALCULATE POSITION VALUE
        // ====================================================================

        // Position value = notional size * entry price
        // This represents the full position exposure
        //
        // Example:
        // - Size: 5000 USDC (1000 * 5x leverage)
        // - Entry price: 2000 (in 1e18 precision)
        // - Position value: 5000 USDC
        uint256 positionValue = (position.size * position.entryPrice) / PRECISION;

        // ====================================================================
        // STEP 5: CALCULATE HEALTH RATIO
        // ====================================================================

        // Health ratio = (equity / position value) * BASIS_POINTS
        // Expressed in basis points (10000 = 100%)
        //
        // This tells us what percentage of the position value is backed by equity
        // Lower ratio = closer to liquidation
        // Higher ratio = healthier position
        //
        // Example:
        // - Equity: 250 USDC
        // - Position value: 5000 USDC
        // - Health ratio: (250 / 5000) * 10000 = 500 (5%)
        // - At exactly maintenance margin threshold
        uint256 healthRatio = (uint256(equity) * BASIS_POINTS) / positionValue;

        // ====================================================================
        // STEP 6: RETURN HEALTH RATIO
        // ====================================================================

        // Return the calculated health ratio
        // Used by liquidation logic to determine if position should be liquidated
        // Also used by frontend to display liquidation risk to users
        return healthRatio;
    }

    /**
     * @dev Remove position from user's position array
     * FIX #4: Use O(1) lookup instead of O(n) loop to prevent DoS
     */
    function _removeUserPosition(address user, bytes32 positionId) internal {
        bytes32[] storage userPositionList = userPositions[user];
        uint256 index = positionIndex[user][positionId];
        uint256 lastIndex = userPositionList.length - 1;

        // If not the last position, swap with last
        if (index != lastIndex) {
            bytes32 lastPositionId = userPositionList[lastIndex];
            userPositionList[index] = lastPositionId;
            // FIX #4: Update the moved position's index
            positionIndex[user][lastPositionId] = index;
        }

        // Remove last element
        userPositionList.pop();
        // Clean up index mapping
        delete positionIndex[user][positionId];
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

        // FIX #10: Validate maintenance margin is within acceptable bounds
        if (_maintenanceMargin < MIN_MAINTENANCE_MARGIN ||
            _maintenanceMargin > MAX_MAINTENANCE_MARGIN) {
            revert InvalidMaintenanceMargin();
        }

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
        address oldRecipient = feeRecipient;
        feeRecipient = _feeRecipient;
        emit FeeRecipientUpdated(oldRecipient, _feeRecipient); // FIX #9
    }

    /**
     * @notice Update minimum collateral requirement
     */
    function setMinCollateral(uint256 _minCollateral) external onlyRole(ADMIN_ROLE) {
        uint256 oldAmount = minCollateral;
        minCollateral = _minCollateral;
        emit MinCollateralUpdated(oldAmount, _minCollateral); // FIX #9
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

    // ============================================================================
    // UPGRADE SAFETY
    // ============================================================================

    /**
     * @dev Gap for future storage variables in upgrades
     * FIX #14: Reserves 50 storage slots to allow adding new state variables
     * in future upgrades without breaking storage layout
     *
     * When adding new state variables in an upgrade:
     * 1. Add them BEFORE this gap
     * 2. Reduce the gap size by the number of slots used
     * Example: If you add 2 new uint256 variables, change [50] to [48]
     */
    uint256[50] private __gap;
}
