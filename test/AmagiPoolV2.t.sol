// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {AmagiPoolV2, ProtocolPaused, ZeroAmount, InsufficientBalance, InsufficientCollateral, HealthFactorOk, InvalidHealthFactor, InsufficientLiquidity, TransferFailed, PriceExpired, InvalidPrice} from "../src/AmagiPoolV2.sol";
import {AmagiPool} from "../src/AmagiPool.sol";
import {MockPriceFeed} from "./mocks/MockPriceFeed.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

contract AmagiPoolV2Test is Test {
    AmagiPool public pool; // V1 proxy
    AmagiPoolV2 public poolV2;
    MockUSDC public usdc;
    MockPriceFeed public price;

    address owner = address(this);
    address toko = makeAddr("toko");
    address noa = makeAddr("noa");
    address liquidator = makeAddr("liquidator");

    uint256 constant INITIAL_USDC = 10_000e6;
    uint256 constant INITIAL_ETH = 10 ether;

    function setUp() public {
        usdc = new MockUSDC();
        price = new MockPriceFeed(2000e8);

        AmagiPool implementation = new AmagiPool();
        bytes memory data = abi.encodeWithSelector(
            AmagiPool.initialize.selector,
            address(usdc),
            address(price)
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), data);
        pool = AmagiPool(payable(address(proxy)));
        _upgrade();

        usdc.mint(address(poolV2), INITIAL_USDC);

        usdc.mint(liquidator, 10_000e6);
        vm.prank(liquidator);
        usdc.approve(address(poolV2), type(uint256).max);
    }

    function _userDepositsUsdc(address _user, uint256 amount) internal {
        vm.startPrank(_user);
        usdc.mint(_user, amount);
        usdc.approve(address(poolV2), type(uint256).max);
        poolV2.deposit(amount);
        vm.stopPrank();
    }

    function _userDepositsEth(address _user, uint256 amount) internal {
        vm.deal(_user, amount);
        vm.prank(_user);
        poolV2.depositCollateral{value: amount}();
    }

    function _upgrade() internal {
        AmagiPoolV2 newLogic = new AmagiPoolV2();
        bytes memory data = abi.encodeWithSelector(
            AmagiPoolV2.initializeV2.selector
        );
        vm.prank(owner);
        pool.upgradeToAndCall(address(newLogic), data);

        poolV2 = AmagiPoolV2(payable(address(pool)));
    }

    function test_MiscellaneousFunctions() public {
        // 1: receive()
        vm.deal(toko, 1 ether);
        vm.prank(toko);
        (bool success, ) = address(poolV2).call{value: 1 ether}("");
        assertTrue(success, "Contract should accept plain ETH");

        // 2: getPrice()
        uint256 p = poolV2.getPrice();
        assertGt(p, 0);

        // 3: balanceOf()
        _userDepositsUsdc(noa, 1000e6);
        uint256 bal = poolV2.balanceOf(noa);
        assertEq(bal, 1000e6);
    }

    function test_AdminFunctionsAndEmptyPool() public {
        assertEq(poolV2.getUtilization(), 0);

        vm.prank(owner);
        poolV2.setIrmParams(0.01e18, 0.05e18, 3e18, 0.9e18);

        assertEq(poolV2.BASE_RATE(), 0.01e18);
    }

    /* ------------------------------------------------
    Deposit & Withdraw
    --------------------------------------------------*/
    // Happy Paths
    function test_DepositCalculatesSharesCorrectly() public {
        _userDepositsUsdc(toko, INITIAL_USDC);

        (, , uint256 depositShare) = poolV2.users(toko);

        assertEq(depositShare, INITIAL_USDC * poolV2.USDC_SCALE());
    }

    function test_WithdrawFullyCoversShares() public {
        _userDepositsUsdc(toko, 1000e6);
        vm.prank(toko);
        poolV2.withdraw(1000e6);

        (, , uint256 shares) = poolV2.users(toko);
        assertEq(shares, 0, "All shares should be removed");
        assertEq(poolV2.totalDeposits(), 0, "Global deposits should be zero");
    }

    function test_Withdraw() public {
        _userDepositsUsdc(toko, 1000e6);

        vm.prank(toko);
        poolV2.withdraw(500e6);

        assertEq(usdc.balanceOf(toko), 500e6);
    }

    // Reverts
    function test_DepositRevertsOnZeroAmount() public {
        _userDepositsUsdc(toko, INITIAL_USDC);

        vm.prank(toko);
        vm.expectRevert(ZeroAmount.selector);
        poolV2.deposit(0);
    }

    function test_WithdrawRevertOnZeroAmount() public {
        _userDepositsUsdc(toko, 1000e6);
        vm.prank(toko);
        vm.expectRevert(ZeroAmount.selector);
        poolV2.withdraw(0);
    }

    function test_WithdrawRevertOnInsufficientBalance() public {
        _userDepositsUsdc(toko, 1000e6);
        vm.prank(toko);
        vm.expectRevert(InsufficientBalance.selector);
        poolV2.withdraw(1001e6); // მომხმარებელს არ აქვს ამდენი წილი
    }

    function test_WithdrawRevertsOnInsufficientLiquidity() public {
        _userDepositsUsdc(toko, 1000e6);
        _userDepositsEth(noa, 20 ether);

        vm.prank(noa);
        poolV2.borrow(11_000e6);

        vm.prank(toko);
        vm.expectRevert(InsufficientLiquidity.selector);
        poolV2.withdraw(500e6);
    }

    /*---------------------------------------------------
    Collateral
    ----------------------------------------------------*/
    // Happy paths
    function test_WithdrawCollateralWithNoDebt() public {
        _userDepositsEth(toko, 2 ether);

        vm.prank(toko);
        poolV2.withdrawCollateral(1 ether);

        (uint128 collateral, , ) = poolV2.users(toko);
        assertEq(collateral, 1 ether);
    }

    // Reverts
    function test_DepositCollateralRevertsOnZeroAmount() public {
        vm.deal(toko, 1 ether);
        vm.prank(toko);
        vm.expectRevert(ZeroAmount.selector);
        poolV2.depositCollateral{value: 0}();
    }

    function test_WithdrawCollateralRevertOnZeroAmount() public {
        _userDepositsEth(toko, 1 ether);
        vm.prank(toko);
        vm.expectRevert(ZeroAmount.selector);
        poolV2.withdrawCollateral(0);
    }

    function test_WithdrawCollateralRevertOnInsufficientBalance() public {
        _userDepositsEth(toko, 1 ether);
        vm.prank(toko);
        vm.expectRevert(InsufficientBalance.selector);
        poolV2.withdrawCollateral(1.1 ether);
    }

    function test_WithdrawCollateralRevertOnInvalidHf() public {
        _userDepositsEth(toko, 1 ether);
        vm.prank(toko);
        poolV2.borrow(1400e6);

        price.setPrice(1000e8);

        vm.prank(toko);
        vm.expectRevert(InvalidHealthFactor.selector);
        poolV2.withdrawCollateral(1 ether);
    }

    /*-------------------------------------------------
    Borrow & Repay & Interest
    --------------------------------------------------*/
    // Happy paths
    function test_RepayReducesDebt() public {
        _userDepositsUsdc(toko, INITIAL_USDC);
        _userDepositsEth(noa, 2 ether);

        vm.prank(noa);
        poolV2.borrow(1000e6);

        (, uint128 borrowSharesBefore, ) = poolV2.users(noa);
        uint256 totalBSharesBefore = poolV2.totalBorrowShares();

        vm.warp(block.timestamp + 10 days);

        vm.startPrank(noa);
        usdc.approve(address(pool), type(uint256).max);
        poolV2.repay(500e6);
        vm.stopPrank();

        (, uint128 borrowSharesAfter, ) = poolV2.users(noa);
        uint256 sharesBurned = totalBSharesBefore - poolV2.totalBorrowShares();

        assertGt(uint256(borrowSharesBefore), uint256(borrowSharesAfter));
        assertApproxEqAbs(sharesBurned, 500e18, 1e18);
    }

    function test_InterestAccrualOverTime() public {
        _userDepositsUsdc(toko, 5000e6);
        _userDepositsEth(noa, 1 ether);

        vm.prank(noa);
        poolV2.borrow(1000e6);

        uint256 currentBindex = poolV2.globalBorrowIndex();

        vm.warp(block.timestamp + 30 days);

        _userDepositsUsdc(toko, 1000e6);

        assertGt(poolV2.globalBorrowIndex(), currentBindex);
    }

    function test_HighUtilizationTriggersSlope2() public {
        _userDepositsUsdc(toko, 10_000e6);
        _userDepositsEth(noa, 20 ether);

        vm.prank(noa);
        poolV2.borrow(9000e6);

        // Utilization  > 80%
        uint256 util = poolV2.getUtilization();

        uint256 rate = poolV2.getBorrowRate(util);
        assertGt(
            rate,
            poolV2.BASE_RATE(),
            "Rate should increase due to high utilization"
        );
        assertGt(rate, 0.1e18, "Rate should be very high due to SLOPE2");
    }

    function test_UpdateIndexSameBlock() public {
        _userDepositsUsdc(toko, 1000e6);

        _userDepositsUsdc(toko, 500e6);

        (, , uint256 shares) = poolV2.users(toko);
        assertEq(shares, 1500e6 * poolV2.USDC_SCALE());
    }

    // Reverts
    function test_BorrowRevertOnZeroAmount() public {
        _userDepositsEth(toko, 1 ether);
        vm.prank(toko);
        vm.expectRevert(ZeroAmount.selector);
        poolV2.borrow(0);
    }

    function test_BorrowRevertOnInsufficientCollateral() public {
        _userDepositsEth(toko, 1 ether);

        vm.startPrank(toko);

        poolV2.borrow(1000e6);

        vm.expectRevert(InsufficientCollateral.selector);
        poolV2.borrow(501e6); // max borrow = 1500 usd

        vm.stopPrank();
    }

    function test_RevertIfInsufficientLiquidity() public {
        _userDepositsEth(toko, 10 ether);

        vm.prank(toko);
        vm.expectRevert(InsufficientLiquidity.selector);
        poolV2.borrow(11_000e6);
    }

    function test_RevertIf_RepayWithNoDebt() public {
        vm.startPrank(toko);
        usdc.mint(toko, 100e6);
        usdc.approve(address(pool), 100e6);
        vm.expectRevert(); // უნდა დარეზერვდეს რადგან ვალი 0-ია
        pool.repay(100e6);
        vm.stopPrank();
    }

    function test_RepayRevertOnZeroAmount() public {
        _userDepositsEth(toko, 1 ether);

        vm.startPrank(toko);
        poolV2.borrow(1400e6);

        vm.expectRevert(ZeroAmount.selector);
        poolV2.repay(0);
        vm.stopPrank();
    }

    function test_RepayExcessAmount() public {
        _userDepositsEth(toko, 1 ether);

        vm.prank(toko);
        poolV2.borrow(1400e6);

        usdc.mint(toko, 100e6);
        vm.prank(toko);
        usdc.approve(address(poolV2), type(uint256).max);

        vm.prank(toko);
        poolV2.repay(1500e6);

        assertEq(usdc.balanceOf(toko), 100e6);
    }

    /* ---------------------------------------------
    Liquidation & Oracles
    -----------------------------------------------*/
    // Happy paths
    function test_LiquidationFlow() public {
        _userDepositsEth(toko, 1 ether);

        vm.prank(toko);
        poolV2.borrow(1400e6);

        price.setPrice(1600e8);

        uint256 balanceBefore = address(liquidator).balance;

        vm.prank(liquidator);
        poolV2.liquidate(toko, 500e6);

        uint256 expectedCollateral = (500e18 * 1e18 * 105) / (1600e18 * 100);
        uint256 actualCollateral = address(liquidator).balance - balanceBefore;

        assertApproxEqAbs(
            actualCollateral,
            expectedCollateral,
            1e10,
            "Liquidator bonus incorrect"
        );

        (, uint128 borrowSharesAfter, ) = poolV2.users(toko);
        assertLt(
            uint256(borrowSharesAfter),
            1400e18,
            "Toko's debt should decrease"
        );
    }

    function test_BadDebtLiquidation() public {
        _userDepositsEth(toko, 1 ether);

        vm.prank(toko);
        poolV2.borrow(1400e6);

        price.setPrice(400e8);

        uint256 balanceBefore = address(liquidator).balance;

        vm.prank(liquidator);
        poolV2.liquidate(toko, 1400e6);

        uint256 expectedCollateral = 1e18;
        uint256 actualCollateral = address(liquidator).balance - balanceBefore;

        assertApproxEqAbs(
            actualCollateral,
            expectedCollateral,
            1e10,
            "Liquidator bonus incorrect"
        );

        (uint128 collateral, , ) = poolV2.users(toko);
        assertEq(collateral, 0, "Toko still has a debt");
    }

    function test_LiquidateExcessAmount() public {
        _userDepositsEth(toko, 1 ether);

        vm.prank(toko);
        poolV2.borrow(1000e6);

        price.setPrice(1200e8);

        uint256 liqBalanceBefore = usdc.balanceOf(liquidator);

        vm.prank(liquidator);
        poolV2.liquidate(toko, 2000e6);

        assertEq(
            usdc.balanceOf(liquidator),
            liqBalanceBefore - 1000e6,
            "Should only charge the actual debt even if user requests more"
        );
        (, uint128 borrowSharesAfter, ) = poolV2.users(toko);
        assertEq(borrowSharesAfter, 0, "Debt should be fully cleared");
    }

    // Reverts
    function test_LiquidateRevertOnZeroAmount() public {
        _userDepositsEth(toko, 1 ether);

        vm.prank(toko);
        poolV2.borrow(1400e6);

        price.setPrice(500e6);

        vm.prank(liquidator);
        vm.expectRevert(ZeroAmount.selector);
        poolV2.liquidate(toko, 0);
    }

    function test_LiquidateRevertOnHealthFactorOk() public {
        _userDepositsEth(toko, 1 ether);

        vm.prank(toko);
        poolV2.borrow(800e6);

        price.setPrice(1500e8);

        vm.prank(liquidator);
        vm.expectRevert(HealthFactorOk.selector);
        poolV2.liquidate(toko, 800e6);
    }

    function test_RevertIfPriceExpired() public {
        _userDepositsEth(toko, 1 ether);
        vm.warp(block.timestamp + 25 hours);
        vm.prank(toko);
        vm.expectRevert(PriceExpired.selector);
        poolV2.borrow(100e6);
    }

    function test_RevertIfInvalidPrice() public {
        _userDepositsEth(toko, 1 ether);
        price.setPrice(0);

        vm.prank(toko);
        vm.expectRevert(InvalidPrice.selector);
        poolV2.borrow(100e6);
    }

    /* -------------------------------------------
    Access Control & Pausing
    ---------------------------------------------*/
    // Happy paths
    function test_UnpauseAllowsOperations() public {
        vm.startPrank(owner);
        poolV2.setPaused(true);
        poolV2.setPaused(false);
        vm.stopPrank();

        _userDepositsUsdc(toko, 1000e6);
        (, , uint256 depositShare) = poolV2.users(toko);

        assertGt(depositShare, 0);
    }

    // Reverts
    function test_DepositRevertOnPause() public {
        vm.prank(owner);
        poolV2.setPaused(true);

        vm.startPrank(toko);

        usdc.mint(toko, INITIAL_USDC);
        usdc.approve(address(pool), type(uint256).max);

        vm.expectRevert(ProtocolPaused.selector);
        poolV2.deposit(INITIAL_USDC);

        vm.stopPrank();
    }

    function test_DepositCollateralRevertOnPause() public {
        vm.prank(owner);
        poolV2.setPaused(true);

        vm.deal(toko, INITIAL_ETH);

        vm.prank(toko);
        vm.expectRevert(ProtocolPaused.selector);
        poolV2.depositCollateral{value: INITIAL_ETH}();

        vm.stopPrank();
    }

    function test_BorrowRevertOnPause() public {
        _userDepositsEth(toko, INITIAL_ETH);

        vm.prank(owner);
        poolV2.setPaused(true);

        vm.prank(toko);
        vm.expectRevert(ProtocolPaused.selector);
        poolV2.borrow(1000e6);
    }

    function test_WithdrawRevertOnPause() public {
        _userDepositsUsdc(toko, INITIAL_USDC);

        vm.prank(owner);
        poolV2.setPaused(true);

        vm.prank(toko);
        vm.expectRevert(ProtocolPaused.selector);
        poolV2.withdraw(1000e6);
    }

    function test_WithdrawCollateralRevertOnPause() public {
        _userDepositsEth(toko, INITIAL_ETH);

        vm.prank(owner);
        poolV2.setPaused(true);

        vm.prank(toko);
        vm.expectRevert(ProtocolPaused.selector);
        poolV2.withdrawCollateral(1 ether);

        vm.stopPrank();
    }

    function test_LiquidationRevertOnPause() public {
        _userDepositsEth(toko, 1 ether);

        vm.prank(toko);
        poolV2.borrow(1500e6);

        price.setPrice(700e8);

        vm.prank(owner);
        poolV2.setPaused(true);

        vm.prank(liquidator);
        vm.expectRevert(ProtocolPaused.selector);
        poolV2.liquidate(toko, 1500e6);
    }
    function test_RepayRevertOnPause() public {
        _userDepositsEth(toko, INITIAL_ETH);

        vm.prank(toko);
        poolV2.borrow(1000e6);

        vm.prank(owner);
        poolV2.setPaused(true);

        vm.prank(toko);
        vm.expectRevert(ProtocolPaused.selector);
        poolV2.repay(800e6);
    }
    function test_UpgradeOnlyOwner() public {
        AmagiPoolV2 newImpl = new AmagiPoolV2();
        bytes memory data = abi.encodeWithSelector(
            AmagiPoolV2.initializeV2.selector
        );
        vm.prank(toko);
        vm.expectRevert();
        pool.upgradeToAndCall(address(newImpl), data);
    }

    function test_RevertIfEthTransferFails() public {
        BadReceiver badUser = new BadReceiver();
        vm.deal(address(badUser), 1 ether);
        badUser.deposit{value: 1 ether}(address(poolV2));

        vm.prank(address(badUser));
        vm.expectRevert(TransferFailed.selector);
        badUser.withdraw(address(poolV2), 1 ether);
    }
}

// Create contracts that that doesn't have receiving function
contract BadReceiver {
    function deposit(address pool) external payable {
        AmagiPoolV2(payable(pool)).depositCollateral{value: msg.value}();
    }

    function withdraw(address pool, uint256 amount) external {
        AmagiPoolV2(payable(pool)).withdrawCollateral(amount);
    }
}
