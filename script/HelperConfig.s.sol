// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {MockUSDC} from "../test/mocks/MockUSDC.sol";
import {MockPriceFeed} from "../test/mocks/MockPriceFeed.sol";

contract HelperConfig is Script {
    struct NetworkConfig {
        address usdc;
        address priceFeed;
    }
    NetworkConfig public activeNetworkConfig;

    // Sepolia addresses
    address constant SEPOLIA_USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    address constant SEPOLIA_ETH_USD =
        0x694AA1769357215DE4FAC081bf1f309aDC325306;

    constructor() {
        if (block.chainid == 11155111) {
            activeNetworkConfig = getSepoliaConfig();
        } else {
            activeNetworkConfig = getOrCreateAnvilConfig();
        }
    }

    function getSepoliaConfig() public pure returns (NetworkConfig memory) {
        return NetworkConfig({usdc: SEPOLIA_USDC, priceFeed: SEPOLIA_ETH_USD});
    }

    function getOrCreateAnvilConfig() public returns (NetworkConfig memory) {
        if (activeNetworkConfig.usdc != address(0)) {
            return activeNetworkConfig;
        }

        vm.startBroadcast();
        MockUSDC usdc = new MockUSDC();
        MockPriceFeed priceFeed = new MockPriceFeed(2000e8);
        vm.stopBroadcast();

        return
            NetworkConfig({usdc: address(usdc), priceFeed: address(priceFeed)});
    }

    function getNetworkConfig() public view returns (NetworkConfig memory) {
        return activeNetworkConfig;
    }
}
