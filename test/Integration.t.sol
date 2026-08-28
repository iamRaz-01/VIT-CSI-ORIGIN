// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// =============================================================================
// Integration.t.sol - End-to-End 2-User Integration Test
// CSI ORIGIN 2026, PS-12
//
// Verifies the complete Critical Demo Path (Technical Architecture §4, §21):
//
//   1. User A and User B each deposit USDC -> totalAssets() grows (yield accrual)
//   2. Both have distinct Constraints set (per-user isolation)
//   3. poke(A) in good market -> EXECUTE_FULL, atomic withdraw+swap, events correct
//   4. poke(A) with tight maxSlippageBps -> DCAHook reverts, vault unchanged (atomicity)
//   5. poke(B) same market snapshot, different Constraints -> different logged action
//   6. All of the above reproducible from evm_revert to snapshot
//
// INTERFACE_CONTRACTS.md §11.2 (Feature 7 demo verification),
// Technical Architecture §21 (Definition of Done checklist).
// =============================================================================

import {Test, console2}  from "forge-std/Test.sol";
import {ForkTestBase}    from "./ForkTestBase.sol";

import {DCAVault}          from "../src/core/DCAVault.sol";
import {DCACoordinator}    from "../src/core/DCACoordinator.sol";
import {DCAHook}           from "../src/core/DCAHook.sol";
import {MockYieldStrategy} from "../src/strategies/MockYieldStrategy.sol";
import {MockERC20}         from "../src/mocks/MockERC20.sol";
import {Constraints, IDCACoordinator} from "../src/interfaces/IDCACoordinator.sol";

import {IHooks}            from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager}      from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback}   from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks}             from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey}           from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency}          from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta}   from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

