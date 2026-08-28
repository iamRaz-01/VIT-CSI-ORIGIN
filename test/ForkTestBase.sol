// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// =============================================================================
// ForkTestBase.sol - Shared base contract for all fork-based tests
// CSI ORIGIN 2026, PS-12
//
// Provides:
//   - Anvil Base fork setup (reads BASE_RPC_URL + FORK_BLOCK_NUMBER from env,
//     with a fallback to a public endpoint so CI works without a .env file)
//   - Demo wallet setup (User A, User B with test ETH + USDC)
//   - Access to live Aave v3 Pool, Uniswap v4 PoolManager on the fork
//   - evm_snapshot/evm_revert helpers for repeatable test isolation
//
// All test contracts that run against the fork should inherit this.
// Unit tests (DecisionEngine.t.sol) do NOT need fork setup and should not
// inherit this - they're pure Solidity tests with no external calls.
// =============================================================================

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

abstract contract ForkTestBase is Test {
    // -------------------------------------------------------------------------
    // Live addresses on Base mainnet (inherited by the fork)
    // -------------------------------------------------------------------------
    address internal constant USDC         = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant AAVE_POOL    = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address internal constant POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;

    // Known large USDC holder on Base - impersonatable on the fork
    address internal constant USDC_WHALE   = 0x0B0A5886664376F59C351ba3f598C8A8B4D0A6f3;

    // -------------------------------------------------------------------------
    // Demo personas
    // -------------------------------------------------------------------------
    address internal USER_A = makeAddr("USER_A");
    address internal USER_B = makeAddr("USER_B");
    uint256 internal constant DEMO_USDC_AMOUNT = 1_000_000e6; // 1M USDC
    uint256 internal constant DEMO_ETH_AMOUNT  = 100 ether;

    // -------------------------------------------------------------------------
    // Fork handle for vm.selectFork / vm.rollFork
    // -------------------------------------------------------------------------
    uint256 internal forkId;

    // -------------------------------------------------------------------------
    // setUp() - called before each test function by the Foundry test runner
    // -------------------------------------------------------------------------
    function setUp() public virtual {
        // Create a fork from env or fall back to public Base endpoint.
        // Using a pinned block ensures deterministic test results.
        string memory rpcUrl    = vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org"));
        uint256 forkBlock       = vm.envOr("FORK_BLOCK_NUMBER", uint256(0));

        if (forkBlock == 0) {
            forkId = vm.createSelectFork(rpcUrl);
        } else {
            forkId = vm.createSelectFork(rpcUrl, forkBlock);
        }

        // Fund demo wallets from the whale
        _fundWallet(USER_A);
        _fundWallet(USER_B);

        // Child contracts call their own deploy hooks after super.setUp()
        _deployContracts();
    }

    // -------------------------------------------------------------------------
    // Override in each test contract to deploy the contracts under test
    // -------------------------------------------------------------------------
    function _deployContracts() internal virtual {}

    // -------------------------------------------------------------------------
    // Wallet funding helpers
    // -------------------------------------------------------------------------
    function _fundWallet(address wallet) internal {
        vm.deal(wallet, DEMO_ETH_AMOUNT);
        vm.prank(USDC_WHALE);
        IERC20(USDC).transfer(wallet, DEMO_USDC_AMOUNT);
    }

    // -------------------------------------------------------------------------
    // Snapshot/revert helpers (mirrors evm_snapshot / evm_revert)
    // -------------------------------------------------------------------------
    uint256 private _snapshotId;

    function _snapshot() internal {
        _snapshotId = vm.snapshot();
    }

    function _revert() internal {
        vm.revertTo(_snapshotId);
    }
}
