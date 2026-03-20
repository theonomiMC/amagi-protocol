// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AmagiPool} from "../../src/AmagiPool.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockPriceFeed} from "../mocks/MockPriceFeed.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

abstract contract BaseTest is Test {
    AmagiPool public pool;
    MockPriceFeed public priceFeed;
    MockUSDC public usdc;

    address public owner = makeAddr("owner");
    address public user = makeAddr("user");
    address public liquidator = makeAddr("liquidator");

    int256 constant INIT_PRICE = 2000e8;

    function setUp() public virtual {
        vm.startPrank(owner);

        usdc = new MockUSDC();
        priceFeed = new MockPriceFeed(INIT_PRICE);

        AmagiPool impl = new AmagiPool();
        bytes memory data = abi.encodeWithSelector(AmagiPool.initialize.selector, address(usdc), address(priceFeed));

        pool = AmagiPool(payable(address(new ERC1967Proxy(address(impl), data))));

        vm.stopPrank();

        usdc.mint(liquidator, 10_000e6);
        vm.prank(liquidator);
        usdc.approve(address(pool), type(uint256).max);
    }
}
