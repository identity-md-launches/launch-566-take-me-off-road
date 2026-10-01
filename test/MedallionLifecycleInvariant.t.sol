// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {FareToken} from "src/FareToken.sol";
import {MedallionHook} from "src/MedallionHook.sol";
import {FareDeploy} from "./helpers/FareDeploy.sol";
import {FareRouter} from "./helpers/FareRouter.sol";
import {FareNFTMock, FarePool4Mock, FareReceiverMock} from "./mocks/RetireBurnMocks.sol";

/// @dev Real PoolManager and settlement. Ghost fees come from raw manager Swap events;
/// ghost spending comes from the specified budget, and received IMD from the sink balance.
/// Expected failures are caught and checked; every unexpected handler revert fails the campaign.
contract MedallionLifecycleHandler is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    bytes32 constant SWAP = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    bytes32 constant RECOUPED = keccak256("Recouped(uint256,uint256)");
    uint256 constant CAP = 1.64 ether;
    IPoolManager public immutable manager;
    MedallionHook public immutable hook;
    FareRouter public immutable router;
    FareToken public immutable imd;
    FareNFTMock public immutable nft;
    FarePool4Mock public immutable oracle;
    FareReceiverMock public immutable receiver;
    PoolKey internal launch;
    address[3] public actors;

    uint256 public ghostFees;
    uint256 public ghostDonations;
    uint256 public ghostSpent;
    uint256 public ghostIMD;
    uint256 public ghostLastBurn;
    uint256 public recoupedEvents;
    bool public ghostRetired;
    uint256 public trades;
    uint256 public burns;
    uint256 public rejectedBurns;
    uint256 public rejectedRetirements;
    uint256 public rejectedSwaps;

    struct BurnState {
        uint256 batch;
        bool tooSoon;
        address actor;
        uint256 actorETH;
        uint256 actorIMD;
        uint256 sinkBefore;
    }

    constructor(IPoolManager pm, MedallionHook h, FareRouter r, PoolKey memory key) {
        manager = pm;
        hook = h;
        router = r;
        launch = key;
        imd = FareToken(h.IMD());
        nft = FareNFTMock(h.MEDALLION_NFT());
        oracle = FarePool4Mock(h.POOL4_HOOK());
        receiver = FareReceiverMock(payable(h.CREATOR()));
        ghostLastBurn = block.number;
        actors = [address(0xA447), address(0xB447), address(0xC447)];
    }

    function trade(uint96 rawAmount, uint8 mode, uint8 actorSeed) external {
        uint256 amount = bound(uint256(rawAmount), 100, 40 ether);
        mode %= 4;
        bool buy = mode < 2;
        bool exactInput = mode % 2 == 0;
        vm.recordLogs();
        vm.prank(actors[actorSeed % 3]);
        BalanceDelta net = router.swap{value: buy ? 100 ether : 0}(
            launch,
            SwapParams(
                buy,
                exactInput ? -int256(amount) : int256(amount),
                buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            )
        );
        (int128 gross,, uint256 emitted) = _readSwapLogs(PoolId.unwrap(launch.toId()));
        uint256 basis = buy == exactInput ? amount : uint256(gross < 0 ? -int256(gross) : int256(gross));
        uint256 fee = basis * 200 / 10_000;
        // Cross-check the fee independently against what the router actually settled.
        assertEq(int256(gross) - int256(net.amount0()), int256(fee));
        uint256 beforeFees = ghostFees;
        ghostFees += fee;
        assertEq(emitted, beforeFees < CAP && ghostFees >= CAP ? 1 : 0);
        recoupedEvents += emitted;
        ++trades;
    }

    function donate(uint96 rawAmount, uint8 actorSeed) external {
        uint256 amount = bound(uint256(rawAmount), 0, 3 ether);
        vm.prank(actors[actorSeed % 3]);
        router.donateClaims{value: amount}(address(hook));
        ghostDonations += amount;
    }

    function attemptRetire(bool approval, bool refusePayment, uint8 actorSeed) external {
        // Approval may change, but the harness never moves an already retired NFT back.
        nft.configure(nft.holder(), approval);
        receiver.configure(address(0), refusePayment);
        bool expected = !ghostRetired && ghostFees >= CAP && approval && !refusePayment;
        address actor = actors[actorSeed % 3];
        uint256 actorETH = actor.balance;
        vm.prank(actor);
        (bool ok, bytes memory reason) = address(hook).call(abi.encodeCall(hook.retire, ()));
        assertEq(ok, expected, "retirement success must match its prerequisites");
        if (ok) {
            ghostRetired = true;
        } else {
            ++rejectedRetirements;
            if (ghostRetired) assertEq(bytes4(reason), MedallionHook.AlreadyRetired.selector);
            else if (ghostFees < CAP) assertEq(bytes4(reason), MedallionHook.NotRecouped.selector);
            else if (!approval) assertEq(bytes4(reason), MedallionHook.RetireRefused.selector);
        }
        assertEq(actor.balance, actorETH, "retirement has no caller reward");
    }

    function burn(uint8 oracleMode, uint16 elapsed, bool excessiveMinimum, uint8 actorSeed) external {
        // Include same-block retries, cooldown edges, and idle periods beyond staleness.
        uint256 advance = elapsed % 8 == 7 ? 50_401 : elapsed % 8;
        vm.roll(vm.getBlockNumber() + advance);
        oracleMode %= 3;
        oracle.configure(oracleMode == 0, 0, oracleMode == 2 ? 1 : 0);
        BurnState memory s;
        {
            bool normal = oracleMode == 0 && (ghostSpent == 0 || vm.getBlockNumber() - ghostLastBurn <= 50_400);
            uint256 budget = ghostFees > CAP ? ghostFees - CAP - ghostSpent : 0;
            s.batch = normal ? 0.05 ether : 0.01 ether;
            if (s.batch > budget) s.batch = budget;
        }
        s.tooSoon = vm.getBlockNumber() - ghostLastBurn < 5;
        s.actor = actors[actorSeed % 3];
        s.actorETH = s.actor.balance;
        s.actorIMD = imd.balanceOf(s.actor);
        s.sinkBefore = imd.balanceOf(hook.DEAD());
        vm.recordLogs();
        vm.prank(s.actor);
        (bool ok, bytes memory result) =
            address(hook).call(abi.encodeCall(hook.burnIMD, (false, excessiveMinimum ? type(uint128).max : 0)));
        assertEq(
            ok, !s.tooSoon && s.batch >= 0.002 ether && !excessiveMinimum, "burn success must match its prerequisites"
        );
        if (ok) {
            uint256 received = imd.balanceOf(hook.DEAD()) - s.sinkBefore;
            assertEq(abi.decode(result, (uint256)), received);
            PoolKey memory plain =
                PoolKey(Currency.wrap(address(0)), Currency.wrap(address(imd)), 10_000, 200, IHooks(address(0)));
            (int128 rawETH, int128 rawIMD, uint256 emitted) = _readSwapLogs(PoolId.unwrap(plain.toId()));
            assertEq(int256(rawETH), -int256(s.batch));
            assertEq(uint256(uint128(rawIMD)), received, "all pool output must reach the sink");
            assertEq(emitted, 0, "burn cannot emit Recouped");
            // Deep real liquidity keeps this stricter output bound valid in both modes.
            assertGe(received, s.batch * 96 / 100);
            ghostSpent += s.batch;
            ghostIMD += received;
            ghostLastBurn = vm.getBlockNumber();
            ++burns;
        } else {
            ++rejectedBurns;
            bytes4 expectedError = s.tooSoon
                ? MedallionHook.TooSoon.selector
                : s.batch < 0.002 ether ? MedallionHook.NothingToBurn.selector : MedallionHook.Slippage.selector;
            assertEq(bytes4(result), expectedError);
            assertEq(imd.balanceOf(hook.DEAD()), s.sinkBefore);
        }
        assertEq(s.actor.balance, s.actorETH, "burn has no ETH caller reward");
        assertEq(imd.balanceOf(s.actor), s.actorIMD, "burn has no IMD caller reward");
    }

    function poke(uint8 actorSeed) external {
        vm.prank(actors[actorSeed % 3]);
        hook.pokeAnchor();
    }

    function partialSwap(bool buy, uint8 actorSeed) external {
        (uint160 price,,,) = manager.getSlot0(launch.toId());
        // One sqrt-price unit leaves far less room than the requested 1 ETH.
        SwapParams memory params =
            SwapParams(buy, buy ? -int256(1 ether) : int256(1 ether), buy ? price - 1 : price + 1);
        vm.prank(actors[actorSeed % 3]);
        (bool ok, bytes memory reason) =
            address(router).call{value: buy ? 1 ether : 0}(abi.encodeCall(router.swap, (launch, params)));
        assertFalse(ok, "specified ETH partial fill must revert");
        assertEq(
            reason,
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterSwap.selector,
                abi.encodeWithSelector(MedallionHook.PartialFill.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        ++rejectedSwaps;
    }

    function unauthorizedCallback(uint8 actorSeed) external {
        vm.prank(actors[actorSeed % 3]);
        (bool ok, bytes memory reason) =
            address(hook).call(abi.encodeCall(hook.unlockCallback, (abi.encode(uint8(1), false, CAP, uint256(0)))));
        assertFalse(ok);
        assertEq(bytes4(reason), MedallionHook.Unauthorized.selector);
    }

    function _readSwapLogs(bytes32 expectedPool) private returns (int128 eth, int128 tokens, uint256 recouped) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP) {
                assertEq(logs[i].topics[1], expectedPool);
                (eth, tokens,,,,) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                ++found;
            }
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == RECOUPED) {
                (uint256 fees, uint256 atBlock) = abi.decode(logs[i].data, (uint256, uint256));
                assertEq(fees, hook.totalFees());
                assertEq(atBlock, block.number);
                ++recouped;
            }
        }
        assertEq(found, 1, "must observe exactly one real pool swap");
    }
}

