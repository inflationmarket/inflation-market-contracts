// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IvAMM
 * @notice Interface for the virtual Automated Market Maker
 * @dev Provides Mark Price via virtual reserves (no real tokens held)
 */
interface IvAMM {
    // ============================================================================
    // VIEW FUNCTIONS
    // ============================================================================

    /**
     * @notice Get current mark price
     * @return Mark price with 18 decimal precision
     * @dev Price = virtualQuoteAssetReserve / virtualBaseAssetReserve
     */
    function getMarkPrice() external view returns (uint256);

    /**
     * @notice Calculate mark price after a hypothetical trade
     * @param size Notional size (positive = long, negative = short)
     * @return newMarkPrice Mark price after trade
     * @return priceImpact Price impact percentage (basis points)
     * @dev Does not execute trade, only simulates impact
     */
    function getPriceForTrade(
        int256 size
    ) external view returns (uint256 newMarkPrice, uint256 priceImpact);

    /**
     * @notice Get virtual base asset reserve
     * @return Base reserve amount
     */
    function virtualBaseAssetReserve() external view returns (uint256);

    /**
     * @notice Get virtual quote asset reserve
     * @return Quote reserve amount
     */
    function virtualQuoteAssetReserve() external view returns (uint256);

    /**
     * @notice Get constant product k
     * @return k value (baseReserve * quoteReserve)
     */
    function k() external view returns (uint256);

    /**
     * @notice Get last cached mark price
     * @return Last mark price
     */
    function lastMarkPrice() external view returns (uint256);

    /**
     * @notice Get timestamp of last price update
     * @return Last update timestamp
     */
    function lastPriceUpdateTime() external view returns (uint256);

    /**
     * @notice Get total long open interest
     * @return Long open interest
     */
    function totalLongOpenInterest() external view returns (uint256);

    /**
     * @notice Get total short open interest
     * @return Short open interest
     */
    function totalShortOpenInterest() external view returns (uint256);

    /**
     * @notice Get maximum allowed price impact
     * @return Max price impact in basis points
     */
    function maxPriceImpact() external view returns (uint256);

    // ============================================================================
    // STATE-CHANGING FUNCTIONS
    // ============================================================================

    /**
     * @notice Update virtual reserves after a trade
     * @param size Notional size (positive = long opens, negative = short opens)
     * @dev Only callable by PositionManager
     * @dev Updates reserves and recalculates mark price
     */
    function updateReserves(int256 size) external;

    /**
     * @notice Rebalance reserves to anchor toward Index Price
     * @param indexPrice Current oracle price
     * @dev Only callable by keeper
     * @dev Adjusts reserves to reduce mark/index divergence
     */
    function rebalanceToIndex(uint256 indexPrice) external;

    /**
     * @notice Initialize the vAMM with starting reserves
     * @param baseReserve Initial base asset reserve
     * @param quoteReserve Initial quote asset reserve
     * @dev Only callable once by owner
     * @dev Sets k = baseReserve * quoteReserve
     */
    function initialize(uint256 baseReserve, uint256 quoteReserve) external;

    /**
     * @notice Set maximum price impact
     * @param _maxPriceImpact New max impact in basis points
     * @dev Only callable by governance
     */
    function setMaxPriceImpact(uint256 _maxPriceImpact) external;

    /**
     * @notice Set position manager address
     * @param _positionManager PositionManager contract address
     * @dev Only callable by owner
     */
    function setPositionManager(address _positionManager) external;

    // ============================================================================
    // EVENTS
    // ============================================================================

    /**
     * @notice Emitted when reserves are updated
     * @param baseReserve New base reserve
     * @param quoteReserve New quote reserve
     */
    event ReservesUpdated(uint256 baseReserve, uint256 quoteReserve);

    /**
     * @notice Emitted when mark price updates
     * @param price New mark price
     * @param timestamp Update timestamp
     */
    event MarkPriceUpdated(uint256 price, uint256 timestamp);

    /**
     * @notice Emitted when reserves are rebalanced
     * @param baseReserve New base reserve
     * @param quoteReserve New quote reserve
     */
    event ReservesRebalanced(uint256 baseReserve, uint256 quoteReserve);

    /**
     * @notice Emitted when vAMM is initialized
     * @param baseReserve Initial base reserve
     * @param quoteReserve Initial quote reserve
     */
    event VammInitialized(uint256 baseReserve, uint256 quoteReserve);

    /**
     * @notice Emitted when max price impact changes
     * @param oldImpact Previous max impact
     * @param newImpact New max impact
     */
    event MaxPriceImpactUpdated(uint256 oldImpact, uint256 newImpact);

    // ============================================================================
    // ERRORS
    // ============================================================================

    /// @notice Thrown when price impact exceeds maximum
    error PriceImpactTooHigh();

    /// @notice Thrown when vAMM already initialized
    error AlreadyInitialized();

    /// @notice Thrown when invalid reserve amounts provided
    error InvalidReserves();

    /// @notice Thrown when trade size would drain reserves
    error InsufficientLiquidity();
}
