// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// =============================================================================
// DeployFrontend.s.sol - Simplified deployment for frontend demo
// Deploys Vault + MockYieldStrategy + Coordinator WITHOUT the Hook
// The coordinator operates in stub mode (direct withdraw, no swap) which
// is sufficient for demonstrating the frontend user journey.
// =============================================================================

import {Script, console2} from "forge-std/Script.sol";
import {DCAVault}          from "../src/core/DCAVault.sol";
import {DCACoordinator}    from "../src/core/DCACoordinator.sol";
import {MockYieldStrategy} from "../src/strategies/MockYieldStrategy.sol";
import {MockERC20}         from "../src/mocks/MockERC20.sol";
import {IERC20}            from "@openzeppelin/token/ERC20/IERC20.sol";

contract DeployFrontend is Script {
    uint256 internal deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address internal deployer   = vm.addr(deployerKey);

    // Anvil default accounts
    address constant USER_A = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address constant USER_B = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;

    function run() external {
        // Fund the deployer on Anvil
        vm.deal(deployer, 100 ether);
        vm.deal(USER_A, 100 ether);
        vm.deal(USER_B, 100 ether);

        vm.startBroadcast(deployerKey);

        // STEP 1 - Deploy MockERC20 as USDC stand-in (6 decimals)
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        console2.log("USDC (Mock):        ", address(usdc));

        // STEP 2 - Deploy MockERC20 as target token
        MockERC20 mockToken = new MockERC20("Mock DCA Target", "mDCA", 18);
        console2.log("MockToken:          ", address(mockToken));

        // STEP 3 - Deploy DCAVault
        DCAVault vault = new DCAVault(address(usdc), "DCA Vault USDC", "dcaUSDC");
        console2.log("DCAVault:           ", address(vault));

        // STEP 4 - Deploy MockYieldStrategy (5% APR, deterministic)
        MockYieldStrategy strategy = new MockYieldStrategy(address(usdc), address(vault), 500);
        vault.setStrategy(address(strategy));
        console2.log("MockYieldStrategy:  ", address(strategy));

        // STEP 5 - Deploy DCACoordinator (no pool manager — stub mode)
        //          In stub mode, poke() does direct vault withdrawal (1:1, no swap)
        DCACoordinator coordinator = new DCACoordinator(address(vault), address(0));
        vault.setCoordinator(address(coordinator));
        console2.log("DCACoordinator:     ", address(coordinator));

        // STEP 6 - Mint USDC to demo users
        usdc.mint(USER_A, 100_000e6);  // 100,000 USDC
        usdc.mint(USER_B, 100_000e6);  // 100,000 USDC
        console2.log("Minted 100k USDC to User A and B");

        vm.stopBroadcast();

        console2.log("\n=== FRONTEND DEPLOYMENT COMPLETE ===");
        console2.log("USDC:              ", address(usdc));
        console2.log("MockToken:         ", address(mockToken));
        console2.log("DCAVault:          ", address(vault));
        console2.log("MockYieldStrategy: ", address(strategy));
        console2.log("DCACoordinator:    ", address(coordinator));
        console2.log("User A:            ", USER_A);
        console2.log("User B:            ", USER_B);
        console2.log("====================================\n");
        console2.log("UPDATE frontend/config.js with these addresses!");
    }
}
