// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @dev Stand-in for the POOL4 CappedBurnHook, meant to be `vm.etch`ed at POOL4_HOOK so a real PoolManager
/// can run the fixed POOL4 pool. The constant address carries flags 0x2840 (beforeInitialize,
/// beforeAddLiquidity, afterSwap), so the manager calls exactly those three callbacks and nothing else.
/// It also answers the two views MedallionHook reads, with switchable failure modes.
contract FarePool4HookMock {
    /// @dev 0 = healthy, 1 = views revert, 2 = afterSwap reverts (pool swaps fail), 3 = views return 31 bytes.
    uint8 public mode;
    bool public open;
    int256 public tick;
    uint256 public afterSwapCalls;
    uint256 public beforeAddLiquidityCalls;
    int128 public lastSwapETH;
    int128 public lastSwapIMD;

    function configure(bool marketOpen_, int256 refTick_, uint8 mode_) external {
        open = marketOpen_;
        tick = refTick_;
        mode = mode_;
    }

    function marketOpen() external view returns (bool) {
        _views();
        return open;
    }

    function refTick() external view returns (int24) {
        _views();
        return int24(tick);
    }

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        returns (bytes4)
    {
        ++beforeAddLiquidityCalls;
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta delta, bytes calldata)
        external
        returns (bytes4, int128)
    {
        require(mode != 2, "POOL4 hook refused the swap");
        ++afterSwapCalls;
        lastSwapETH = delta.amount0();
        lastSwapIMD = delta.amount1();
        return (IHooks.afterSwap.selector, 0);
    }

    function _views() private view {
        require(mode != 1, "POOL4 views unavailable");
        if (mode == 3) {
            assembly ("memory-safe") {
                mstore(0, 1)
                return(0, 31)
            }
        }
    }
}
