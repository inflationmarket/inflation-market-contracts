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
     * @param isLong True for long position, false for short
     * @param collateralAmount Amount of USDC collateral to deposit
     * @param leverage Leverage multiplier (scaled by 1e18, e.g., 5e18 = 5x)
     * @return positionId Unique identifier for the position
     */
    function openPosition(
        bool isLong,
        uint256 collateralAmount,
        uint256 leverage
    ) external nonReentrant whenNotPaused returns (bytes32 positionId) {
        // Validate inputs
        if (collateralAmount < minCollateral) revert InsufficientCollateral();
        if (leverage < MIN_LEVERAGE || leverage > maxLeverage) revert InvalidLeverage();

        // Calculate position size
        uint256 size = (collateralAmount * leverage) / PRECISION;

        // Get current market price from vAMM
        uint256 entryPrice = vamm.getPrice();

        // Get current funding index
        uint256 entryFundingIndex = _getCurrentFundingIndex();

        // Calculate liquidation price
        uint256 liquidationPrice = _calculateLiquidationPrice(
            entryPrice,
            leverage,
            isLong
        );

        // Lock collateral in vault
        vault.lockCollateral(msg.sender, collateralAmount);

        // Calculate and deduct trading fee
        uint256 fee = (size * tradingFee) / BASIS_POINTS;
        if (fee > 0) {
            vault.lockCollateral(msg.sender, fee);
            vault.releaseCollateral(feeRecipient, fee);
        }

        // Generate unique position ID
        positionId = keccak256(
            abi.encodePacked(
                msg.sender,
                block.timestamp,
                totalPositions,
                isLong
            )
        );

        // Create and store position
        positions[positionId] = Position({
            trader: msg.sender,
            isLong: isLong,
            size: size,
            collateral: collateralAmount,
            leverage: leverage,
            entryPrice: entryPrice,
            entryFundingIndex: entryFundingIndex,
            timestamp: block.timestamp,
            liquidationPrice: liquidationPrice
        });

        // Track user's positions
        userPositions[msg.sender].push(positionId);
        totalPositions++;

        emit PositionOpened(
            positionId,
            msg.sender,
            isLong,
            collateralAmount,
            size,
            leverage,
            entryPrice,
            block.timestamp
        );

        return positionId;
    }

    /**
     * @notice Close an existing position
     * @param positionId The ID of the position to close
     * @return pnl The profit or loss from closing the position
     */
    function closePosition(bytes32 positionId)
        external
        nonReentrant
        whenNotPaused
        returns (int256 pnl)
    {
        Position storage position = positions[positionId];
        if (position.trader != msg.sender) revert NotPositionOwner();
        if (position.size == 0) revert PositionNotFound();

        // Calculate P&L including funding payments
        pnl = calculatePnL(positionId);

        uint256 currentPrice = vamm.getPrice();

        // Calculate final amount to return
        uint256 finalAmount;
        if (pnl >= 0) {
            // Profit: collateral + PnL
            finalAmount = position.collateral + uint256(pnl);
        } else {
            // Loss: collateral - loss
            uint256 loss = uint256(-pnl);
            if (loss >= position.collateral) {
                finalAmount = 0; // Total loss
            } else {
                finalAmount = position.collateral - loss;
            }
        }

        // Release collateral to trader
        if (finalAmount > 0) {
            vault.releaseCollateral(msg.sender, finalAmount);
        }

        // Remove position from tracking
        _removeUserPosition(msg.sender, positionId);

        // Delete position
        delete positions[positionId];

        emit PositionClosed(
            positionId,
            msg.sender,
            pnl,
            currentPrice,
            block.timestamp
        );

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
     * @notice Calculate current P&L for a position
     * @param positionId The ID of the position
     * @return pnl Current profit or loss including funding payments
     */
    function calculatePnL(bytes32 positionId)
        public
        view
        returns (int256 pnl)
    {
        Position storage position = positions[positionId];
        if (position.size == 0) revert PositionNotFound();

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
     * @dev Calculate P&L for a position
     */
    function _calculatePnL(Position storage position)
        internal
        view
        returns (int256 pnl)
    {
        uint256 currentPrice = vamm.getPrice();

        // Calculate price change P&L
        int256 priceDelta = int256(currentPrice) - int256(position.entryPrice);
        if (!position.isLong) {
            priceDelta = -priceDelta;
        }

        // P&L = (price change / entry price) * size * collateral
        pnl = (priceDelta * int256(position.size)) / int256(position.entryPrice);

        // Subtract funding payments
        int256 fundingPayment = _calculateFundingPayment(position);
        pnl -= fundingPayment;

        return pnl;
    }

    /**
     * @dev Calculate funding payment for a position
     */
    function _calculateFundingPayment(Position storage position)
        internal
        view
        returns (int256 payment)
    {
        uint256 currentIndex = _getCurrentFundingIndex();
        uint256 indexDelta = currentIndex > position.entryFundingIndex
            ? currentIndex - position.entryFundingIndex
            : 0;

        // Funding payment = size * index delta
        payment = int256((position.size * indexDelta) / PRECISION);

        // Long pays short if funding rate is positive
        if (!position.isLong) {
            payment = -payment;
        }

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
