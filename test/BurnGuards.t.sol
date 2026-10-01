// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {MedallionHook} from "../src/MedallionHook.sol";
import {FareDeploy} from "./helpers/FareDeploy.sol";
import {FareManagerMock, FareIMDMock} from "./mocks/RetireBurnMocks.sol";

/// @dev Independent responses let one selector fail while the other still answers correctly.
contract FareRawOracle {
    bytes private marketResponse;
    bytes private referenceResponse;
    bool private failMarket;
    bool private failReference;

    function configure(bytes memory market, bytes memory referenceTick, bool marketFails, bool referenceFails)
        external
    {
        marketResponse = market;
        referenceResponse = referenceTick;
        failMarket = marketFails;
        failReference = referenceFails;
    }

    fallback() external {
        bytes memory response;
        if (msg.sig == bytes4(keccak256("marketOpen()"))) {
            require(!failMarket, "market unavailable");
            response = marketResponse;
        } else {
            require(msg.sig == bytes4(keccak256("refTick()")), "unknown selector");
            require(!failReference, "reference unavailable");
            response = referenceResponse;
        }
        assembly ("memory-safe") {
            return(add(response, 32), mload(response))
        }
    }
}

/// @notice Adversarial oracle ABI, rollback and quote boundaries from specification section 7.
/// forge-config: default.fuzz.runs = 256
contract BurnGuardsTest is Test, FareDeploy {
    using PoolIdLibrary for PoolKey;

    address private constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address private constant POOL4 = 0xc6C965Bd164c483e87d0B550671798e9A3602840;
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 private constant CAP = 1.64 ether;
    FareRawOracle private oracle;
    FareManagerMock private manager;
    FareIMDMock private imd;
    MedallionHook private hook;
    PoolKey private launchKey;
    PoolKey private plainKey;

    function setUp() public {
        vm.chainId(1);
        vm.roll(100);
        vm.etch(POOL4, address(new FareRawOracle()).code);
        oracle = FareRawOracle(POOL4);
        _oracle(true, 0);
        vm.etch(IMD, address(new FareIMDMock()).code);
        imd = FareIMDMock(IMD);
        manager = new FareManagerMock();
        hook = _deployHook(IPoolManager(address(manager)));
        launchKey = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(0x447)), 3000, 60, IHooks(address(hook)));
        plainKey = PoolKey(Currency.wrap(address(0)), Currency.wrap(IMD), 10_000, 200, IHooks(address(0)));
        manager.initializeHook(IHooks(address(hook)), launchKey);
        manager.setTick(plainKey, 0);
        imd.mint(address(manager), 10 ** 38);
    }

    function _oracle(bool open, int256 tick) private {
        oracle.configure(abi.encode(open), abi.encode(tick), false, false);
    }

    function _ready() private {
        manager.accrue(IHooks(address(hook)), launchKey, CAP + 1 ether);
        vm.roll(105);
    }

    function _assertUnspent() private view {
        assertEq(hook.totalFees(), CAP + 1 ether);
        assertEq(hook.burnSpent(), 0);
        assertEq(hook.totalIMDBurned(), 0);
        assertEq(hook.creatorPaid(), 0);
        assertEq(hook.lastBurnBlock(), 100);
        assertEq(manager.balanceOf(address(hook), 0), CAP + 1 ether);
        assertEq(imd.balanceOf(DEAD), 0);
        assertEq(manager.unlockCount(), 0);
        assertEq(manager.swapCount(), 0);
        assertFalse(manager.unlocked());
    }

    function _assertFallback() private {
        vm.expectRevert(MedallionHook.Pool4Unavailable.selector);
        hook.burnIMD(true, 0);
        hook.burnIMD(false, 0);
        assertEq(hook.burnSpent(), 0.01 ether);
        assertEq(hook.lastRefTick(), 0);
        assertEq(imd.balanceOf(DEAD), 0.01 ether);
    }

    function testFuzz_eachOracleSelectorRequiresExactlyOneABIWord(uint8 sizeSeed, bool malformedReference) public {
        _ready();
        // Generate every length in [0, 65] except 32 without discarding fuzz inputs.
        uint256 size = bound(uint256(sizeSeed), 0, 64);
        if (size >= 32) ++size;
        bytes memory malformed = new bytes(size);
        // Long market responses still encode `true` in their first word, so a
        // decoder that silently accepts trailing bytes would wrongly use normal mode.
        if (!malformedReference && size > 32) {
            assembly ("memory-safe") {
                mstore(add(malformed, 32), 1)
            }
        }
        if (malformedReference) oracle.configure(abi.encode(true), malformed, false, false);
        else oracle.configure(malformed, abi.encode(int256(0)), false, false);
        _assertFallback();
    }

    function test_shortMarketResponseCannotCountAsPreviouslyReadClosedPool() public {
        // A missing/short zero word must be unavailable, not interpreted as a
        // legitimate `false` that seeds the fallback reference at construction.
        oracle.configure(new bytes(31), abi.encode(int256(700)), false, false);
        MedallionHook other = _deployHook(IPoolManager(address(manager)));
        assertFalse(other.pool4Seen());
        assertEq(other.anchorTick(), 0);
        vm.roll(105);
        vm.expectRevert(MedallionHook.Pool4Unavailable.selector);
        other.pokeAnchor();
    }

    function testFuzz_marketOpenRejectsNonCanonicalFullWord(uint256 word) public {
        _ready();
        word = bound(word, 2, type(uint256).max);
        oracle.configure(abi.encode(word), abi.encode(int256(0)), false, false);
        _assertFallback();
    }

    function testFuzz_referenceRejectsFullWordOutsideTickRange(uint256 magnitude, bool negative) public {
        _ready();
        magnitude = bound(magnitude, uint256(uint24(TickMath.MAX_TICK)) + 1, uint256(type(int256).max));
        int256 malformedTick = negative ? -int256(magnitude) : int256(magnitude);
        oracle.configure(abi.encode(true), abi.encode(malformedTick), false, false);
        _assertFallback();
    }

    function test_eachOracleSelectorMayRevertIndependently() public {
        _ready();
        oracle.configure(abi.encode(true), abi.encode(int256(0)), true, false);
        _assertFallback();
        vm.roll(110);
        oracle.configure(abi.encode(true), abi.encode(int256(0)), false, true);
        hook.burnIMD(false, 0);
        assertEq(hook.burnSpent(), 0.02 ether);
        assertEq(hook.lastRefTick(), 0);
    }

    function test_referenceDirtySignExtensionIsRejected() public {
        _ready();
        // An ABI int24 of -1 must fill the high 232 bits with ones.
        oracle.configure(abi.encode(true), abi.encode(uint256(type(uint24).max)), false, false);
        _assertFallback();
    }

    function test_extremeValidReferencesAreAcceptedAndSeedExactly() public {
        _oracle(true, TickMath.MIN_TICK);
        hook.pokeAnchor();
        assertEq(hook.anchorTick(), TickMath.MIN_TICK);
        assertEq(hook.lastRefTick(), TickMath.MIN_TICK);
        _oracle(true, TickMath.MAX_TICK);
        hook.pokeAnchor();
        assertEq(hook.anchorTick(), TickMath.MAX_TICK);
        assertEq(hook.lastRefTick(), TickMath.MAX_TICK);
    }

    function test_badReferenceAtConstructionCannotEnableFallbackButCanRecover() public {
        oracle.configure(abi.encode(true), abi.encode(int256(type(int256).min)), false, false);
        hook = _deployHook(IPoolManager(address(manager)));
        assertFalse(hook.pool4Seen());
        launchKey.hooks = IHooks(address(hook));
        manager.initializeHook(IHooks(address(hook)), launchKey);
        _ready();
        vm.expectRevert(MedallionHook.Pool4Unavailable.selector);
        hook.burnIMD(false, 0);
        vm.expectRevert(MedallionHook.Pool4Unavailable.selector);
        hook.pokeAnchor();
        _oracle(true, -1000);
        hook.pokeAnchor();
        assertTrue(hook.pool4Seen());
        assertEq(hook.startOfBlockAnchor(), -1000);
        assertEq(hook.lastRefTick(), -1000);
        _oracle(false, -1000);
        manager.setTick(plainKey, -1000);
        hook.burnIMD(false, 0);
        assertEq(hook.burnSpent(), 0.01 ether);
    }

    function test_precedenceAvailabilityBeforeBudgetAndBudgetBeforePoolReads() public {
        // An unreadable slot makes the swap pool unavailable throughout this sequence.
        bytes32 slot = keccak256(abi.encode(PoolId.unwrap(plainKey.toId()), uint256(6)));
        vm.mockCall(address(manager), abi.encodeWithSignature("extsload(bytes32)", slot), abi.encode(bytes32(0)));
        _oracle(false, 0);
        vm.expectRevert(MedallionHook.TooSoon.selector);
        hook.burnIMD(true, 0);
        vm.roll(105);
        vm.expectRevert(MedallionHook.Pool4Unavailable.selector);
        hook.burnIMD(true, 0);
        vm.expectRevert(MedallionHook.NothingToBurn.selector);
        hook.burnIMD(false, 0);
        manager.accrue(IHooks(address(hook)), launchKey, CAP + 0.002 ether);
        vm.expectRevert(MedallionHook.PoolUnavailable.selector);
        hook.burnIMD(false, type(uint256).max);
        assertEq(hook.burnSpent(), 0);
        assertEq(hook.anchorBlock(), 100);
    }

    function testFuzz_invalidSpotTickFailsBeforeUnlock(int24 badTick) public {
        _ready();
        int256 tick = bound(int256(badTick), int256(TickMath.MAX_TICK) + 1, int256(type(int24).max));
        if (badTick < 0) tick = -tick;
        bytes32 slot = keccak256(abi.encode(PoolId.unwrap(plainKey.toId()), uint256(6)));
        bytes32 malformed = bytes32(uint256(1 << 96) | uint256(uint24(int24(tick))) << 160);
        vm.mockCall(address(manager), abi.encodeWithSignature("extsload(bytes32)", slot), abi.encode(malformed));
        vm.expectRevert(MedallionHook.PoolUnavailable.selector);
        hook.burnIMD(false, 0);
        _assertUnspent();
    }

    function test_partialFillPrecedesSlippageAndCannotMutateAnchor() public {
        _ready();
        _oracle(false, 0);
        manager.setTick(plainKey, 1000);
        manager.setFill(9999);
        vm.expectRevert(MedallionHook.PartialFill.selector);
        hook.burnIMD(false, type(uint256).max);
        assertEq(hook.anchorTick(), 0);
        assertEq(hook.anchorBlock(), 100);
        _assertUnspent();
        manager.setFill(10_000);
        hook.pokeAnchor();
        assertEq(hook.anchorTick(), 200);
        hook.burnIMD(false, 0);
        assertEq(hook.burnSpent(), 0.01 ether);
    }

    function test_slippageRevertsAnchorReseedAndCanRetryInSameBlock() public {
        _ready();
        _oracle(true, 1000);
        manager.setTick(plainKey, 1000);
        manager.setOutput(0, 0.055 ether);
        vm.expectRevert(MedallionHook.Slippage.selector);
        hook.burnIMD(false, type(uint256).max);
        assertEq(hook.anchorTick(), 0);
        assertEq(hook.lastRefTick(), 0);
        assertEq(hook.anchorBlock(), 100);
        _assertUnspent();
        hook.burnIMD(false, 0.055 ether);
        assertEq(hook.anchorTick(), 1000);
        assertEq(hook.totalIMDBurned(), 0.055 ether);
    }

    function test_normalReseedDoesNotRewriteExistingStartOfBlockFallbackReference() public {
        _ready();
        _oracle(true, 1000);
        hook.pokeAnchor();
        assertEq(hook.anchorTick(), 1000);
        assertEq(hook.startOfBlockAnchor(), 0);
        _oracle(false, 1000);
        manager.setOutput(9600, 0);
        // This block still uses the anchor that existed before the normal reseed.
        hook.burnIMD(false, 0);
        assertEq(imd.balanceOf(DEAD), 0.0096 ether);
        assertEq(hook.anchorTick(), 1000);
        vm.roll(110);
        vm.expectRevert(MedallionHook.PriceOffReference.selector);
        hook.burnIMD(false, 0);
        assertEq(hook.burnSpent(), 0.01 ether);
    }

    function test_quoteFloorAtPositiveAndNegativeTicksToSingleWei() public {
        _ready();
        // Independent decimal evaluation: floor(floor(0.05e18 * (10001/10000)^tick) * 96/100).
        int24[4] memory ticks = [int24(1), int24(-1), int24(1000), int24(-1000)];
        uint256[4] memory floors = [
            uint256(48004800000000000),
            uint256(47995200479952003),
            uint256(53047938844955168),
            uint256(43432413212772905)
        ];
        for (uint256 i; i < ticks.length; ++i) {
            _oracle(true, ticks[i]);
            manager.setTick(plainKey, ticks[i]);
            manager.setOutput(0, floors[i] - 1);
            vm.expectRevert(MedallionHook.Slippage.selector);
            hook.burnIMD(false, 0);
            manager.setOutput(0, floors[i]);
            assertEq(hook.burnIMD(false, 0), floors[i]);
            vm.roll(block.number + 5);
        }
        assertEq(hook.burnSpent(), 0.2 ether);
    }

    function test_quotePrecisionAcrossSquareRoot128BitBoundary() public {
        _ready();
        // Decimal prices are independently evaluated at 120 decimal digits.
        // A 1e18-unit bracket at these 1e36-unit outputs avoids treating TickMath's
        // minute approximation error as exact real-number arithmetic.
        int24[2] memory ticks = [int24(443635), int24(443637)];
        uint256[2] memory floors =
            [uint256(885321901942495519877276731305900069), uint256(885498975176103038406207385424928561)];
        for (uint256 i; i < ticks.length; ++i) {
            _oracle(true, ticks[i]);
            manager.setTick(plainKey, ticks[i]);
            manager.setOutput(0, floors[i] - 1 ether);
            vm.expectRevert(MedallionHook.Slippage.selector);
            hook.burnIMD(false, 0);
            manager.setOutput(0, floors[i] + 1 ether);
            assertEq(hook.burnIMD(false, 0), floors[i] + 1 ether);
            vm.roll(block.number + 5);
        }
        assertEq(hook.burnSpent(), 0.1 ether);
        assertEq(manager.balanceOf(address(hook), 0), CAP + 0.9 ether);
    }
}
