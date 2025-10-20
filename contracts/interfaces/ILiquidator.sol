// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ILiquidator
 * @notice Interface for automated position liquidation
 * @dev The "immune system" - removes threats (underwater positions)
 */
interface ILiquidator {
    // ============================================================================
    // VIEW FUNCTIONS
    // ============================================================================

    /**
     * @notice Check if a position is liquidatable
     * @param positionId Position identifier
     * @return true if position can be liquidated
     * @dev Position is liquidatable when margin ratio < maintenance margin
     */
    function isLiquidatable(bytes32 positionId) external view returns (bool);

    /**
     * @notice Get liquidation fee percentage
     * @return Fee percentage in basis points
     */
    function liquidationFeePercent() external view returns (uint256);

    /**
     * @notice Get liquidator reward percentage
     * @return Reward percentage in basis points
     */
    function liquidatorRewardPercent() external view returns (uint256);

    /**
     * @notice Get insurance fund address
     * @return Insurance fund address
     */
    function insuranceFund() external view returns (address);

    /**
     * @notice Get current insurance fund balance
     * @return Balance in collateral token
     */
    function insuranceFundBalance() external view returns (uint256);

    /**
     * @notice Get insurance fund ratio vs total open interest
     * @return Ratio in basis points
     * @dev Health metric: higher is better
     */
    function getInsuranceFundRatio() external view returns (uint256);

    /**
     * @notice Get position manager address
     * @return PositionManager contract address
     */
    function positionManager() external view returns (address);

    /**
     * @notice Get vault address
     * @return Vault contract address
     */
    function vault() external view returns (address);

    /**
     * @notice Get index oracle address
     * @return IndexOracle contract address
     */
    function indexOracle() external view returns (address);

    // ============================================================================
    // STATE-CHANGING FUNCTIONS
    // ============================================================================

    /**
     * @notice Liquidate an underwater position
     * @param positionId Position to liquidate
     * @dev Callable by anyone (permissionless liquidation)
     * @dev Liquidator receives reward for executing
     * @dev Remaining collateral goes to insurance fund
     */
    function liquidatePosition(bytes32 positionId) external;

    /**
     * @notice Batch liquidate multiple positions
     * @param positionIds Array of position identifiers
     * @dev Gas-efficient for keepers
     * @dev Skips positions that are not liquidatable
     */
    function batchLiquidate(bytes32[] calldata positionIds) external;

    /**
     * @notice Set liquidation fee percentage
     * @param _feePercent New fee in basis points
     * @dev Only callable by governance
     */
    function setLiquidationFee(uint256 _feePercent) external;

    /**
     * @notice Set liquidator reward percentage
     * @param _rewardPercent New reward in basis points
     * @dev Only callable by governance
     */
    function setLiquidatorReward(uint256 _rewardPercent) external;

    /**
     * @notice Set insurance fund address
     * @param _insuranceFund New insurance fund address
     * @dev Only callable by governance
     */
    function setInsuranceFund(address _insuranceFund) external;

    /**
     * @notice Deposit to insurance fund
     * @param amount Amount to deposit
     * @dev Callable by governance to strengthen fund
     */
    function depositToInsuranceFund(uint256 amount) external;

    /**
     * @notice Withdraw from insurance fund
     * @param amount Amount to withdraw
     * @dev Only callable by governance in emergency
     */
    function withdrawFromInsuranceFund(uint256 amount) external;

    // ============================================================================
    // EVENTS
    // ============================================================================

    /**
     * @notice Emitted when position is liquidated
     * @param positionId Position identifier
     * @param user Position owner
     * @param liquidator Address that executed liquidation
     * @param reward Reward paid to liquidator
     * @param insuranceFundContribution Amount sent to insurance fund
     */
    event PositionLiquidated(
        bytes32 indexed positionId,
        address indexed user,
        address indexed liquidator,
        uint256 reward,
        uint256 insuranceFundContribution
    );

    /**
     * @notice Emitted when insurance fund receives deposit
     * @param amount Deposit amount
     * @param newBalance New insurance fund balance
     */
    event InsuranceFundDeposit(uint256 amount, uint256 newBalance);

    /**
     * @notice Emitted when withdrawal from insurance fund
     * @param amount Withdrawal amount
     * @param newBalance New insurance fund balance
     */
    event InsuranceFundWithdrawal(uint256 amount, uint256 newBalance);

    /**
     * @notice Emitted when liquidation parameters updated
     * @param liquidationFee New liquidation fee
     * @param liquidatorReward New liquidator reward
     */
    event LiquidationParametersUpdated(
        uint256 liquidationFee,
        uint256 liquidatorReward
    );

    /**
     * @notice Emitted when insurance fund address changes
     * @param oldFund Previous insurance fund
     * @param newFund New insurance fund
     */
    event InsuranceFundUpdated(address oldFund, address newFund);

    // ============================================================================
    // ERRORS
    // ============================================================================

    /// @notice Thrown when attempting to liquidate healthy position
    error PositionNotLiquidatable();

    /// @notice Thrown when insurance fund balance insufficient
    error InsufficientInsuranceFund();

    /// @notice Thrown when invalid liquidation parameters provided
    error InvalidLiquidationParameters();
}
