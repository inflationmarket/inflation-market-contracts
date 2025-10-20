// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import "./interfaces/IvAMM.sol";

/**
 * @title vAMM
 * @notice Virtual AMM providing mark price discovery for Inflation Market.
 */
contract vAMM is Initializable, OwnableUpgradeable, UUPSUpgradeable, ReentrancyGuardUpgradeable, IvAMM {
    uint256 private constant PRECISION = 1e18;
    uint256 private constant BASIS_POINTS = 10_000;

    uint256 private _baseReserve;
    uint256 private _quoteReserve;
    uint256 private _k;

    uint256 private _lastMarkPrice;
    uint256 private _lastPriceUpdate;

    uint256 private _totalLongOI;
    uint256 private _totalShortOI;

    uint256 private _maxPriceImpact; // basis points
    address private _positionManager;

    bool private _initialized;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        uint256 baseReserve_,
        uint256 quoteReserve_
    ) external initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        if (_initialized) revert AlreadyInitialized();
        if (baseReserve_ == 0 || quoteReserve_ == 0) revert InvalidReserves();

        _baseReserve = baseReserve_;
        _quoteReserve = quoteReserve_;
        _k = baseReserve_ * quoteReserve_;

        _positionManager = address(0);
        _maxPriceImpact = 1_000; // 10%

        _updateMarkPrice();
        _initialized = true;

        emit VammInitialized(_baseReserve, _quoteReserve);
    }

    modifier onlyPositionManager() {
        require(msg.sender == _positionManager, "not position manager");
        _;
    }

    // ==========================================================================
    // VIEW FUNCTIONS
    // ==========================================================================

    function getMarkPrice() public view override returns (uint256) {
        if (_baseReserve == 0) revert InvalidReserves();
        return (_quoteReserve * PRECISION) / _baseReserve;
    }

    function getPriceForTrade(
        int256 size
    ) external view override returns (uint256 newMarkPrice, uint256 priceImpact) {
        (uint256 newBase, uint256 newQuote) = _previewReserves(size);
        if (newBase == 0) revert InvalidReserves();

        uint256 oldPrice = getMarkPrice();
        newMarkPrice = (newQuote * PRECISION) / newBase;

        if (oldPrice == 0) {
            priceImpact = 0;
        } else {
            uint256 diff = oldPrice > newMarkPrice ? oldPrice - newMarkPrice : newMarkPrice - oldPrice;
            priceImpact = (diff * BASIS_POINTS) / oldPrice;
        }
    }

    function virtualBaseAssetReserve() external view override returns (uint256) {
        return _baseReserve;
    }

    function virtualQuoteAssetReserve() external view override returns (uint256) {
        return _quoteReserve;
    }

    function k() external view override returns (uint256) {
        return _k;
    }

    function lastMarkPrice() external view override returns (uint256) {
        return _lastMarkPrice;
    }

    function lastPriceUpdateTime() external view override returns (uint256) {
        return _lastPriceUpdate;
    }

    function totalLongOpenInterest() external view override returns (uint256) {
        return _totalLongOI;
    }

    function totalShortOpenInterest() external view override returns (uint256) {
        return _totalShortOI;
    }

    function maxPriceImpact() external view override returns (uint256) {
        return _maxPriceImpact;
    }

    // ==========================================================================
    // STATE-CHANGING FUNCTIONS
    // ==========================================================================

    function updateReserves(int256 size) external override onlyPositionManager nonReentrant {
        if (size == 0) return;

        (uint256 newBase, uint256 newQuote) = _previewReserves(size);
        uint256 newPrice = (newQuote * PRECISION) / newBase;

        if (_lastMarkPrice != 0) {
            uint256 diff = _lastMarkPrice > newPrice ? _lastMarkPrice - newPrice : newPrice - _lastMarkPrice;
            if ((_lastMarkPrice != 0 ? (diff * BASIS_POINTS) / _lastMarkPrice : 0) > _maxPriceImpact) {
                revert PriceImpactTooHigh();
            }
        }

        _applyOpenInterest(size);

        _baseReserve = newBase;
        _quoteReserve = newQuote;
        _k = _baseReserve * _quoteReserve;

        _updateMarkPrice();

        emit ReservesUpdated(_baseReserve, _quoteReserve);
        emit MarkPriceUpdated(_lastMarkPrice, _lastPriceUpdate);
    }

    function rebalanceToIndex(uint256 indexPrice) external override onlyPositionManager {
        if (indexPrice == 0) revert InvalidReserves();
        _lastMarkPrice = indexPrice;
        _quoteReserve = (indexPrice * _baseReserve) / PRECISION;
        _k = _baseReserve * _quoteReserve;
        _lastPriceUpdate = block.timestamp;

        emit ReservesRebalanced(_baseReserve, _quoteReserve);
        emit MarkPriceUpdated(_lastMarkPrice, _lastPriceUpdate);
    }

    function setMaxPriceImpact(uint256 maxImpact) external override onlyOwner {
        if (maxImpact == 0 || maxImpact > BASIS_POINTS) revert InvalidReserves();
        uint256 oldImpact = _maxPriceImpact;
        _maxPriceImpact = maxImpact;
        emit MaxPriceImpactUpdated(oldImpact, maxImpact);
    }

    function setPositionManager(address positionManager_) external override onlyOwner {
        if (positionManager_ == address(0)) revert InvalidReserves();
        _positionManager = positionManager_;
    }

    // ==========================================================================
    // INTERNAL HELPERS
    // ==========================================================================

    function _previewReserves(int256 size) internal view returns (uint256 newBase, uint256 newQuote) {
        if (size > 0) {
            uint256 amountIn = uint256(size);
            newQuote = _quoteReserve + amountIn;
            newBase = _k / newQuote;
            if (newBase >= _baseReserve) revert InsufficientLiquidity();
        } else {
            uint256 amountIn = uint256(-size);
            newBase = _baseReserve + amountIn;
            newQuote = _k / newBase;
            if (newQuote >= _quoteReserve) revert InsufficientLiquidity();
        }
    }

    function _applyOpenInterest(int256 size) internal {
        if (size > 0) {
            uint256 delta = uint256(size);
            if (delta > _totalShortOI) {
                _totalLongOI += delta;
            } else {
                _totalShortOI -= delta;
            }
        } else {
            uint256 delta = uint256(-size);
            if (delta > _totalLongOI) {
                _totalShortOI += delta;
            } else {
                _totalLongOI -= delta;
            }
        }
    }

    function _updateMarkPrice() internal {
        _lastMarkPrice = getMarkPrice();
        _lastPriceUpdate = block.timestamp;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
