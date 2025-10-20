// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IFundingRateCalculator
 * @notice Interface for calculating and managing funding rates
 * @dev The "hypothalamus" - regulates internal balance between longs and shorts
 */
interface IFundingRateCalculator {
    // ============================================================================
    // VIEW FUNCTIONS
    // ============================================================================

    /**
     * @notice Get current funding rate
     * @return Current funding rate (can be negative)
     * @dev Positive = longs pay shorts, Negative = shorts pay longs
     */
    function currentFundingRate() external view returns (int256);

    /**
     * @notice Get funding rate as annualized percentage
     * @return Funding rate in APR terms
     * @dev Converts hourly rate to annual: rate * 24 * 365
     */
    function getFundingRateAPR() external view returns (int256);

    /**
     * @notice Get long funding index
     * @return Cumulative funding index for long positions
     */
    function longFundingIndex() external view returns (int256);

    /**
     * @notice Get short funding index
     * @return Cumulative funding index for short positions
     */
    function shortFundingIndex() external view returns (int256);

    /**
     * @notice Get last funding update timestamp
     * @return Timestamp of last funding rate calculation
     */
    function lastFundingTime() external view returns (uint256);

    /**
     * @notice Get funding interval
     * @return Funding calculation interval in seconds (e.g., 3600 = hourly)
     */
    function fundingInterval() external view returns (uint256);

    /**
     * @notice Get total long open interest
     * @return Total notional value of all long positions
     */
    function totalLongOpenInterest() external view returns (uint256);

    /**
     * @notice Get total short open interest
     * @return Total notional value of all short positions
     */
    function totalShortOpenInterest() external view returns (uint256);

    /**
     * @notice Get funding rate coefficient
     * @return Coefficient used in funding rate calculation
     */
    function fundingRateCoefficient() external view returns (uint256);

    /**
     * @notice Get maximum funding rate
     * @return Max funding rate cap (positive)
     */
    function maxFundingRate() external view returns (uint256);

    /**
     * @notice Get minimum funding rate
     * @return Min funding rate floor (negative)
     */
    function minFundingRate() external view returns (uint256);

    // ============================================================================
    // STATE-CHANGING FUNCTIONS
    // ============================================================================

    /**
     * @notice Calculate and update funding rate
     * @param markPrice Current market price from vAMM
     * @param indexPrice Oracle price from IndexOracle
     * @dev Only callable by PositionManager
     * @dev Updates funding indices for both longs and shorts
     */
    function updateFundingRate(
        uint256 markPrice,
        uint256 indexPrice
    ) external;

    /**
     * @notice Calculate funding payment for a position
     * @param isLong Position direction (true = long, false = short)
     * @param size Position size in USD
     * @param entryFundingIndex Funding index when position opened
     * @return Funding payment (positive = receive, negative = pay)
     */
    function calculateFundingPayment(
        bool isLong,
        uint256 size,
        int256 entryFundingIndex
    ) external view returns (int256);

    /**
     * @notice Update open interest tracking
     * @param isLong Position direction
     * @param sizeDelta Change in position size
     * @param isIncrease true = opening/increasing, false = closing/decreasing
     * @dev Only callable by PositionManager
     */
    function updateOpenInterest(
        bool isLong,
        uint256 sizeDelta,
        bool isIncrease
    ) external;

    /**
     * @notice Set funding rate coefficient
     * @param _coefficient New coefficient
     * @dev Only callable by governance
     */
    function setFundingRateCoefficient(uint256 _coefficient) external;

    /**
     * @notice Set maximum funding rate
     * @param _maxRate New maximum rate
     * @dev Only callable by governance
     */
    function setMaxFundingRate(uint256 _maxRate) external;

    /**
     * @notice Set minimum funding rate
     * @param _minRate New minimum rate
     * @dev Only callable by governance
     */
    function setMinFundingRate(uint256 _minRate) external;

    /**
     * @notice Set funding interval
     * @param _interval New interval in seconds
     * @dev Only callable by governance
     */
    function setFundingInterval(uint256 _interval) external;

    // ============================================================================
    // EVENTS
    // ============================================================================

    /**
     * @notice Emitted when funding rate is updated
     * @param rate New funding rate
     * @param timestamp Update timestamp
     */
    event FundingRateUpdated(int256 rate, uint256 timestamp);

    /**
     * @notice Emitted when open interest changes
     * @param longOI Total long open interest
     * @param shortOI Total short open interest
     */
    event OpenInterestUpdated(uint256 longOI, uint256 shortOI);

    /**
     * @notice Emitted when funding payment is processed
     * @param positionId Position identifier
     * @param payment Funding payment amount
     */
    event FundingPaymentProcessed(bytes32 indexed positionId, int256 payment);

    /**
     * @notice Emitted when parameters are updated
     * @param coefficient Funding rate coefficient
     * @param maxRate Maximum funding rate
     * @param minRate Minimum funding rate
     */
    event FundingParametersUpdated(
        uint256 coefficient,
        uint256 maxRate,
        uint256 minRate
    );

    // ============================================================================
    // ERRORS
    // ============================================================================

    /// @notice Thrown when trying to update funding too soon
    error FundingUpdateTooSoon();

    /// @notice Thrown when invalid funding parameters provided
    error InvalidFundingParameters();
}
