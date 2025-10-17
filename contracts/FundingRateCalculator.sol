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
 * @notice Calculates funding rates based on market conditions
 * @dev Funding rates help keep perpetual futures prices anchored to spot
 */
contract FundingRateCalculator is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    IFundingRateCalculator
{
    // ============================================================================
    // STATE VARIABLES
    // ============================================================================

    IvAMM public vamm;
    IIndexOracle public indexOracle;

    int256 public lastFundingRate;
    uint256 public lastUpdateTimestamp;
    uint256 public fundingInterval; // Time between funding payments (e.g., 8 hours)

    uint256 public constant PRECISION = 1e18;
    int256 public constant MAX_FUNDING_RATE = 0.001e18; // 0.1% per interval

    // ============================================================================
    // INITIALIZATION
    // ============================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _vamm,
        address _indexOracle,
        uint256 _fundingInterval
    ) public initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();

        require(_vamm != address(0), "Invalid vAMM");
        require(_indexOracle != address(0), "Invalid oracle");

        vamm = IvAMM(_vamm);
        indexOracle = IIndexOracle(_indexOracle);
        fundingInterval = _fundingInterval;
        lastUpdateTimestamp = block.timestamp;
    }

    // ============================================================================
    // CORE FUNCTIONS
    // ============================================================================

    /**
     * @notice Calculate current funding rate
     * @return fundingRate Current funding rate (can be positive or negative)
     */
    function calculateFundingRate()
        external
        view
        override
        returns (int256 fundingRate)
    {
        // Get mark price from vAMM
        uint256 markPrice = vamm.getPrice();

        // Get index price from oracle
        (uint256 indexPrice, ) = indexOracle.getLatestIndex();

        // Calculate premium = (markPrice - indexPrice) / indexPrice
        int256 premium = (int256(markPrice) - int256(indexPrice)) * int256(PRECISION) / int256(indexPrice);

        // Funding rate = premium / interval
        // Simplified: use premium directly with cap
        fundingRate = premium;

        // Cap funding rate
        if (fundingRate > MAX_FUNDING_RATE) {
            fundingRate = MAX_FUNDING_RATE;
        } else if (fundingRate < -MAX_FUNDING_RATE) {
            fundingRate = -MAX_FUNDING_RATE;
        }

        return fundingRate;
    }

    /**
     * @notice Update and store the funding rate
     * @return fundingRate Updated funding rate
     */
    function updateFundingRate() external override returns (int256 fundingRate) {
        require(
            block.timestamp >= lastUpdateTimestamp + fundingInterval,
            "Too early to update"
        );

        fundingRate = this.calculateFundingRate();
        lastFundingRate = fundingRate;
        lastUpdateTimestamp = block.timestamp;

        emit FundingRateUpdated(fundingRate, block.timestamp);
        return fundingRate;
    }

    /**
     * @notice Get the last recorded funding rate
     * @return Last funding rate
     */
    function getLastFundingRate() external view override returns (int256) {
        return lastFundingRate;
    }

    /**
     * @notice Get timestamp of last funding rate update
     * @return Timestamp
     */
    function getLastUpdateTimestamp() external view override returns (uint256) {
        return lastUpdateTimestamp;
    }

    /**
     * @notice Get funding interval duration
     * @return Funding interval in seconds
     */
    function getFundingInterval() external view override returns (uint256) {
        return fundingInterval;
    }

    // ============================================================================
    // ADMIN FUNCTIONS
    // ============================================================================

    function setFundingInterval(uint256 _fundingInterval) external onlyOwner {
        require(_fundingInterval > 0, "Invalid interval");
        fundingInterval = _fundingInterval;
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyOwner
    {}
}
