// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import "./interfaces/ILiquidator.sol";
import "./interfaces/IPositionManager.sol";

/**
 * @title Liquidator
 * @notice Handles liquidation of undercollateralized positions
 * @dev Provides incentives for liquidators to maintain protocol solvency
 */
contract Liquidator is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ILiquidator
{
    // ============================================================================
    // STATE VARIABLES
    // ============================================================================

    IPositionManager public positionManager;
    uint256 public liquidationThreshold; // Threshold for liquidation (e.g., 8000 = 80%)
    uint256 public liquidationRewardBps; // Reward in basis points (e.g., 500 = 5%)

    uint256 public constant BASIS_POINTS = 10000;

    // ============================================================================
    // INITIALIZATION
    // ============================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _positionManager,
        uint256 _liquidationThreshold,
        uint256 _liquidationRewardBps
    ) public initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();

        require(_positionManager != address(0), "Invalid PositionManager");
        require(_liquidationThreshold < BASIS_POINTS, "Invalid threshold");
        require(_liquidationRewardBps < BASIS_POINTS, "Invalid reward");

        positionManager = IPositionManager(_positionManager);
        liquidationThreshold = _liquidationThreshold;
        liquidationRewardBps = _liquidationRewardBps;
    }

    // ============================================================================
    // CORE FUNCTIONS
    // ============================================================================

    /**
     * @notice Liquidate an undercollateralized position
     * @param positionId ID of the position to liquidate
     * @return reward Liquidation reward paid to caller
     */
    function liquidate(bytes32 positionId)
        external
        override
        returns (uint256 reward)
    {
        require(canLiquidate(positionId), "Position not liquidatable");

        // Calculate reward before liquidation
        reward = calculateLiquidationReward(positionId);

        // Trigger liquidation in PositionManager
        positionManager.liquidatePosition(positionId);

        emit PositionLiquidated(positionId, msg.sender, reward);
        return reward;
    }

    /**
     * @notice Check if a position can be liquidated
     * @param positionId ID of the position
     * @return liquidatable True if position is liquidatable
     */
    function canLiquidate(bytes32 positionId)
        public
        view
        override
        returns (bool liquidatable)
    {
        return positionManager.isPositionLiquidatable(positionId);
    }

    /**
     * @notice Calculate liquidation reward for a position
     * @param positionId ID of the position
     * @return reward Reward amount
     */
    function calculateLiquidationReward(bytes32 positionId)
        public
        view
        override
        returns (uint256 reward)
    {
        IPositionManager.Position memory position = positionManager.getPosition(positionId);

        // Reward = liquidationRewardBps % of collateral
        reward = (position.collateral * liquidationRewardBps) / BASIS_POINTS;

        return reward;
    }

    /**
     * @notice Set new liquidation threshold
     * @param threshold New threshold value
     */
    function setLiquidationThreshold(uint256 threshold)
        external
        override
        onlyOwner
    {
        require(threshold < BASIS_POINTS, "Invalid threshold");
        liquidationThreshold = threshold;
        emit LiquidationThresholdUpdated(threshold);
    }

    /**
     * @notice Get current liquidation threshold
     * @return threshold Current threshold
     */
    function getLiquidationThreshold()
        external
        view
        override
        returns (uint256 threshold)
    {
        return liquidationThreshold;
    }

    // ============================================================================
    // ADMIN FUNCTIONS
    // ============================================================================

    function setLiquidationReward(uint256 _liquidationRewardBps)
        external
        onlyOwner
    {
        require(_liquidationRewardBps < BASIS_POINTS, "Invalid reward");
        liquidationRewardBps = _liquidationRewardBps;
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyOwner
    {}
}
