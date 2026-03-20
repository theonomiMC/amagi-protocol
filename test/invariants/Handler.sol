// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {AmagiPool} from "../../src/AmagiPool.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockPriceFeed} from "../mocks/MockPriceFeed.sol";

contract Handler is CommonBase, StdCheats, StdUtils {
    AmagiPool public pool;
    MockUSDC public usdc;
    MockPriceFeed public priceFeed;

    // actors
    address[] public actors;
    address[] public activeBorrowers;
    address internal currentActor;
    uint256 public previousIndex;

    mapping(address => bool) isBorrower;

    // ghost variables
    uint256 public ghost_totalDeposits;
    uint256 public ghost_totalWithdrawn;
    uint256 public ghost_totalBorrowed;
    uint256 public ghost_totalRepaid;
    uint256 public ghost_totalLiquidated;

    constructor(AmagiPool _pool, MockUSDC _usdc, MockPriceFeed _priceFeed) {
        pool = _pool;
        usdc = _usdc;
        priceFeed = _priceFeed;
        previousIndex = pool.globalBorrowIndex();
        for (uint256 i = 0; i < 5; i++) {
            actors.push(makeAddr(string(abi.encodePacked("actor", i))));
        }
    }

    modifier useActor(uint256 seed) {
        currentActor = actors[bound(seed, 0, actors.length - 1)];
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    // VIEW
    function activeBorrowersLength() public view returns (uint256) {
        return activeBorrowers.length;
    }

    function activeBorrowersAt(uint256 i) public view returns (address) {
        return activeBorrowers[i];
    }

    // MAIN
    function deposit(uint256 amount, uint256 seed) public useActor(seed) {
        amount = bound(amount, 1e6, 1_000_000e6);
        usdc.mint(currentActor, amount);
        usdc.approve(address(pool), amount);
        pool.deposit(amount);

        ghost_totalDeposits += amount * pool.USDC_SCALE();
        previousIndex = pool.globalBorrowIndex();
    }

    function depositCollateral(uint256 amount, uint256 seed) public useActor(seed) {
        amount = bound(amount, 0.1 ether, 10_000_000 ether);
        vm.deal(currentActor, amount);
        pool.depositCollateral{value: amount}();
        previousIndex = pool.globalBorrowIndex();
    }

    function withdraw(uint256 amount, uint256 seed) public useActor(seed) {
        (,, uint256 userDeposit) = pool.users(currentActor);
        if (userDeposit == 0) return;

        amount = bound(amount, 1, userDeposit / pool.USDC_SCALE());

        try pool.withdraw(amount) {
            uint256 scaledAmount = amount * pool.USDC_SCALE();
            if (ghost_totalDeposits >= scaledAmount) {
                ghost_totalDeposits -= scaledAmount;
            }
            ghost_totalWithdrawn += scaledAmount;
        } catch {}
        previousIndex = pool.globalBorrowIndex();
    }

    function borrow(uint256 amount, uint256 seed) public useActor(seed) {
        (uint128 collateral,,) = pool.users(currentActor);
        if (collateral == 0) return;

        uint256 price = pool.getPrice();
        uint256 maxBorrow = (uint256(collateral) * price * pool.LTV()) / (pool.PRECISION() * 100);
        if (maxBorrow == 0) return;

        amount = bound(amount, 1, maxBorrow / pool.USDC_SCALE());
        try pool.borrow(amount) {
            ghost_totalBorrowed += amount * pool.USDC_SCALE();

            if (!isBorrower[currentActor]) {
                isBorrower[currentActor] = true;
                activeBorrowers.push(currentActor);
            }
        } catch {}
        previousIndex = pool.globalBorrowIndex();
    }

    function repay(uint256 amount, uint256 seed) public useActor(seed) {
        (, uint128 borrowShares,) = pool.users(currentActor);
        if (borrowShares == 0) return;

        uint256 debt = (uint256(borrowShares) * pool.globalBorrowIndex()) / pool.PRECISION();
        if (debt == 0) return;

        uint256 maxRepay = debt / pool.USDC_SCALE();
        if (maxRepay == 0) return;

        amount = bound(amount, 1, maxRepay);

        usdc.mint(currentActor, amount);
        usdc.approve(address(pool), amount);

        try pool.repay(amount) {
            ghost_totalRepaid += amount * pool.USDC_SCALE();
            (, uint128 newShares,) = pool.users(currentActor);

            if (newShares == 0 && isBorrower[currentActor]) {
                isBorrower[currentActor] = false;
            }
        } catch {}
        previousIndex = pool.globalBorrowIndex();
    }

    function liquidate(uint256 amount, uint256 targetSeed) public {
        address target = actors[bound(targetSeed, 0, actors.length - 1)];
        (uint128 collateral, uint128 borrowShares,) = pool.users(target);
        if (borrowShares == 0) return;

        uint256 price = pool.getPrice();
        uint256 debt = (uint256(borrowShares) * pool.globalBorrowIndex()) / pool.PRECISION();

        uint256 hf = (uint256(collateral) * price * pool.LIQ_THRESHOLD()) / (100 * debt);

        if (hf >= pool.PRECISION()) return;

        amount = bound(amount, 1, debt / pool.USDC_SCALE());

        address liquidator = makeAddr("invariant_liquidator");
        usdc.mint(liquidator, amount);

        vm.startPrank(liquidator);

        usdc.approve(address(pool), type(uint256).max);
        try pool.liquidate(target, amount) {
            ghost_totalLiquidated += amount * pool.USDC_SCALE();
        } catch {}

        vm.stopPrank();
        previousIndex = pool.globalBorrowIndex();
    }

    // PRICE
    function forwaredTime(uint256 _time) public {
        uint256 time = bound(_time, 60, 30 days);
        vm.warp(block.timestamp + time);
        priceFeed.setLastUpdated(block.timestamp);
    }
}
