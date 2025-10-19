// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title MockIndexOracle
 * @notice Mock oracle for testing that allows setting prices directly
 */
contract MockIndexOracle is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable
{
    uint256 public indexPrice;
    uint256 public lastUpdateTime;

    event PriceUpdated(uint256 newPrice, uint256 timestamp);

    function initialize(uint256 _initialPrice) public initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();

        indexPrice = _initialPrice;
        lastUpdateTime = block.timestamp;
    }

    function getIndexPrice() external view returns (uint256) {
        return indexPrice;
    }

    function setPrice(uint256 _price) external {
        indexPrice = _price;
        lastUpdateTime = block.timestamp;
        emit PriceUpdated(_price, block.timestamp);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
