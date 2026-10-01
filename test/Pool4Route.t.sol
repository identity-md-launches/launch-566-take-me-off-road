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
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {FareToken} from "../src/FareToken.sol";
import {MedallionHook} from "../src/MedallionHook.sol";
import {FareDeploy} from "./helpers/FareDeploy.sol";
import {FareRouter} from "./helpers/FareRouter.sol";
import {FareNFTMock} from "./mocks/RetireBurnMocks.sol";
import {FarePool4HookMock} from "./mocks/Pool4HookMock.sol";

/// @notice The POOL4 route on a real PoolManager: a v4-callable hook sits at POOL4_HOOK, the fixed
/// (ETH, IMD, 10000, 60, POOL4_HOOK) pool is initialized and funded, and burns settle through it.
/// Every other suite drives real burns through the plain pool only; here the real pools' prices move,
/// so the one-sided reference guard, the fallback anchor and the slippage floor are checked against
/// genuine swap output instead of a scripted manager.
contract Pool4RouteTest is Test, FareDeploy {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    bytes32 constant SWAP_EVENT = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    address constant NFT = 0x9C8fF314C9Bc7F6e59A9d9225Fb22946427eDC03;
    address constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address constant POOL4 = 0xc6C965Bd164c483e87d0B550671798e9A3602840;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address constant KEEPER = address(0xB077);
    uint160 constant Q96 = 79228162514264337593543950336;
    uint256 constant POOL_LIQUIDITY = 1_000 ether;

    PoolManager manager;
    MedallionHook hook;
    FareRouter router;
    FarePool4HookMock oracle;
    FareToken imd;
    PoolKey launch;
    PoolKey pool4;
    PoolKey plain;

    function setUp() public {
        vm.chainId(1);
        vm.roll(100);
        vm.deal(address(this), 10_000_000 ether);
        FareToken token = new FareToken();
        vm.etch(IMD, address(token).code);
        imd = FareToken(IMD);
        deal(IMD, address(this), 1e27, true);
        vm.etch(NFT, address(new FareNFTMock()).code);
        FareNFTMock(NFT).configure(address(0x4447), true);
        vm.etch(POOL4, address(new FarePool4HookMock()).code);
        oracle = FarePool4HookMock(POOL4);
        oracle.configure(true, 0, 0);
        assertEq(uint160(POOL4) & 0x3fff, 0x2840, "POOL4_HOOK address flags");

        manager = new PoolManager(address(this));
        hook = _deployHook(manager);
        router = new FareRouter(manager);
        token.approve(address(router), type(uint256).max);
        imd.approve(address(router), type(uint256).max);
        launch = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 3000, 60, IHooks(address(hook)));
        pool4 = PoolKey(Currency.wrap(address(0)), Currency.wrap(IMD), 10_000, 60, IHooks(POOL4));
        plain = PoolKey(Currency.wrap(address(0)), Currency.wrap(IMD), 10_000, 200, IHooks(address(0)));
        manager.initialize(launch, Q96);
        manager.initialize(pool4, Q96);
        manager.initialize(plain, Q96);
        router.modifyLiquidity{value: 1_000_000 ether}(
            launch, ModifyLiquidityParams(-887220, 887220, 1_000_000 ether, 0)
        );
        router.modifyLiquidity{value: POOL_LIQUIDITY}(
            pool4, ModifyLiquidityParams(-887220, 887220, int256(POOL_LIQUIDITY), 0)
        );
        router.modifyLiquidity{value: POOL_LIQUIDITY}(
            plain, ModifyLiquidityParams(-887200, 887200, int256(POOL_LIQUIDITY), 0)
        );
        assertEq(oracle.beforeAddLiquidityCalls(), 1, "the real manager drives the POOL4 hook callbacks");
        router.swap{value: 100 ether}(launch, SwapParams(true, -100 ether, TickMath.MIN_SQRT_PRICE + 1));
        assertEq(hook.totalFees(), 2 ether);
        assertEq(hook.burnable(), 0.36 ether);
        vm.roll(105);
    }

    function test_pool4RouteSettlesThroughRealManagerWithFixedKey() public {
        oracle.configure(true, 0, 0);
        uint256 claimsBefore = manager.balanceOf(address(hook), 0);
        uint256 managerETH = address(manager).balance;
        uint256 managerIMD = imd.balanceOf(address(manager));
        vm.recordLogs();
        vm.prank(KEEPER);
        uint256 out = hook.burnIMD(true, 0);
        (bytes32 poolId, int128 rawETH, int128 rawIMD) = _singleSwap();
        assertEq(poolId, PoolId.unwrap(pool4.toId()), "burn must swap in the fixed POOL4 key");
        assertEq(rawETH, -0.05 ether);
        assertEq(uint256(uint128(rawIMD)), out);
        assertEq(oracle.afterSwapCalls(), 1, "the POOL4 hook saw exactly one swap");
        assertEq(oracle.lastSwapETH(), -0.05 ether);
        assertEq(oracle.lastSwapIMD(), rawIMD);
        assertEq(imd.balanceOf(DEAD), out);
        assertEq(managerIMD - imd.balanceOf(address(manager)), out);
        assertEq(address(manager).balance, managerETH, "claims settle the ETH leg without moving ETH");
        assertEq(claimsBefore - manager.balanceOf(address(hook), 0), 0.05 ether);
        assertEq(hook.burnSpent(), 0.05 ether);
        assertEq(hook.totalIMDBurned(), out);
        assertEq(hook.lastBurnBlock(), 105);
        assertEq(hook.lastReferenceBlock(), 105);
        assertEq(hook.anchorTick(), 0);
        assertEq(KEEPER.balance, 0);
        assertEq(imd.balanceOf(KEEPER), 0);
        // 1% LP fee and a 0.05 ETH swap against 1000 ETH of liquidity: well above the 96% floor.
        assertGe(out, 0.05 ether * 96 / 100);
        assertLt(out, 0.05 ether);
        _assertSettled();
    }

    function test_pool4HookRevertAbortsBurnAtomicallyAndPlainRouteStillWorks() public {
        oracle.configure(true, 0, 2);
        uint256 claimsBefore = manager.balanceOf(address(hook), 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                POOL4,
                IHooks.afterSwap.selector,
                abi.encodeWithSignature("Error(string)", "POOL4 hook refused the swap"),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        hook.burnIMD(true, 0);
        assertEq(manager.balanceOf(address(hook), 0), claimsBefore);
        assertEq(hook.burnSpent(), 0);
        assertEq(hook.totalIMDBurned(), 0);
        assertEq(hook.lastBurnBlock(), 100, "a failed swap must not consume the cooldown");
        assertEq(hook.lastReferenceBlock(), 100, "a failed swap must roll back the reference seed");
        assertEq(imd.balanceOf(DEAD), 0);
        _assertSettled();

        vm.recordLogs();
        uint256 out = hook.burnIMD(false, 0);
        (bytes32 poolId, int128 rawETH,) = _singleSwap();
        assertEq(poolId, PoolId.unwrap(plain.toId()));
        assertEq(rawETH, -0.05 ether);
        assertEq(imd.balanceOf(DEAD), out);
        assertEq(oracle.afterSwapCalls(), 0);
    }

    function test_uninitializedPool4PoolFailsBeforeAnyUnlock() public {
        PoolManager fresh = new PoolManager(address(this));
        MedallionHook other = _deployHook(fresh);
        FareRouter otherRouter = new FareRouter(fresh);
        FareToken token = new FareToken();
        token.approve(address(otherRouter), type(uint256).max);
        PoolKey memory otherLaunch =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 3000, 60, IHooks(address(other)));
        fresh.initialize(otherLaunch, Q96);
        otherRouter.modifyLiquidity{value: 100_000 ether}(
            otherLaunch, ModifyLiquidityParams(-887220, 887220, 100_000 ether, 0)
        );
        otherRouter.swap{value: 100 ether}(otherLaunch, SwapParams(true, -100 ether, TickMath.MIN_SQRT_PRICE + 1));
        vm.roll(vm.getBlockNumber() + 5);
        assertEq(other.burnable(), 0.36 ether);

        vm.expectRevert(MedallionHook.PoolUnavailable.selector);
        other.burnIMD(true, 0);
        vm.expectRevert(MedallionHook.PoolUnavailable.selector);
        other.burnIMD(false, 0);
        assertEq(other.burnSpent(), 0);
        assertEq(other.lastReferenceBlock(), 105, "still the constructor's seed");
        assertEq(fresh.balanceOf(address(other), 0), 2 ether);
        // A fallback poke reads the plain pool too, and the first seed is still the constructor's.
        oracle.configure(false, 0, 0);
        vm.expectRevert(MedallionHook.PoolUnavailable.selector);
        other.pokeAnchor();
    }

    function test_closedMarketRefusesPool4RouteAndFallbackUsesPlainPoolOnly() public {
        oracle.configure(false, 0, 0);
        vm.expectRevert(MedallionHook.Pool4Unavailable.selector);
        hook.burnIMD(true, 0);
        vm.recordLogs();
        hook.burnIMD(false, 0);
        (bytes32 poolId, int128 rawETH,) = _singleSwap();
        assertEq(poolId, PoolId.unwrap(plain.toId()));
        assertEq(rawETH, -0.01 ether, "fallback batch is 0.01 ETH");
        assertEq(oracle.afterSwapCalls(), 0);
        assertEq(hook.burnSpent(), 0.01 ether);
        assertEq(hook.lastReferenceBlock(), 100, "fallback never refreshes the live reference");
    }

    function test_shortOracleWordOnRealManagerIsFallbackNotRevert() public {
        oracle.configure(true, 0, 3);
        vm.expectRevert(MedallionHook.Pool4Unavailable.selector);
        hook.burnIMD(true, 0);
        hook.burnIMD(false, 0);
        assertEq(hook.burnSpent(), 0.01 ether);
    }

    function test_pool4GuardRejectsSpotBelowReferenceAndAcceptsSpotAbove() public {
        _move(pool4, true, 10 ether);
        int24 spot = _tick(pool4);
        assertLt(spot, -150, "10 ETH into 1000 ETH of liquidity moves the price down more than 150 ticks");
        vm.expectRevert(MedallionHook.PriceOffReference.selector);
        hook.burnIMD(true, 0);
        assertEq(hook.burnSpent(), 0);
        assertEq(hook.lastReferenceBlock(), 100, "the seed rolls back with the guard");

        // The oracle tracks the market down: within tolerance again.
        oracle.configure(true, spot + 150, 0);
        hook.burnIMD(true, 0);
        assertEq(hook.burnSpent(), 0.05 ether);
        assertEq(hook.lastRefTick(), spot + 150);

        // Far above the reference is never refused: the guard is one-sided.
        vm.roll(vm.getBlockNumber() + 5);
        _move(pool4, false, 60 ether);
        assertGt(_tick(pool4), 800);
        oracle.configure(true, 0, 0);
        uint256 out = hook.burnIMD(true, 0);
        assertGt(out, _quote(0.05 ether, 800), "a higher spot pays more IMD than the reference quote");
        assertEq(hook.burnSpent(), 0.1 ether);
    }

    function test_plainToleranceIsWiderInNormalModeThanInFallback() public {
        _move(plain, true, 10 ether);
        int24 spot = _tick(plain);
        assertLt(spot, -150);
        assertGt(spot, -300);
        // Normal mode, plain pool: 300 ticks of tolerance under the live reference.
        hook.burnIMD(false, 0);
        assertEq(hook.burnSpent(), 0.05 ether);
        assertEq(hook.anchorTick(), 0);

        // Fallback: the reference is the start-of-block anchor (0) with only 150 ticks of tolerance.
        vm.roll(vm.getBlockNumber() + 5);
        oracle.configure(false, 0, 0);
        vm.expectRevert(MedallionHook.PriceOffReference.selector);
        hook.burnIMD(false, 0);
        assertEq(hook.anchorTick(), 0, "a refused burn does not step the anchor");
        assertEq(hook.anchorBlock(), 105, "the normal burn's seed is the last anchor write");

        // A poke steps the anchor toward spot this block; the next block's burn uses it as reference.
        spot = _tick(plain);
        assertGt(spot, -200, "the normal burn itself moved the price by about one tick");
        hook.pokeAnchor();
        assertEq(hook.anchorTick(), spot, "one step of up to 200 ticks reaches a spot within 200");
        assertEq(hook.anchorBlock(), vm.getBlockNumber());
        vm.expectRevert(MedallionHook.PriceOffReference.selector);
        hook.burnIMD(false, 0);
        vm.roll(vm.getBlockNumber() + 1);
        uint256 out = hook.burnIMD(false, 0);
        assertEq(hook.burnSpent(), 0.06 ether);
        assertGe(out, _quote(0.01 ether, spot) * 96 / 100);
        assertEq(hook.startOfBlockAnchor(), spot);
    }

    function test_fallbackAnchorNeedsOneBlockPerStepAndStaysInsideBand() public {
        oracle.configure(false, 0, 0);
        _move(plain, true, 80 ether);
        int24 spot = _tick(plain);
        assertLt(spot, -1200, "80 ETH moves the price well beyond the fallback band");
        for (uint256 i = 1; i <= 7; ++i) {
            hook.pokeAnchor();
            int24 expected = int24(-200 * int256(i));
            if (expected < -1000) expected = -1000;
            assertEq(hook.anchorTick(), expected);
            hook.pokeAnchor();
            assertEq(hook.anchorTick(), expected, "a second poke in the same block is a no-op");
            vm.roll(vm.getBlockNumber() + 1);
        }
        assertEq(hook.anchorTick(), -1000, "the anchor is clamped to lastRef - FALLBACK_BAND");
        assertEq(hook.lastRefTick(), 0);
        vm.expectRevert(MedallionHook.PriceOffReference.selector);
        hook.burnIMD(false, 0);
        // Only a live reference can move lastRef, and then the band moves with it.
        oracle.configure(true, spot, 0);
        hook.pokeAnchor();
        assertEq(hook.lastRefTick(), spot);
        assertEq(hook.anchorTick(), spot);
        vm.roll(vm.getBlockNumber() + 1);
        hook.burnIMD(false, 0);
        assertEq(hook.burnSpent(), 0.05 ether);
    }

    function test_thinPool4LiquidityTripsSlippageFloorAndRollsBackSeed() public {
        router.modifyLiquidity(pool4, ModifyLiquidityParams(-887220, 887220, -int256(POOL_LIQUIDITY - 1 ether), 0));
        oracle.configure(true, 0, 0);
        uint256 claimsBefore = manager.balanceOf(address(hook), 0);
        vm.expectRevert(MedallionHook.Slippage.selector);
        hook.burnIMD(true, 0);
        assertEq(manager.balanceOf(address(hook), 0), claimsBefore);
        assertEq(hook.burnSpent(), 0);
        assertEq(hook.lastBurnBlock(), 100);
        assertEq(hook.lastReferenceBlock(), 100);
        assertEq(_tick(pool4), 0, "the refused swap left no price impact");
        _assertSettled();
        router.modifyLiquidity{value: POOL_LIQUIDITY}(
            pool4, ModifyLiquidityParams(-887220, 887220, int256(POOL_LIQUIDITY), 0)
        );
        hook.burnIMD(true, 0);
        assertEq(hook.burnSpent(), 0.05 ether);
    }

    function test_staleBurnFallsBackUntilLivePokeRestoresPool4() public {
        hook.burnIMD(true, 0);
        vm.roll(vm.getBlockNumber() + 50_401);
        vm.expectRevert(MedallionHook.Pool4Unavailable.selector);
        hook.burnIMD(true, 0);
        hook.burnIMD(false, 0);
        assertEq(hook.burnSpent(), 0.06 ether, "stale mode spends the fallback batch");
        hook.pokeAnchor();
        assertEq(hook.lastReferenceBlock(), vm.getBlockNumber());
        vm.roll(vm.getBlockNumber() + 5);
        hook.burnIMD(true, 0);
        assertEq(hook.burnSpent(), 0.11 ether);
        assertEq(oracle.afterSwapCalls(), 2);
    }

    function test_callerMinimumAboveRealOutputFailsWithoutSideEffects() public {
        uint256 priceBefore = _sqrt(pool4);
        vm.expectRevert(MedallionHook.Slippage.selector);
        hook.burnIMD(true, 0.05 ether);
        assertEq(_sqrt(pool4), priceBefore);
        assertEq(hook.burnSpent(), 0);
        assertEq(imd.balanceOf(DEAD), 0);
        _assertSettled();
        uint256 out = hook.burnIMD(true, 0.049 ether);
        assertGe(out, 0.049 ether);
    }

    function _move(PoolKey memory key, bool down, uint256 amount) internal {
        router.swap{value: down ? amount : 0}(
            key, SwapParams(down, -int256(amount), down ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1)
        );
    }

    function _tick(PoolKey memory key) internal view returns (int24 tick) {
        (, tick,,) = IPoolManager(address(manager)).getSlot0(key.toId());
    }

    function _sqrt(PoolKey memory key) internal view returns (uint160 price) {
        (price,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
    }

    function _quote(uint256 amount, int24 tick) internal pure returns (uint256) {
        uint256 sqrtPrice = TickMath.getSqrtPriceAtTick(tick);
        return (sqrtPrice * sqrtPrice * amount) >> 192;
    }

    function _singleSwap() internal returns (bytes32 poolId, int128 eth, int128 tokens) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_EVENT) {
                poolId = logs[i].topics[1];
                (eth, tokens,,,,) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                ++found;
            }
        }
        assertEq(found, 1, "exactly one real pool swap");
    }

    function _assertSettled() internal view {
        IPoolManager pm = IPoolManager(address(manager));
        assertFalse(pm.isUnlocked());
        assertEq(pm.getNonzeroDeltaCount(), 0);
        assertEq(pm.currencyDelta(address(hook), Currency.wrap(address(0))), 0);
        assertEq(pm.currencyDelta(address(hook), Currency.wrap(IMD)), 0);
        assertEq(address(hook).balance, 0);
        assertEq(imd.balanceOf(address(hook)), 0);
    }

    receive() external payable {}
}
