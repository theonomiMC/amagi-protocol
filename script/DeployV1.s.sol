// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {AmagiPool} from "../src/AmagiPool.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployV1 is Script {
    function run() external returns (address proxy, address implementation) {
        HelperConfig config = new HelperConfig();
        HelperConfig.NetworkConfig memory cfg = config.getNetworkConfig();
        
        vm.startBroadcast();

        implementation = address(new AmagiPool());
        bytes memory data = abi.encodeWithSelector(
            AmagiPool.initialize.selector,
            cfg.usdc,
            cfg.priceFeed
        );
        proxy = address(new ERC1967Proxy(address(implementation), data));

        vm.stopBroadcast();
        return (proxy, implementation);
    }
}