// =============================================================================
// MockIntegrationPoolManager — simulates Uniswap v4 PoolManager for integration
// Implements unlock, sync, settle, swap, take, extsload to test full hook flow.
// =============================================================================
contract MockIntegrationPoolManager is IPoolManager {
    using PoolIdLibrary for PoolKey;

    uint160 public mockSqrtPriceX96;
    int128  public mockSlippageBps; // Simulated slippage during swap

    function setSlot0(uint160 sqrtPriceX96) external {
        mockSqrtPriceX96 = sqrtPriceX96;
    }

    function setSlippageBps(int128 bps) external {
        mockSlippageBps = bps;
    }

    function extsload(bytes32 /* slot */) external view override returns (bytes32) {
        return bytes32(uint256(mockSqrtPriceX96));
    }

    function extsload(bytes32 /* startSlot */, uint256 /* nSlots */) external view override returns (bytes32[] memory) {
        bytes32[] memory res = new bytes32[](1);
        res[0] = bytes32(uint256(mockSqrtPriceX96));
        return res;
    }

    function extsload(bytes32[] calldata /* slots */) external view override returns (bytes32[] memory) {
        bytes32[] memory res = new bytes32[](1);
        res[0] = bytes32(uint256(mockSqrtPriceX96));
        return res;
    }

    function unlock(bytes calldata data) external override returns (bytes memory) {
        return IUnlockCallback(msg.sender).unlockCallback(data);
    }

    function sync(Currency /* currency */) external override {}

    function settle() external payable override returns (uint256) {
        return 0;
    }

    function settleFor(address /* recipient */) external payable override returns (uint256) {
        return 0;
    }

    function clear(Currency /* currency */, uint256 /* amount */) external override {}

    function mint(address /* to */, uint256 /* id */, uint256 /* amount */) external override {}

    function burn(address /* from */, uint256 /* id */, uint256 /* amount */) external override {}

    // IExttload
    function exttload(bytes32[] calldata /* slots */) external view override returns (bytes32[] memory) { return new bytes32[](0); }
    function exttload(bytes32 /* slot */) external view override returns (bytes32) { return bytes32(0); }

    // IProtocolFees
    function protocolFeeController() external view override returns (address) { return address(0); }
    function protocolFeesAccrued(Currency /* currency */) external view override returns (uint256) { return 0; }
    function setProtocolFee(PoolKey memory /* key */, uint24 /* newProtocolFee */) external override {}
    function setProtocolFeeController(address /* controller */) external override {}
    function collectProtocolFees(address /* recipient */, Currency /* currency */, uint256 /* amount */) external override returns (uint256) { return 0; }

    // IERC6909Claims
    function allowance(address /* owner */, address /* spender */, uint256 /* id */) external view override returns (uint256) { return 0; }
    function approve(address /* spender */, uint256 /* id */, uint256 /* amount */) external override returns (bool) { return true; }
    function balanceOf(address /* owner */, uint256 /* id */) external view override returns (uint256) { return 0; }
    function isOperator(address /* owner */, address /* spender */) external view override returns (bool) { return false; }
    function setOperator(address /* operator */, bool /* approved */) external override returns (bool) { return true; }
    function transfer(address /* receiver */, uint256 /* id */, uint256 /* amount */) external override returns (bool) { return true; }
    function transferFrom(address /* sender */, address /* receiver */, uint256 /* id */, uint256 /* amount */) external override returns (bool) { return true; }

    function updateDynamicLPFee(PoolKey memory /* key */, uint24 /* newDynamicLPFee */) external override {}

    function initialize(PoolKey memory /* key */, uint160 /* sqrtPriceX96 */) external override returns (int24) {
        return 0;
    }

    function modifyLiquidity(
        PoolKey memory /* key */,
        IPoolManager.ModifyLiquidityParams memory /* params */,
        bytes calldata /* hookData */
    ) external override returns (BalanceDelta, BalanceDelta) {
        return (toBalanceDelta(0, 0), toBalanceDelta(0, 0));
    }

    function donate(PoolKey memory /* key */, uint256 /* a0 */, uint256 /* a1 */, bytes calldata /* hookData */)
        external override returns (BalanceDelta) {
        return toBalanceDelta(0, 0);
    }

    function swap(
        PoolKey memory key,
        IPoolManager.SwapParams memory params,
        bytes calldata hookData
    ) external override returns (BalanceDelta swapDelta) {
        // 1. Call beforeSwap on hook
        if (address(key.hooks) != address(0)) {
            key.hooks.beforeSwap(msg.sender, key, params, hookData);
        }

        // 2. Compute output amounts with simulated slippage
        uint256 amountIn = uint256(-params.amountSpecified);
        uint256 amountOut = amountIn;
        if (mockSlippageBps > 0) {
            amountOut = amountIn - (amountIn * uint256(int256(mockSlippageBps))) / 10_000;
        }

        int128 a0;
        int128 a1;
        if (params.zeroForOne) {
            a0 = -int128(uint128(amountIn));
            a1 = int128(uint128(amountOut));
        } else {
            a0 = int128(uint128(amountOut));
            a1 = -int128(uint128(amountIn));
        }
        swapDelta = toBalanceDelta(a0, a1);

        // 3. Call afterSwap on hook
        if (address(key.hooks) != address(0)) {
            key.hooks.afterSwap(msg.sender, key, params, swapDelta, hookData);
        }

        return swapDelta;
    }

    function take(Currency currency, address to, uint256 amount) external override {
        // Mint output token directly to user
        MockERC20(Currency.unwrap(currency)).mint(to, amount);
    }
}

