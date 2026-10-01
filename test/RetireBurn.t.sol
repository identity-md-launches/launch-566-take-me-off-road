// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {MedallionHook} from "../src/MedallionHook.sol";
import {FareDeploy} from "./helpers/FareDeploy.sol";
import {FareManagerMock, FarePool4Mock, FareNFTMock, FareIMDMock, FareReceiverMock} from "./mocks/RetireBurnMocks.sol";

contract RetireBurnTest is Test, FareDeploy {
    using PoolIdLibrary for PoolKey;

    address constant CREATOR = 0x70c6C4fcaAb11151FCEDb32eaaC3431547193A0a;
    address constant NFT = 0x9C8fF314C9Bc7F6e59A9d9225Fb22946427eDC03;
    address constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address constant POOL4 = 0xc6C965Bd164c483e87d0B550671798e9A3602840;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address constant OWNER = address(0x4447);
    uint256 constant CAP = 1.64 ether;

    FareManagerMock manager;
    FarePool4Mock oracle;
    FareNFTMock nft;
    FareIMDMock imd;
    MedallionHook hook;
    PoolKey launchKey;
    PoolKey pool4Key;
    PoolKey plainKey;

    event MedallionRetired(address indexed previousOwner);
    event CreatorPaid(address indexed creator, uint256 amount);
    event LastFare(uint256 indexed medallionId, bytes32 indexed hash, string text);

    function setUp() public {
        vm.chainId(1);
        vm.roll(100);
        vm.etch(POOL4, address(new FarePool4Mock()).code);
        vm.etch(NFT, address(new FareNFTMock()).code);
        vm.etch(IMD, address(new FareIMDMock()).code);
        oracle = FarePool4Mock(POOL4);
        nft = FareNFTMock(NFT);
        imd = FareIMDMock(IMD);
        oracle.configure(true, 0, 0);
        nft.configure(OWNER, false);
        manager = new FareManagerMock();
        hook = _deployHook(IPoolManager(address(manager)));
        launchKey = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(0xFA447)), 3000, 60, IHooks(address(hook)));
        pool4Key = PoolKey(Currency.wrap(address(0)), Currency.wrap(IMD), 10_000, 60, IHooks(POOL4));
        plainKey = PoolKey(Currency.wrap(address(0)), Currency.wrap(IMD), 10_000, 200, IHooks(address(0)));
        manager.initializeHook(IHooks(address(hook)), launchKey);
        manager.setTick(pool4Key, 0);
        manager.setTick(plainKey, 0);
        vm.deal(address(manager), 100 ether);
        imd.mint(address(manager), 100 ether);
    }

    function _fund(uint256 amount) internal {
        manager.accrue(IHooks(address(hook)), launchKey, amount);
    }

    function _ready() internal {
        _fund(CAP + 1 ether);
        vm.roll(block.number + 5);
    }

    function _closed(int24 spot) internal {
        oracle.configure(false, 0, 0);
        manager.setTick(plainKey, spot);
    }

    function _assertLedger() internal view {
        assertGe(manager.balanceOf(address(hook), 0), hook.totalFees() - hook.creatorPaid() - hook.burnSpent());
        assertEq(hook.creatorEntitlement(), hook.totalFees() < CAP ? hook.totalFees() : CAP);
        assertEq(hook.burnable(), hook.totalFees() - hook.creatorEntitlement() - hook.burnSpent());
    }

    function test_constructorSeedsAnchorAndStartsCooldown() public view {
        assertTrue(hook.pool4Seen());
        assertEq(hook.anchorTick(), 0);
        assertEq(hook.lastRefTick(), 0);
        assertEq(hook.lastBurnBlock(), 100);
        assertEq(hook.lastReferenceBlock(), 100);
    }

    function test_constructorSeedsClosedOracle() public {
        oracle.configure(false, 875, 0);
        MedallionHook other = _deployHook(IPoolManager(address(manager)));
        assertTrue(other.pool4Seen());
        assertEq(other.anchorTick(), 875);
        assertEq(other.lastRefTick(), 875);
        assertEq(other.lastReferenceBlock(), block.number);
    }

    function test_retireBelowCapReverts() public {
        _fund(CAP - 1);
        vm.expectRevert(MedallionHook.NotRecouped.selector);
        hook.retire();
        assertEq(hook.creatorPaid(), 0);
        assertEq(nft.holder(), OWNER);
        _assertLedger();
    }

    function test_retireWithoutApprovalLeavesEverythingUnchanged() public {
        _fund(CAP + 0.03 ether);
        bytes memory refusal = abi.encodeWithSignature("Error(string)", "NO_APPROVAL");
        vm.expectRevert(abi.encodeWithSelector(MedallionHook.RetireRefused.selector, refusal));
        hook.retire();
        assertFalse(hook.retired());
        assertEq(hook.creatorPaid(), 0);
        assertEq(CREATOR.balance, 0);
        assertEq(nft.holder(), OWNER);
        assertEq(manager.balanceOf(address(hook), 0), CAP + 0.03 ether);
        _assertLedger();
    }

    function test_retireAtomicTransferExactPaymentAndLastFareEvents() public {
        _fund(CAP + 0.1 ether);
        nft.configure(OWNER, true);
        vm.expectEmit(true, false, false, true, address(hook));
        emit MedallionRetired(OWNER);
        vm.expectEmit(true, false, false, true, address(hook));
        emit CreatorPaid(CREATOR, CAP);
        vm.expectEmit(true, true, false, true, address(hook));
        emit LastFare(447, hook.LAST_FARE_HASH(), hook.LAST_FARE());
        vm.prank(address(0xCA11));
        hook.retire();
        assertEq(nft.holder(), DEAD);
        assertTrue(hook.retired());
        assertEq(hook.creatorPaid(), CAP);
        assertEq(CREATOR.balance, CAP);
        assertEq(manager.balanceOf(address(hook), 0), 0.1 ether);
        assertEq(manager.unlockCount(), 1);
        _assertLedger();
        vm.expectRevert(MedallionHook.AlreadyRetired.selector);
        hook.retire();
        assertEq(CREATOR.balance, CAP);
    }

    function test_retireAlreadyDeadNeedsNoApprovalAndEmitsNoTransferEvent() public {
        _fund(CAP);
        nft.configure(DEAD, false);
        vm.recordLogs();
        hook.retire();
        Vm.Log[] memory entries = vm.getRecordedLogs();
        for (uint256 i; i < entries.length; ++i) {
            assertTrue(entries[i].topics[0] != keccak256("MedallionRetired(address)"));
        }
        assertEq(nft.transferCount(), 0);
        assertEq(CREATOR.balance, CAP);
        assertTrue(hook.retired());
    }

    function test_retireNoNFTCodeAndMalformedOwnerFailClosed() public {
        _fund(CAP);
        nft.setBadOwner(true);
        vm.expectRevert(MedallionHook.MedallionUnavailable.selector);
        hook.retire();
        vm.etch(NFT, "");
        vm.expectRevert(MedallionHook.MedallionUnavailable.selector);
        hook.retire();
        assertEq(hook.creatorPaid(), 0);
    }

    function test_retireSuccessfulCallWithoutMovingNFTReverts() public {
        _fund(CAP);
        nft.configure(OWNER, true);
        nft.setNoMove(true);
        vm.expectPartialRevert(MedallionHook.RetireRefused.selector);
        hook.retire();
        assertEq(nft.transferCount(), 0);
        assertEq(hook.creatorPaid(), 0);
        assertFalse(hook.retired());
    }

    function test_retireCreatorRefusalRollsBackNFTAndClaims() public {
        _fund(CAP);
        nft.configure(OWNER, true);
        vm.etch(CREATOR, address(new FareReceiverMock()).code);
        FareReceiverMock(payable(CREATOR)).configure(address(hook), true);
        vm.expectRevert();
        hook.retire();
        assertEq(nft.holder(), OWNER);
        assertFalse(hook.retired());
        assertEq(hook.creatorPaid(), 0);
        assertEq(manager.balanceOf(address(hook), 0), CAP);
    }

    function test_retireNFTAndCreatorReentrancyBothRefused() public {
        _fund(CAP);
        nft.configure(OWNER, true);
        nft.setReenter(address(hook));
        vm.etch(CREATOR, address(new FareReceiverMock()).code);
        FareReceiverMock(payable(CREATOR)).configure(address(hook), false);
        hook.retire();
        assertEq(nft.reentryError(), MedallionHook.Reentrant.selector);
        assertEq(FareReceiverMock(payable(CREATOR)).reentryError(), MedallionHook.Reentrant.selector);
        assertEq(CREATOR.balance, CAP);
        assertTrue(hook.retired());
    }

    function test_burnTooSoonTakesPrecedence() public {
        vm.etch(POOL4, "");
        vm.expectRevert(MedallionHook.TooSoon.selector);
        hook.burnIMD(true, 0);
    }

    function test_burnReserveUnavailableBelowCapAndBelowMinimum() public {
        _fund(CAP - 1);
        vm.roll(block.number + 5);
        vm.expectRevert(MedallionHook.NothingToBurn.selector);
        hook.burnIMD(false, 0);
        _fund(0.002 ether);
        vm.expectRevert(MedallionHook.NothingToBurn.selector);
        hook.burnIMD(false, 0);
        assertEq(hook.burnable(), 0.002 ether - 1);
    }

    function test_burnExactlyMinimumWorksBeforeRetirement() public {
        _fund(CAP + 0.002 ether);
        vm.roll(block.number + 5);
        hook.burnIMD(false, 0);
        assertEq(hook.burnSpent(), 0.002 ether);
        assertEq(hook.creatorPaid(), 0);
        assertEq(manager.balanceOf(address(hook), 0), CAP);
        assertEq(imd.balanceOf(DEAD), 0.002 ether);
        _assertLedger();
    }

    function test_burnNormalUsesExactFixedPool4KeyAndMaximumBatch() public {
        _ready();
        uint256 callerETH = address(this).balance;
        hook.burnIMD(true, 0);
        assertEq(PoolId.unwrap(manager.lastPoolId()), PoolId.unwrap(pool4Key.toId()));
        assertEq(hook.burnSpent(), 0.05 ether);
        assertEq(imd.balanceOf(DEAD), 0.05 ether);
        assertEq(hook.totalIMDBurned(), 0.05 ether);
        assertEq(imd.balanceOf(address(this)), 0);
        assertEq(address(this).balance, callerETH);
        assertEq(hook.lastBurnBlock(), block.number);
        assertEq(hook.creatorPaid(), 0);
        _assertLedger();
    }

    function test_burnPlainNormalUsesExactFixedKey() public {
        _ready();
        hook.burnIMD(false, 0);
        assertEq(PoolId.unwrap(manager.lastPoolId()), PoolId.unwrap(plainKey.toId()));
        assertEq(hook.burnSpent(), 0.05 ether);
        assertEq(manager.unlockCount(), 1);
    }

    function test_burnBatchUsesRemainingBurnable() public {
        _fund(CAP + 0.025 ether);
        vm.roll(block.number + 5);
        hook.burnIMD(false, 0);
        assertEq(hook.burnSpent(), 0.025 ether);
        assertEq(hook.burnable(), 0);
        _assertLedger();
    }

    function test_burnDonationsCannotIncreaseBatchOrBudget() public {
        _fund(CAP);
        manager.donateClaims(address(hook), 99 ether);
        vm.roll(block.number + 5);
        vm.expectRevert(MedallionHook.NothingToBurn.selector);
        hook.burnIMD(false, 0);
        assertEq(hook.totalFees(), CAP);
        assertEq(hook.burnable(), 0);
        _assertLedger();
    }

    function test_burnEnforcesCooldownAgainAfterSuccess() public {
        _ready();
        hook.burnIMD(false, 0);
        vm.roll(block.number + 4);
        vm.expectRevert(MedallionHook.TooSoon.selector);
        hook.burnIMD(false, 0);
        vm.roll(block.number + 1);
        hook.burnIMD(false, 0);
        assertEq(hook.burnSpent(), 0.1 ether);
    }

    function test_burnPool4RejectsBelowReferenceBeyond150Ticks() public {
        _ready();
        manager.setTick(pool4Key, -151);
        vm.expectRevert(MedallionHook.PriceOffReference.selector);
        hook.burnIMD(true, 0);
        manager.setTick(pool4Key, -150);
        hook.burnIMD(true, 0);
    }

    function test_burnPlainNormalAllows300TicksButNoMore() public {
        _ready();
        manager.setTick(plainKey, -301);
        vm.expectRevert(MedallionHook.PriceOffReference.selector);
        hook.burnIMD(false, 0);
        manager.setTick(plainKey, -300);
        hook.burnIMD(false, 0);
    }

    function test_burnGuardIsOneSidedAtHigherSpot() public {
        _ready();
        manager.setTick(pool4Key, 50_000);
        hook.burnIMD(true, 0);
        assertEq(hook.burnSpent(), 0.05 ether);
    }

    function test_burnReferenceFloorExcludesLPFeeAndRespectsCallerMinimum() public {
        _ready();
        manager.setOutput(9599, 0);
        vm.expectRevert(MedallionHook.Slippage.selector);
        hook.burnIMD(false, 0);
        manager.setOutput(9700, 0);
        vm.expectRevert(MedallionHook.Slippage.selector);
        hook.burnIMD(false, 0.049 ether);
        manager.setOutput(9600, 0);
        hook.burnIMD(false, 0);
        assertEq(imd.balanceOf(DEAD), 0.048 ether);
    }

    function test_burnNonzeroReferenceQuote() public {
        _ready();
        oracle.configure(true, 1000, 0);
        manager.setTick(plainKey, 1000);
        // 0.05 * 1.0001^1000 * 0.96 is about 0.053048 ETH-equivalent IMD.
        manager.setOutput(10_000, 0.053 ether);
        vm.expectRevert(MedallionHook.Slippage.selector);
        hook.burnIMD(false, 0);
        manager.setOutput(10_000, 0.0531 ether);
        hook.burnIMD(false, 0);
        assertEq(hook.anchorTick(), 1000);
        assertEq(hook.lastRefTick(), 1000);
        assertEq(imd.balanceOf(DEAD), 0.0531 ether);
    }

    function test_burnZeroAndPartialFillRevertAndRestoreLedger() public {
        _ready();
        uint256 claims = manager.balanceOf(address(hook), 0);
        manager.setFill(0);
        vm.expectRevert(MedallionHook.PartialFill.selector);
        hook.burnIMD(false, 0);
        manager.setFill(9999);
        vm.expectRevert(MedallionHook.PartialFill.selector);
        hook.burnIMD(false, 0);
        assertEq(hook.burnSpent(), 0);
        assertEq(manager.balanceOf(address(hook), 0), claims);
        assertEq(hook.lastBurnBlock(), 100);
        assertEq(imd.balanceOf(DEAD), 0);
    }

    function test_burnFullInputWithZeroOutputReverts() public {
        _ready();
        manager.setOutput(0, 0);
        vm.expectRevert(MedallionHook.PartialFill.selector);
        hook.burnIMD(false, 0);
        assertEq(hook.burnSpent(), 0);
        assertEq(hook.totalIMDBurned(), 0);
        _assertLedger();
    }

    function testFuzz_burnBatchAndRetirementKeepExactReservation(uint96 excess, bool fallbackMode) public {
        uint256 surplus = bound(uint256(excess), 0.002 ether, 1 ether);
        _fund(CAP + surplus);
        manager.donateClaims(address(hook), 1 ether);
        vm.roll(block.number + 5);
        if (fallbackMode) _closed(0);
        uint256 maximum = fallbackMode ? 0.01 ether : 0.05 ether;
        uint256 expected = surplus < maximum ? surplus : maximum;
        hook.burnIMD(false, 0);
        assertEq(hook.burnSpent(), expected);
        assertEq(hook.creatorPaid(), 0);
        assertEq(manager.balanceOf(address(hook), 0), CAP + surplus + 1 ether - expected);
        _assertLedger();
        nft.configure(OWNER, true);
        hook.retire();
        assertEq(CREATOR.balance, CAP);
        assertEq(hook.burnable(), surplus - expected);
        _assertLedger();
    }

    function test_burnReentrancyRefusedAcrossAllPermissionlessEntrypoints() public {
        _ready();
        manager.setReentry(true);
        hook.burnIMD(false, 0);
        assertEq(manager.burnReentryError(), MedallionHook.Reentrant.selector);
        assertEq(manager.retireReentryError(), MedallionHook.Reentrant.selector);
        assertEq(manager.pokeReentryError(), MedallionHook.Reentrant.selector);
        assertEq(hook.burnSpent(), 0.05 ether);
        _assertLedger();
    }

    function test_burnCannotJoinAnotherCallersUnlock() public {
        _ready();
        manager.unlock("");
        assertEq(hook.burnSpent(), 0);
        assertEq(hook.lastBurnBlock(), 100);
        _assertLedger();
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(msg.sender == address(manager), "only mock manager");
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "manager already unlocked"));
        hook.burnIMD(false, 0);
        return "";
    }

    function test_burnClosedOracleOnlyPlainFallbackAllowedBeforeBudgetCheck() public {
        vm.roll(block.number + 5);
        _closed(0);
        vm.expectRevert(MedallionHook.Pool4Unavailable.selector);
        hook.burnIMD(true, 0);
        _fund(CAP + 1 ether);
        hook.burnIMD(false, 0);
        assertEq(hook.burnSpent(), 0.01 ether);
        assertEq(PoolId.unwrap(manager.lastPoolId()), PoolId.unwrap(plainKey.toId()));
    }

    function test_burnMissingOracleFallbackWorksAfterPriorSeed() public {
        _ready();
        vm.etch(POOL4, "");
        hook.burnIMD(false, 0);
        assertEq(hook.burnSpent(), 0.01 ether);
    }

    function test_neverReadOracleDisablesBurnAndPoke() public {
        vm.etch(POOL4, "");
        MedallionHook other = _deployHook(IPoolManager(address(manager)));
        assertFalse(other.pool4Seen());
        vm.roll(block.number + 5);
        vm.expectRevert(MedallionHook.Pool4Unavailable.selector);
        other.burnIMD(false, 0);
        vm.expectRevert(MedallionHook.Pool4Unavailable.selector);
        other.pokeAnchor();
    }

    function _seedHookAfterOracleArrives() internal {
        bytes memory oracleCode = POOL4.code;
        vm.etch(POOL4, "");
        hook = _deployHook(IPoolManager(address(manager)));
        assertFalse(hook.pool4Seen());
        launchKey.hooks = IHooks(address(hook));
        manager.initializeHook(IHooks(address(hook)), launchKey);
        _fund(CAP + 1 ether);
        vm.roll(block.number + 5);
        vm.etch(POOL4, oracleCode);
        oracle.configure(true, 1000, 0);
        hook.pokeAnchor();
        assertTrue(hook.pool4Seen());
        assertEq(hook.anchorTick(), 1000);
        assertEq(hook.startOfBlockAnchor(), 1000);
        oracle.configure(false, 1000, 0);
    }

    function test_firstDelayedSeedProtectsSameBlockFallbackPriceGuard() public {
        _seedHookAfterOracleArrives();
        manager.setTick(plainKey, 800);
        // A zero snapshot would allow this spot, despite being 200 ticks below the first known reference.
        vm.expectRevert(MedallionHook.PriceOffReference.selector);
        hook.burnIMD(false, 0);
        assertEq(hook.burnSpent(), 0);
        assertEq(hook.startOfBlockAnchor(), 1000);
    }

    function test_firstDelayedSeedProtectsSameBlockFallbackMinimumOutput() public {
        _seedHookAfterOracleArrives();
        manager.setTick(plainKey, 1000);
        // At reference 1000 the floor exceeds 0.0106 IMD; the mock's default 0.01 output is insufficient.
        vm.expectRevert(MedallionHook.Slippage.selector);
        hook.burnIMD(false, 0);
        manager.setOutput(10_000, 0.011 ether);
        hook.burnIMD(false, 0);
        assertEq(hook.burnSpent(), 0.01 ether);
        assertEq(imd.balanceOf(DEAD), 0.011 ether);
        assertEq(hook.startOfBlockAnchor(), 1000);
        _assertLedger();
    }

    function test_revertingOracleNeverSeeds() public {
        oracle.configure(true, 0, 1);
        MedallionHook other = _deployHook(IPoolManager(address(manager)));
        assertFalse(other.pool4Seen());
    }

    function test_shortOracleReturnNeverSeeds() public {
        oracle.configure(true, 0, 2);
        MedallionHook other = _deployHook(IPoolManager(address(manager)));
        assertFalse(other.pool4Seen());
    }

    function test_invalidOracleBoolNeverSeeds() public {
        oracle.configure(true, 0, 3);
        MedallionHook other = _deployHook(IPoolManager(address(manager)));
        assertFalse(other.pool4Seen());
    }

    function test_outOfRangeOracleTickNeverSeeds() public {
        oracle.configure(true, 887273, 0);
        MedallionHook invalidTick = _deployHook(IPoolManager(address(manager)));
        assertFalse(invalidTick.pool4Seen());
    }

    function test_malformedOracleFallsBackAfterSeed() public {
        _ready();
        oracle.configure(true, 0, 2);
        hook.burnIMD(false, 0);
        assertEq(hook.burnSpent(), 0.01 ether);
    }

    function test_noPriorBurnAllowsNormalAfterLongIdle() public {
        _fund(CAP + 1 ether);
        vm.roll(block.number + 60_000);
        hook.burnIMD(true, 0);
        assertEq(hook.burnSpent(), 0.05 ether);
    }

    function test_priorBurnBecomesStaleAndFallbackResumesNormalLater() public {
        _ready();
        hook.burnIMD(true, 0);
        vm.roll(block.number + 50_401);
        vm.expectRevert(MedallionHook.Pool4Unavailable.selector);
        hook.burnIMD(true, 0);
        hook.burnIMD(false, 0);
        assertEq(hook.burnSpent(), 0.06 ether);
        vm.roll(block.number + 5);
        hook.burnIMD(true, 0);
        assertEq(hook.burnSpent(), 0.11 ether);
    }

    function test_staleBoundaryIsInclusive() public {
        _ready();
        hook.burnIMD(true, 0);
        vm.roll(block.number + 50_400);
        hook.burnIMD(true, 0);
        assertEq(hook.burnSpent(), 0.1 ether);
    }

    function _assertStaleLiveRecovery(int24 tick, uint256 quotedOutput, bool viaPool4) internal {
        _ready();
        hook.burnIMD(true, 0);
        vm.roll(block.number + hook.STALE_AFTER_BLOCKS() + 1);
        oracle.configure(true, tick, 0);
        manager.setTick(pool4Key, tick);
        manager.setTick(plainKey, tick);
        vm.expectRevert(MedallionHook.Pool4Unavailable.selector);
        hook.burnIMD(true, 0);

        vm.prank(address(0xCA11));
        hook.pokeAnchor();
        assertEq(hook.lastRefTick(), tick);
        assertEq(hook.anchorTick(), tick);
        assertEq(hook.lastReferenceBlock(), block.number);
        assertEq(hook.lastBurnBlock(), 105);
        // Fill at the new market quote, including downward moves outside the old fallback band.
        manager.setOutput(10_000, quotedOutput);
        hook.burnIMD(viaPool4, 0);
        assertEq(hook.burnSpent(), 0.1 ether);
        assertEq(hook.burnable(), 0.9 ether);
        assertEq(imd.balanceOf(DEAD), 0.05 ether + quotedOutput);
        assertEq(PoolId.unwrap(manager.lastPoolId()), PoolId.unwrap(viaPool4 ? pool4Key.toId() : plainKey.toId()));
        _assertLedger();
    }

    function test_staleLivePokeRecoversPool4AfterLargeDownwardMove() public {
        // floor(0.05 ether * 1.0001**-1500), independently calculated decimal quote.
        _assertStaleLiveRecovery(-1500, 43_035_721_566_438_176, true);
    }

    function test_staleLivePokeRecoversPlainAfterLargeDownwardMove() public {
        _assertStaleLiveRecovery(-1500, 43_035_721_566_438_176, false);
    }

    function test_staleLivePokeRecoversPool4AfterLargeUpwardMove() public {
        // floor(0.05 ether * 1.0001**1500), independently calculated decimal quote.
        _assertStaleLiveRecovery(1500, 58_091_276_479_250_418, true);
    }

    function test_staleLivePokeRecoversPlainAfterLargeUpwardMove() public {
        _assertStaleLiveRecovery(1500, 58_091_276_479_250_418, false);
    }

    function test_staleLivePokeRecoversWithoutInitializedPlainPool() public {
        manager = new FareManagerMock();
        hook = _deployHook(IPoolManager(address(manager)));
        launchKey.hooks = IHooks(address(hook));
        manager.initializeHook(IHooks(address(hook)), launchKey);
        manager.setTick(pool4Key, 0);
        imd.mint(address(manager), 1 ether);
        _ready();
        hook.burnIMD(true, 0);
        vm.roll(block.number + hook.STALE_AFTER_BLOCKS() + 1);
        vm.expectRevert(MedallionHook.PoolUnavailable.selector);
        hook.burnIMD(false, 0);

        oracle.configure(true, -1500, 0);
        manager.setTick(pool4Key, -1500);
        hook.pokeAnchor();
        manager.setOutput(10_000, 43_035_721_566_438_176);
        hook.burnIMD(true, 0);
        assertEq(hook.burnSpent(), 0.1 ether);
        assertEq(hook.lastRefTick(), -1500);
        assertEq(hook.lastReferenceBlock(), block.number);
        _assertLedger();
    }

    function test_livePokeDoesNotSpendFeesOrResetBurnCooldown() public {
        _ready();
        hook.burnIMD(true, 0);
        uint256 burnedAt = hook.lastBurnBlock();
        uint256 claims = manager.balanceOf(address(hook), 0);
        uint256 burnedIMD = hook.totalIMDBurned();
        vm.roll(burnedAt + 4);
        hook.pokeAnchor();
        assertEq(hook.lastBurnBlock(), burnedAt);
        assertEq(hook.lastReferenceBlock(), block.number);
        assertEq(hook.burnSpent(), 0.05 ether);
        assertEq(hook.totalIMDBurned(), burnedIMD);
        assertEq(manager.balanceOf(address(hook), 0), claims);
        assertEq(manager.unlockCount(), 1);
        vm.expectRevert(MedallionHook.TooSoon.selector);
        hook.burnIMD(true, 0);
        vm.roll(burnedAt + 5);
        hook.burnIMD(true, 0);
        assertEq(hook.burnSpent(), 0.1 ether);
        _assertLedger();
    }

    function _assertFallbackPokesCannotRefreshOracle(bool malformed) internal {
        _ready();
        hook.burnIMD(true, 0);
        uint256 originalReferenceBlock = hook.lastReferenceBlock();
        vm.roll(block.number + hook.STALE_AFTER_BLOCKS() + 1);
        oracle.configure(malformed, 5000, malformed ? 2 : 0);
        manager.setTick(plainKey, 5000);
        for (uint256 i; i < 6; ++i) {
            hook.pokeAnchor();
            vm.roll(block.number + 1);
        }
        assertEq(hook.lastRefTick(), 0);
        assertEq(hook.anchorTick(), 1000);
        assertEq(hook.burnSpent(), 0.05 ether);
        assertEq(hook.lastReferenceBlock(), originalReferenceBlock);
        // Becoming readable/open is insufficient: a fresh validated seed or burn is still required.
        oracle.configure(true, 5000, 0);
        vm.expectRevert(MedallionHook.Pool4Unavailable.selector);
        hook.burnIMD(true, 0);
        _assertLedger();
    }

    function test_staleClosedOracleFallbackPokesCannotRefreshFreshness() public {
        _assertFallbackPokesCannotRefreshOracle(false);
    }

    function test_staleMalformedOracleFallbackPokesCannotRefreshFreshness() public {
        _assertFallbackPokesCannotRefreshOracle(true);
    }

    function _pokeAfterStaleBurn() internal returns (uint256 seededAt) {
        _ready();
        hook.burnIMD(true, 0);
        vm.roll(block.number + hook.STALE_AFTER_BLOCKS() + 1);
        hook.pokeAnchor();
        seededAt = block.number;
        assertEq(hook.lastReferenceBlock(), seededAt);
        assertEq(hook.lastBurnBlock(), 105);
    }

    function test_liveSeedFreshnessBoundaryIsInclusive() public {
        uint256 seededAt = _pokeAfterStaleBurn();
        vm.roll(seededAt + hook.STALE_AFTER_BLOCKS());
        hook.burnIMD(true, 0);
        assertEq(hook.burnSpent(), 0.1 ether);
        assertEq(hook.lastReferenceBlock(), block.number);
    }

    function test_liveSeedFreshnessExpiresBackToFallback() public {
        uint256 seededAt = _pokeAfterStaleBurn();
        vm.roll(seededAt + hook.STALE_AFTER_BLOCKS() + 1);
        vm.expectRevert(MedallionHook.Pool4Unavailable.selector);
        hook.burnIMD(true, 0);
        hook.burnIMD(false, 0);
        assertEq(hook.burnSpent(), 0.06 ether);
        assertEq(hook.lastReferenceBlock(), seededAt);
    }

    function test_fallbackBurnUsesStartOfBlockAnchorAfterPoke() public {
        _ready();
        _closed(1000);
        hook.pokeAnchor();
        assertEq(hook.anchorTick(), 200);
        manager.setOutput(9650, 0);
        // Passes 96% of reference zero, fails 96% of the newly stepped anchor 200.
        hook.burnIMD(false, 0);
        assertEq(hook.anchorTick(), 200);
        assertEq(imd.balanceOf(DEAD), 0.00965 ether);
    }

    function test_fallbackDownwardPokeCannotRelaxSameBlockGuard() public {
        _ready();
        _closed(-200);
        hook.pokeAnchor();
        assertEq(hook.anchorTick(), -200);
        vm.expectRevert(MedallionHook.PriceOffReference.selector);
        hook.burnIMD(false, 0);
        vm.roll(block.number + 1);
        hook.burnIMD(false, 0);
        assertEq(hook.burnSpent(), 0.01 ether);
    }

    function test_fallbackTolerance150AndOneStepPerBlockEvenAfterIdle() public {
        _ready();
        _closed(-151);
        vm.expectRevert(MedallionHook.PriceOffReference.selector);
        hook.burnIMD(false, 0);
        manager.setTick(plainKey, -150);
        hook.burnIMD(false, 0);
        vm.roll(block.number + 60_000);
        manager.setTick(plainKey, 10_000);
        int24 oldAnchor = hook.anchorTick();
        hook.pokeAnchor();
        assertEq(hook.anchorTick(), oldAnchor + 200);
        hook.pokeAnchor();
        hook.pokeAnchor();
        assertEq(hook.anchorTick(), oldAnchor + 200);
    }

    function test_fallbackAnchorClampsToLastReferenceBand() public {
        _ready();
        _closed(5000);
        for (uint256 i; i < 8; ++i) {
            hook.pokeAnchor();
            vm.roll(block.number + 1);
        }
        assertEq(hook.anchorTick(), 1000);
        assertEq(hook.lastRefTick(), 0);
        manager.setTick(plainKey, -5000);
        for (uint256 i; i < 12; ++i) {
            hook.pokeAnchor();
            vm.roll(block.number + 1);
        }
        assertEq(hook.anchorTick(), -1000);
        assertEq(hook.lastRefTick(), 0);
    }

    function test_pokeNormalReseedsReferencePermissionlessly() public {
        oracle.configure(true, 700, 0);
        vm.prank(address(0xCA11));
        hook.pokeAnchor();
        assertEq(hook.anchorTick(), 700);
        assertEq(hook.lastRefTick(), 700);
        vm.roll(block.number + 1);
        oracle.configure(false, 50_000, 0);
        manager.setTick(plainKey, 5000);
        hook.pokeAnchor();
        assertEq(hook.anchorTick(), 900);
        assertEq(hook.lastRefTick(), 700);
    }

    function test_sepoliaRetirementAndBurnRevertEvenWithEtchedMainnetMocks() public {
        _ready();
        nft.configure(OWNER, true);
        vm.chainId(11155111);
        vm.expectRevert(MedallionHook.WrongChain.selector);
        hook.retire();
        vm.expectRevert(MedallionHook.WrongChain.selector);
        hook.burnIMD(false, 0);
        assertEq(nft.holder(), OWNER);
        assertEq(hook.burnSpent(), 0);
    }

    function test_completeLifecyclePreservesReservationAndStatus() public {
        assertEq(hook.status(), "IN SERVICE. Recouped 0.00 of 1.64 ETH.");
        _fund(1.239 ether);
        assertEq(hook.status(), "IN SERVICE. Recouped 1.23 of 1.64 ETH.");
        _fund(0.501 ether);
        assertEq(
            hook.status(),
            "RECOUPED, NOT RETIRED. The 1.64 ETH is ready and is released only by the transaction that retires medallion #447."
        );
        vm.roll(block.number + 5);
        manager.setOutput(10_000, 12.39 ether);
        hook.burnIMD(false, 0);
        nft.configure(OWNER, true);
        hook.retire();
        assertEq(
            hook.status(),
            "RETIRED. Medallion #447 is at 0x...dEaD. 1.64 ETH paid. Every fee buys $IMD and sends it there. IMD burned so far: 12.3."
        );
        _assertLedger();
    }
}
