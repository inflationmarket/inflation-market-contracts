// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import "./interfaces/IvAMM.sol";

/**
 * @title vAMM (Virtual Automated Market Maker)
 * @notice Provides price discovery without requiring actual asset reserves
 * @dev Uses constant product formula (x * y = k) with virtual reserves
 */
contract vAMM is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    IvAMM
{
    // ============================================================================
    // STATE VARIABLES
    // ============================================================================

    uint256 public baseReserve; // Virtual base asset reserve
    uint256 public quoteReserve; // Virtual quote asset reserve (USDC)
    uint256 public k; // Constant product (x * y = k)

    uint256 public constant PRECISION = 1e18;

    address public positionManager;

    // ============================================================================
    // MODIFIERS
    // ============================================================================

    modifier onlyPositionManager() {
        require(msg.sender == positionManager, "Only PositionManager");
        _;
    }

    // ============================================================================
    // INITIALIZATION
    // ============================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        uint256 _baseReserve,
        uint256 _quoteReserve,
        address _positionManager
    ) public initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        require(_baseReserve > 0, "Invalid base reserve");
        require(_quoteReserve > 0, "Invalid quote reserve");
        require(_positionManager != address(0), "Invalid PositionManager");

        baseReserve = _baseReserve;
        quoteReserve = _quoteReserve;
        k = _baseReserve * _quoteReserve;
        positionManager = _positionManager;

        emit LiquidityUpdated(baseReserve, quoteReserve);
    }

    // ============================================================================
    // CORE FUNCTIONS
    // ============================================================================

    /**
     * @notice Execute a swap (virtual trade)
     * @param amountIn Amount to swap in
     * @param isLong True for long (buy base), false for short (sell base)
     * @return amountOut Amount received
     */
    function swap(uint256 amountIn, bool isLong)
        external
        override
        onlyPositionManager
        nonReentrant
        returns (uint256 amountOut)
    {
        require(amountIn > 0, "Amount must be positive");

        if (isLong) {
            // Buy base asset with quote
            amountOut = getAmountOut(amountIn, isLong);
            quoteReserve += amountIn;
            baseReserve -= amountOut;
        } else {
            // Sell base asset for quote
            amountOut = getAmountOut(amountIn, isLong);
            baseReserve += amountIn;
            quoteReserve -= amountOut;
        }

        uint256 newPrice = getPrice();

        emit Swap(msg.sender, isLong, amountIn, amountOut, newPrice);
        emit LiquidityUpdated(baseReserve, quoteReserve);

        return amountOut;
    }

    /**
     * @notice Get current price (quote per base)
     * @return price Current price scaled by PRECISION
     */
    function getPrice() public view override returns (uint256 price) {
        // Price = quoteReserve / baseReserve
        price = (quoteReserve * PRECISION) / baseReserve;
        return price;
    }

    /**
     * @notice Get current reserves
     * @return _baseReserve Base reserve amount
     * @return _quoteReserve Quote reserve amount
     */
    function getReserves()
        external
        view
        override
        returns (uint256 _baseReserve, uint256 _quoteReserve)
    {
        return (baseReserve, quoteReserve);
    }

    /**
     * @notice Add liquidity (admin only)
     * @param baseAmount Base amount to add
     * @param quoteAmount Quote amount to add
     */
    function addLiquidity(uint256 baseAmount, uint256 quoteAmount)
        external
        override
        onlyOwner
    {
        require(baseAmount > 0 && quoteAmount > 0, "Invalid amounts");

        baseReserve += baseAmount;
        quoteReserve += quoteAmount;
        k = baseReserve * quoteReserve;

        emit LiquidityUpdated(baseReserve, quoteReserve);
    }

    /**
     * @notice Remove liquidity (admin only)
     * @param liquidity Percentage of liquidity to remove (in basis points)
     * @return base Base amount removed
     * @return quote Quote amount removed
     */
    function removeLiquidity(uint256 liquidity)
        external
        override
        onlyOwner
        returns (uint256 base, uint256 quote)
    {
        require(liquidity <= 10000, "Invalid liquidity");

        base = (baseReserve * liquidity) / 10000;
        quote = (quoteReserve * liquidity) / 10000;

        baseReserve -= base;
        quoteReserve -= quote;
        k = baseReserve * quoteReserve;

        emit LiquidityUpdated(baseReserve, quoteReserve);

        return (base, quote);
    }

    /**
     * @notice Calculate output amount for a given input
     * @param amountIn Input amount
     * @param isLong Direction of trade
     * @return amountOut Output amount
     */
    function getAmountOut(uint256 amountIn, bool isLong)
        public
        view
        override
        returns (uint256 amountOut)
    {
        require(amountIn > 0, "Amount must be positive");

        if (isLong) {
            // Buying base with quote: k = (quoteReserve + amountIn) * (baseReserve - amountOut)
            uint256 newQuoteReserve = quoteReserve + amountIn;
            uint256 newBaseReserve = k / newQuoteReserve;
            amountOut = baseReserve - newBaseReserve;
        } else {
            // Selling base for quote: k = (baseReserve + amountIn) * (quoteReserve - amountOut)
            uint256 newBaseReserve = baseReserve + amountIn;
            uint256 newQuoteReserve = k / newBaseReserve;
            amountOut = quoteReserve - newQuoteReserve;
        }

        return amountOut;
    }

    // ============================================================================
    // ADMIN FUNCTIONS
    // ============================================================================

    function setPositionManager(address _positionManager) external onlyOwner {
        require(_positionManager != address(0), "Invalid address");
        positionManager = _positionManager;
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyOwner
    {}
}