// =============================================================================
// IntegrationTest — End-to-End Integration Suite
// =============================================================================
contract IntegrationTest is ForkTestBase {
    using PoolIdLibrary for PoolKey;

    MockERC20                  internal mockUSDC;
    MockERC20                  internal mockToken;
    DCAVault                   internal vault;
    MockYieldStrategy          internal strategy;
    DCACoordinator             internal coordinator;
    DCAHook                    internal hook;
    MockIntegrationPoolManager internal poolManagerMock;
    PoolKey                    internal poolKey;

    uint160 constant HOOK_FLAGS = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
    uint160 constant INITIAL_SQRT_PRICE = 79228162514264337593543950336; // 1:1 Q96

    function _deployContracts() internal override {
        // 1. Tokens
        mockUSDC  = new MockERC20("USD Coin", "USDC", 6);
        mockToken = new MockERC20("Mock Target", "mDCA", 18);

        // Ensure token ordering: currency0 < currency1
        address token0 = address(mockUSDC) < address(mockToken) ? address(mockUSDC) : address(mockToken);
        address token1 = address(mockUSDC) < address(mockToken) ? address(mockToken) : address(mockUSDC);

        // 2. PoolManager
        poolManagerMock = new MockIntegrationPoolManager();
        poolManagerMock.setSlot0(INITIAL_SQRT_PRICE);

        // 3. Vault & Strategy
        vault = new DCAVault(address(mockUSDC), "DCA Vault USDC", "dcaUSDC");
        strategy = new MockYieldStrategy(address(mockUSDC), address(vault), 500); // 5% APR
        vault.setStrategy(address(strategy));

        // 4. Coordinator
        coordinator = new DCACoordinator(address(vault), address(poolManagerMock));
        vault.setCoordinator(address(coordinator));

        // 5. DCAHook (mined address with 0xC0 flags)
        address hookAddr = _mineHookAddress(address(coordinator), address(poolManagerMock));
        hook = DCAHook(_deployAt(hookAddr, address(coordinator), address(poolManagerMock)));

        // 6. PoolKey
        poolKey = PoolKey({
            currency0:   Currency.wrap(token0),
            currency1:   Currency.wrap(token1),
            fee:         3000,
            tickSpacing: 60,
            hooks:       IHooks(address(hook))
        });

        coordinator.setPoolKey(poolKey);
        coordinator.setReferencePrice(PoolId.unwrap(poolKey.toId()), INITIAL_SQRT_PRICE);

        // Fund demo users with test USDC
        mockUSDC.mint(USER_A, DEMO_USDC_AMOUNT);
        mockUSDC.mint(USER_B, DEMO_USDC_AMOUNT);

        vm.prank(USER_A);
        mockUSDC.approve(address(vault), type(uint256).max);

        vm.prank(USER_B);
        mockUSDC.approve(address(vault), type(uint256).max);
    }

    function _mineHookAddress(address coord, address pm) internal returns (address) {
        bytes memory initCode = abi.encodePacked(
            type(DCAHook).creationCode,
            abi.encode(coord, pm)
        );
        bytes32 initCodeHash = keccak256(initCode);

        uint256 salt = 0;
        while (true) {
            address candidate = vm.computeCreate2Address(
                bytes32(salt),
                initCodeHash,
                address(this)
            );
            if (uint160(candidate) & Hooks.ALL_HOOK_MASK == HOOK_FLAGS) {
                return candidate;
            }
            unchecked { salt++; }
        }
    }

    function _deployAt(address target, address coord, address pm) internal returns (address) {
        bytes memory initCode = abi.encodePacked(
            type(DCAHook).creationCode,
            abi.encode(coord, pm)
        );

        bytes32 initCodeHash = keccak256(initCode);
        uint256 salt = 0;
        while (true) {
            address candidate = vm.computeCreate2Address(
                bytes32(salt),
                initCodeHash,
                address(this)
            );
            if (candidate == target) break;
            unchecked { salt++; }
        }

        address deployed;
        bytes32 saltBytes = bytes32(salt);
        assembly {
            deployed := create2(0, add(initCode, 0x20), mload(initCode), saltBytes)
        }
        require(deployed == target, "Deploy failed");
        return deployed;
    }

    function _defaultConstraints() internal pure returns (Constraints memory) {
        return Constraints({
            minFrequencyDays:      7,
            maxDelayDays:          14,
            goodDeviationBps:      100,
            badDeviationBps:       300,
            trancheFlexMinBps:     5_000,
            trancheFlexMaxBps:     10_000,
            standardTrancheAmount: 1_000e6,
            maxSlippageBps:        200 // 2%
        });
    }

    // =========================================================================
    // Feature 1 - Deposit & yield accrual, per user
    // =========================================================================
    function test_depositAndYield_userA() public {
        uint256 depositAmt = 1_000e6;
        vm.prank(USER_A);
        uint256 shares = vault.deposit(depositAmt, USER_A);

        assertGt(shares, 0, "Shares should be minted");
        assertEq(vault.balanceOf(USER_A), shares);
        assertEq(vault.balanceOf(USER_B), 0, "User B should have 0 shares");

        // Warp 365 days -> 5% APR on 1000 = 50 USDC yield
        vm.warp(block.timestamp + 365 days);

        uint256 userAssets = vault.convertToAssets(vault.balanceOf(USER_A));
        assertGe(userAssets, 1_049e6, "Assets should grow with yield");
        assertGt(userAssets, depositAmt, "Assets strictly greater than deposit");
        assertEq(vault.balanceOf(USER_B), 0, "User B still has 0");
    }

    function test_depositAndYield_twoUsers_isolated() public {
        vm.prank(USER_A);
        vault.deposit(1_000e6, USER_A);

        vm.prank(USER_B);
        vault.deposit(500e6, USER_B);

        assertGt(vault.balanceOf(USER_A), vault.balanceOf(USER_B));

        vm.warp(block.timestamp + 365 days);

        uint256 assetsA = vault.convertToAssets(vault.balanceOf(USER_A));
        uint256 assetsB = vault.convertToAssets(vault.balanceOf(USER_B));

        assertGe(assetsA, 1_049e6);
        assertGe(assetsB, 524e6);
        assertGt(assetsA, assetsB);
    }

    // =========================================================================
    // Feature 2 - Per-user constraints
    // =========================================================================
    function test_setConstraints_validatesInputs() public {
        Constraints memory c = _defaultConstraints();

        c.minFrequencyDays = 0;
        vm.prank(USER_A);
        vm.expectRevert();
        coordinator.setConstraints(c);

        c = _defaultConstraints();
        c.maxDelayDays = 0;
        vm.prank(USER_A);
        vm.expectRevert();
        coordinator.setConstraints(c);

        c = _defaultConstraints();
        c.trancheFlexMinBps = 10_000;
        c.trancheFlexMaxBps = 5_000;
        vm.prank(USER_A);
        vm.expectRevert();
        coordinator.setConstraints(c);

        c = _defaultConstraints();
        c.goodDeviationBps = 500;
        c.badDeviationBps = 200;
        vm.prank(USER_A);
        vm.expectRevert();
        coordinator.setConstraints(c);

        c = _defaultConstraints();
        c.maxSlippageBps = 2_500; // exceeds 2000 ceiling
        vm.prank(USER_A);
        vm.expectRevert();
        coordinator.setConstraints(c);

        // Valid succeeds
        c = _defaultConstraints();
        vm.prank(USER_A);
        coordinator.setConstraints(c);

        assertEq(coordinator.getConstraints(USER_A).minFrequencyDays, 7);
    }

    function test_setConstraints_perUserIsolation() public {
        Constraints memory cA = _defaultConstraints();
        cA.minFrequencyDays = 3;

        Constraints memory cB = _defaultConstraints();
        cB.minFrequencyDays = 14;

        vm.prank(USER_A);
        coordinator.setConstraints(cA);

        vm.prank(USER_B);
        coordinator.setConstraints(cB);

        assertEq(coordinator.getConstraints(USER_A).minFrequencyDays, 3);
        assertEq(coordinator.getConstraints(USER_B).minFrequencyDays, 14);
    }

    // =========================================================================
    // Feature 4 - Atomic Coordinator: poke -> decide -> execute
    // =========================================================================
    function test_poke_goodMarket_executeFull() public {
        // 1. Deposit
        vm.prank(USER_A);
        vault.deposit(10_000e6, USER_A);

        // 2. Set constraints
        vm.prank(USER_A);
        coordinator.setConstraints(_defaultConstraints());

        uint256 sharesBefore = vault.balanceOf(USER_A);

        // 3. Poke (market deviation = 0 -> EXECUTE_FULL)
        coordinator.poke(USER_A);

        // 4. Verify tranche was withdrawn from vault
        uint256 sharesAfter = vault.balanceOf(USER_A);
        assertLt(sharesAfter, sharesBefore, "Shares should decrease after swap");

        // 5. Verify output tokens delivered to USER_A
        assertGt(mockToken.balanceOf(USER_A), 0, "User should receive output tokens");

        // 6. Verify coordinator records
        (IDCACoordinator.Action action, uint256 ts, uint256 inAmt, uint256 outAmt) = coordinator.lastDecision(USER_A);
        assertEq(uint8(action), uint8(IDCACoordinator.Action.EXECUTE_FULL));
        assertEq(ts, block.timestamp);
        assertEq(inAmt, 1_000e6);
        assertGt(outAmt, 0);
    }

    function test_poke_ineligible_isNoOp() public {
        vm.prank(USER_A);
        vault.deposit(10_000e6, USER_A);

        vm.prank(USER_A);
        coordinator.setConstraints(_defaultConstraints());

        // First poke executes
        coordinator.poke(USER_A);
        uint256 sharesAfterFirst = vault.balanceOf(USER_A);

        // Immediate second poke is ineligible (minFrequencyDays = 7)
        coordinator.poke(USER_A); // silent no-op

        assertEq(vault.balanceOf(USER_A), sharesAfterFirst, "Vault shares unchanged on no-op");
    }

    function test_poke_delay_leavesVaultUntouched() public {
        vm.prank(USER_A);
        vault.deposit(10_000e6, USER_A);

        vm.prank(USER_A);
        coordinator.setConstraints(_defaultConstraints());

        // Move market price: +5% deviation (> badDeviationBps of 3%)
        uint160 badPrice = uint160(uint256(INITIAL_SQRT_PRICE) * 105 / 100);
        poolManagerMock.setSlot0(badPrice);

        uint256 sharesBefore = vault.balanceOf(USER_A);

        // Poke -> should trigger DELAY
        coordinator.poke(USER_A);

        (IDCACoordinator.Action action,,, ) = coordinator.lastDecision(USER_A);
        assertEq(uint8(action), uint8(IDCACoordinator.Action.DELAY));
        assertEq(vault.balanceOf(USER_A), sharesBefore, "Vault untouched on DELAY");
    }

    // =========================================================================
    // Feature 4 + 5 - Atomicity on hook rejection
    // =========================================================================
    function test_hookRejects_vaultUntouched() public {
        vm.prank(USER_A);
        vault.deposit(10_000e6, USER_A);

        // User A sets 0 slippage tolerance
        Constraints memory tightC = _defaultConstraints();
        tightC.maxSlippageBps = 0;
        vm.prank(USER_A);
        coordinator.setConstraints(tightC);

        // Pool has 1% slippage (100 bps > 0)
        poolManagerMock.setSlippageBps(100);

        uint256 sharesBefore = vault.balanceOf(USER_A);

        // Poke must revert due to Hook SlippageCapExceeded
        vm.expectRevert(DCAHook.SlippageCapExceeded.selector);
        coordinator.poke(USER_A);

        // Entire transaction reverted: vault shares and coordinator state unchanged
        assertEq(vault.balanceOf(USER_A), sharesBefore, "Vault shares must be completely unchanged");
        assertEq(coordinator.lastPokeTimestamp(USER_A), 0, "Last poke timestamp unchanged");
    }

    // =========================================================================
    // Feature 5 - Hook trust model
    // =========================================================================
    function test_hook_rejectsUntrustedCaller() public {
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne:        true,
            amountSpecified:   -1_000e6,
            sqrtPriceLimitX96: 0
        });

        // Calling hook directly with untrusted sender reverts UntrustedCaller
        vm.expectRevert(DCAHook.UntrustedCaller.selector);
        hook.beforeSwap(address(0x1337), poolKey, params, abi.encode(USER_A));
    }

    // =========================================================================
    // Feature 6 - Permissionless poke
    // =========================================================================
    function test_poke_permissionless() public {
        vm.prank(USER_A);
        vault.deposit(10_000e6, USER_A);

        vm.prank(USER_A);
        coordinator.setConstraints(_defaultConstraints());

        address randomKeeper = makeAddr("KEEPER");

        // Keeper calls poke(USER_A)
        vm.prank(randomKeeper);
        coordinator.poke(USER_A);

        // Output delivered to USER_A, not keeper
        assertGt(mockToken.balanceOf(USER_A), 0);
        assertEq(mockToken.balanceOf(randomKeeper), 0, "Keeper must not receive output tokens");
    }

    // =========================================================================
    // Feature 7 - Multi-user: different Constraints -> different outcomes
    // =========================================================================
    function test_twoUsers_differentConstraints_differentDecisions() public {
        vm.prank(USER_A);
        vault.deposit(10_000e6, USER_A);

        vm.prank(USER_B);
        vault.deposit(10_000e6, USER_B);

        // User A: wide tolerance (goodDeviation = 200 bps)
        Constraints memory cA = _defaultConstraints();
        cA.goodDeviationBps = 200;
        cA.badDeviationBps = 500;
        vm.prank(USER_A);
        coordinator.setConstraints(cA);

        // User B: tight tolerance (goodDeviation = 50 bps, badDeviation = 100 bps)
        Constraints memory cB = _defaultConstraints();
        cB.goodDeviationBps = 50;
        cB.badDeviationBps = 100;
        vm.prank(USER_B);
        coordinator.setConstraints(cB);

        // Market moves by +1.5% (150 bps)
        uint160 devPrice = uint160(uint256(INITIAL_SQRT_PRICE) * 10150 / 10000);
        poolManagerMock.setSlot0(devPrice);

        // Poke User B first -> 150 bps >= 100 bps -> DELAY (does not alter reference price)
        coordinator.poke(USER_B);

        // Poke User A -> 150 bps <= 200 bps -> EXECUTE_FULL
        coordinator.poke(USER_A);

        (IDCACoordinator.Action actionA,,,) = coordinator.lastDecision(USER_A);
        (IDCACoordinator.Action actionB,,,) = coordinator.lastDecision(USER_B);

        assertEq(uint8(actionA), uint8(IDCACoordinator.Action.EXECUTE_FULL), "User A executes full");
        assertEq(uint8(actionB), uint8(IDCACoordinator.Action.DELAY), "User B delays");
        assertTrue(actionA != actionB, "Different constraints produce different decisions");
    }

    // =========================================================================
    // Demo reproducibility - evm_snapshot/revert
    // =========================================================================
    function test_snapshotRevert_restoresAllState() public {
        vm.prank(USER_A);
        vault.deposit(10_000e6, USER_A);

        vm.prank(USER_A);
        coordinator.setConstraints(_defaultConstraints());

        uint256 sharesPre = vault.balanceOf(USER_A);

        _snapshot();

        coordinator.poke(USER_A);
        assertLt(vault.balanceOf(USER_A), sharesPre);

        _revert();

        assertEq(vault.balanceOf(USER_A), sharesPre, "State fully restored after snapshot revert");
        assertEq(coordinator.lastPokeTimestamp(USER_A), 0);
    }
}
