// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IPositionManager
 * @notice Interface for managing perpetual positions in the Inflation Market
 */
interface IPositionManager {
    // ============================================================================
    // STRUCTS
    // ============================================================================

    struct Position {
        address trader;
        uint256 collateral; // USDC collateral
        uint256 size; // Position size in index units
        uint256 entryPrice; // Entry price (scaled by 1e18)
        uint256 entryFundingRate; // Funding rate at entry
        bool isLong; // True for long, false for short
        uint256 lastUpdateTimestamp;
        uint256 leverage; // Leverage multiplier (e.g., 5 = 5x)
    }

    // ============================================================================
    // EVENTS
    // ============================================================================

    event PositionOpened(
        bytes32 indexed positionId,
        address indexed trader,
        uint256 collateral,
        uint256 size,
        uint256 entryPrice,
        uint256 leverage,
        bool isLong
    );

    event PositionClosed(
        bytes32 indexed positionId,
        address indexed trader,
        int256 pnl,
        uint256 closingPrice
    );

    event PositionLiquidated(
        bytes32 indexed positionId,
        address indexed trader,
        address indexed liquidator,
        uint256 liquidationPrice
    );

    event CollateralAdded(
        bytes32 indexed positionId,
        address indexed trader,
        uint256 amount
    );

    event CollateralRemoved(
        bytes32 indexed positionId,
        address indexed trader,
        uint256 amount
    );

    // ============================================================================
    // FUNCTIONS
    // ============================================================================

    function openPosition(
        uint256 collateral,
        uint256 leverage,
        bool isLong
    ) external returns (bytes32 positionId);

    function closePosition(bytes32 positionId) external returns (int256 pnl);

    function addCollateral(bytes32 positionId, uint256 amount) external;

    function removeCollateral(bytes32 positionId, uint256 amount) external;

    function liquidatePosition(bytes32 positionId) external;

    function getPosition(bytes32 positionId) external view returns (Position memory);

    function calculatePnL(bytes32 positionId) external view returns (int256);

    function getPositionHealth(bytes32 positionId) external view returns (uint256);

    function isLiquidatable(bytes32 positionId) external view returns (bool);
}
