// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {AmagiPool} from "../src/AmagiPool.sol";
import {AmagiPoolV2} from "../src/AmagiPoolV2.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

contract DeployV2 is Script {
    address public constant PROXY_ADDRESS = 0xfA7f34169E182737fa06abAC901E361b42b445A4;

    function run() external returns (address) {
        HelperConfig config = new HelperConfig();
        vm.startBroadcast();
        AmagiPoolV2 newImplementation = new AmagiPoolV2();
        AmagiPoolV2(payable(PROXY_ADDRESS)).upgradeToAndCall(
            address(newImplementation),
            abi.encodeWithSelector(AmagiPoolV2.initializeV2.selector)
        );
        vm.stopBroadcast();

        return PROXY_ADDRESS;
    }
}
