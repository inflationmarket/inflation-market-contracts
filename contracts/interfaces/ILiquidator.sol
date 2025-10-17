// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ILiquidator
 * @notice Interface for liquidating undercollateralized positions
 */
interface ILiquidator {
    event PositionLiquidated(
        bytes32 indexed positionId,
        address indexed liquidator,
        uint256 reward
    );

    event LiquidationThresholdUpdated(uint256 newThreshold);

    function liquidate(bytes32 positionId) external returns (uint256 reward);

    function canLiquidate(bytes32 positionId) external view returns (bool);

    function calculateLiquidationReward(bytes32 positionId) external view returns (uint256);

    function setLiquidationThreshold(uint256 threshold) external;

    function getLiquidationThreshold() external view returns (uint256);
}
