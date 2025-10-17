// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

import "./interfaces/IIndexOracle.sol";

/**
 * @title IndexOracle
 * @notice Fetches inflation index data from Chainlink oracles
 * @dev Integrates with Chainlink price feeds for real-world inflation data
 */
contract IndexOracle is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    IIndexOracle
{
    // ============================================================================
    // STATE VARIABLES
    // ============================================================================

    AggregatorV3Interface public priceFeed;
    uint256 public lastIndex;
    uint256 public lastUpdateTimestamp;

    // Mock storage for historical data
    mapping(uint256 => uint256) public historicalIndices;

    // ============================================================================
    // INITIALIZATION
    // ============================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _priceFeed) public initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();

        require(_priceFeed != address(0), "Invalid price feed");
        priceFeed = AggregatorV3Interface(_priceFeed);
    }

    // ============================================================================
    // CORE FUNCTIONS
    // ============================================================================

    /**
     * @notice Get the latest inflation index
     * @return index Current inflation index
     * @return timestamp Time of last update
     */
    function getLatestIndex()
        external
        view
        override
        returns (uint256 index, uint256 timestamp)
    {
        (
            /* uint80 roundID */,
            int256 price,
            /* uint256 startedAt */,
            uint256 updatedAt,
            /* uint80 answeredInRound */
        ) = priceFeed.latestRoundData();

        require(price > 0, "Invalid price");

        // Convert Chainlink price to index (scaled to 1e18)
        index = uint256(price) * 1e10; // Chainlink uses 8 decimals, scale to 18
        timestamp = updatedAt;

        return (index, timestamp);
    }

    /**
     * @notice Get historical inflation index (mock implementation)
     * @param timestamp Historical timestamp
     * @return index Historical index value
     */
    function getHistoricalIndex(uint256 timestamp)
        external
        view
        override
        returns (uint256 index)
    {
        index = historicalIndices[timestamp];
        if (index == 0) {
            // Return current index if historical not available
            (index, ) = this.getLatestIndex();
        }
        return index;
    }

    /**
     * @notice Update the stored index value
     */
    function updateIndex() external override {
        (uint256 newIndex, uint256 timestamp) = this.getLatestIndex();

        lastIndex = newIndex;
        lastUpdateTimestamp = timestamp;
        historicalIndices[timestamp] = newIndex;

        emit IndexUpdated(newIndex, timestamp);
    }

    /**
     * @notice Set a new oracle source
     * @param newSource Address of new Chainlink aggregator
     */
    function setOracleSource(address newSource) external override onlyOwner {
        require(newSource != address(0), "Invalid address");
        priceFeed = AggregatorV3Interface(newSource);
        emit OracleSourceUpdated(newSource);
    }

    /**
     * @notice Get decimals used for index values
     * @return Decimals (always 18)
     */
    function getIndexDecimals() external pure override returns (uint8) {
        return 18;
    }

    // ============================================================================
    // ADMIN FUNCTIONS
    // ============================================================================

    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyOwner
    {}
}
