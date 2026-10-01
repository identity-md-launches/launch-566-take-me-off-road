// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {FareToken} from "../src/FareToken.sol";
import {MedallionHook} from "../src/MedallionHook.sol";
import {FareDeploy} from "./helpers/FareDeploy.sol";
import {FareRouter} from "./helpers/FareRouter.sol";

contract FeeActionHandler {
    FareRouter public immutable router;
    MedallionHook public immutable hook;
    PoolKey internal key;
    uint256 public donatedClaims;
    uint256 public successfulTrades;

    constructor(FareRouter router_, MedallionHook hook_, FareToken token_, PoolKey memory key_) {
        router = router_;
        hook = hook_;
        key = key_;
        token_.approve(address(router_), type(uint256).max);
    }

    function trade(uint96 rawAmount, bool buy, bool exactInput) external {
        uint256 amount = 100 + uint256(rawAmount) % (30 ether);
        router.swap{value: buy ? 100 ether : 0}(
            key,
            SwapParams(
                buy,
                exactInput ? -int256(amount) : int256(amount),
                buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            )
        );
        ++successfulTrades;
    }

    function donateClaims(uint96 rawAmount) external {
        uint256 amount = uint256(rawAmount) % (3 ether);
        donatedClaims += amount;
        router.donateClaims{value: amount}(address(hook));
    }

    receive() external payable {}
}

/// @dev Random real swaps in all four modes interleaved with unsolicited claim donations.
contract HookAccountingInvariantTest is Test, FareDeploy {
    PoolManager manager;
    MedallionHook hook;
    FareRouter router;
    FeeActionHandler handler;
    uint256 creatorStartingBalance;

    function setUp() public {
        vm.deal(address(this), 100_000 ether);
        manager = new PoolManager(address(this));
        FareToken token = new FareToken();
        hook = _deployHook(manager);
        router = new FareRouter(manager);
        token.approve(address(router), type(uint256).max);
        PoolKey memory key =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 3000, 60, IHooks(address(hook)));
        manager.initialize(key, 79228162514264337593543950336);
        router.modifyLiquidity{value: 10_000 ether}(key, ModifyLiquidityParams(-887220, 887220, 10_000 ether, 0));
        handler = new FeeActionHandler(router, hook, token, key);
        token.transfer(address(handler), 1_000_000 ether);
        vm.deal(address(handler), 100_000 ether);
        creatorStartingBalance = hook.CREATOR().balance;
        targetContract(address(handler));
    }

    function invariant_claimsCoverLedgerAndIncludeDonationsExactly() public view {
        assertEq(manager.balanceOf(address(hook), 0), hook.totalFees() + handler.donatedClaims());
        assertGe(manager.balanceOf(address(hook), 0), hook.totalFees() - hook.creatorPaid() - hook.burnSpent());
    }

    function invariant_onlyFeesAccrueAndCreatorDoesNotReceiveSwapPayments() public view {
        assertEq(hook.creatorPaid(), 0);
        assertEq(hook.CREATOR().balance, creatorStartingBalance);
        assertEq(hook.burnSpent(), 0);
        assertEq(address(hook).balance, 0);
        assertEq(address(router).balance, 0);
        uint256 entitlement = hook.totalFees() < 1.64 ether ? hook.totalFees() : 1.64 ether;
        assertEq(hook.creatorEntitlement(), entitlement);
        assertEq(hook.burnable(), hook.totalFees() - entitlement);
    }

    receive() external payable {}
}
