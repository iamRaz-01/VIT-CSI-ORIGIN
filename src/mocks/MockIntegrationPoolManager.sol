// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager}      from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback}   from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey}           from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency}          from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {MockERC20}         from "./MockERC20.sol";

/// @title MockIntegrationPoolManager
/// @notice Simulates Uniswap v4 PoolManager for local development, integration tests, and standalone Anvil runs.
contract MockIntegrationPoolManager is IPoolManager {
    using PoolIdLibrary for PoolKey;

    uint160 public mockSqrtPriceX96 = 79228162514264337593543950336; // 1:1 Q96
    int128  public mockSlippageBps;

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

    function exttload(bytes32[] calldata /* slots */) external view override returns (bytes32[] memory) { return new bytes32[](0); }
    function exttload(bytes32 /* slot */) external view override returns (bytes32) { return bytes32(0); }

    function protocolFeeController() external view override returns (address) { return address(0); }
    function protocolFeesAccrued(Currency /* currency */) external view override returns (uint256) { return 0; }
    function setProtocolFee(PoolKey memory /* key */, uint24 /* newProtocolFee */) external override {}
    function setProtocolFeeController(address /* controller */) external override {}
    function collectProtocolFees(address /* recipient */, Currency /* currency */, uint256 /* amount */) external override returns (uint256) { return 0; }

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
        if (address(key.hooks) != address(0)) {
            key.hooks.beforeSwap(msg.sender, key, params, hookData);
        }

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

        if (address(key.hooks) != address(0)) {
            key.hooks.afterSwap(msg.sender, key, params, swapDelta, hookData);
        }

        return swapDelta;
    }

    function take(Currency currency, address to, uint256 amount) external override {
        MockERC20(Currency.unwrap(currency)).mint(to, amount);
    }
}
