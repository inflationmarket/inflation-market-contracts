// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import "../interfaces/IIndexOracle.sol";

/**
 * @title MockIndexOracle
 * @notice Lightweight oracle used in tests; satisfies the IIndexOracle interface.
 */
contract MockIndexOracle is Initializable, OwnableUpgradeable, UUPSUpgradeable, IIndexOracle {
    uint256 private constant DEFAULT_UPDATE_INTERVAL = 1 hours;
    uint256 private constant BASIS_POINTS = 10_000;

    uint256 private _indexPrice;
    int256 private _lastAnnualRealYield;
    uint256 private _lastUpdateTime;
    uint256 private _updateInterval;
    uint256 private _maxDeviation;

    address private _cpiFeed;
    address private _treasuryFeed;

    uint256[] private _history;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(uint256 initialPrice) external initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();

        require(initialPrice > 0, "invalid price");

        _indexPrice = initialPrice;
        _lastAnnualRealYield = 0;
        _lastUpdateTime = block.timestamp;
        _updateInterval = DEFAULT_UPDATE_INTERVAL;
        _maxDeviation = BASIS_POINTS; // effectively disables deviation checks

        _history.push(initialPrice);
    }

    // ==========================================================================
    // VIEW FUNCTIONS
    // ==========================================================================

    function getIndexPrice() external view override returns (uint256) {
        if (_isStale()) revert OracleDataStale();
        return _indexPrice;
    }

    function getTWAP(uint256 periods) external view override returns (uint256) {
        if (_history.length == 0) revert OracleDataStale();

        uint256 samples = periods == 0 || periods > _history.length ? _history.length : periods;
        uint256 sum;
        for (uint256 i = 0; i < samples; ++i) {
            sum += _history[_history.length - 1 - i];
        }
        return sum / samples;
    }

    function lastAnnualRealYield() external view override returns (int256) {
        return _lastAnnualRealYield;
    }

    function lastUpdateTime() external view override returns (uint256) {
        return _lastUpdateTime;
    }

    function updateInterval() external view override returns (uint256) {
        return _updateInterval;
    }

    function priceHistory(uint256 index) external view override returns (uint256) {
        if (index >= _history.length) revert InvalidPrice();
        return _history[index];
    }

    function cpiDataFeed() external view override returns (address) {
        return _cpiFeed;
    }

    function treasuryYieldFeed() external view override returns (address) {
        return _treasuryFeed;
    }

    // ==========================================================================
    // STATE-CHANGING FUNCTIONS
    // ==========================================================================

    function updateIndexPrice() external override {
        if (block.timestamp < _lastUpdateTime + _updateInterval) revert UpdateTooSoon();

        _pushPrice(_indexPrice);
        emit IndexPriceUpdated(_indexPrice, _lastAnnualRealYield, block.timestamp);
    }

    function setIndexPriceManual(uint256 price) external override onlyOwner {
        if (price == 0) revert InvalidPrice();
        _guardDeviation(price);
        _pushPrice(price);
        emit ManualPriceUpdate(price, block.timestamp);
    }

    function setPrice(uint256 price) external {
        if (price == 0) revert InvalidPrice();
        _pushPrice(price);
        emit ManualPriceUpdate(price, block.timestamp);
    }

    function setOracleFeeds(address cpiFeed, address treasuryFeed) external override onlyOwner {
        _cpiFeed = cpiFeed;
        _treasuryFeed = treasuryFeed;
        emit OracleFeedUpdated(cpiFeed, treasuryFeed);
    }

    function setUpdateInterval(uint256 interval) external override onlyOwner {
        if (interval == 0) revert InvalidPrice();
        uint256 oldInterval = _updateInterval;
        _updateInterval = interval;
        emit UpdateIntervalChanged(oldInterval, interval);
    }

    function setMaxPriceDeviation(uint256 maxDeviation) external override onlyOwner {
        if (maxDeviation == 0 || maxDeviation > BASIS_POINTS) revert InvalidPrice();
        _maxDeviation = maxDeviation;
    }

    // ==========================================================================
    // TEST UTILITIES
    // ==========================================================================

    function setAnnualRealYield(int256 realYield) external onlyOwner {
        _lastAnnualRealYield = realYield;
    }

    // ==========================================================================
    // INTERNAL HELPERS
    // ==========================================================================

    function _guardDeviation(uint256 newPrice) private view {
        if (_indexPrice == 0 || _maxDeviation == BASIS_POINTS) return;
        uint256 delta = _indexPrice > newPrice ? _indexPrice - newPrice : newPrice - _indexPrice;
        if ((delta * BASIS_POINTS) / _indexPrice > _maxDeviation) {
            revert PriceDeviationTooHigh();
        }
    }

    function _isStale() private view returns (bool) {
        return block.timestamp > _lastUpdateTime + _updateInterval * 2;
    }

    function _pushPrice(uint256 price) private {
        _indexPrice = price;
        _lastUpdateTime = block.timestamp;
        _history.push(price);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
