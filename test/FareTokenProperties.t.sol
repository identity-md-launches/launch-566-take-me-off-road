// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FareToken} from "src/FareToken.sol";

/// @dev A closed set of holders lets the model account for every issued unit. Expected
/// balances and allowances come only from action inputs, never from contract reads.
contract FareTokenActionHandler is Test {
    FareToken public immutable token;
    address[4] public actors;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;
    uint256 public burned;

    constructor() {
        actors = [address(0xA11CE), address(0xB0B), address(0xCAFE), address(0xD00D)];
        vm.prank(actors[0]);
        token = new FareToken();
        expectedBalance[actors[0]] = 1e27;
        for (uint256 i = 1; i < actors.length; ++i) {
            vm.prank(actors[0]);
            token.transfer(actors[i], 1e27 / 4);
            expectedBalance[actors[0]] -= 1e27 / 4;
            expectedBalance[actors[i]] = 1e27 / 4;
        }
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 raw, uint8 mode) external {
        address owner = _actor(ownerSeed);
        address spender = mode % 7 == 0 ? address(0) : _actor(spenderSeed);
        uint256 amount = mode % 3 == 0 ? type(uint256).max : (mode % 3 == 1 ? 0 : raw);
        bytes memory result = _call(
            owner,
            abi.encodeCall(token.approve, (spender, amount)),
            spender == address(0) ? FareToken.InvalidSpender.selector : bytes4(0)
        );
        if (spender != address(0)) {
            assertTrue(abi.decode(result, (bool)));
            expectedAllowance[owner][spender] = amount;
        }
    }

    function transfer(uint256 ownerSeed, uint256 receiverSeed, uint256 raw, uint8 mode) external {
        address owner = _actor(ownerSeed);
        address recipient = mode % 7 == 0 ? address(0) : _actor(receiverSeed);
        uint256 amount = _amount(raw, expectedBalance[owner], mode);
        bytes4 error = recipient == address(0)
            ? FareToken.InvalidReceiver.selector
            : (amount > expectedBalance[owner] ? FareToken.InsufficientBalance.selector : bytes4(0));
        bytes memory result = _call(owner, abi.encodeCall(token.transfer, (recipient, amount)), error);
        if (error == bytes4(0)) {
            assertTrue(abi.decode(result, (bool)));
            expectedBalance[owner] -= amount;
            expectedBalance[recipient] += amount;
        }
    }

    function burn(uint256 ownerSeed, uint256 raw, uint8 mode) external {
        address owner = _actor(ownerSeed);
        uint256 amount = _amount(raw, expectedBalance[owner], mode);
        bytes4 error = amount > expectedBalance[owner] ? FareToken.InsufficientBalance.selector : bytes4(0);
        _call(owner, abi.encodeCall(token.burn, (amount)), error);
        if (error == bytes4(0)) {
            expectedBalance[owner] -= amount;
            burned += amount;
        }
    }

    /// @dev Half of the delegated calls fit both budgets. The other half exercise
    /// exact exhaustion, insufficient approval, insufficient balance and zero addresses.
    function spend(uint256 ownerSeed, uint256 spenderSeed, uint256 recipientSeed, uint256 raw, uint8 mode, bool destroy)
        external
    {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address recipient = mode % 7 == 0 ? address(0) : _actor(recipientSeed);
        uint256 approved = expectedAllowance[owner][spender];
        uint256 balance = expectedBalance[owner];
        uint256 budget = balance < approved ? balance : approved;
        uint256 amount = mode % 2 == 0 ? raw % (budget + 1) : _amount(raw, balance, mode);

        bytes4 error;
        if (amount > approved) error = FareToken.InsufficientAllowance.selector;
        else if (!destroy && recipient == address(0)) error = FareToken.InvalidReceiver.selector;
        else if (amount > balance) error = FareToken.InsufficientBalance.selector;

        bytes memory data = destroy
            ? abi.encodeCall(token.burnFrom, (owner, amount))
            : abi.encodeCall(token.transferFrom, (owner, recipient, amount));
        bytes memory result = _call(spender, data, error);
        if (error == bytes4(0)) {
            if (approved != type(uint256).max) expectedAllowance[owner][spender] -= amount;
            expectedBalance[owner] -= amount;
            if (destroy) {
                burned += amount;
            } else {
                assertTrue(abi.decode(result, (bool)));
                expectedBalance[recipient] += amount;
            }
        }
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }

    function _amount(uint256 raw, uint256 available, uint8 mode) private pure returns (uint256) {
        uint8 choice = mode % 6;
        if (choice == 0) return 0;
        if (choice == 1) return 1;
        if (choice == 2) return available;
        if (choice == 3) return available + 1;
        if (choice == 4) return type(uint256).max;
        return raw % (available + 1);
    }

    function _call(address caller, bytes memory data, bytes4 expectedError) private returns (bytes memory result) {
        vm.prank(caller);
        bool success;
        (success, result) = address(token).call(data);
        if (expectedError == bytes4(0)) {
            assertTrue(success, "valid token operation reverted");
        } else {
            assertFalse(success, "invalid token operation succeeded");
            assertEq(result, abi.encodeWithSelector(expectedError), "wrong rejection reason");
        }
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract FareTokenStatefulPropertiesTest is Test {
    FareTokenActionHandler private handler;
    FareToken private token;

    function setUp() public {
        handler = new FareTokenActionHandler();
        token = handler.token();
        bytes4[] memory actions = new bytes4[](4);
        actions[0] = handler.approve.selector;
        actions[1] = handler.transfer.selector;
        actions[2] = handler.burn.selector;
        actions[3] = handler.spend.selector;
        targetSelector(FuzzSelector(address(handler), actions));
        targetContract(address(handler));
    }

    function invariant_everyIssuedUnitIsHeldOrBurned() public view {
        uint256 totalHeld;
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            assertEq(token.balanceOf(actor), handler.expectedBalance(actor), "holder ledger differs from model");
            totalHeld += token.balanceOf(actor);
        }
        assertEq(token.totalSupply(), totalHeld);
        assertEq(totalHeld + handler.burned(), 1e27);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
    }

    function invariant_approvalsAreIsolatedAndOnlySuccessfulSpendingConsumesThem() public view {
        for (uint256 i; i < 4; ++i) {
            address owner = handler.actors(i);
            assertEq(token.allowance(owner, address(0)), 0);
            for (uint256 j; j < 4; ++j) {
                address spender = handler.actors(j);
                assertEq(token.allowance(owner, spender), handler.expectedAllowance(owner, spender));
            }
        }
    }
}

/// forge-config: default.fuzz.runs = 1000
contract FareTokenAllowancePropertiesTest is Test {
    FareToken private token;
    address private constant HOLDER = address(0xA11CE);
    address private constant SPENDER = address(0xB0B);
    address private constant RECIPIENT = address(0xCAFE);

    function setUp() public {
        token = new FareToken();
    }

    function testFuzz_finiteAllowanceBudgetSharedByTransferAndBurn(uint256 moved, uint256 burned) public {
        moved = bound(moved, 0, 1e27);
        burned = bound(burned, 0, 1e27 - moved);
        token.approve(SPENDER, moved + burned);
        vm.startPrank(SPENDER);
        token.transferFrom(address(this), HOLDER, moved);
        token.burnFrom(address(this), burned);
        vm.expectRevert(FareToken.InsufficientAllowance.selector);
        token.transferFrom(address(this), RECIPIENT, 1);
        vm.stopPrank();
        assertEq(token.allowance(address(this), SPENDER), 0);
        assertEq(token.balanceOf(HOLDER), moved);
        assertEq(token.balanceOf(address(this)), 1e27 - moved - burned);
        assertEq(token.totalSupply(), 1e27 - burned);
    }

    function testFuzz_failedDelegatedBurnDoesNotConsumeFiniteApproval(uint256 held, uint256 extra) public {
        held = bound(held, 0, 1e27);
        extra = bound(extra, 1, type(uint256).max - held - 1);
        token.transfer(HOLDER, held);
        uint256 requested = held + extra;
        vm.prank(HOLDER);
        token.approve(SPENDER, requested);
        vm.prank(SPENDER);
        vm.expectRevert(FareToken.InsufficientBalance.selector);
        token.burnFrom(HOLDER, requested);
        assertEq(token.allowance(HOLDER, SPENDER), requested);
        assertEq(token.balanceOf(HOLDER), held);
        assertEq(token.totalSupply(), 1e27);
    }

    function testFuzz_zeroRecipientFailureRestoresSpentApproval(uint256 amount) public {
        amount = bound(amount, 0, 1e27);
        token.approve(SPENDER, amount);
        vm.prank(SPENDER);
        vm.expectRevert(FareToken.InvalidReceiver.selector);
        token.transferFrom(address(this), address(0), amount);
        assertEq(token.allowance(address(this), SPENDER), amount);
        assertEq(token.balanceOf(address(this)), 1e27);
        assertEq(token.totalSupply(), 1e27);
    }

    function testFuzz_revocationStopsOldSpenderAndDoesNotAffectAnother(uint256 amount, bool destroy) public {
        amount = bound(amount, 1, 1e27);
        token.approve(SPENDER, type(uint256).max);
        token.approve(HOLDER, amount);
        token.approve(SPENDER, 0);
        vm.startPrank(SPENDER);
        vm.expectRevert(FareToken.InsufficientAllowance.selector);
        if (destroy) token.burnFrom(address(this), amount);
        else token.transferFrom(address(this), RECIPIENT, amount);
        vm.stopPrank();
        assertEq(token.allowance(address(this), HOLDER), amount);
        vm.prank(HOLDER);
        token.transferFrom(address(this), RECIPIENT, amount);
        assertEq(token.balanceOf(RECIPIENT), amount);
        assertEq(token.allowance(address(this), HOLDER), 0);
        assertEq(token.totalSupply(), 1e27);
    }

    function testFuzz_delegatedSelfTransferConsumesFiniteBudgetWithoutChangingBalance(uint256 amount) public {
        amount = bound(amount, 0, 1e27);
        token.approve(SPENDER, amount);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(address(this), address(this), amount));
        assertEq(token.allowance(address(this), SPENDER), 0);
        assertEq(token.balanceOf(address(this)), 1e27);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_maxMinusOneAllowanceIsFiniteEvenWhenBurningEntireSupply() public {
        token.approve(SPENDER, type(uint256).max - 1);
        vm.prank(SPENDER);
        token.burnFrom(address(this), 1e27);
        assertEq(token.allowance(address(this), SPENDER), type(uint256).max - 1 - 1e27);
        assertEq(token.totalSupply(), 0);
        assertEq(token.balanceOf(address(this)), 0);
        vm.prank(SPENDER);
        vm.expectRevert(FareToken.InsufficientBalance.selector);
        token.burnFrom(address(this), 1);
        assertEq(token.allowance(address(this), SPENDER), type(uint256).max - 1 - 1e27);
    }
}
