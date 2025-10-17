// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import "./interfaces/IPositionManager.sol";
import "./interfaces/IVault.sol";
import "./interfaces/IIndexOracle.sol";
import "./interfaces/IFundingRateCalculator.sol";
import "./interfaces/IvAMM.sol";

/**
 * @title PositionManager
 * @notice THE HEART - Core contract for managing perpetual positions in Inflation Market
 * @dev Handles position lifecycle: open, modify, close, liquidate
 */
contract PositionManager is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    IPositionManager
{
    // ============================================================================
    // STATE VARIABLES
    // ============================================================================

    // Core protocol contracts
    IVault public vault;
    IIndexOracle public indexOracle;
    IFundingRateCalculator public fundingRateCalculator;
    IvAMM public vamm;

    // Position tracking
    mapping(bytes32 => Position) public positions;
    mapping(address => bytes32[]) public userPositions;
    uint256 public totalPositions;

    // Protocol parameters
    uint256 public constant LIQUIDATION_THRESHOLD = 8000; // 80% (out of 10000)
    uint256 public constant MIN_LEVERAGE = 1e18; // 1x
    uint256 public constant MAX_LEVERAGE = 20e18; // 20x
    uint256 public constant MIN_COLLATERAL = 10e6; // 10 USDC (6 decimals)
    uint256 public constant PRICE_PRECISION = 1e18;
    uint256 public constant BASIS_POINTS = 10000;

    // Fees
    uint256 public tradingFee; // In basis points (e.g., 10 = 0.1%)
    uint256 public protocolFeeShare; // Percentage of fees going to protocol
    address public feeRecipient;

    // ============================================================================
    // INITIALIZATION
    // ============================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _vault,
        address _indexOracle,
        address _fundingRateCalculator,
        address _vamm,
        address _feeRecipient
    ) public initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        require(_vault != address(0), "Invalid vault");
        require(_indexOracle != address(0), "Invalid oracle");
        require(_fundingRateCalculator != address(0), "Invalid funding calculator");
        require(_vamm != address(0), "Invalid vAMM");
        require(_feeRecipient != address(0), "Invalid fee recipient");

        vault = IVault(_vault);
        indexOracle = IIndexOracle(_indexOracle);
        fundingRateCalculator = IFundingRateCalculator(_fundingRateCalculator);
        vamm = IvAMM(_vamm);
        feeRecipient = _feeRecipient;

        tradingFee = 10; // 0.1%
        protocolFeeShare = 5000; // 50%
    }

    // ============================================================================
    // CORE POSITION FUNCTIONS
    // ============================================================================

    /**
     * @notice Open a new perpetual position
     * @param collateral Amount of USDC collateral to deposit
     * @param leverage Leverage multiplier (scaled by 1e18)
     * @param isLong True for long position, false for short
     * @return positionId Unique identifier for the position
     */
    function openPosition(
        uint256 collateral,
        uint256 leverage,
        bool isLong
    ) external override nonReentrant whenNotPaused returns (bytes32 positionId) {
        require(collateral >= MIN_COLLATERAL, "Collateral too low");
        require(leverage >= MIN_LEVERAGE && leverage <= MAX_LEVERAGE, "Invalid leverage");

        // Lock collateral in vault
        vault.lockCollateral(msg.sender, collateral);

        // Calculate position size
        uint256 size = (collateral * leverage) / PRICE_PRECISION;

        // Get current price from vAMM
        uint256 currentPrice = vamm.getPrice();

        // Get current funding rate
        int256 currentFundingRate = fundingRateCalculator.getLastFundingRate();

        // Generate position ID
        positionId = keccak256(
            abi.encodePacked(msg.sender, block.timestamp, totalPositions)
        );

        // Create position
        positions[positionId] = Position({
            trader: msg.sender,
            collateral: collateral,
            size: size,
            entryPrice: currentPrice,
            entryFundingRate: uint256(currentFundingRate > 0 ? currentFundingRate : -currentFundingRate),
            isLong: isLong,
            lastUpdateTimestamp: block.timestamp,
            leverage: leverage
        });

        // Track user positions
        userPositions[msg.sender].push(positionId);
        totalPositions++;

        emit PositionOpened(
            positionId,
            msg.sender,
            collateral,
            size,
            currentPrice,
            leverage,
            isLong
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
        override
        nonReentrant
        whenNotPaused
        returns (int256 pnl)
    {
        Position storage position = positions[positionId];
        require(position.trader == msg.sender, "Not position owner");
        require(position.size > 0, "Position does not exist");

        // Calculate PnL
        pnl = _calculatePnL(position);

        // Get current price for event
        uint256 currentPrice = vamm.getPrice();

        // Release collateral with PnL adjustment
        uint256 finalCollateral;
        if (pnl >= 0) {
            finalCollateral = position.collateral + uint256(pnl);
        } else {
            uint256 loss = uint256(-pnl);
            finalCollateral = position.collateral > loss ? position.collateral - loss : 0;
        }

        vault.releaseCollateral(msg.sender, finalCollateral);

        // Clean up position
        delete positions[positionId];
        _removeUserPosition(msg.sender, positionId);

        emit PositionClosed(positionId, msg.sender, pnl, currentPrice);

        return pnl;
    }

    /**
     * @notice Add collateral to an existing position
     * @param positionId The ID of the position
     * @param amount Amount of collateral to add
     */
    function addCollateral(bytes32 positionId, uint256 amount)
        external
        override
        nonReentrant
        whenNotPaused
    {
        Position storage position = positions[positionId];
        require(position.trader == msg.sender, "Not position owner");
        require(position.size > 0, "Position does not exist");
        require(amount > 0, "Amount must be positive");

        // Lock additional collateral
        vault.lockCollateral(msg.sender, amount);
        position.collateral += amount;

        emit CollateralAdded(positionId, msg.sender, amount);
    }

    /**
     * @notice Remove collateral from an existing position
     * @param positionId The ID of the position
     * @param amount Amount of collateral to remove
     */
    function removeCollateral(bytes32 positionId, uint256 amount)
        external
        override
        nonReentrant
        whenNotPaused
    {
        Position storage position = positions[positionId];
        require(position.trader == msg.sender, "Not position owner");
        require(position.size > 0, "Position does not exist");
        require(amount > 0, "Amount must be positive");
        require(amount < position.collateral, "Cannot remove all collateral");

        // Check if position remains healthy after removal
        position.collateral -= amount;
        require(getPositionHealth(positionId) > LIQUIDATION_THRESHOLD, "Position unhealthy");

        vault.releaseCollateral(msg.sender, amount);

        emit CollateralRemoved(positionId, msg.sender, amount);
    }

    /**
     * @notice Liquidate an undercollateralized position
     * @param positionId The ID of the position to liquidate
     */
    function liquidatePosition(bytes32 positionId)
        external
        override
        nonReentrant
        whenNotPaused
    {
        Position storage position = positions[positionId];
        require(position.size > 0, "Position does not exist");
        require(isLiquidatable(positionId), "Position not liquidatable");

        address trader = position.trader;
        uint256 currentPrice = vamm.getPrice();

        // Calculate liquidation reward (5% of collateral)
        uint256 liquidationReward = (position.collateral * 500) / BASIS_POINTS;

        // Release remaining collateral to protocol
        uint256 remainingCollateral = position.collateral > liquidationReward
            ? position.collateral - liquidationReward
            : 0;

        if (liquidationReward > 0) {
            vault.releaseCollateral(msg.sender, liquidationReward);
        }

        if (remainingCollateral > 0) {
            vault.releaseCollateral(feeRecipient, remainingCollateral);
        }

        // Clean up position
        delete positions[positionId];
        _removeUserPosition(trader, positionId);

        emit PositionLiquidated(positionId, trader, msg.sender, currentPrice);
    }

    // ============================================================================
    // VIEW FUNCTIONS
    // ============================================================================

    /**
     * @notice Get position details
     * @param positionId The ID of the position
     * @return position The position struct
     */
    function getPosition(bytes32 positionId)
        external
        view
        override
        returns (Position memory)
    {
        return positions[positionId];
    }

    /**
     * @notice Calculate current PnL for a position
     * @param positionId The ID of the position
     * @return pnl Current profit or loss
     */
    function calculatePnL(bytes32 positionId)
        external
        view
        override
        returns (int256 pnl)
    {
        Position storage position = positions[positionId];
        require(position.size > 0, "Position does not exist");
        return _calculatePnL(position);
    }

    /**
     * @notice Get position health ratio
     * @param positionId The ID of the position
     * @return healthRatio Health ratio (10000 = 100%)
     */
    function getPositionHealth(bytes32 positionId)
        public
        view
        override
        returns (uint256 healthRatio)
    {
        Position storage position = positions[positionId];
        require(position.size > 0, "Position does not exist");

        int256 pnl = _calculatePnL(position);
        int256 effectiveCollateral = int256(position.collateral) + pnl;

        if (effectiveCollateral <= 0) {
            return 0;
        }

        // Health ratio = effective collateral / required collateral
        uint256 requiredCollateral = (position.size * PRICE_PRECISION) / position.leverage;
        healthRatio = (uint256(effectiveCollateral) * BASIS_POINTS) / requiredCollateral;

        return healthRatio;
    }

    /**
     * @notice Check if a position can be liquidated
     * @param positionId The ID of the position
     * @return liquidatable True if position can be liquidated
     */
    function isLiquidatable(bytes32 positionId)
        public
        view
        override
        returns (bool liquidatable)
    {
        Position storage position = positions[positionId];
        if (position.size == 0) return false;

        uint256 health = getPositionHealth(positionId);
        return health < LIQUIDATION_THRESHOLD;
    }

    /**
     * @notice Get all positions for a user
     * @param user The user address
     * @return positionIds Array of position IDs
     */
    function getUserPositions(address user)
        external
        view
        returns (bytes32[] memory positionIds)
    {
        return userPositions[user];
    }

    // ============================================================================
    // INTERNAL FUNCTIONS
    // ============================================================================

    /**
     * @dev Internal function to calculate PnL
     */
    function _calculatePnL(Position storage position)
        internal
        view
        returns (int256 pnl)
    {
        uint256 currentPrice = vamm.getPrice();
        int256 priceDelta = int256(currentPrice) - int256(position.entryPrice);

        if (!position.isLong) {
            priceDelta = -priceDelta;
        }

        // PnL = (price change * size) / entry price
        pnl = (priceDelta * int256(position.size)) / int256(position.entryPrice);

        // Apply funding rate (simplified)
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
        returns (int256 fundingPayment)
    {
        int256 currentFundingRate = fundingRateCalculator.getLastFundingRate();
        uint256 timeDelta = block.timestamp - position.lastUpdateTimestamp;

        // Simplified funding calculation
        fundingPayment = (int256(position.size) * currentFundingRate * int256(timeDelta)) /
                        (int256(PRICE_PRECISION) * 86400); // Daily funding

        return fundingPayment;
    }

    /**
     * @dev Remove position from user's position array
     */
    function _removeUserPosition(address user, bytes32 positionId) internal {
        bytes32[] storage positions = userPositions[user];
        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i] == positionId) {
                positions[i] = positions[positions.length - 1];
                positions.pop();
                break;
            }
        }
    }

    // ============================================================================
    // ADMIN FUNCTIONS
    // ============================================================================

    function setTradingFee(uint256 _tradingFee) external onlyOwner {
        require(_tradingFee <= 100, "Fee too high"); // Max 1%
        tradingFee = _tradingFee;
    }

    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        require(_feeRecipient != address(0), "Invalid address");
        feeRecipient = _feeRecipient;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyOwner
    {}
}
