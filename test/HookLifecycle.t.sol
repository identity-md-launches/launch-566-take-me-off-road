// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {FareToken} from "../src/FareToken.sol";
import {MedallionHook} from "../src/MedallionHook.sol";
import {FareDeploy} from "./helpers/FareDeploy.sol";
import {FareRouter} from "./helpers/FareRouter.sol";
import {FarePool4Mock, FareNFTMock, FareReceiverMock} from "./mocks/RetireBurnMocks.sol";

/// @dev Attempts a top-level operation while somebody else already owns the real manager unlock.
contract LifecycleNestedUnlock is IUnlockCallback {
    IPoolManager immutable manager;
    MedallionHook immutable hook;

    constructor(IPoolManager manager_, MedallionHook hook_) {
        manager = manager_;
        hook = hook_;
    }

    function attempt(bool retirement) external {
        manager.unlock(abi.encode(retirement));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        if (abi.decode(data, (bool))) hook.retire();
        else hook.burnIMD(false, 0);
        return "";
    }
}

/// @notice Real v4 unlocks and currency settlement, with only fixed-address external contracts mocked.
contract HookLifecycleTest is Test, FareDeploy {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    address constant CREATOR = 0x70c6C4fcaAb11151FCEDb32eaaC3431547193A0a;
    address constant NFT = 0x9C8fF314C9Bc7F6e59A9d9225Fb22946427eDC03;
    address constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address constant POOL4 = 0xc6C965Bd164c483e87d0B550671798e9A3602840;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address constant NFT_OWNER = address(0x4447);
    address constant KEEPER = address(0xB077);
    uint160 constant Q96 = 79228162514264337593543950336;

    PoolManager manager;
    MedallionHook hook;
    FareRouter router;
    FareNFTMock nft;
    FarePool4Mock oracle;
    FareToken imd;
    PoolKey launch;
    PoolKey plain;

    event MedallionRetired(address indexed previousOwner);
    event CreatorPaid(address indexed creator, uint256 amount);
    event LastFare(uint256 indexed medallionId, bytes32 indexed fareHash, string fare);

    function setUp() public {
        vm.chainId(1);
        vm.roll(100);
        vm.deal(address(this), 100_000 ether);
        FareToken token = new FareToken();
        vm.etch(IMD, address(token).code);
        imd = FareToken(IMD);
        deal(IMD, address(this), 1e27, true);
        vm.etch(NFT, address(new FareNFTMock()).code);
        vm.etch(POOL4, address(new FarePool4Mock()).code);
        nft = FareNFTMock(NFT);
        oracle = FarePool4Mock(POOL4);
        nft.configure(NFT_OWNER, true);
        oracle.configure(true, 0, 0);

        manager = new PoolManager(address(this));
        hook = _deployHook(manager);
        router = new FareRouter(manager);
        token.approve(address(router), type(uint256).max);
        imd.approve(address(router), type(uint256).max);
        launch = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 3000, 60, IHooks(address(hook)));
        plain = PoolKey(Currency.wrap(address(0)), Currency.wrap(IMD), 10_000, 200, IHooks(address(0)));
        manager.initialize(launch, Q96);
        manager.initialize(plain, Q96);
        router.modifyLiquidity{value: 10_000 ether}(launch, ModifyLiquidityParams(-887220, 887220, 10_000 ether, 0));
        router.modifyLiquidity{value: 10_000 ether}(plain, ModifyLiquidityParams(-887200, 887200, 10_000 ether, 0));
        router.swap{value: 100 ether}(launch, SwapParams(true, -100 ether, TickMath.MIN_SQRT_PRICE + 1));
        assertEq(hook.totalFees(), 2 ether);
        assertEq(manager.balanceOf(address(hook), 0), 2 ether);
        vm.roll(105);
    }

    function test_realRetirementPaysExactlyCapAndPlainBurnSettlesEveryDelta() public {
        uint256 creatorBefore = CREATOR.balance;
        uint256 managerETHBefore = address(manager).balance;
        vm.expectEmit(true, false, false, true, address(hook));
        emit MedallionRetired(NFT_OWNER);
        vm.expectEmit(true, false, false, true, address(hook));
        emit CreatorPaid(CREATOR, 1.64 ether);
        vm.expectEmit(true, true, false, true, address(hook));
        emit LastFare(447, hook.LAST_FARE_HASH(), hook.LAST_FARE());
        vm.prank(KEEPER);
        hook.retire();

        assertEq(nft.ownerOf(447), DEAD);
        assertEq(nft.transferCount(), 1);
        assertTrue(hook.retired());
        assertEq(hook.creatorPaid(), 1.64 ether);
        assertEq(CREATOR.balance - creatorBefore, 1.64 ether);
        assertEq(managerETHBefore - address(manager).balance, 1.64 ether);
        assertEq(manager.balanceOf(address(hook), 0), 0.36 ether);
        _assertSettled();

        uint256 spent = _burnAndCheck(0.05 ether);
        assertGt(spent, 0.048 ether);
        assertEq(manager.balanceOf(address(hook), 0), 0.31 ether);
        assertEq(hook.burnable(), 0.31 ether);
        assertEq(CREATOR.balance - creatorBefore, 1.64 ether);
    }

    function test_realBurnBeforeRetirementPreservesFullCreatorReserve() public {
        uint256 creatorBefore = CREATOR.balance;
        _burnAndCheck(0.05 ether);
        assertEq(manager.balanceOf(address(hook), 0), 1.95 ether);
        assertGe(manager.balanceOf(address(hook), 0), hook.CREATOR_CAP());
        assertEq(hook.creatorPaid(), 0);
        assertEq(CREATOR.balance, creatorBefore);
        assertEq(nft.ownerOf(447), NFT_OWNER);
        hook.retire();
        assertEq(CREATOR.balance - creatorBefore, 1.64 ether);
        assertEq(manager.balanceOf(address(hook), 0), 0.31 ether);
        _assertSettled();
    }

    function test_realFallbackBurnUsesSmallerBatchAndSettles() public {
        oracle.configure(false, 0, 0);
        _burnAndCheck(0.01 ether);
        assertEq(hook.burnSpent(), 0.01 ether);
        assertEq(manager.balanceOf(address(hook), 0), 1.99 ether);
    }

    function test_realPoolCallerMinimumFailureRollsBackSwapAndLedger() public {
        (uint160 priceBefore,,,) = IPoolManager(address(manager)).getSlot0(plain.toId());
        uint256 imdBefore = imd.balanceOf(address(manager));
        vm.expectRevert(MedallionHook.Slippage.selector);
        hook.burnIMD(false, 1 ether);
        (uint160 priceAfter,,,) = IPoolManager(address(manager)).getSlot0(plain.toId());
        assertEq(priceAfter, priceBefore);
        assertEq(imd.balanceOf(address(manager)), imdBefore);
        assertEq(imd.balanceOf(DEAD), 0);
        assertEq(manager.balanceOf(address(hook), 0), 2 ether);
        assertEq(hook.burnSpent(), 0);
        assertEq(hook.totalIMDBurned(), 0);
        assertEq(hook.lastBurnBlock(), 100);
        _assertSettled();
        _burnAndCheck(0.05 ether);
    }

    function test_realEmptyPoolRevertsPartialFillWithoutSpendingClaims() public {
        router.modifyLiquidity(plain, ModifyLiquidityParams(-887200, 887200, -10_000 ether, 0));
        vm.expectRevert(MedallionHook.PartialFill.selector);
        hook.burnIMD(false, 0);
        assertEq(manager.balanceOf(address(hook), 0), 2 ether);
        assertEq(hook.burnSpent(), 0);
        assertEq(hook.totalIMDBurned(), 0);
        assertEq(hook.lastBurnBlock(), 100);
        _assertSettled();
    }

    function test_realRetirementRejectingRecipientRollsBackNFTAndClaims() public {
        vm.etch(CREATOR, address(new FareReceiverMock()).code);
        FareReceiverMock(payable(CREATOR)).configure(address(0), true);
        uint256 creatorBefore = CREATOR.balance;
        uint256 managerBefore = address(manager).balance;
        vm.expectRevert();
        hook.retire();
        assertEq(nft.ownerOf(447), NFT_OWNER);
        assertEq(nft.transferCount(), 0);
        assertFalse(hook.retired());
        assertEq(hook.creatorPaid(), 0);
        assertEq(CREATOR.balance, creatorBefore);
        assertEq(address(manager).balance, managerBefore);
        assertEq(manager.balanceOf(address(hook), 0), 2 ether);
        _assertSettled();
        FareReceiverMock(payable(CREATOR)).configure(address(0), false);
        hook.retire();
        assertTrue(hook.retired());
        assertEq(CREATOR.balance - creatorBefore, 1.64 ether);
    }

    function test_retirementCannotNestInsideAnotherManagerUnlock() public {
        LifecycleNestedUnlock nested = new LifecycleNestedUnlock(manager, hook);
        vm.expectRevert(IPoolManager.AlreadyUnlocked.selector);
        nested.attempt(true);
        assertEq(nft.ownerOf(447), NFT_OWNER);
        assertEq(nft.transferCount(), 0);
        assertFalse(hook.retired());
        assertEq(hook.creatorPaid(), 0);
        assertEq(manager.balanceOf(address(hook), 0), 2 ether);
        _assertSettled();
        hook.retire();
        assertTrue(hook.retired());
    }

    function test_burnCannotNestInsideAnotherManagerUnlock() public {
        LifecycleNestedUnlock nested = new LifecycleNestedUnlock(manager, hook);
        vm.expectRevert(IPoolManager.AlreadyUnlocked.selector);
        nested.attempt(false);
        assertEq(hook.burnSpent(), 0);
        assertEq(hook.lastBurnBlock(), 100);
        assertEq(manager.balanceOf(address(hook), 0), 2 ether);
        _assertSettled();
        _burnAndCheck(0.05 ether);
    }

    function _burnAndCheck(uint256 batch) internal returns (uint256 output) {
        uint256 claimsBefore = manager.balanceOf(address(hook), 0);
        uint256 burnedBefore = hook.totalIMDBurned();
        uint256 managerETH = address(manager).balance;
        uint256 managerIMD = imd.balanceOf(address(manager));
        uint256 sinkBefore = imd.balanceOf(DEAD);
        uint256 keeperETH = KEEPER.balance;
        uint256 keeperIMD = imd.balanceOf(KEEPER);
        vm.prank(KEEPER);
        output = hook.burnIMD(false, 0);
        assertGt(output, 0);
        assertEq(claimsBefore - manager.balanceOf(address(hook), 0), batch);
        assertEq(address(manager).balance, managerETH, "burned claims settle ETH without an ETH transfer");
        assertEq(managerIMD - imd.balanceOf(address(manager)), output);
        assertEq(imd.balanceOf(DEAD) - sinkBefore, output);
        assertEq(hook.totalIMDBurned() - burnedBefore, output);
        assertEq(KEEPER.balance, keeperETH);
        assertEq(imd.balanceOf(KEEPER), keeperIMD);
        assertEq(imd.balanceOf(address(hook)), 0);
        assertEq(manager.balanceOf(address(hook), 0), hook.totalFees() - hook.creatorPaid() - hook.burnSpent());
        _assertSettled();
    }

    function _assertSettled() internal view {
        IPoolManager pm = IPoolManager(address(manager));
        assertFalse(pm.isUnlocked());
        assertEq(pm.getNonzeroDeltaCount(), 0);
        assertEq(pm.currencyDelta(address(hook), Currency.wrap(address(0))), 0);
        assertEq(pm.currencyDelta(address(hook), Currency.wrap(IMD)), 0);
    }

    receive() external payable {}
}
