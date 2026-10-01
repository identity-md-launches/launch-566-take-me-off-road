// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
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

/// @dev Drives burns through both fixed routes on a real PoolManager while the two IMD pools' prices,
/// the POOL4 oracle and the block number move at random. A ghost model of spec section 7 predicts, for
/// every burn, which guard refuses it or whether it reaches the swap; the anchor, reference and ledger
/// state the hook exposes must equal the model after every call, including after every rollback.
contract BurnReferenceHandler is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    bytes32 constant SWAP = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    uint256 constant CAP = 1.64 ether;

    struct Model {
        int24 anchor;
        int24 lastRef;
        uint256 anchorBlock;
        uint256 snapshotBlock;
        int24 startAnchor;
        uint256 lastRefBlock;
    }

    IPoolManager public immutable manager;
    MedallionHook public immutable hook;
    FareRouter public immutable router;
    FareToken public immutable imd;
    FarePool4HookMock public immutable oracle;
    PoolKey internal launch;
    PoolKey internal pool4;
    PoolKey internal plain;
    address[3] public actors;

    Model internal m;
    uint256 public ghostFees;
    uint256 public ghostSpent;
    uint256 public ghostIMD;
    uint256 public ghostLastBurn;
    uint8 internal oracleMode;
    int24 internal oracleTick;

    uint256 public burnsPool4;
    uint256 public burnsPlainNormal;
    uint256 public burnsFallback;
    uint256 public tooSoon;
    uint256 public pool4Unavailable;
    uint256 public nothingToBurn;
    uint256 public offReference;
    uint256 public slippage;
    uint256 public hookRefusals;
    uint256 public pokesLive;
    uint256 public pokesFallback;
    uint256 public largestFallbackStep;

    constructor(
        IPoolManager pm,
        MedallionHook h,
        FareRouter r,
        PoolKey memory launch_,
        PoolKey memory pool4_,
        PoolKey memory plain_
    ) {
        manager = pm;
        hook = h;
        router = r;
        launch = launch_;
        pool4 = pool4_;
        plain = plain_;
        imd = FareToken(h.IMD());
        oracle = FarePool4HookMock(h.POOL4_HOOK());
        actors = [address(0xA447), address(0xB447), address(0xC447)];
        ghostLastBurn = block.number;
        m = Model(0, 0, block.number, block.number, 0, block.number);
    }

    function model() external view returns (Model memory) {
        return m;
    }

    function accrue(uint96 rawAmount, uint8 actorSeed) external {
        uint256 amount = bound(uint256(rawAmount), 50, 40 ether);
        vm.prank(actors[actorSeed % 3]);
        router.swap{value: amount}(launch, SwapParams(true, -int256(amount), TickMath.MIN_SQRT_PRICE + 1));
        ghostFees += amount / 50;
        assertEq(hook.totalFees(), ghostFees, "exact-input buy fee is exactly 2% of the input");
    }

    function movePlain(uint96 rawAmount, bool down, uint8 actorSeed) external {
        _move(plain, rawAmount, down, actorSeed);
    }

    function movePool4(uint96 rawAmount, bool down, uint8 actorSeed) external {
        _move(pool4, rawAmount, down, actorSeed);
    }

    /// @dev 0 open, 1 closed, 2 views revert, 3 views return 31 bytes, 4 open but POOL4 swaps revert.
    function setOracle(uint8 modeSeed, int24 tickSeed) external {
        oracleMode = modeSeed % 5;
        oracleTick = int24(bound(int256(tickSeed), -20_000, 20_000));
        oracle.configure(
            oracleMode != 1, oracleTick, oracleMode == 2 ? 1 : oracleMode == 3 ? 3 : oracleMode == 4 ? 2 : 0
        );
    }

    function roll(uint8 seed) external {
        uint256 advance = seed % 8 == 7 ? 50_401 : seed % 8;
        vm.roll(vm.getBlockNumber() + advance);
    }

    struct BurnContext {
        uint256 bn;
        uint256 callerMin;
        address actor;
        uint256 actorETH;
        uint256 actorIMD;
        uint256 sinkBefore;
        bytes4 guard;
        uint256 batch;
        uint256 minOut;
        bool normal;
    }

    function burn(bool viaPool4, uint8 minSeed, uint8 actorSeed) external {
        BurnContext memory c;
        c.bn = vm.getBlockNumber();
        c.callerMin = minSeed % 4 == 0 ? type(uint128).max : 0;
        c.actor = actors[actorSeed % 3];
        c.actorETH = c.actor.balance;
        c.actorIMD = imd.balanceOf(c.actor);
        c.sinkBefore = imd.balanceOf(hook.DEAD());

        Model memory next;
        (c.guard, c.batch, c.minOut, c.normal, next) = _predict(viaPool4, c.bn, c.callerMin);
        vm.recordLogs();
        vm.prank(c.actor);
        (bool ok, bytes memory result) = address(hook).call(abi.encodeCall(hook.burnIMD, (viaPool4, c.callerMin)));

        if (c.guard != bytes4(0)) {
            assertFalse(ok, "a guard the model predicts must refuse the burn");
            assertEq(bytes4(result), c.guard, "wrong guard");
            if (c.guard == MedallionHook.TooSoon.selector) ++tooSoon;
            else if (c.guard == MedallionHook.Pool4Unavailable.selector) ++pool4Unavailable;
            else if (c.guard == MedallionHook.NothingToBurn.selector) ++nothingToBurn;
            else ++offReference;
        } else if (ok) {
            uint256 out = abi.decode(result, (uint256));
            _checkFilled(viaPool4, c, out);
            if (c.normal) {
                if (viaPool4) ++burnsPool4;
                else ++burnsPlainNormal;
            } else {
                uint256 step = _distance(next.anchor, m.anchor);
                if (step > largestFallbackStep) largestFallbackStep = step;
                ++burnsFallback;
            }
            m = next;
            ghostSpent += c.batch;
            ghostIMD += out;
            ghostLastBurn = c.bn;
        } else {
            bytes4 reason = bytes4(result);
            if (reason == MedallionHook.Slippage.selector) {
                ++slippage;
            } else {
                assertEq(reason, CustomRevert.WrappedError.selector, "only the POOL4 hook may refuse past the guards");
                assertTrue(viaPool4 && oracleMode == 4, "a wrapped failure means the POOL4 hook refused");
                ++hookRefusals;
            }
            assertEq(imd.balanceOf(hook.DEAD()), c.sinkBefore);
        }
        assertEq(c.actor.balance, c.actorETH, "burn has no ETH caller reward");
        assertEq(imd.balanceOf(c.actor), c.actorIMD, "burn has no IMD caller reward");
        _assertModel();
    }

    function _checkFilled(bool viaPool4, BurnContext memory c, uint256 out) internal {
        uint256 received = imd.balanceOf(hook.DEAD()) - c.sinkBefore;
        (int128 rawETH, int128 rawIMD) = _singleSwap(PoolId.unwrap((viaPool4 ? pool4 : plain).toId()));
        assertEq(int256(rawETH), -int256(c.batch), "the whole batch is spent");
        assertEq(uint256(uint128(rawIMD)), out, "all pool output is reported");
        assertEq(received, out, "all pool output reaches the sink");
        assertGe(out, c.minOut, "output never below the reference floor or the caller minimum");
    }

    function poke(uint8 actorSeed) external {
        uint256 bn = vm.getBlockNumber();
        Model memory next = m;
        (bool available, bool open) = _oracleState();
        if (available && open) {
            _seed(next, oracleTick, bn);
            ++pokesLive;
        } else {
            _blockReference(next, bn);
            _step(next, _spot(plain), bn);
            ++pokesFallback;
        }
        address actor = actors[actorSeed % 3];
        uint256 actorETH = actor.balance;
        vm.prank(actor);
        hook.pokeAnchor();
        assertEq(actor.balance, actorETH);
        m = next;
        _assertModel();
    }

    function _predict(bool viaPool4, uint256 bn, uint256 callerMin)
        internal
        view
        returns (bytes4 guard, uint256 batch, uint256 minOut, bool normal, Model memory next)
    {
        next = m;
        if (bn - ghostLastBurn < 5) return (MedallionHook.TooSoon.selector, 0, 0, false, next);
        (bool available, bool open) = _oracleState();
        uint256 fresh = ghostLastBurn > m.lastRefBlock ? ghostLastBurn : m.lastRefBlock;
        normal = available && open && (ghostSpent == 0 || bn - fresh <= 50_400);
        if (!normal && viaPool4) return (MedallionHook.Pool4Unavailable.selector, 0, 0, normal, next);
        uint256 budget = ghostFees > CAP ? ghostFees - CAP - ghostSpent : 0;
        batch = normal ? 0.05 ether : 0.01 ether;
        if (batch > budget) batch = budget;
        if (batch < 0.002 ether) return (MedallionHook.NothingToBurn.selector, batch, 0, normal, next);
        int24 spot = _spot(viaPool4 ? pool4 : plain);
        int24 ref;
        if (normal) {
            ref = oracleTick;
            _seed(next, ref, bn);
        } else {
            ref = _blockReference(next, bn);
            _step(next, spot, bn);
        }
        int24 tolerance = normal && !viaPool4 ? int24(300) : int24(150);
        if (int256(spot) < int256(ref) - tolerance) {
            return (MedallionHook.PriceOffReference.selector, batch, 0, normal, m);
        }
        minOut = FullMath.mulDiv(_quote(batch, ref), 9_600, 10_000);
        if (callerMin > minOut) minOut = callerMin;
    }

    function _assertModel() internal view {
        assertEq(hook.anchorTick(), m.anchor, "anchor");
        assertEq(hook.lastRefTick(), m.lastRef, "lastRef");
        assertEq(hook.anchorBlock(), m.anchorBlock, "anchorBlock");
        assertEq(hook.startOfBlockAnchor(), m.startAnchor, "startOfBlockAnchor");
        assertEq(hook.lastReferenceBlock(), m.lastRefBlock, "lastReferenceBlock");
        assertEq(hook.lastBurnBlock(), ghostLastBurn, "lastBurnBlock");
        assertEq(hook.burnSpent(), ghostSpent, "burnSpent");
    }

    function _oracleState() internal view returns (bool available, bool open) {
        available = oracleMode == 0 || oracleMode == 1 || oracleMode == 4;
        open = available && oracleMode != 1;
    }

    function _seed(Model memory t, int24 ref, uint256 bn) internal pure {
        _blockReference(t, bn);
        t.anchor = ref;
        t.lastRef = ref;
        t.anchorBlock = bn;
        t.lastRefBlock = bn;
    }

    function _blockReference(Model memory t, uint256 bn) internal pure returns (int24) {
        if (t.snapshotBlock != bn) {
            t.startAnchor = t.anchor;
            t.snapshotBlock = bn;
        }
        return t.startAnchor;
    }

    function _step(Model memory t, int24 spot, uint256 bn) internal pure {
        if (t.anchorBlock == bn) return;
        int256 target = spot;
        int256 low = int256(t.lastRef) - 1000;
        int256 high = int256(t.lastRef) + 1000;
        if (target < low) target = low;
        if (target > high) target = high;
        int256 current = t.anchor;
        if (target > current + 200) target = current + 200;
        if (target < current - 200) target = current - 200;
        t.anchor = int24(target);
        t.anchorBlock = bn;
    }

    function _move(PoolKey memory key, uint96 rawAmount, bool down, uint8 actorSeed) internal {
        uint256 amount = bound(uint256(rawAmount), 0.01 ether, 60 ether);
        SwapParams memory params =
            SwapParams(down, -int256(amount), down ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
        bool refused = oracleMode == 4 && address(key.hooks) == address(oracle);
        vm.prank(actors[actorSeed % 3]);
        (bool ok, bytes memory reason) =
            address(router).call{value: down ? amount : 0}(abi.encodeCall(router.swap, (key, params)));
        assertEq(ok, !refused, "pool moves succeed unless the POOL4 hook refuses swaps");
        if (!ok) assertEq(bytes4(reason), CustomRevert.WrappedError.selector);
    }

    function _spot(PoolKey memory key) internal view returns (int24 tick) {
        (, tick,,) = manager.getSlot0(key.toId());
    }

    function _quote(uint256 amount, int24 tick) internal pure returns (uint256) {
        uint256 sqrtPrice = TickMath.getSqrtPriceAtTick(tick);
        if (sqrtPrice <= type(uint128).max) {
            return FullMath.mulDiv(sqrtPrice * sqrtPrice, amount, uint256(1) << 192);
        }
        uint256 ratioX128 = FullMath.mulDiv(sqrtPrice, sqrtPrice, uint256(1) << 64);
        return FullMath.mulDiv(ratioX128, amount, uint256(1) << 128);
    }

    function _distance(int24 a, int24 b) internal pure returns (uint256) {
        int256 d = int256(a) - int256(b);
        return uint256(d < 0 ? -d : d);
    }

    function _singleSwap(bytes32 expectedPool) internal returns (int128 eth, int128 tokens) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP) {
                assertEq(logs[i].topics[1], expectedPool, "burn must use the fixed key of the chosen route");
                (eth, tokens,,,,) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                ++found;
            }
        }
        assertEq(found, 1, "exactly one real pool swap per burn");
    }
}

