// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

interface IFareRouterToken {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @dev Small test-only router: each unlock must settle the real manager's balances.
contract FareRouter is IUnlockCallback {
    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey memory key, SwapParams memory params) external payable returns (BalanceDelta delta) {
        delta = abi.decode(manager.unlock(abi.encode(uint8(0), msg.sender, key, abi.encode(params))), (BalanceDelta));
        _refund();
    }

    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params)
        external
        payable
        returns (BalanceDelta delta)
    {
        delta = abi.decode(manager.unlock(abi.encode(uint8(1), msg.sender, key, abi.encode(params))), (BalanceDelta));
        _refund();
    }

    function donateClaims(address to) external payable {
        PoolKey memory unused;
        manager.unlock(abi.encode(uint8(2), to, unused, abi.encode(msg.value)));
    }

    function donate(PoolKey memory key, uint256 amount0, uint256 amount1) external payable {
        manager.unlock(abi.encode(uint8(3), msg.sender, key, abi.encode(amount0, amount1)));
        _refund();
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (uint8 action, address payer, PoolKey memory key, bytes memory parameters) =
            abi.decode(data, (uint8, address, PoolKey, bytes));
        BalanceDelta delta;
        if (action == 0) {
            delta = manager.swap(key, abi.decode(parameters, (SwapParams)), "");
        } else if (action == 1) {
            (delta,) = manager.modifyLiquidity(key, abi.decode(parameters, (ModifyLiquidityParams)), "");
        } else if (action == 2) {
            uint256 amount = abi.decode(parameters, (uint256));
            manager.mint(payer, 0, amount);
            manager.settle{value: amount}();
            return "";
        } else {
            require(action == 3, "invalid action");
            (uint256 amount0, uint256 amount1) = abi.decode(parameters, (uint256, uint256));
            delta = manager.donate(key, amount0, amount1, "");
        }
        _settle(key.currency0, payer, delta.amount0());
        _settle(key.currency1, payer, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(Currency currency, address payer, int128 delta) private {
        if (delta > 0) {
            manager.take(currency, payer, uint128(delta));
        } else if (delta < 0) {
            uint256 amount = uint256(-int256(delta));
            if (Currency.unwrap(currency) == address(0)) {
                manager.settle{value: amount}();
            } else {
                manager.sync(currency);
                require(IFareRouterToken(Currency.unwrap(currency)).transferFrom(payer, address(manager), amount));
                manager.settle();
            }
        }
    }

    function _refund() private {
        uint256 amount = address(this).balance;
        if (amount != 0) {
            (bool ok,) = msg.sender.call{value: amount}("");
            require(ok, "refund failed");
        }
    }

    receive() external payable {}
}
