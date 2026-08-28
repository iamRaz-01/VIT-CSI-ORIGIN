// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ForkTestBase} from "./ForkTestBase.sol";
import {DCAVault} from "../src/core/DCAVault.sol";
import {AaveYieldStrategy} from "../src/strategies/AaveYieldStrategy.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {console2} from "forge-std/console2.sol";

contract LiveAaveForkTest is ForkTestBase {
    DCAVault internal aaveVault;
    AaveYieldStrategy internal aaveStrategy;

    function _deployContracts() internal override {
        // Deploy real DCAVault with AaveYieldStrategy against live Base Mainnet Aave Pool
        aaveVault = new DCAVault(USDC, "DCA Vault USDC", "dcaUSDC");
        aaveStrategy = new AaveYieldStrategy(USDC, address(aaveVault), AAVE_POOL);
        aaveVault.setStrategy(address(aaveStrategy));
    }

    function test_liveAave_deposit_and_totalAssets() public {
        uint256 depositAmount = 10_000e6; // 10,000 USDC

        // Check initial state
        assertEq(aaveVault.totalAssets(), 0, "Initial assets should be 0");

        // User A approves and deposits
        vm.startPrank(USER_A);
        IERC20(USDC).approve(address(aaveVault), depositAmount);
        uint256 shares = aaveVault.deposit(depositAmount, USER_A);
        vm.stopPrank();

        assertGt(shares, 0, "Shares should be minted");
        assertEq(aaveVault.balanceOf(USER_A), shares, "User A share balance matches");
        
        // Check total assets after deposit into live Aave Pool
        uint256 assetsAfter = aaveVault.totalAssets();
        console2.log("Live Aave totalAssets after 10,000 USDC deposit:", assetsAfter);
        assertApproxEqAbs(assetsAfter, depositAmount, 2, "Total assets matches deposit within ray rounding");
        assertGt(assetsAfter, 9_999e6, "Assets close to deposit");

        // Warp 30 days to observe live aToken rebasing interest
        vm.warp(block.timestamp + 30 days);
        uint256 assetsAfter30Days = aaveVault.totalAssets();
        console2.log("Live Aave totalAssets after 30 days:", assetsAfter30Days);
        assertGe(assetsAfter30Days, assetsAfter, "Assets should grow with real Aave yield");

        // Test user withdrawal from live Aave Pool
        vm.startPrank(USER_A);
        uint256 usdcBefore = IERC20(USDC).balanceOf(USER_A);
        aaveVault.withdraw(depositAmount, USER_A, USER_A);
        uint256 usdcAfter = IERC20(USDC).balanceOf(USER_A);
        vm.stopPrank();

        assertEq(usdcAfter - usdcBefore, depositAmount, "User receives withdrawn USDC from Aave");
        console2.log("Successfully withdrew from live Aave Pool");
    }
}
