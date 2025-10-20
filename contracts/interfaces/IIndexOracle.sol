// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IIndexOracle
 * @notice Interface for the Index Oracle that provides Real Yield data
 * @dev The "eyes and ears" - provides sensory input about economic conditions
 */
interface IIndexOracle {
    // ============================================================================
    // VIEW FUNCTIONS
    // ============================================================================

    /**
     * @notice Get current Index Price (Real Yield index)
     * @return Current index price with 18 decimal precision
     * @dev Reverts if oracle data is stale (>2x update interval)
     */
    function getIndexPrice() external view returns (uint256);

    /**
     * @notice Get time-weighted average Index Price
     * @param periods Number of historical periods to average
     * @return TWAP of index price
     * @dev Used for funding rate calculations to smooth volatility
     */
    function getTWAP(uint256 periods) external view returns (uint256);

    /**
     * @notice Get the last calculated annual real yield
     * @return Annual real yield (can be negative)
     * @dev Real Yield = Treasury Yield - Inflation Rate
     */
    function lastAnnualRealYield() external view returns (int256);

    /**
     * @notice Get timestamp of last update
     * @return Timestamp when index was last updated
     */
    function lastUpdateTime() external view returns (uint256);

    /**
     * @notice Get update interval in seconds
     * @return Update interval (e.g., 3600 = hourly)
     */
    function updateInterval() external view returns (uint256);

    /**
     * @notice Get historical price at specific index
     * @param index History array index
     * @return Historical price
     */
    function priceHistory(uint256 index) external view returns (uint256);

    /**
     * @notice Get Chainlink CPI data feed address
     * @return CPI oracle address
     */
    function cpiDataFeed() external view returns (address);

    /**
     * @notice Get Chainlink Treasury yield data feed address
     * @return Treasury yield oracle address
     */
    function treasuryYieldFeed() external view returns (address);

    // ============================================================================
    // STATE-CHANGING FUNCTIONS
    // ============================================================================

    /**
     * @notice Fetch latest data and update Index Price
     * @dev Called by Chainlink Automation or keeper
     * @dev Performs continuous compounding based on real yield
     * @dev Only callable if sufficient time has passed since last update
     */
    function updateIndexPrice() external;

    /**
     * @notice Emergency manual price update
     * @param price New index price
     * @dev Only callable by owner/admin
     */
    function setIndexPriceManual(uint256 price) external;

    /**
     * @notice Update Chainlink oracle feed addresses
     * @param _cpiDataFeed New CPI oracle address
     * @param _treasuryYieldFeed New Treasury yield oracle address
     */
    function setOracleFeeds(
        address _cpiDataFeed,
        address _treasuryYieldFeed
    ) external;

    /**
     * @notice Set update interval
     * @param _updateInterval New interval in seconds
     */
    function setUpdateInterval(uint256 _updateInterval) external;

    /**
     * @notice Set maximum allowed price deviation
     * @param _maxDeviation Max deviation in basis points
     */
    function setMaxPriceDeviation(uint256 _maxDeviation) external;

    // ============================================================================
    // EVENTS
    // ============================================================================

    /**
     * @notice Emitted when index price is updated
     * @param price New index price
     * @param annualRealYield Current annual real yield rate
     * @param timestamp Update timestamp
     */
    event IndexPriceUpdated(
        uint256 indexed price,
        int256 annualRealYield,
        uint256 timestamp
    );

    /**
     * @notice Emitted when price is manually updated
     * @param price New price
     * @param timestamp Update timestamp
     */
    event ManualPriceUpdate(uint256 price, uint256 timestamp);

    /**
     * @notice Emitted when oracle feeds are updated
     * @param cpiOracle New CPI oracle address
     * @param treasuryOracle New Treasury yield oracle address
     */
    event OracleFeedUpdated(address cpiOracle, address treasuryOracle);

    /**
     * @notice Emitted when update interval changes
     * @param oldInterval Previous interval
     * @param newInterval New interval
     */
    event UpdateIntervalChanged(uint256 oldInterval, uint256 newInterval);

    // ============================================================================
    // ERRORS
    // ============================================================================

    /// @notice Thrown when trying to update too soon
    error UpdateTooSoon();

    /// @notice Thrown when oracle data is stale
    error OracleDataStale();

    /// @notice Thrown when price deviation exceeds max allowed
    error PriceDeviationTooHigh();

    /// @notice Thrown when invalid price provided
    error InvalidPrice();
}
