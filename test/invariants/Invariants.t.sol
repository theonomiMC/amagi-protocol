// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../base/BaseTest.sol";
import {Handler} from "./Handler.sol";

contract AmagiInvariantsTest is BaseTest {
    Handler handler;

    function setUp() public override {
        super.setUp();
        handler = new Handler(pool, usdc, priceFeed);
        targetContract(address(handler));
    }

    // HELPER
    function getHealthFactor(uint256 collateral, uint256 borrowShares) internal view returns (uint256) {
        if (borrowShares == 0) return type(uint256).max;

        uint256 debt = (borrowShares * pool.globalBorrowIndex()) / pool.PRECISION();

        if (debt == 0) return type(uint256).max;

        uint256 hf = (collateral * pool.getPrice() * pool.LIQ_THRESHOLD()) / (100 * debt);
        return hf;
    }

    // Invariant 1: Solvency
    function invariant_solvency() public view {
        uint256 totalPlus =
            handler.ghost_totalDeposits() + handler.ghost_totalRepaid() + handler.ghost_totalLiquidated();

        uint256 totalMinus = handler.ghost_totalBorrowed();

        uint256 expectedBalance = (totalPlus - totalMinus) / pool.USDC_SCALE();
        assertGe(usdc.balanceOf(address(pool)), expectedBalance);
    }

    // Invariant 2: Collateral insolvency
    function invariant_noBadDebt() public view {
        uint256 len = handler.activeBorrowersLength();
        for (uint256 i; i < len; i++) {
            address user = handler.activeBorrowersAt(i);
            (uint128 collateral, uint128 borrowShares,) = pool.users(user);

            if (borrowShares == 0) continue;

            uint256 debt = (uint256(borrowShares) * pool.globalBorrowIndex()) / pool.PRECISION();
            uint256 collateralValue = (uint256(collateral) * pool.getPrice()) / pool.PRECISION();

            assertGe(collateralValue, debt, "Protocol has Bad Debt!");
        }
    }

    // Invariant 3:
    function invariant_healthFactorValid() public view {
        uint256 len = handler.activeBorrowersLength();
        for (uint256 i; i < len; i++) {
            address user = handler.activeBorrowersAt(i);
            (uint128 collateral, uint128 borrowShares,) = pool.users(user);

            if (borrowShares == 0) continue;

            uint256 hf = getHealthFactor(uint256(collateral), uint256(borrowShares));

            assertGe(hf, pool.PRECISION(), "Protocol has Bad Debt!");
        }
    }

    // Invariant 4:
    function invariant_indexMonotonicity() public view {
        assertGe(pool.globalBorrowIndex(), handler.previousIndex(), "Index decreased");
    }
}
