// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../base/BaseTest.sol";
import {HandlerV2} from "./HandlerV2.t.sol";
import {AmagiPoolV2} from "../../src/AmagiPoolV2.sol";

contract AmagiInvariantsV2Test is BaseTest {
    HandlerV2 handler;
    AmagiPoolV2 poolV2;

    function setUp() public override {
        super.setUp();

        vm.startPrank(owner);
        AmagiPoolV2 newLogic = new AmagiPoolV2();
        pool.upgradeToAndCall(
            address(newLogic),
            abi.encodeWithSelector(AmagiPoolV2.initializeV2.selector)
        );
        vm.stopPrank();

        poolV2 = AmagiPoolV2(payable(address(pool)));

        handler = new HandlerV2(poolV2, usdc, priceFeed);
        targetContract(address(handler));
    }

    // Invariant 1: Solvency
    function invariant_solvency() public view {
        uint256 totalAssets = usdc.balanceOf(address(poolV2)) *
            poolV2.USDC_SCALE() +
            ((poolV2.totalBorrowShares() * poolV2.globalBorrowIndex()) / 1e18);

        uint256 totalLiabilities = (poolV2.totalDeposits() *
            poolV2.globalDepositIndex()) / 1e18;

        assertApproxEqAbs(
            totalAssets,
            totalLiabilities,
            1e10,
            "Protocol is insolvent"
        );
    }

    function invariant_depositorBalances() public view {
        uint256 expectedAssets = handler.getCurrentDeposits();
        uint256 actualAssets = (poolV2.totalDeposits() *
            poolV2.globalDepositIndex()) / 1e18;
        assertLe(expectedAssets * poolV2.USDC_SCALE(), actualAssets);
    }

    function invariant_TotalDebtConsistency() public view {
        address[] memory actors = handler.getActors();
        uint256 len = actors.length;
        uint256 sum = 0;
        for (uint256 i = 0; i < len; i++) {
            sum += handler.ghost_userBorrowShares(actors[i]);
        }
        assertEq(poolV2.totalBorrowShares(), sum);
    }
}
