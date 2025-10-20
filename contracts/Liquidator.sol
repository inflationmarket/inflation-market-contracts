// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import "./interfaces/ILiquidator.sol";
import "./interfaces/IPositionManager.sol";
import "./interfaces/IVault.sol";
import "./interfaces/IIndexOracle.sol";

/**
 * @title Liquidator
 * @notice Executes liquidations and manages the protocol insurance fund.
 */
contract Liquidator is Initializable, OwnableUpgradeable, UUPSUpgradeable, ILiquidator {
    uint256 private constant BASIS_POINTS = 10_000;

    IPositionManager private _positionManager;
    IVault private _vault;
    IIndexOracle private _indexOracle;

    uint256 private _liquidationFeePercent;
    uint256 private _liquidatorRewardPercent;

    address private _insuranceFund;
    uint256 private _insuranceFundBalance;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address positionManager_,
        address vault_,
        address oracle_,
        address insuranceFund_,
        uint256 liquidationFeePercent_,
        uint256 liquidatorRewardPercent_
    ) external initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();

        if (
            positionManager_ == address(0) ||
            vault_ == address(0) ||
            oracle_ == address(0) ||
            insuranceFund_ == address(0)
        ) {
            revert InvalidLiquidationParameters();
        }

        _positionManager = IPositionManager(positionManager_);
        _vault = IVault(vault_);
        _indexOracle = IIndexOracle(oracle_);
        _insuranceFund = insuranceFund_;

        _setLiquidationFee(liquidationFeePercent_);
        _setLiquidatorReward(liquidatorRewardPercent_);
    }

    // ==========================================================================
    // VIEW FUNCTIONS
    // ==========================================================================

    function isLiquidatable(bytes32 positionId) public view override returns (bool) {
        return _positionManager.isPositionLiquidatable(positionId);
    }

    function liquidationFeePercent() external view override returns (uint256) {
        return _liquidationFeePercent;
    }

    function liquidatorRewardPercent() external view override returns (uint256) {
        return _liquidatorRewardPercent;
    }

    function insuranceFund() external view override returns (address) {
        return _insuranceFund;
    }

    function insuranceFundBalance() external view override returns (uint256) {
        return _insuranceFundBalance;
    }

    function getInsuranceFundRatio() external view override returns (uint256) {
        if (_insuranceFundBalance == 0) return 0;
        // Without full system metrics, expose ratio against liquidation fee schedule.
        return (_insuranceFundBalance * BASIS_POINTS) / (_liquidationFeePercent == 0 ? 1 : _liquidationFeePercent);
    }

    function positionManager() external view override returns (address) {
        return address(_positionManager);
    }

    function vault() external view override returns (address) {
        return address(_vault);
    }

    function indexOracle() external view override returns (address) {
        return address(_indexOracle);
    }

    // ==========================================================================
    // STATE-CHANGING FUNCTIONS
    // ==========================================================================

    function liquidatePosition(bytes32 positionId) external override {
        if (!isLiquidatable(positionId)) revert PositionNotLiquidatable();

        IPositionManager.Position memory position = _positionManager.getPosition(positionId);
        _positionManager.liquidatePosition(positionId);

        emit PositionLiquidated(positionId, position.trader, msg.sender, 0, 0);
    }

    function batchLiquidate(bytes32[] calldata positionIds) external override {
        for (uint256 i = 0; i < positionIds.length; ++i) {
            if (!isLiquidatable(positionIds[i])) {
                continue;
            }

            IPositionManager.Position memory position = _positionManager.getPosition(positionIds[i]);
            _positionManager.liquidatePosition(positionIds[i]);
            emit PositionLiquidated(positionIds[i], position.trader, msg.sender, 0, 0);
        }
    }

    function setLiquidationFee(uint256 feePercent) external override onlyOwner {
        _setLiquidationFee(feePercent);
        emit LiquidationParametersUpdated(_liquidationFeePercent, _liquidatorRewardPercent);
    }

    function setLiquidatorReward(uint256 rewardPercent) external override onlyOwner {
        _setLiquidatorReward(rewardPercent);
        emit LiquidationParametersUpdated(_liquidationFeePercent, _liquidatorRewardPercent);
    }

    function setInsuranceFund(address insuranceFund_) external override onlyOwner {
        if (insuranceFund_ == address(0)) revert InvalidLiquidationParameters();
        address oldFund = _insuranceFund;
        _insuranceFund = insuranceFund_;
        emit InsuranceFundUpdated(oldFund, insuranceFund_);
    }

    function depositToInsuranceFund(uint256 amount) external override onlyOwner {
        if (amount == 0) revert InvalidLiquidationParameters();
        _insuranceFundBalance += amount;
        emit InsuranceFundDeposit(amount, _insuranceFundBalance);
    }

    function withdrawFromInsuranceFund(uint256 amount) external override onlyOwner {
        if (amount == 0 || amount > _insuranceFundBalance) revert InsufficientInsuranceFund();
        _insuranceFundBalance -= amount;
        emit InsuranceFundWithdrawal(amount, _insuranceFundBalance);
    }

    // ==========================================================================
    // INTERNAL HELPERS
    // ==========================================================================

    function _setLiquidationFee(uint256 feePercent) internal {
        if (feePercent > BASIS_POINTS) revert InvalidLiquidationParameters();
        _liquidationFeePercent = feePercent;
    }

    function _setLiquidatorReward(uint256 rewardPercent) internal {
        if (rewardPercent > BASIS_POINTS) revert InvalidLiquidationParameters();
        _liquidatorRewardPercent = rewardPercent;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
