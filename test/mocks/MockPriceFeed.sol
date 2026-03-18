// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockPriceFeed {
    int256 public latestPrice;
    uint256 public lastUpdated;
    uint8 private _decimals;

    constructor(int256 _price) {
        latestPrice = _price;
        lastUpdated = block.timestamp;
        _decimals = 8; // ნაგულისხმევი Chainlink ETH/USD-სთვის
    }

    // ეს ფუნქცია საშუალებას მოგცემს PRICE_FEED_DECIMALS > 18 ბრენჩიც დატესტო
    function setDecimals(uint8 newDecimals) external {
        _decimals = newDecimals;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function setPrice(int256 _price) external {
        latestPrice = _price;
        lastUpdated = block.timestamp;
    }

    function setLastUpdated(uint256 _timestamp) public {
        lastUpdated = _timestamp;
    }

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt, // აი აქ უნდა დაბრუნდეს შენახული დრო
            uint80 answeredInRound
        )
    {
        return (1, latestPrice, block.timestamp, lastUpdated, 1);
    }
}
