// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {
    AmagiPool,
    ZeroAmount,
    InsufficientBalance,
    InsufficientCollateral,
    HealthFactorOk,
    InvalidHealthFactor,
    InsufficientLiquidity,
    TransferFailed,
    PriceExpired,
    InvalidPrice
} from "../src/AmagiPool.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockPriceFeed} from "./mocks/MockPriceFeed.sol";

contract AmagiPoolTest is Test {
    AmagiPool public pool;
    MockUSDC public usdc;
    MockPriceFeed public price;

    address user = makeAddr("user");
    address liquidator = makeAddr("liquidator");

    int256 public initPrice = 2000e8; // $2000 (8 decimals)
    uint256 constant INITIAL_USDC = 1000e6; // 1000 USDC
    uint256 constant INITIAL_ETH = 10 ether;
    uint256 constant USDC_SCALE = 1e12;

    function setUp() public {
        // deploy pool
        usdc = new MockUSDC();
        price = new MockPriceFeed(initPrice);
        pool = new AmagiPool(address(usdc), address(price));

        usdc.mint(liquidator, 10_000e6);
        vm.prank(liquidator);
        usdc.approve(address(pool), type(uint256).max);
    }

    modifier _depositUsdc() {
        vm.startPrank(user);
        usdc.mint(user, INITIAL_USDC);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(INITIAL_USDC);
        vm.stopPrank();
        _;
    }
    modifier _depositEth() {
        vm.startPrank(user);
        vm.deal(user, INITIAL_ETH);
        pool.depositCollateral{value: INITIAL_ETH}();
        vm.stopPrank();
        _;
    }

    function _passTime(uint256 time) internal {
        vm.warp(block.timestamp + time);
    }

    function _setPrice(uint256 newPrice) internal {
        price.setPrice(int256(newPrice));
    }

    function _setupBorrowPosition(address _user, uint256 ethAmount, uint256 borrowAmount) internal {
        vm.deal(_user, ethAmount);
        usdc.mint(address(pool), borrowAmount * 2);

        vm.startPrank(_user);
        pool.depositCollateral{value: ethAmount}();
        pool.borrow(borrowAmount);
        vm.stopPrank();
    }

    function _setupLiquidate(uint256 debtToCover, uint256 _price)
        internal
        view
        returns (uint256 expectedCollateralOut, uint256 expectedSharesRemoved)
    {
        uint256 scaledDebt = debtToCover * pool.USDC_SCALE();
        // Collateral Out: (Debt * 1e18 * 105) / (Price * 100)
        expectedCollateralOut = (scaledDebt * pool.PRECISION() * (100 + pool.LIQ_BONUS())) / (_price * 100);

        // Shares Removed: (Debt * 1e18) / Index
        expectedSharesRemoved = (scaledDebt * pool.PRECISION()) / pool.globalBorrowIndex();
    }

    // deposit
    function test_deposit_updatesUserBalance() public _depositUsdc {
        uint256 poolBalanceAfterDeposit = usdc.balanceOf(address(pool));

        (, uint256 userDeposit,) = pool.users(user);

        assertEq(userDeposit, INITIAL_USDC * USDC_SCALE);
        assertEq(poolBalanceAfterDeposit, INITIAL_USDC);
    }

    function test_deposit_revertsOnZero() public {
        vm.prank(user);
        vm.expectRevert(ZeroAmount.selector);
        pool.deposit(0);
    }

    // withdraw
    function test_withdraw_reducesBalance() public _depositUsdc {
        uint256 withdrawAmount = 600e6;
        vm.prank(user);
        pool.withdraw(withdrawAmount);

        (, uint256 deposit,) = pool.users(user);
        assertEq(deposit, (INITIAL_USDC - withdrawAmount) * USDC_SCALE);
    }

    function test_withdraw_revertsIfInsufficientBalance() public _depositUsdc {
        // user deposited 1000 usdc
        vm.prank(user);
        vm.expectRevert(InsufficientBalance.selector);
        pool.withdraw(1500e6);
    }

    function test_withdraw_revertsOnZero() public _depositUsdc {
        vm.prank(user);
        vm.expectRevert(ZeroAmount.selector);
        pool.withdraw(0);
    }

    function test_withdraw_revertsIfInsufficientLiquidity() public _depositUsdc {
        address borrower = liquidator;

        vm.deal(borrower, 10 ether);
        vm.startPrank(borrower);
        pool.depositCollateral{value: 10 ether}();

        pool.borrow(900e6);
        vm.stopPrank();

        vm.prank(user);
        vm.expectRevert(InsufficientLiquidity.selector);
        pool.withdraw(500e6);
    }

    // depositCollateral
    function test_depositCollateral_updatesCollateral() public _depositEth {
        (uint256 collateral,,) = pool.users(user);
        assertEq(collateral, INITIAL_ETH);
        assertEq(address(pool).balance, INITIAL_ETH);
    }

    function test_depositCollateral_revertsOnZero() public {
        vm.prank(user);
        vm.expectRevert(ZeroAmount.selector);
        pool.depositCollateral{value: 0}();
    }

    // withdrawCollateral
    function test_withdrawCollateral_reducesCollateral() public _depositEth {
        vm.prank(user);
        pool.withdrawCollateral(2 ether);
        assertEq(address(pool).balance, 8 ether);
    }

    function test_withdrawCollateral_revertsIfInsufficientBalance() public _depositEth {
        vm.prank(user);
        vm.expectRevert(InsufficientBalance.selector);
        pool.withdrawCollateral(11 ether);
    }

    function test_withdrawCollateral_revertsIfHealthFactorBreaks() public _depositEth {
        usdc.mint(address(pool), 20_000e6);

        uint256 maxBorrow = 15_000e6;
        vm.prank(user);
        pool.borrow(maxBorrow); // 10 * 2000 = 20_000; max borrow = 15_000;

        _passTime(30 days);

        _setPrice(2000e8);

        vm.prank(user);
        vm.expectRevert(InvalidHealthFactor.selector);
        pool.withdrawCollateral(3 ether);
    }

    function test_withdrawCollateral_revertsOnZero() public _depositEth {
        vm.prank(user);
        vm.expectRevert(ZeroAmount.selector);
        pool.withdrawCollateral(0);
    }

    function test_withdrawCollateral_transferFails() public {
        RejectETH bad = new RejectETH();

        vm.deal(address(bad), 1 ether);

        vm.prank(address(bad));
        pool.depositCollateral{value: 1 ether}();

        vm.prank(address(bad));
        vm.expectRevert(TransferFailed.selector);
        pool.withdrawCollateral(1 ether);
    }

    // Borrow
    function test_borrow_transfersUSDC() public _depositEth {
        usdc.mint(address(pool), 20_000e6);

        uint256 borrowAmount = 11_000e6;

        vm.prank(user);
        pool.borrow(borrowAmount);

        (,, uint256 borrowShares) = pool.users(user);

        assertEq(usdc.balanceOf(user), borrowAmount);
        assertGt(borrowShares, 0);
    }

    function test_borrow_revertsIfInsufficientCollateral() public _depositEth {
        usdc.mint(address(pool), 20_000e6);

        vm.prank(user);
        pool.borrow(11_000e6);

        vm.prank(user);
        vm.expectRevert(InsufficientCollateral.selector);
        pool.borrow(4_001e6);
    }

    function test_borrow_revertsOnZero() public _depositEth {
        vm.prank(user);
        vm.expectRevert(ZeroAmount.selector);
        pool.borrow(0);
    }

    function test_borrow_insufficientLiquidity() public _depositUsdc {
        address borrower = makeAddr("borrower");
        vm.deal(borrower, 2 ether);

        vm.startPrank(borrower);
        pool.depositCollateral{value: 2 ether}();

        vm.expectRevert(InsufficientLiquidity.selector);
        pool.borrow(2_000e6);
        vm.stopPrank();
    }

    // Repay
    function test_repay_reducesShares() public _depositEth {
        usdc.mint(address(pool), 20_000e6);
        uint256 borrowAmount = 10_000e6;

        vm.prank(user);
        pool.borrow(borrowAmount);
        (,, uint256 borrowShares) = pool.users(user);

        _passTime(90 days);

        vm.startPrank(user);
        usdc.approve(address(pool), 5_000e6);
        pool.repay(5_000e6);
        vm.stopPrank();

        (,, uint256 borrowSharesAfterRepay) = pool.users(user);

        assertLt(borrowSharesAfterRepay, borrowShares);
    }

    function test_repay_capsAtTotalDebt() public _depositEth {
        usdc.mint(address(pool), 20_000e6);
        uint256 borrowAmount = 10_000e6;

        vm.prank(user);
        pool.borrow(borrowAmount);

        uint256 mintAmount = 5_000e6;

        usdc.mint(user, mintAmount);

        vm.startPrank(user);
        usdc.approve(address(pool), type(uint256).max);
        pool.repay(mintAmount + borrowAmount);
        vm.stopPrank();

        (,, uint256 borrowSharesAfterRepay) = pool.users(user);

        assertEq(usdc.balanceOf(user), mintAmount);
        assertEq(borrowSharesAfterRepay, 0);
    }

    function test_repay_revertZeroAmount() public {
        _setupBorrowPosition(user, 5 ether, 4000e6);

        vm.prank(user);
        vm.expectRevert(ZeroAmount.selector);
        pool.repay(0);
    }

    // liquidate
    function test_liquidate_revertsIfHealthFactorOk() public {
        // user  - collateral to deposit - borrow amount
        _setupBorrowPosition(user, 10 ether, 10_000e6);

        vm.prank(liquidator);
        vm.expectRevert(HealthFactorOk.selector);
        pool.liquidate(user, 5_000e6);
    }

    function test_liquidate_transfersCollateralToLiquidator() public {
        _setupBorrowPosition(user, 10 ether, 10_000e6);

        uint256 debtToCover = 5_000e6;
        uint256 currentPrice = 1200e18;
        _setPrice(1200e8);

        uint256 liqBalanceBefore = liquidator.balance;
        (,, uint256 sharesBefore) = pool.users(user);

        vm.prank(liquidator);
        pool.liquidate(user, debtToCover);

        uint256 scaledDebt = debtToCover * pool.USDC_SCALE();
        uint256 expectedCollateralOut = (scaledDebt * (100 + pool.LIQ_BONUS())) / ((currentPrice * 100) / 1e18);

        assertEq(liquidator.balance - liqBalanceBefore, expectedCollateralOut);
        (,, uint256 sharesAfter) = pool.users(user);

        uint256 expectedSharesRemoved = (scaledDebt * pool.PRECISION()) / pool.globalBorrowIndex();
        assertEq(sharesBefore - sharesAfter, expectedSharesRemoved);
    }

    function test_liquidate_reducesUserDebt() public {
        _setupBorrowPosition(user, 10 ether, 10_000e6);

        uint256 debtToCover = 5_000e6;

        _setPrice(1200e8);

        (,, uint256 sharesBefore) = pool.users(user);
        (, uint256 expectedShares) = _setupLiquidate(debtToCover, 1200e18);

        vm.prank(liquidator);
        pool.liquidate(user, debtToCover);

        (,, uint256 sharesAfter) = pool.users(user);
        assertEq(sharesBefore - sharesAfter, expectedShares);
    }

    function test_liquidate_partialLiquidation() public {
        _setupBorrowPosition(user, 10 ether, 10_000e6);
        _setPrice(1200e8);

        vm.prank(liquidator);
        pool.liquidate(user, 5_000e6);

        (,, uint256 sharesAfter) = pool.users(user);
        assertGt(sharesAfter, 0);
    }

    function test_liquidate_capsAtTotalDebt() public {
        _setupBorrowPosition(user, 5 ether, 5_000e6);

        uint256 currentDebt = 5_000e6;
        _setPrice(1200e8);

        uint256 liquidatorBalanceBefore = usdc.balanceOf(liquidator);

        vm.prank(liquidator);
        pool.liquidate(user, 100_000e6);

        assertEq(usdc.balanceOf(liquidator), liquidatorBalanceBefore - currentDebt);
    }

    function test_liquidate_capsAtAvailableCollateral() public {
        _setupBorrowPosition(user, 1.5 ether, 1600e6);

        _setPrice(1000e8);

        uint256 liqBalanceBefore = liquidator.balance;

        vm.prank(liquidator);
        pool.liquidate(user, 1600e6);

        assertEq(liquidator.balance - liqBalanceBefore, 1.5 ether, "Liquidator should be capped at 1.5 ETH");

        (uint256 collateral,,) = pool.users(user);
        assertEq(collateral, 0, "User should have 0 collateral left");
    }

    function test_liquidate_revertsOnZeroAmount() public {
        vm.prank(liquidator);
        vm.expectRevert(ZeroAmount.selector);
        pool.liquidate(user, 0);
    }

    // Interest
    function test_interest_accruedAfterTime() public {
        _setupBorrowPosition(user, 10 ether, 10_000e6);
        uint256 principal = 10_000e6 * pool.USDC_SCALE();

        (,, uint256 shares) = pool.users(user);

        uint256 timePassed = 365 days;
        uint256 indexAtStart = pool.globalBorrowIndex();

        _passTime(timePassed);

        uint256 expectedIndex = indexAtStart + (indexAtStart * pool.INTEREST_RATE() * timePassed) / (100 * 365 days);

        uint256 expectedDebt = (shares * expectedIndex) / pool.PRECISION();
        console.log(expectedDebt, principal);
        assertGt(expectedDebt, principal);
    }

    function test_interest_zeroIfNoTimePassed() public {
        _setupBorrowPosition(user, 10 ether, 10_000e6);
        uint256 principal = 10_000e6 * pool.USDC_SCALE();

        (,, uint256 shares) = pool.users(user);
        uint256 expectedDebt = (shares * pool.globalBorrowIndex()) / pool.PRECISION();

        assertEq(principal, expectedDebt);
    }

    // Price
    function test_price_revertsOnInvalidPrice() public _depositEth {
        usdc.mint(address(pool), 1000e6);

        price.setPrice(0);

        vm.prank(user);
        vm.expectRevert(InvalidPrice.selector);
        pool.borrow(100e6);
    }

    function test_price_revertsOnExpiredPrice() public _depositEth {
        price.setPrice(initPrice);

        vm.warp(block.timestamp + 25 hours);

        address freshUser = makeAddr("freshUser");
        vm.deal(freshUser, 1 ether);
        vm.startPrank(freshUser);
        pool.depositCollateral{value: 1 ether}();

        vm.expectRevert(PriceExpired.selector);
        pool.borrow(10e6);
        vm.stopPrank();
    }

    function test_price_highDecimalsBranch() public {
        price.setDecimals(20);
        price.setPrice(2000 * 1e20);

        _setupBorrowPosition(user, 1 ether, 100e6);

        (uint256 collateral,,) = pool.users(user);
        uint256 collateralValue = (collateral * pool.getPrice()) / pool.PRECISION();

        assertEq(collateralValue, 2000e18);
    }

    // index
    function test_updateIndex_branches() public {
        usdc.mint(address(pool), 1000e6);
        _setupBorrowPosition(user, 1 ether, 100e6);
        vm.warp(block.timestamp + 1 hours);

        vm.prank(user);
        usdc.approve(address(pool), 10e6);
        pool.repay(10e6);
        assertGt(pool.globalBorrowIndex(), 1e18);
    }
}

contract RejectETH {
    receive() external payable {
        revert();
    }
}
