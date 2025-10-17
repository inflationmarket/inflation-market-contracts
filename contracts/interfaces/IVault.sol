// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IVault
 * @notice Interface for managing collateral and liquidity in the protocol
 */
interface IVault {
    event Deposit(address indexed user, uint256 amount, uint256 shares);
    event Withdraw(address indexed user, uint256 shares, uint256 amount);
    event CollateralLocked(address indexed trader, uint256 amount);
    event CollateralReleased(address indexed trader, uint256 amount);

    function deposit(uint256 amount) external returns (uint256 shares);

    function withdraw(uint256 shares) external returns (uint256 amount);

    function lockCollateral(address trader, uint256 amount) external;

    function releaseCollateral(address trader, uint256 amount) external;

    function getAvailableLiquidity() external view returns (uint256);

    function getTotalAssets() external view returns (uint256);

    function convertToShares(uint256 assets) external view returns (uint256);

    function convertToAssets(uint256 shares) external view returns (uint256);
}
