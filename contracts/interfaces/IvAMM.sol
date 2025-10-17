// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IvAMM
 * @notice Interface for Virtual Automated Market Maker (vAMM) for price discovery
 */
interface IvAMM {
    event Swap(
        address indexed trader,
        bool isLong,
        uint256 amountIn,
        uint256 amountOut,
        uint256 newPrice
    );

    event LiquidityUpdated(uint256 baseReserve, uint256 quoteReserve);

    function swap(
        uint256 amountIn,
        bool isLong
    ) external returns (uint256 amountOut);

    function getPrice() external view returns (uint256);

    function getReserves() external view returns (uint256 baseReserve, uint256 quoteReserve);

    function addLiquidity(uint256 baseAmount, uint256 quoteAmount) external;

    function removeLiquidity(uint256 liquidity) external returns (uint256 base, uint256 quote);

    function getAmountOut(uint256 amountIn, bool isLong) external view returns (uint256);
}
