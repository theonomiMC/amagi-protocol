// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {AmagiPool} from "../src/AmagiPool.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract deployV1 is Script {
    address constant USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238; // Sepolia USDC
    address constant PRICE_FEED = 0x694AA1769357215DE4FAC081bf1f309aDC325306;

    function run() public returns (address proxy) {
        vm.startBroadcast();

        AmagiPool implementation = new AmagiPool();
        bytes memory data = abi.encodeWithSelector(AmagiPool.initialize.selector, address(USDC), address(PRICE_FEED));
        proxy = address(new ERC1967Proxy(address(implementation), data));
        vm.stopBroadcast();
    }
}
