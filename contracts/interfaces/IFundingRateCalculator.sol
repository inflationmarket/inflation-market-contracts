// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IFundingRateCalculator
 * @notice Interface for calculating funding rates based on market conditions
 */
interface IFundingRateCalculator {
    event FundingRateUpdated(int256 fundingRate, uint256 timestamp);

    function calculateFundingRate() external view returns (int256);

    function updateFundingRate() external returns (int256);

    function getLastFundingRate() external view returns (int256);

    function getLastUpdateTimestamp() external view returns (uint256);

    function getFundingInterval() external view returns (uint256);
}
