// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {FareToken} from "../src/FareToken.sol";
import {MedallionHook} from "../src/MedallionHook.sol";
import {FareDeploy} from "./helpers/FareDeploy.sol";
import {FareRouter} from "./helpers/FareRouter.sol";

contract HookFeesTest is Test, FareDeploy {
    using StateLibrary for IPoolManager;

    bytes32 constant SWAP_EVENT = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    bytes32 constant RECOUPED_EVENT = keccak256("Recouped(uint256,uint256)");
    uint160 constant Q96 = 79228162514264337593543950336;
    PoolManager manager;
    FareToken token;
    MedallionHook hook;
    FareRouter router;
    PoolKey key;

    function setUp() public {
        vm.deal(address(this), 1_000_000 ether);
        manager = new PoolManager(address(this));
        token = new FareToken();
        hook = _deployHook(manager);
        router = new FareRouter(manager);
        token.approve(address(router), type(uint256).max);
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 3000, 60, IHooks(address(hook)));
        manager.initialize(key, Q96);
        router.modifyLiquidity{value: 10_000 ether}(key, ModifyLiquidityParams(-887220, 887220, 10_000 ether, 0));
    }

    function test_permissionsAndFlags() public view {
        assertEq(uint160(address(hook)) & 0x3fff, 0x10cc);
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(
            p.afterInitialize && p.beforeSwap && p.afterSwap && p.beforeSwapReturnDelta && p.afterSwapReturnDelta
        );
        assertFalse(p.beforeInitialize || p.beforeAddLiquidity || p.afterAddLiquidity || p.beforeRemoveLiquidity);
        assertFalse(p.afterRemoveLiquidity || p.beforeDonate || p.afterDonate);
        assertFalse(p.afterAddLiquidityReturnDelta || p.afterRemoveLiquidityReturnDelta);
    }

    function test_constructorRejectsIncorrectFlags() public {
        bytes memory code = abi.encodePacked(type(MedallionHook).creationCode, abi.encode(manager));
        bytes32 hash = keccak256(code);
        bytes32 salt = bytes32(uint256(100_000_000));
        address predicted =
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, hash)))));
        assertTrue(uint160(predicted) & 0x3fff != 0x10cc);
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new MedallionHook{salt: salt}(manager);
    }

    function test_enabledCallbacksAndUnlockRejectUnauthorizedCalls() public {
        SwapParams memory params = SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1);
        vm.expectRevert(MedallionHook.Unauthorized.selector);
        hook.afterInitialize(address(this), key, Q96, 0);
        vm.expectRevert(MedallionHook.Unauthorized.selector);
        hook.beforeSwap(address(this), key, params, "");
        vm.expectRevert(MedallionHook.Unauthorized.selector);
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), "");
        vm.expectRevert(MedallionHook.Unauthorized.selector);
        hook.unlockCallback("");
    }

    function test_exactInputBuyMintsETHClaims() public {
        (BalanceDelta delta, int128 gross) = _recordSwap(true, -1 ether);
        assertEq(delta.amount0(), -1 ether);
        assertEq(gross, -0.98 ether);
        _assertAccounting(0.02 ether);
    }

    function test_exactOutputSellMintsETHClaims() public {
        (BalanceDelta delta, int128 gross) = _recordSwap(false, 1 ether);
        assertEq(delta.amount0(), 1 ether);
        assertEq(gross, 1.02 ether);
        _assertAccounting(0.02 ether);
    }

    function test_exactOutputBuyChargesTwoPercentOfGrossETH() public {
        (BalanceDelta delta, int128 gross) = _recordSwap(true, 1 ether);
        uint256 expected = uint256(-int256(gross)) * 200 / 10_000;
        assertEq(int256(delta.amount0()), int256(gross) - int256(expected));
        assertEq(delta.amount1(), 1 ether);
        _assertAccounting(expected);
    }

    function test_exactInputSellChargesTwoPercentOfGrossETH() public {
        (BalanceDelta delta, int128 gross) = _recordSwap(false, -1 ether);
        uint256 expected = uint256(int256(gross)) * 200 / 10_000;
        assertEq(int256(delta.amount0()), int256(gross) - int256(expected));
        assertEq(delta.amount1(), -1 ether);
        _assertAccounting(expected);
    }

    function test_feeRoundingTruncatesAtWeiPrecision() public {
        _recordSwap(true, -49);
        _assertAccounting(0);
        _recordSwap(true, -50);
        _assertAccounting(1);
    }

    function test_swapsDoNotDependOnExternalRecipientsOrMainnetContracts() public {
        bytes memory refuseEveryCall = hex"60006000fd";
        vm.etch(hook.CREATOR(), refuseEveryCall);
        vm.etch(hook.MEDALLION_NFT(), refuseEveryCall);
        vm.etch(hook.POOL4_HOOK(), refuseEveryCall);
        vm.etch(hook.IMD(), refuseEveryCall);
        uint256 creatorBalance = hook.CREATOR().balance;
        _recordSwap(true, -1 ether);
        _recordSwap(false, 1 ether);
        _assertAccounting(0.04 ether);
        assertEq(hook.CREATOR().balance, creatorBalance);
    }

    function testFuzz_allFourModesConserveClaims(uint96 rawAmount, uint8 rawMode) public {
        uint256 amount = bound(uint256(rawAmount), 100, 10 ether);
        uint256 mode = uint256(rawMode) % 4;
        bool buy = mode < 2;
        bool exactInput = mode % 2 == 0;
        (, int128 gross) = _recordSwap(buy, exactInput ? -int256(amount) : int256(amount));
        uint256 fee = (buy == exactInput ? amount : _abs(gross)) * 200 / 10_000;
        _assertAccounting(fee);
    }

    function test_beforeSwapBuyPartialFillRevertsAndRollsBackFee() public {
        vm.expectRevert(_wrappedPartialFill());
        router.swap{value: 1 ether}(key, SwapParams(true, -1 ether, TickMath.getSqrtPriceAtTick(-1)));
        _assertAccounting(0);
    }

    function test_beforeSwapSellPartialFillRevertsAndRollsBackFee() public {
        vm.expectRevert(_wrappedPartialFill());
        router.swap(key, SwapParams(false, 1 ether, TickMath.getSqrtPriceAtTick(1)));
        _assertAccounting(0);
    }

    function test_afterSwapBuyPartialFillChargesOnlyActualGrossETH() public {
        (BalanceDelta delta, int128 gross) = _recordSwapWithLimit(true, 1 ether, TickMath.getSqrtPriceAtTick(-1));
        assertGt(delta.amount1(), 0);
        assertLt(delta.amount1(), 1 ether);
        _assertAccounting(_abs(gross) * 200 / 10_000);
    }

    function test_afterSwapSellPartialFillChargesOnlyActualGrossETH() public {
        (BalanceDelta delta, int128 gross) = _recordSwapWithLimit(false, -1 ether, TickMath.getSqrtPriceAtTick(1));
        assertLt(delta.amount1(), 0);
        assertGt(delta.amount1(), -1 ether);
        _assertAccounting(_abs(gross) * 200 / 10_000);
    }

    function test_otherNativePoolRemainsFeeFree() public {
        PoolKey memory other = key;
        other.fee = 500;
        manager.initialize(other, Q96);
        router.modifyLiquidity{value: 10 ether}(other, ModifyLiquidityParams(-6000, 6000, 10 ether, 0));
        BalanceDelta delta = router.swap{value: 1 ether}(other, SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1));
        assertEq(delta.amount0(), -1 ether);
        assertEq(PoolId.unwrap(hook.launchPool()), PoolId.unwrap(key.toId()));
        _assertAccounting(0);
    }

    function test_nonNativeInitializationNeverClaimsLaunchPool() public {
        MedallionHook fresh = _deployHook(manager);
        FareToken other = new FareToken();
        (address a, address b) =
            address(token) < address(other) ? (address(token), address(other)) : (address(other), address(token));
        PoolKey memory nonNative = PoolKey(Currency.wrap(a), Currency.wrap(b), 3000, 60, IHooks(address(fresh)));
        manager.initialize(nonNative, Q96);
        assertEq(PoolId.unwrap(fresh.launchPool()), bytes32(0));
        PoolKey memory native = key;
        native.hooks = IHooks(address(fresh));
        manager.initialize(native, Q96);
        assertEq(PoolId.unwrap(fresh.launchPool()), PoolId.unwrap(native.toId()));
        nonNative.fee = 500;
        manager.initialize(nonNative, Q96);
        assertEq(PoolId.unwrap(fresh.launchPool()), PoolId.unwrap(native.toId()));
    }

    function test_donatedClaimsDoNotIncreaseFeesOrBurnable() public {
        _recordSwap(true, -1 ether);
        router.donateClaims{value: 4 ether}(address(hook));
        assertEq(manager.balanceOf(address(hook), 0), 4.02 ether);
        assertEq(hook.totalFees(), 0.02 ether);
        assertEq(hook.creatorEntitlement(), 0.02 ether);
        assertEq(hook.burnable(), 0);
        assertGe(manager.balanceOf(address(hook), 0), hook.totalFees() - hook.creatorPaid() - hook.burnSpent());
    }

    function test_poolDonationsDoNotChargeHookFees() public {
        router.donate{value: 1 ether}(key, 1 ether, 1 ether);
        _assertAccounting(0);
    }

    function test_recoupedIsEmittedOnceAndOnlyExcessBecomesBurnable() public {
        uint256 creatorBefore = hook.CREATOR().balance;
        _recordSwap(true, -81 ether);
        assertEq(hook.burnable(), 0);
        assertEq(hook.creatorEntitlement(), 1.62 ether);
        vm.recordLogs();
        _swap(true, -2 ether);
        _swap(false, 1 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 recouped;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == RECOUPED_EVENT) {
                ++recouped;
                (uint256 amount, uint256 blockNumber) = abi.decode(logs[i].data, (uint256, uint256));
                assertEq(amount, 1.66 ether);
                assertEq(blockNumber, block.number);
            }
        }
        assertEq(recouped, 1);
        assertEq(hook.totalFees(), 1.68 ether);
        assertEq(hook.creatorEntitlement(), 1.64 ether);
        assertEq(hook.burnable(), 0.04 ether);
        assertEq(hook.creatorPaid(), 0);
        assertEq(hook.CREATOR().balance, creatorBefore);
        assertEq(manager.balanceOf(address(hook), 0), 1.68 ether);
    }

    function test_statusTruncatesAndCapSentenceIsExact() public {
        assertEq(hook.status(), "IN SERVICE. Recouped 0.00 of 1.64 ETH.");
        _recordSwap(true, -0.999 ether);
        assertEq(hook.status(), "IN SERVICE. Recouped 0.01 of 1.64 ETH.");
        _recordSwap(true, -82 ether);
        assertEq(
            hook.status(),
            "RECOUPED, NOT RETIRED. The 1.64 ETH is ready and is released only by the transaction that retires medallion #447."
        );
    }

    function test_lastFareIsPinned() public view {
        assertEq(bytes(hook.LAST_FARE()).length, 1126);
        assertEq(hook.LAST_FARE_HASH(), 0x0d095dc39a486d88dd13cac371e1aefd8e9c5f9315fdbeba70a10371604762f2);
        assertEq(keccak256(bytes(hook.LAST_FARE())), hook.LAST_FARE_HASH());
    }

    function test_runtimeContainsNoForbiddenOpcodes() public view {
        bytes memory code = address(hook).code;
        assertLe(code.length, 24576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
            } else {
                assertTrue(op != 0xf2 && op != 0xf4 && op != 0xff, "forbidden opcode");
            }
        }
    }

    function test_freshManagerWithTokenOnlyLiquidityAcceptsBuy() public {
        PoolManager empty = new PoolManager(address(this));
        MedallionHook fresh = _deployHook(empty);
        FareRouter emptyRouter = new FareRouter(empty);
        token.approve(address(emptyRouter), type(uint256).max);
        PoolKey memory freshKey = key;
        freshKey.hooks = IHooks(address(fresh));
        empty.initialize(freshKey, Q96);
        emptyRouter.modifyLiquidity(freshKey, ModifyLiquidityParams(-6000, 0, 100 ether, 0));
        assertEq(address(empty).balance, 0);
        BalanceDelta delta =
            emptyRouter.swap{value: 1 ether}(freshKey, SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1));
        assertGt(delta.amount1(), 0);
        assertEq(empty.balanceOf(address(fresh), 0), 0.02 ether);
        assertEq(address(fresh).balance, 0);
    }

    function _recordSwap(bool buy, int256 amount) internal returns (BalanceDelta delta, int128 grossETH) {
        return _recordSwapWithLimit(buy, amount, buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
    }

    function _recordSwapWithLimit(bool buy, int256 amount, uint160 limit)
        internal
        returns (BalanceDelta delta, int128 grossETH)
    {
        vm.recordLogs();
        delta = router.swap{value: buy ? 100 ether : 0}(key, SwapParams(buy, amount, limit));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_EVENT) {
                (grossETH,,,,,) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                found = true;
            }
        }
        assertTrue(found, "real manager Swap event required");
    }

    function _swap(bool buy, int256 amount) internal returns (BalanceDelta) {
        return router.swap{value: buy ? 100 ether : 0}(
            key, SwapParams(buy, amount, buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1)
        );
    }

    function _assertAccounting(uint256 expectedFee) internal view {
        assertEq(hook.totalFees(), expectedFee);
        assertEq(manager.balanceOf(address(hook), 0), expectedFee);
        assertEq(hook.creatorEntitlement(), expectedFee < hook.CREATOR_CAP() ? expectedFee : hook.CREATOR_CAP());
        assertEq(hook.burnable(), expectedFee < hook.CREATOR_CAP() ? 0 : expectedFee - hook.CREATOR_CAP());
        assertEq(hook.creatorPaid(), 0);
        assertEq(hook.burnSpent(), 0);
        assertEq(address(hook).balance, 0);
    }

    function _wrappedPartialFill() internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            IHooks.afterSwap.selector,
            abi.encodeWithSelector(MedallionHook.PartialFill.selector),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function _abs(int128 value) internal pure returns (uint256) {
        return uint256(value < 0 ? -int256(value) : int256(value));
    }

    receive() external payable {}
}
