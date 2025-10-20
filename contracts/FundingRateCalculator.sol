// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import "./interfaces/IFundingRateCalculator.sol";
import "./interfaces/IvAMM.sol";
import "./interfaces/IIndexOracle.sol";

/**
 * @title FundingRateCalculator
 * @notice Calculates continuous funding between longs and shorts for Inflation Market.
 */
contract FundingRateCalculator is Initializable, OwnableUpgradeable, UUPSUpgradeable, IFundingRateCalculator {
    uint256 private constant PRECISION = 1e18;
    uint256 private constant APR_MULTIPLIER = 24 * 365;

    IvAMM public vamm;
    IIndexOracle public indexOracle;
    address public positionManager;

    int256 private _currentFundingRate;
    int256 private _longIndexAccumulator;
    int256 private _shortIndexAccumulator;

    uint256 private _lastFundingTime;
    uint256 private _fundingInterval;

    uint256 private _totalLongOpenInterest;
    uint256 private _totalShortOpenInterest;

    uint256 private _fundingRateCoefficient;
    uint256 private _maxFundingRate; // positive cap (per interval)
    uint256 private _minFundingRate; // positive magnitude for negative cap

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address vamm_,
        address oracle_,
        address positionManager_,
        uint256 fundingInterval_,
        uint256 coefficient_,
        uint256 maxRate_,
        uint256 minRate_
    ) external initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();

        require(vamm_ != address(0) && oracle_ != address(0), "invalid address");
        require(fundingInterval_ > 0, "invalid interval");

        vamm = IvAMM(vamm_);
        indexOracle = IIndexOracle(oracle_);
        positionManager = positionManager_;

        _fundingInterval = fundingInterval_;
        _fundingRateCoefficient = coefficient_ == 0 ? PRECISION : coefficient_;
        _maxFundingRate = maxRate_ == 0 ? 5e14 : maxRate_; // default 0.05% per interval
        _minFundingRate = minRate_ == 0 ? 5e14 : minRate_;

        _lastFundingTime = block.timestamp;
    }

    // ==========================================================================
    // MODIFIERS
    // ==========================================================================

    modifier onlyPositionManager() {
        require(msg.sender == positionManager, "not position manager");
        _;
    }

    // ==========================================================================
    // VIEW FUNCTIONS
    // ==========================================================================

    function currentFundingRate() external view override returns (int256) {
        return _currentFundingRate;
    }

    function getFundingRateAPR() external view override returns (int256) {
        return _currentFundingRate * int256(APR_MULTIPLIER);
    }

    function longFundingIndex() public view override returns (int256) {
        (int256 longIndex, ) = _previewIndices();
        return longIndex;
    }

    function shortFundingIndex() public view override returns (int256) {
        (, int256 shortIndex) = _previewIndices();
        return shortIndex;
    }

    function lastFundingTime() external view override returns (uint256) {
        return _lastFundingTime;
    }

    function fundingInterval() external view override returns (uint256) {
        return _fundingInterval;
    }

    function totalLongOpenInterest() external view override returns (uint256) {
        return _totalLongOpenInterest;
    }

    function totalShortOpenInterest() external view override returns (uint256) {
        return _totalShortOpenInterest;
    }

    function fundingRateCoefficient() external view override returns (uint256) {
        return _fundingRateCoefficient;
    }

    function maxFundingRate() external view override returns (uint256) {
        return _maxFundingRate;
    }

    function minFundingRate() external view override returns (uint256) {
        return _minFundingRate;
    }

    // ==========================================================================
    // STATE-CHANGING FUNCTIONS
    // ==========================================================================

    function updateFundingRate(
        uint256 markPrice,
        uint256 indexPrice
    ) external override onlyPositionManager {
        if (indexPrice == 0) revert InvalidFundingParameters();

        uint256 elapsed = block.timestamp - _lastFundingTime;
        if (_lastFundingTime != 0 && elapsed < _fundingInterval) {
            revert FundingUpdateTooSoon();
        }

        if (_lastFundingTime != 0) {
            _accrueFunding(elapsed);
        }

        int256 newRate = _computeFundingRate(markPrice, indexPrice);
        _currentFundingRate = newRate;
        _lastFundingTime = block.timestamp;

        emit FundingRateUpdated(newRate, block.timestamp);
    }

    function calculateFundingPayment(
        bool isLong,
        uint256 size,
        int256 entryFundingIndex
    ) external view override returns (int256) {
        (int256 longIndexPreview, int256 shortIndexPreview) = _previewIndices();
        int256 currentIndex = isLong ? longIndexPreview : shortIndexPreview;
        int256 indexDelta = currentIndex - entryFundingIndex;

        int256 payment = (int256(size) * indexDelta) / int256(PRECISION);
        if (!isLong) {
            payment = -payment;
        }
        return payment;
    }

    function updateOpenInterest(
        bool isLong,
        uint256 sizeDelta,
        bool isIncrease
    ) external override onlyPositionManager {
        if (sizeDelta == 0) return;

        if (isLong) {
            if (isIncrease) {
                _totalLongOpenInterest += sizeDelta;
            } else {
                _totalLongOpenInterest = sizeDelta >= _totalLongOpenInterest
                    ? 0
                    : _totalLongOpenInterest - sizeDelta;
            }
        } else {
            if (isIncrease) {
                _totalShortOpenInterest += sizeDelta;
            } else {
                _totalShortOpenInterest = sizeDelta >= _totalShortOpenInterest
                    ? 0
                    : _totalShortOpenInterest - sizeDelta;
            }
        }

        emit OpenInterestUpdated(_totalLongOpenInterest, _totalShortOpenInterest);
    }

    function setFundingRateCoefficient(uint256 coefficient) external override onlyOwner {
        if (coefficient == 0) revert InvalidFundingParameters();
        _fundingRateCoefficient = coefficient;
        emit FundingParametersUpdated(coefficient, _maxFundingRate, _minFundingRate);
    }

    function setMaxFundingRate(uint256 maxRate) external override onlyOwner {
        if (maxRate == 0) revert InvalidFundingParameters();
        _maxFundingRate = maxRate;
        emit FundingParametersUpdated(_fundingRateCoefficient, maxRate, _minFundingRate);
    }

    function setMinFundingRate(uint256 minRate) external override onlyOwner {
        if (minRate == 0) revert InvalidFundingParameters();
        _minFundingRate = minRate;
        emit FundingParametersUpdated(_fundingRateCoefficient, _maxFundingRate, minRate);
    }

    function setFundingInterval(uint256 interval) external override onlyOwner {
        if (interval == 0) revert InvalidFundingParameters();
        _fundingInterval = interval;
        emit FundingParametersUpdated(_fundingRateCoefficient, _maxFundingRate, _minFundingRate);
    }

    function setPositionManager(address positionManager_) external onlyOwner {
        positionManager = positionManager_;
    }

    // ==========================================================================
    // INTERNAL HELPERS
    // ==========================================================================

    function _accrueFunding(uint256 elapsed) internal {
        if (elapsed == 0 || _fundingInterval == 0) return;
        int256 delta = (_currentFundingRate * int256(elapsed)) / int256(_fundingInterval);
        _longIndexAccumulator += delta;
        _shortIndexAccumulator -= delta;
    }

    function _previewIndices() internal view returns (int256 longIndex, int256 shortIndex) {
        longIndex = _longIndexAccumulator;
        shortIndex = _shortIndexAccumulator;

        if (_fundingInterval == 0 || _lastFundingTime == 0) {
            return (longIndex, shortIndex);
        }

        uint256 elapsed = block.timestamp - _lastFundingTime;
        if (elapsed == 0) return (longIndex, shortIndex);

        int256 delta = (_currentFundingRate * int256(elapsed)) / int256(_fundingInterval);
        longIndex += delta;
        shortIndex -= delta;
    }

    function _computeFundingRate(uint256 markPrice, uint256 indexPrice) internal view returns (int256) {
        if (indexPrice == 0) revert InvalidFundingParameters();

        int256 mark = int256(markPrice);
        int256 index = int256(indexPrice);
        int256 premium = ((mark - index) * int256(_fundingRateCoefficient)) / int256(indexPrice);

        if (premium > int256(_maxFundingRate)) {
            premium = int256(_maxFundingRate);
        } else if (premium < -int256(_minFundingRate)) {
            premium = -int256(_minFundingRate);
        }

        return premium;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
