// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

import "./interfaces/IIndexOracle.sol";

/**
 * @title IndexOracle
 * @notice Aggregates CPI and Treasury yield data to compute the Inflation Market index price.
 * @dev Implements the Inflation Market IIndexOracle interface.
 */
contract IndexOracle is Initializable, OwnableUpgradeable, UUPSUpgradeable, IIndexOracle {
    // ==========================================================================
    // CONSTANTS
    // ==========================================================================

    uint256 private constant PRECISION = 1e18;
    uint256 private constant BASIS_POINTS = 10_000;
    uint256 private constant DEFAULT_MAX_DEV = 1_000; // 10%
    uint256 private constant DEFAULT_UPDATE_INTERVAL = 1 hours;
    uint256 private constant MAX_HISTORY = 90;

    // ==========================================================================
    // STATE
    // ==========================================================================

    AggregatorV3Interface private _cpiFeed;
    AggregatorV3Interface private _treasuryFeed;

    uint256 private _indexPrice; // scaled to 1e18
    int256 private _lastAnnualRealYield; // signed difference between treasury and CPI

    uint256 private _lastUpdateTime;
    uint256 private _updateInterval;
    uint256 private _maxPriceDeviation; // basis points

    uint256[] private _priceHistory;

    // ==========================================================================
    // INITIALIZATION
    // ==========================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address cpiFeed_,
        address treasuryFeed_,
        uint256 updateInterval_,
        uint256 maxDeviation_
    ) external initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();

        if (cpiFeed_ == address(0) || treasuryFeed_ == address(0)) {
            revert InvalidPrice();
        }

        _cpiFeed = AggregatorV3Interface(cpiFeed_);
        _treasuryFeed = AggregatorV3Interface(treasuryFeed_);

        _updateInterval = updateInterval_ == 0 ? DEFAULT_UPDATE_INTERVAL : updateInterval_;
        _maxPriceDeviation = maxDeviation_ == 0 ? DEFAULT_MAX_DEV : maxDeviation_;

        // Prime history with an initial reading so downstream consumers have a baseline.
        (uint256 price, int256 realYield) = _fetchLatestIndex();
        _snapshotIndex(price, realYield);
    }

    // ==========================================================================
    // VIEW FUNCTIONS
    // ==========================================================================

    /// @inheritdoc IIndexOracle
    function getIndexPrice() external view override returns (uint256) {
        if (_stale()) revert OracleDataStale();
        return _indexPrice;
    }

    /// @inheritdoc IIndexOracle
    function getTWAP(uint256 periods) external view override returns (uint256) {
        if (_priceHistory.length == 0) revert OracleDataStale();

        uint256 samples = periods == 0 || periods > _priceHistory.length
            ? _priceHistory.length
            : periods;

        uint256 sum;
        for (uint256 i = 0; i < samples; ++i) {
            sum += _priceHistory[_priceHistory.length - 1 - i];
        }
        return sum / samples;
    }

    /// @inheritdoc IIndexOracle
    function lastAnnualRealYield() external view override returns (int256) {
        return _lastAnnualRealYield;
    }

    /// @inheritdoc IIndexOracle
    function lastUpdateTime() external view override returns (uint256) {
        return _lastUpdateTime;
    }

    /// @inheritdoc IIndexOracle
    function updateInterval() external view override returns (uint256) {
        return _updateInterval;
    }

    /// @inheritdoc IIndexOracle
    function priceHistory(uint256 index) external view override returns (uint256) {
        if (index >= _priceHistory.length) revert InvalidPrice();
        return _priceHistory[index];
    }

    /// @inheritdoc IIndexOracle
    function cpiDataFeed() external view override returns (address) {
        return address(_cpiFeed);
    }

    /// @inheritdoc IIndexOracle
    function treasuryYieldFeed() external view override returns (address) {
        return address(_treasuryFeed);
    }

    // ==========================================================================
    // MUTATIVE FUNCTIONS
    // ==========================================================================

    /// @inheritdoc IIndexOracle
    function updateIndexPrice() external override {
        if (block.timestamp < _lastUpdateTime + _updateInterval) revert UpdateTooSoon();

        (uint256 price, int256 realYield) = _fetchLatestIndex();

        if (_indexPrice != 0) {
            uint256 delta = _indexPrice > price ? _indexPrice - price : price - _indexPrice;
            if ((_indexPrice == 0 ? 0 : (delta * BASIS_POINTS) / _indexPrice) > _maxPriceDeviation) {
                revert PriceDeviationTooHigh();
            }
        }

        _snapshotIndex(price, realYield);
    }

    /// @inheritdoc IIndexOracle
    function setIndexPriceManual(uint256 price) external override onlyOwner {
        if (price == 0) revert InvalidPrice();

        _indexPrice = price;
        _lastUpdateTime = block.timestamp;
        _priceHistory.push(price);
        _truncateHistory();

        emit ManualPriceUpdate(price, block.timestamp);
    }

    /// @inheritdoc IIndexOracle
    function setOracleFeeds(
        address cpiFeed_,
        address treasuryFeed_
    ) external override onlyOwner {
        if (cpiFeed_ == address(0) || treasuryFeed_ == address(0)) revert InvalidPrice();

        _cpiFeed = AggregatorV3Interface(cpiFeed_);
        _treasuryFeed = AggregatorV3Interface(treasuryFeed_);

        emit OracleFeedUpdated(cpiFeed_, treasuryFeed_);
    }

    /// @inheritdoc IIndexOracle
    function setUpdateInterval(uint256 newInterval) external override onlyOwner {
        if (newInterval == 0) revert InvalidPrice();
        uint256 oldInterval = _updateInterval;
        _updateInterval = newInterval;
        emit UpdateIntervalChanged(oldInterval, newInterval);
    }

    /// @inheritdoc IIndexOracle
    function setMaxPriceDeviation(uint256 maxDeviation) external override onlyOwner {
        if (maxDeviation == 0 || maxDeviation > BASIS_POINTS) revert InvalidPrice();
        _maxPriceDeviation = maxDeviation;
    }

    // ==========================================================================
    // INTERNAL HELPERS
    // ==========================================================================

    function _fetchLatestIndex() internal view returns (uint256 price, int256 realYield) {
        (
            ,
            int256 cpiAnswer,
            ,
            uint256 cpiUpdatedAt,

        ) = _cpiFeed.latestRoundData();
        (
            ,
            int256 treasuryAnswer,
            ,
            uint256 treasuryUpdatedAt,

        ) = _treasuryFeed.latestRoundData();

        if (cpiAnswer <= 0 || treasuryAnswer <= 0) revert InvalidPrice();
        if (_isFeedStale(cpiUpdatedAt) || _isFeedStale(treasuryUpdatedAt)) revert OracleDataStale();

        uint256 cpi = _scaleTo18(uint256(cpiAnswer), _cpiFeed.decimals());
        uint256 treasury = _scaleTo18(uint256(treasuryAnswer), _treasuryFeed.decimals());

        int256 signedCpi = int256(uint256(cpi));
        int256 signedTreasury = int256(uint256(treasury));
        realYield = signedTreasury - signedCpi;

        price = realYield >= 0 ? uint256(realYield) : 0;
    }

    function _snapshotIndex(uint256 price, int256 realYield) internal {
        _indexPrice = price;
        _lastAnnualRealYield = realYield;
        _lastUpdateTime = block.timestamp;

        _priceHistory.push(price);
        _truncateHistory();

        emit IndexPriceUpdated(price, realYield, block.timestamp);
    }

    function _truncateHistory() private {
        uint256 length = _priceHistory.length;
        if (length <= MAX_HISTORY) return;

        uint256 offset = length - MAX_HISTORY;
        for (uint256 i = 0; i < MAX_HISTORY; ++i) {
            _priceHistory[i] = _priceHistory[i + offset];
        }
        for (uint256 j = 0; j < offset; ++j) {
            _priceHistory.pop();
        }
    }

    function _scaleTo18(uint256 value, uint8 decimals_) private pure returns (uint256) {
        if (decimals_ == 18) return value;
        if (decimals_ < 18) {
            return value * 10 ** (18 - decimals_);
        }
        return value / 10 ** (decimals_ - 18);
    }

    function _stale() private view returns (bool) {
        return block.timestamp > _lastUpdateTime + _updateInterval * 2;
    }

    function _isFeedStale(uint256 updatedAt) private view returns (bool) {
        return updatedAt == 0 || block.timestamp > updatedAt + _updateInterval * 2;
    }

    // ==========================================================================
    // UUPS GUARD
    // ==========================================================================

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