/// @notice Spec sections 4-7: conservation and irreversible retirement across random real unlocks.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract MedallionLifecycleInvariantTest is Test, FareDeploy {
    using TransientStateLibrary for IPoolManager;

    address constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address constant NFT = 0x9C8fF314C9Bc7F6e59A9d9225Fb22946427eDC03;
    address constant ORACLE = 0xc6C965Bd164c483e87d0B550671798e9A3602840;
    address constant CREATOR = 0x70c6C4fcaAb11151FCEDb32eaaC3431547193A0a;
    address constant DEAD = address(0xdead);
    address constant OWNER = address(0x447);
    uint256 constant CAP = 1.64 ether;
    PoolManager manager;
    MedallionHook hook;
    FareRouter router;
    MedallionLifecycleHandler handler;
    uint256 creatorBefore;

    function setUp() public {
        vm.chainId(1);
        vm.roll(100);
        vm.deal(address(this), 3_000_000 ether);
        FareToken token = new FareToken();
        vm.etch(IMD, address(token).code);
        deal(IMD, address(this), 1e27, true);
        vm.etch(NFT, address(new FareNFTMock()).code);
        FareNFTMock(NFT).configure(OWNER, true);
        vm.etch(ORACLE, address(new FarePool4Mock()).code);
        FarePool4Mock(ORACLE).configure(true, 0, 0);
        vm.etch(CREATOR, address(new FareReceiverMock()).code);
        manager = new PoolManager(address(this));
        hook = _deployHook(manager);
        router = new FareRouter(manager);
        token.approve(address(router), type(uint256).max);
        FareToken(IMD).approve(address(router), type(uint256).max);
        PoolKey memory launch =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 3000, 60, IHooks(address(hook)));
        PoolKey memory plain = PoolKey(Currency.wrap(address(0)), Currency.wrap(IMD), 10_000, 200, IHooks(address(0)));
        manager.initialize(launch, uint160(1 << 96));
        manager.initialize(plain, uint160(1 << 96));
        router.modifyLiquidity{value: 1_000_000 ether}(
            launch, ModifyLiquidityParams(-887220, 887220, 1_000_000 ether, 0)
        );
        router.modifyLiquidity{value: 10_000 ether}(plain, ModifyLiquidityParams(-887200, 887200, 10_000 ether, 0));
        handler = new MedallionLifecycleHandler(manager, hook, router, launch);
        for (uint256 i; i < 3; ++i) {
            address actor = handler.actors(i);
            vm.deal(actor, 100_000 ether);
            token.transfer(actor, 1_000_000 ether);
            vm.prank(actor);
            token.approve(address(router), type(uint256).max);
        }
        creatorBefore = CREATOR.balance;
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.trade.selector;
        selectors[1] = handler.donate.selector;
        selectors[2] = handler.attemptRetire.selector;
        selectors[3] = handler.burn.selector;
        selectors[4] = handler.poke.selector;
        selectors[5] = handler.partialSwap.selector;
        selectors[6] = handler.unauthorizedCallback.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_feeClaimsConserveAllFlows() public view {
        uint256 fees = handler.ghostFees();
        uint256 paid = handler.ghostRetired() ? CAP : 0;
        uint256 spent = handler.ghostSpent();
        uint256 entitlement = fees < CAP ? fees : CAP;
        assertEq(hook.totalFees(), fees);
        assertEq(hook.creatorEntitlement(), entitlement);
        assertEq(hook.creatorPaid(), paid);
        assertEq(hook.burnSpent(), spent);
        assertEq(hook.burnable(), fees - entitlement - spent);
        assertEq(manager.balanceOf(address(hook), 0), fees + handler.ghostDonations() - paid - spent);
        assertGe(manager.balanceOf(address(hook), 0), fees - paid - spent);
        assertEq(handler.recoupedEvents(), fees >= CAP ? 1 : 0);
    }

    function invariant_retirementAndBurnsReachOnlyFixedRecipients() public view {
        bool isRetired = handler.ghostRetired();
        assertEq(hook.retired(), isRetired);
        assertEq(CREATOR.balance - creatorBefore, isRetired ? CAP : 0);
        assertEq(FareNFTMock(NFT).holder(), isRetired ? DEAD : OWNER);
        assertEq(FareNFTMock(NFT).transferCount(), isRetired ? 1 : 0);
        assertEq(hook.totalIMDBurned(), handler.ghostIMD());
        assertEq(FareToken(IMD).balanceOf(DEAD), handler.ghostIMD());
        assertEq(hook.lastBurnBlock(), handler.ghostLastBurn());
        assertEq(address(hook).balance, 0);
        assertEq(FareToken(IMD).balanceOf(address(hook)), 0);
    }

    function invariant_everyUnlockSettlesAllCurrencyDeltas() public view {
        IPoolManager pm = IPoolManager(address(manager));
        assertFalse(pm.isUnlocked());
        assertEq(pm.getNonzeroDeltaCount(), 0);
        assertEq(pm.currencyDelta(address(hook), Currency.wrap(address(0))), 0);
        assertEq(pm.currencyDelta(address(hook), Currency.wrap(IMD)), 0);
        assertEq(address(router).balance, 0);
    }

    /// @dev A deterministic reachability witness keeps the invariant fixture honest.
    function test_handlerReachesBurnsRetirementAndAtomicFailures() public {
        handler.attemptRetire(true, false, 0);
        handler.trade(40 ether, 0, 0);
        handler.trade(40 ether, 0, 1);
        handler.trade(40 ether, 0, 2);
        handler.donate(1 ether, 1);
        handler.burn(0, 5, true, 0);
        handler.burn(0, 0, false, 2);
        handler.attemptRetire(false, false, 1);
        handler.attemptRetire(true, true, 1);
        handler.attemptRetire(true, false, 2);
        handler.attemptRetire(true, false, 0);
        handler.burn(0, 0, false, 0);
        handler.burn(0, 7, false, 1);
        handler.poke(1);
        handler.trade(1 ether, 1, 1);
        handler.trade(1 ether, 2, 2);
        handler.trade(1 ether, 3, 0);
        handler.partialSwap(true, 0);
        handler.partialSwap(false, 2);
        handler.unauthorizedCallback(1);
        invariant_feeClaimsConserveAllFlows();
        invariant_retirementAndBurnsReachOnlyFixedRecipients();
        invariant_everyUnlockSettlesAllCurrencyDeltas();
        assertEq(handler.trades(), 6);
        assertEq(handler.burns(), 2);
        assertEq(handler.rejectedBurns(), 2);
        assertEq(handler.rejectedRetirements(), 4);
        assertEq(handler.rejectedSwaps(), 2);
        assertTrue(handler.ghostRetired());
    }

    receive() external payable {}
}