/// @notice Spec section 7 under random call sequences on a real PoolManager with both fixed IMD pools.
/// forge-config: default.invariant.runs = 160
/// forge-config: default.invariant.depth = 48
/// forge-config: default.invariant.fail-on-revert = true
contract BurnReferenceInvariantTest is Test, FareDeploy {
    using TransientStateLibrary for IPoolManager;

    address constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address constant NFT = 0x9C8fF314C9Bc7F6e59A9d9225Fb22946427eDC03;
    address constant POOL4 = 0xc6C965Bd164c483e87d0B550671798e9A3602840;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 constant CAP = 1.64 ether;
    uint160 constant Q96 = 79228162514264337593543950336;

    PoolManager manager;
    MedallionHook hook;
    BurnReferenceHandler handler;

    function setUp() public {
        vm.chainId(1);
        vm.roll(100);
        vm.deal(address(this), 10_000_000 ether);
        FareToken token = new FareToken();
        vm.etch(IMD, address(token).code);
        deal(IMD, address(this), 1e27, true);
        vm.etch(NFT, address(new FareNFTMock()).code);
        vm.etch(POOL4, address(new FarePool4HookMock()).code);
        FarePool4HookMock(POOL4).configure(true, 0, 0);

        manager = new PoolManager(address(this));
        hook = _deployHook(manager);
        FareRouter router = new FareRouter(manager);
        token.approve(address(router), type(uint256).max);
        FareToken(IMD).approve(address(router), type(uint256).max);
        PoolKey memory launch =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 3000, 60, IHooks(address(hook)));
        PoolKey memory pool4 = PoolKey(Currency.wrap(address(0)), Currency.wrap(IMD), 10_000, 60, IHooks(POOL4));
        PoolKey memory plain = PoolKey(Currency.wrap(address(0)), Currency.wrap(IMD), 10_000, 200, IHooks(address(0)));
        manager.initialize(launch, Q96);
        manager.initialize(pool4, Q96);
        manager.initialize(plain, Q96);
        router.modifyLiquidity{value: 1_000_000 ether}(
            launch, ModifyLiquidityParams(-887220, 887220, 1_000_000 ether, 0)
        );
        router.modifyLiquidity{value: 1_000 ether}(pool4, ModifyLiquidityParams(-887220, 887220, 1_000 ether, 0));
        router.modifyLiquidity{value: 1_000 ether}(plain, ModifyLiquidityParams(-887200, 887200, 1_000 ether, 0));

        handler = new BurnReferenceHandler(manager, hook, router, launch, pool4, plain);
        for (uint256 i; i < 3; ++i) {
            address actor = handler.actors(i);
            vm.deal(actor, 1_000_000 ether);
            FareToken(IMD).transfer(actor, 1_000_000 ether);
            vm.prank(actor);
            FareToken(IMD).approve(address(router), type(uint256).max);
        }
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.accrue.selector;
        selectors[1] = handler.movePlain.selector;
        selectors[2] = handler.movePool4.selector;
        selectors[3] = handler.setOracle.selector;
        selectors[4] = handler.roll.selector;
        selectors[5] = handler.burn.selector;
        selectors[6] = handler.poke.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_referenceStateMatchesTheModel() public view {
        BurnReferenceHandler.Model memory m = handler.model();
        assertEq(hook.anchorTick(), m.anchor);
        assertEq(hook.lastRefTick(), m.lastRef);
        assertEq(hook.anchorBlock(), m.anchorBlock);
        assertEq(hook.startOfBlockAnchor(), m.startAnchor);
        assertEq(hook.lastReferenceBlock(), m.lastRefBlock);
        assertEq(hook.lastBurnBlock(), handler.ghostLastBurn());
        assertTrue(hook.pool4Seen());
    }

    function invariant_anchorStaysInsideTheBandAroundTheLastLiveReference() public view {
        int256 gap = int256(hook.anchorTick()) - int256(hook.lastRefTick());
        assertLe(gap, 1000);
        assertGe(gap, -1000);
        assertLe(handler.largestFallbackStep(), 200);
        assertGe(hook.anchorBlock(), 100);
        assertLe(hook.anchorBlock(), block.number);
    }

    function invariant_burnLedgerIsConserved() public view {
        uint256 fees = handler.ghostFees();
        uint256 spent = handler.ghostSpent();
        uint256 entitlement = fees < CAP ? fees : CAP;
        assertEq(hook.totalFees(), fees);
        assertEq(hook.burnSpent(), spent);
        assertEq(hook.burnable(), fees - entitlement - spent);
        assertLe(spent + entitlement, fees, "burns never touch the creator reserve");
        assertEq(manager.balanceOf(address(hook), 0), fees - spent);
        assertGe(manager.balanceOf(address(hook), 0), fees - hook.creatorPaid() - spent);
        assertEq(hook.totalIMDBurned(), handler.ghostIMD());
        assertEq(FareToken(IMD).balanceOf(DEAD), handler.ghostIMD());
        assertEq(hook.creatorPaid(), 0);
        assertFalse(hook.retired());
        assertEq(address(hook).balance, 0);
        assertEq(FareToken(IMD).balanceOf(address(hook)), 0);
    }

    function invariant_everyUnlockSettled() public view {
        IPoolManager pm = IPoolManager(address(manager));
        assertFalse(pm.isUnlocked());
        assertEq(pm.getNonzeroDeltaCount(), 0);
    }

    /// @dev Reachability witness: the handler can produce every outcome the model distinguishes.
    function test_handlerReachesEveryBurnOutcome() public {
        handler.roll(5);
        handler.burn(true, 1, 0);
        assertEq(handler.nothingToBurn(), 1);
        handler.accrue(40 ether, 0);
        handler.accrue(40 ether, 1);
        handler.accrue(40 ether, 2);
        assertEq(hook.burnable(), 0.76 ether);
        handler.burn(true, 1, 0);
        assertEq(handler.burnsPool4(), 1);
        handler.burn(true, 1, 1);
        assertEq(handler.tooSoon(), 1);

        handler.roll(5);
        handler.setOracle(1, 0);
        handler.burn(true, 1, 2);
        assertEq(handler.pool4Unavailable(), 1);
        handler.burn(false, 1, 0);
        assertEq(handler.burnsFallback(), 1);

        handler.roll(5);
        handler.movePlain(30 ether, true, 1);
        int24 spot = _tick(handler, false);
        assertLt(spot, -400);
        handler.burn(false, 1, 1);
        assertEq(handler.offReference(), 1);
        handler.poke(0);
        assertEq(hook.anchorTick(), -200);
        handler.roll(1);
        handler.poke(1);
        handler.roll(1);
        handler.poke(2);
        assertEq(handler.pokesFallback(), 3);
        assertEq(hook.anchorTick(), spot < -600 ? int24(-600) : spot);
        handler.roll(3);
        handler.burn(false, 1, 2);
        assertEq(handler.burnsFallback(), spot < -600 ? 1 : 2);

        handler.setOracle(0, 0);
        handler.roll(5);
        handler.burn(false, 1, 0);
        assertEq(handler.offReference(), 2, "normal plain tolerance is 300 ticks under the live reference");
        handler.movePlain(40 ether, false, 0);
        assertGt(_tick(handler, false), -300);
        handler.burn(false, 1, 0);
        assertEq(handler.burnsPlainNormal(), 1);

        handler.roll(5);
        handler.burn(true, 0, 1);
        assertEq(handler.slippage(), 1);
        handler.setOracle(4, 0);
        handler.burn(true, 1, 1);
        assertEq(handler.hookRefusals(), 1);
        handler.burn(false, 1, 1);
        assertEq(handler.burnsPlainNormal(), 2);

        handler.roll(7);
        handler.setOracle(0, 100);
        handler.burn(true, 1, 2);
        assertEq(handler.pool4Unavailable(), 2, "a stale reference refuses POOL4 even when the market is open");
        handler.poke(0);
        assertEq(handler.pokesLive(), 1);
        assertEq(hook.lastRefTick(), 100);
        handler.roll(5);
        handler.burn(true, 1, 2);
        assertEq(handler.burnsPool4(), 2);

        invariant_referenceStateMatchesTheModel();
        invariant_anchorStaysInsideTheBandAroundTheLastLiveReference();
        invariant_burnLedgerIsConserved();
        invariant_everyUnlockSettled();
    }

    function _tick(BurnReferenceHandler h, bool viaPool4) internal view returns (int24 tick) {
        PoolKey memory key = PoolKey(
            Currency.wrap(address(0)),
            Currency.wrap(IMD),
            10_000,
            viaPool4 ? int24(60) : int24(200),
            IHooks(viaPool4 ? POOL4 : address(0))
        );
        (, tick,,) = StateLibrary.getSlot0(IPoolManager(address(h.manager())), PoolIdLibrary.toId(key));
    }

    receive() external payable {}
}
