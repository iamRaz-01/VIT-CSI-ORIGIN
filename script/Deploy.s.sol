// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// =============================================================================
// Deploy.s.sol - DCA Vault Protocol Deployment Script
// CSI ORIGIN 2026, PS-12
// =============================================================================

import {Script, console2} from "forge-std/Script.sol";
import {DCAVault}          from "../src/core/DCAVault.sol";
import {DCACoordinator}    from "../src/core/DCACoordinator.sol";
import {DCAHook}           from "../src/core/DCAHook.sol";
import {AaveYieldStrategy} from "../src/strategies/AaveYieldStrategy.sol";
import {MockYieldStrategy} from "../src/strategies/MockYieldStrategy.sol";
import {MockERC20}         from "../src/mocks/MockERC20.sol";
import {MockIntegrationPoolManager} from "../src/mocks/MockIntegrationPoolManager.sol";
import {Hooks}             from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks}            from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey}           from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency}          from "@uniswap/v4-core/src/types/Currency.sol";

contract Deploy is Script {
    address internal envUSDC      = vm.envAddress("USDC_ADDRESS");
    address internal envAave      = vm.envAddress("AAVE_POOL_ADDRESS");
    address internal envPM        = vm.envAddress("POOL_MANAGER_ADDRESS");
    uint256 internal deployerKey  = vm.envUint("DEPLOYER_PRIVATE_KEY");
    address internal deployer     = vm.addr(deployerKey);

    address public usdcToken;
    address public poolManager;
    address public mockToken;
    address public vault;
    address public yieldStrategy;
    address public coordinator;
    address public hook;

    uint160 internal constant HOOK_FLAGS = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

    function run() external {
        if (deployer.balance < 10 ether) {
            vm.deal(deployer, 100 ether);
        }

        vm.startBroadcast(deployerKey);

        // Auto-detect if environment addresses have bytecode (live fork vs local standalone node)
        if (envUSDC.code.length == 0) {
            usdcToken = address(new MockERC20("USD Coin", "USDC", 6));
            console2.log("Local Mock USDC:    ", usdcToken);
        } else {
            usdcToken = envUSDC;
            console2.log("Fork Base USDC:     ", usdcToken);
        }

        if (envPM.code.length == 0) {
            poolManager = address(new MockIntegrationPoolManager());
            console2.log("Local PoolManager:  ", poolManager);
        } else {
            poolManager = envPM;
            console2.log("Fork PoolManager:   ", poolManager);
        }

        // STEP 1 - MockERC20 (counter-asset for the demo pool)
        mockToken = address(new MockERC20("Mock DCA Target", "mDCA", 18));
        console2.log("MockERC20:          ", mockToken);

        // STEP 2 - DCAVault (ERC-4626, deposit asset = USDC)
        vault = address(new DCAVault(usdcToken, "DCA Vault USDC", "dcaUSDC"));
        console2.log("DCAVault:           ", vault);

        // STEP 3 - Yield Strategy (Aave primary on live fork, Mock fallback on local)
        if (envAave.code.length > 0 && usdcToken == envUSDC) {
            yieldStrategy = address(new AaveYieldStrategy(usdcToken, vault, envAave));
            console2.log("Live Aave Strategy: ", yieldStrategy);
        } else {
            yieldStrategy = address(new MockYieldStrategy(usdcToken, vault, 500));
            console2.log("Mock YieldStrategy: ", yieldStrategy);
        }
        DCAVault(vault).setStrategy(yieldStrategy);

        // STEP 4 - DCACoordinator
        coordinator = address(new DCACoordinator(vault, poolManager));
        DCAVault(vault).setCoordinator(coordinator);
        console2.log("DCACoordinator:     ", coordinator);

        // STEP 5 - DCAHook (mined address with 0xC0 flags)
        bytes memory initCode = abi.encodePacked(
            type(DCAHook).creationCode,
            abi.encode(coordinator, poolManager)
        );
        bytes32 initCodeHash = keccak256(initCode);
        bytes32 salt = _mineSalt(deployer, initCodeHash);

        hook = address(new DCAHook{salt: salt}(coordinator, poolManager));
        console2.log("DCAHook:            ", hook);


        // STEP 6 - Configure PoolKey on DCACoordinator
        address token0 = usdcToken < mockToken ? usdcToken : mockToken;
        address token1 = usdcToken < mockToken ? mockToken : usdcToken;

        PoolKey memory key = PoolKey({
            currency0:   Currency.wrap(token0),
            currency1:   Currency.wrap(token1),
            fee:         3000,
            tickSpacing: 60,
            hooks:       IHooks(hook)
        });

        DCACoordinator(coordinator).setPoolKey(key);

        vm.stopBroadcast();

        console2.log("\n=== DEPLOYMENT COMPLETE ===");
        console2.log("USDC:               ", usdcToken);
        console2.log("PoolManager:        ", poolManager);
        console2.log("MockERC20:          ", mockToken);
        console2.log("DCAVault:           ", vault);
        console2.log("YieldStrategy:      ", yieldStrategy);
        console2.log("DCACoordinator:     ", coordinator);
        console2.log("DCAHook:            ", hook);
        console2.log("===========================\n");
    }

    function _mineSalt(address deployerAddr, bytes32 initCodeHash) internal pure returns (bytes32) {
        uint256 salt = 0;
        while (true) {
            address candidate = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xFF), deployerAddr, salt, initCodeHash))))
            );
            if (uint160(candidate) & Hooks.ALL_HOOK_MASK == HOOK_FLAGS) {
                return bytes32(salt);
            }
            unchecked { salt++; }
        }
        return bytes32(0);
    }
}


