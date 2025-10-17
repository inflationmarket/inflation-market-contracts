// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IIndexOracle
 * @notice Interface for fetching inflation index data from Chainlink oracles
 */
interface IIndexOracle {
    event IndexUpdated(uint256 newIndex, uint256 timestamp);
    event OracleSourceUpdated(address indexed newSource);

    function getLatestIndex() external view returns (uint256 index, uint256 timestamp);

    function getHistoricalIndex(uint256 timestamp) external view returns (uint256);

    function updateIndex() external;

    function setOracleSource(address newSource) external;

    function getIndexDecimals() external pure returns (uint8);
}
