// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {AmagiPoolV2} from "../../src/AmagiPoolV2.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockPriceFeed} from "../mocks/MockPriceFeed.sol";

contract HandlerV2 is Test {
    AmagiPoolV2 public poolV2;
    MockUSDC public usdc;
    MockPriceFeed public priceFeed;

    address[] public actors;

    // ghost variables
    uint256 public totalDepositedByActors;
    uint256 public totalBorrowedByActors;
    uint256 public totalWithdrawnByActors;
    uint256 public totalRepaidrawnByActors;
    uint256 public totalLiquidatedAmount;

    mapping(address => uint256) public ghost_userBorrowShares;

    constructor(AmagiPoolV2 _poolV2, MockUSDC _usdc, MockPriceFeed _priceFeed) {
        poolV2 = _poolV2;
        usdc = _usdc;
        priceFeed = _priceFeed;

        for (uint256 i = 0; i < 5; i++) {
            actors.push(makeAddr(string(abi.encodePacked("actor", i))));
        }
    }

    // Helpers
    function _getActor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _toAssets(uint256 shares, uint256 index) internal view returns (uint256) {
        return (shares * index) / poolV2.PRECISION();
    }

    function _scaleDown(uint256 amount) internal view returns (uint256) {
        return amount / poolV2.USDC_SCALE();
    }

    // Core logic
    function deposit(uint256 amount, uint256 seed) public {
        address actor = _getActor(seed);
        amount = bound(amount, 1e6, 1_000_000e6);

        usdc.mint(actor, amount);

        vm.startPrank(actor);
        usdc.approve(address(poolV2), amount);
        poolV2.deposit(amount);
        vm.stopPrank();

        totalDepositedByActors += amount;
    }

    function depositCollateral(uint256 amount, uint256 seed) public {
        if (amount == 0) return;

        address actor = _getActor(seed);
        // deifne amount range
        amount = bound(amount, 0.1 ether, 100 ether);
        // give actor the "amount" ether
        vm.deal(actor, amount);
        vm.prank(actor);
        poolV2.depositCollateral{value: amount}();
    }

    function withdraw(uint256 amount, uint256 seed) public {
        address actor = _getActor(seed);
        uint256 maxWithdraw = usdc.balanceOf(actor);

        if (maxWithdraw == 0) return;

        uint256 poolLiquidity = usdc.balanceOf(address(poolV2));
        if (poolLiquidity == 0) return;

        amount = bound(amount, 0, maxWithdraw > poolLiquidity ? poolLiquidity : maxWithdraw);

        vm.prank(actor);
        poolV2.withdraw(amount);

        totalWithdrawnByActors += amount;
    }

    function withdrawCollateral(uint256 amount, uint256 seed) public {
        if (amount == 0) return;

        address actor = _getActor(seed);

        (uint128 userCollateral,,) = poolV2.users(actor);

        if (uint256(userCollateral) == 0) return;

        // deifne amount range
        amount = bound(amount, 0.1 ether, userCollateral);

        vm.prank(actor);
        poolV2.withdrawCollateral(amount);
    }

    function borrow(uint256 amount, uint256 seed) public {
        address actor = _getActor(seed);
        (uint128 collateral, uint128 borrowShares,) = poolV2.users(actor);

        if (collateral == 0) return;

        uint256 currentPrice = poolV2.getPrice();
        uint256 collateralValue = (uint256(collateral) * currentPrice) / 1e18;
        uint256 maxBorrowValue = (collateralValue * poolV2.LTV()) / 100;

        uint256 bIndex = poolV2.globalBorrowIndex();
        uint256 currentDebt = _toAssets(uint256(borrowShares), bIndex);

        if (currentDebt >= maxBorrowValue) return;

        uint256 poolLiquidity = usdc.balanceOf(address(poolV2));
        uint256 availableBorrowAmount = _scaleDown(maxBorrowValue - currentDebt);

        amount = bound(amount, 0, availableBorrowAmount > poolLiquidity ? poolLiquidity : availableBorrowAmount);

        if (amount == 0) return;

        (, uint128 sharesBefore,) = poolV2.users(actor);
        vm.prank(actor);
        poolV2.borrow(amount);

        (, uint128 sharesAfter,) = poolV2.users(actor);

        ghost_userBorrowShares[actor] += (sharesAfter - sharesBefore);

        totalBorrowedByActors += amount;
    }

    function repay(uint256 amount, uint256 seed) public {
        address actor = _getActor(seed);

        (, uint128 borrowShares,) = poolV2.users(actor);
        if (borrowShares == 0) return;

        uint256 bIndex = poolV2.globalBorrowIndex();
        // convert shares to usdc assets
        uint256 debtAssets = _toAssets(uint256(borrowShares), bIndex);
        uint256 debtInUsdc = _scaleDown(debtAssets); // 6 decimals
        if (debtInUsdc == 0) debtInUsdc = 1;

        amount = bound(amount, 1e6, debtInUsdc);

        (, uint128 sharesBefore,) = poolV2.users(actor);

        usdc.mint(actor, amount);

        vm.startPrank(actor);
        usdc.approve(address(poolV2), amount);
        poolV2.repay(amount);
        vm.stopPrank();

        (, uint128 sharesAfter,) = poolV2.users(actor);

        ghost_userBorrowShares[actor] -= (sharesBefore - sharesAfter);
        totalRepaidrawnByActors += amount;
    }

    function liquidate(uint256 amount, uint256 seed) public {
        address target = _getActor(seed);

        (uint128 collateral, uint128 borrowShares,) = poolV2.users(target);
        if (borrowShares == 0) return;

        priceFeed.setPrice(1000e8);

        uint256 currentPrice = poolV2.getPrice();
        uint256 bIndex = poolV2.globalBorrowIndex();
        uint256 debt = _toAssets(uint256(borrowShares), bIndex);

        uint256 hf = (uint256(collateral) * currentPrice * poolV2.LIQ_THRESHOLD()) / (100 * debt);

        if (hf > 1e18 || debt == 0) {
            priceFeed.setPrice(2000e8);
            return;
        }

        amount = bound(amount, 1e6, _scaleDown(debt));

        (, uint128 sharesBefore,) = poolV2.users(target);

        address liquidator = makeAddr("invariant_liquidator");

        usdc.mint(liquidator, amount);

        vm.prank(liquidator);
        usdc.approve(address(poolV2), type(uint256).max);
        poolV2.liquidate(target, amount);

        (, uint128 sharesAfter,) = poolV2.users(target);

        priceFeed.setPrice(2000e8);

        ghost_userBorrowShares[target] -= (sharesBefore - sharesAfter);
        totalLiquidatedAmount += amount;
    }

    function warpTime(uint256 secondsToWarp) public {
        secondsToWarp = bound(secondsToWarp, 60, 30 days);
        vm.warp(block.timestamp + secondsToWarp);
    }

    function getActors() public view returns (address[] memory) {
        return actors;
    }

    function getCurrentDeposits() public view returns (uint256) {
        return totalDepositedByActors - totalWithdrawnByActors;
    }
}
