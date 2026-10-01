// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {MedallionHook} from "../src/MedallionHook.sol";
import {FareDeploy} from "./helpers/FareDeploy.sol";
import {FareManagerMock, FarePool4Mock, FareIMDMock} from "./mocks/RetireBurnMocks.sol";

library RetirementReentryProbe {
    function probe(address hook) internal returns (bytes4[3] memory errors) {
        bytes[3] memory calls = [
            abi.encodeCall(MedallionHook.retire, ()),
            abi.encodeCall(MedallionHook.burnIMD, (false, 0)),
            abi.encodeCall(MedallionHook.pokeAnchor, ())
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory reason) = hook.call(calls[i]);
            require(!ok, "cross-entry unexpectedly succeeded");
            errors[i] = bytes4(reason);
        }
    }
}

/// @dev Models arbitrary ownerOf ABI data separately before and after transferFrom.
contract RetirementAdversarialNFT {
    bytes public beforeResponse;
    bytes public afterResponse;
    bytes public refusal;
    bool public rejectBefore;
    bool public rejectAfter;
    bool public rejectTransfer;
    bool public writeDuringOwnerRead;
    uint256 public readWrite;
    uint256 public transfers;
    address public holder;
    address public probeHook;
    bytes4[3] public reentryErrors;

    function configure(address owner, bytes memory first, bytes memory second) external {
        holder = owner;
        beforeResponse = first;
        afterResponse = second;
    }

    function setFaults(bool firstReverts, bool secondReverts, bool transferReverts, bytes memory reason) external {
        rejectBefore = firstReverts;
        rejectAfter = secondReverts;
        rejectTransfer = transferReverts;
        refusal = reason;
    }

    function setWriteDuringOwnerRead(bool enabled) external {
        writeDuringOwnerRead = enabled;
    }

    function setProbe(address target) external {
        probeHook = target;
    }

    function ownerOf(uint256 id) external returns (address) {
        require(id == 447, "wrong id");
        if (writeDuringOwnerRead) readWrite++;
        bool reject = transfers == 0 ? rejectBefore : rejectAfter;
        bytes memory response = reject ? refusal : (transfers == 0 ? beforeResponse : afterResponse);
        assembly ("memory-safe") {
            if reject { revert(add(response, 32), mload(response)) }
            return(add(response, 32), mload(response))
        }
    }

    function transferFrom(address from, address to, uint256 id) external {
        require(from == holder && to == address(0xdead) && id == 447, "wrong transfer");
        if (rejectTransfer) {
            bytes memory reason = refusal;
            assembly ("memory-safe") { revert(add(reason, 32), mload(reason)) }
        }
        transfers++;
        holder = to;
        if (probeHook != address(0)) reentryErrors = RetirementReentryProbe.probe(probeHook);
    }
}

contract RetirementAdversarialCreator {
    address public hook;
    bool public reject;
    uint256 public received;
    uint256 public payments;
    bytes4[3] public reentryErrors;

    function configure(address target, bool refuses) external {
        hook = target;
        reject = refuses;
    }

    receive() external payable {
        require(!reject, "CREATOR_REJECTS");
        received += msg.value;
        payments++;
        reentryErrors = RetirementReentryProbe.probe(hook);
    }
}

/// @dev Deliberately adversarial callback transport. Claims burn/take are conserved;
/// only the timing, number and contents of unlock callbacks are varied.
contract RetirementUnlockManager {
    mapping(address => mapping(uint256 => uint256)) public balanceOf;
    uint8 public mode; // 0 honest, 1 skipped, 2 altered data, 3 replayed, 4 altered then honest
    uint8 public changedField;
    bytes4 public rejectedCallback;
    uint256 public burns;
    uint256 public takes;
    int256 public delta;
    address private unlocker;

    function configure(uint8 nextMode, uint8 field) external {
        mode = nextMode;
        changedField = field;
    }

    function initializeAndAccrue(MedallionHook hook, PoolKey calldata key, uint256 fee) external {
        hook.afterInitialize(msg.sender, key, uint160(1 << 96), 0);
        SwapParams memory params = SwapParams(true, -int256(fee * 50), 1);
        hook.beforeSwap(msg.sender, key, params, "");
        hook.afterSwap(msg.sender, key, params, toBalanceDelta(-int128(int256(fee * 49)), 1), "");
    }

    function mint(address to, uint256 id, uint256 amount) external {
        balanceOf[to][id] += amount;
    }

    function burn(address from, uint256 id, uint256 amount) external {
        require(msg.sender == unlocker && from == unlocker && id == 0, "invalid claim burn");
        balanceOf[from][id] -= amount;
        delta += int256(amount);
        burns++;
    }

    function take(Currency currency, address recipient, uint256 amount) external {
        require(msg.sender == unlocker && Currency.unwrap(currency) == address(0), "invalid take");
        delta -= int256(amount);
        takes++;
        (bool ok,) = recipient.call{value: amount}("");
        require(ok, "payment refused");
    }

    function unlock(bytes calldata data) external returns (bytes memory result) {
        require(unlocker == address(0), "nested unlock");
        unlocker = msg.sender;
        if (mode == 2) {
            result = IUnlockCallback(msg.sender).unlockCallback(_mutated(data));
        } else if (mode == 4) {
            _rejectCallback(_mutated(data));
            result = IUnlockCallback(msg.sender).unlockCallback(data);
        } else if (mode != 1) {
            result = IUnlockCallback(msg.sender).unlockCallback(data);
            if (mode == 3) _rejectCallback(data);
        }
        require(delta == 0, "claims not settled");
        unlocker = address(0);
    }

    function _mutated(bytes calldata data) internal view returns (bytes memory) {
        (uint8 operation, bool route, uint256 amount, uint256 minimum) =
            abi.decode(data, (uint8, bool, uint256, uint256));
        if (changedField == 0) operation++;
        else if (changedField == 1) route = !route;
        else if (changedField == 2) amount++;
        else minimum++;
        return abi.encode(operation, route, amount, minimum);
    }

    function _rejectCallback(bytes memory data) internal {
        (bool ok, bytes memory reason) = unlocker.call(abi.encodeCall(IUnlockCallback.unlockCallback, (data)));
        require(!ok, "callback unexpectedly accepted");
        rejectedCallback = bytes4(reason);
    }
}

/// @notice Failure properties from spec 6 and 9: retirement is atomic and unlock authority is single-use.
/// forge-config: default.fuzz.runs = 512
contract RetirementSecurityTest is Test, FareDeploy {
    address internal constant CREATOR = 0x70c6C4fcaAb11151FCEDb32eaaC3431547193A0a;
    address internal constant NFT = 0x9C8fF314C9Bc7F6e59A9d9225Fb22946427eDC03;
    address internal constant POOL4 = 0xc6C965Bd164c483e87d0B550671798e9A3602840;
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal constant OWNER = address(0x447);
    address internal constant DEAD = address(0xdead);
    uint256 internal constant CAP = 1.64 ether;
    uint256 internal constant FUNDS = CAP + 0.12 ether;
    FareManagerMock internal manager;
    RetirementAdversarialNFT internal nft;
    MedallionHook internal hook;
    PoolKey internal launchKey;

    function setUp() public {
        vm.chainId(1);
        vm.roll(100);
        vm.etch(POOL4, address(new FarePool4Mock()).code);
        FarePool4Mock(POOL4).configure(true, 0, 0);
        vm.etch(NFT, address(new RetirementAdversarialNFT()).code);
        nft = RetirementAdversarialNFT(NFT);
        nft.configure(OWNER, abi.encode(OWNER), abi.encode(DEAD));
        vm.etch(IMD, address(new FareIMDMock()).code);
        manager = new FareManagerMock();
        hook = _deployHook(IPoolManager(address(manager)));
        launchKey = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(0xFA447)), 3000, 60, IHooks(address(hook)));
        manager.initializeHook(IHooks(address(hook)), launchKey);
        manager.accrue(IHooks(address(hook)), launchKey, FUNDS);
        manager.setTick(PoolKey(Currency.wrap(address(0)), Currency.wrap(IMD), 10_000, 200, IHooks(address(0))), 0);
        vm.deal(address(manager), 10 ether);
        vm.deal(CREATOR, 0);
        FareIMDMock(IMD).mint(address(manager), 1 ether);
    }

    function _assertUnchanged() internal view {
        assertFalse(hook.retired());
        assertEq(hook.creatorPaid(), 0);
        assertEq(hook.totalFees(), FUNDS);
        assertEq(hook.burnSpent(), 0);
        assertEq(manager.balanceOf(address(hook), 0), FUNDS);
        assertEq(manager.unlockCount(), 0);
        assertEq(address(manager).balance, 10 ether);
        assertEq(CREATOR.balance, 0);
        assertEq(nft.holder(), OWNER);
        assertEq(nft.transfers(), 0);
    }

    function _expectOwnerRefusal(bytes memory response, bool afterTransfer) internal {
        nft.configure(OWNER, afterTransfer ? abi.encode(OWNER) : response, response);
        if (afterTransfer) vm.expectRevert(abi.encodeWithSelector(MedallionHook.RetireRefused.selector, response));
        else vm.expectRevert(MedallionHook.MedallionUnavailable.selector);
        hook.retire();
        _assertUnchanged();
    }

    function testFuzz_ownerOfRejectsEveryNonWordLength(uint8 lengthSeed, bool afterTransfer) public {
        uint256 length = uint256(lengthSeed) % 128;
        if (length >= 32) length++;
        bytes memory response = new bytes(length);
        // Even data whose leading word names DEAD must be rejected when the ABI length is wrong.
        if (length >= 32) {
            assembly ("memory-safe") { mstore(add(response, 32), 0xdead) }
        }
        _expectOwnerRefusal(response, afterTransfer);
    }

    function testFuzz_ownerOfRejectsDirtyAddressWords(uint96 highBits, address lowBits, bool afterTransfer) public {
        uint256 dirty = (bound(uint256(highBits), 1, type(uint96).max) << 160) | uint160(lowBits);
        _expectOwnerRefusal(abi.encode(dirty), afterTransfer);
    }

    function test_ownerOfRejectsZeroBeforeAndAfterTransfer() public {
        _expectOwnerRefusal(abi.encode(address(0)), false);
        _expectOwnerRefusal(abi.encode(address(0)), true);
    }

    function test_ownerOfUsesStaticcallAndCannotWriteState() public {
        nft.setWriteDuringOwnerRead(true);
        vm.expectRevert(MedallionHook.MedallionUnavailable.selector);
        hook.retire{gas: 1_000_000}();
        assertEq(nft.readWrite(), 0);
        _assertUnchanged();
    }

    function testFuzz_ownerOfRevertPayloadCannotEscapeRetirementError(bytes32 payload, bool afterTransfer) public {
        bytes memory reason = abi.encodePacked(payload);
        nft.setFaults(!afterTransfer, afterTransfer, false, reason);
        if (afterTransfer) vm.expectRevert(abi.encodeWithSelector(MedallionHook.RetireRefused.selector, reason));
        else vm.expectRevert(MedallionHook.MedallionUnavailable.selector);
        hook.retire();
        _assertUnchanged();
    }

    function testFuzz_transferRevertPreservesExactReturndata(bytes memory reason) public {
        nft.setFaults(false, false, true, reason);
        vm.expectRevert(abi.encodeWithSelector(MedallionHook.RetireRefused.selector, reason));
        hook.retire();
        _assertUnchanged();
    }

    function test_postTransferOwnerMustBeDeadAndFailureCanBeRetriedSameTransaction() public {
        _expectOwnerRefusal(abi.encode(address(0xBEEF)), true);
        nft.configure(OWNER, abi.encode(OWNER), abi.encode(DEAD));
        hook.retire();
        assertTrue(hook.retired());
        assertEq(nft.holder(), DEAD);
        assertEq(CREATOR.balance, CAP);
        assertEq(manager.balanceOf(address(hook), 0), FUNDS - CAP);
    }

    function test_crossEntryBlockedFromNFTAndCreatorAndLockClearsForBurn() public {
        nft.setProbe(address(hook));
        vm.etch(CREATOR, address(new RetirementAdversarialCreator()).code);
        RetirementAdversarialCreator receiver = RetirementAdversarialCreator(payable(CREATOR));
        receiver.configure(address(hook), false);
        hook.retire();
        for (uint256 i; i < 3; ++i) {
            assertEq(nft.reentryErrors(i), MedallionHook.Reentrant.selector);
            assertEq(receiver.reentryErrors(i), MedallionHook.Reentrant.selector);
        }
        assertEq(receiver.received(), CAP);
        assertEq(receiver.payments(), 1);
        assertTrue(hook.retired());
        assertEq(nft.holder(), DEAD);
        vm.roll(block.number + 5);
        hook.burnIMD(false, 0);
        hook.pokeAnchor();
        assertEq(hook.burnSpent(), 0.05 ether);
        assertEq(FareIMDMock(IMD).balanceOf(DEAD), 0.05 ether);
        assertEq(CREATOR.balance, CAP);
    }

    function test_creatorRejectionRestoresNFTClaimsUnlockAndPermitsRetry() public {
        vm.etch(CREATOR, address(new RetirementAdversarialCreator()).code);
        RetirementAdversarialCreator receiver = RetirementAdversarialCreator(payable(CREATOR));
        receiver.configure(address(hook), true);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "ETH recipient refused"));
        hook.retire();
        _assertUnchanged();
        assertFalse(manager.unlocked());
        assertEq(manager.currencyDelta(address(0)), 0);
        receiver.configure(address(hook), false);
        hook.retire();
        assertEq(receiver.payments(), 1);
        assertEq(receiver.received(), CAP);
        assertEq(nft.transfers(), 1);
        assertEq(nft.holder(), DEAD);
        assertEq(hook.creatorPaid(), CAP);
        assertEq(manager.balanceOf(address(hook), 0), FUNDS - CAP);
    }

    function test_managerCannotInvokeUnsolicitedUnlockBeforeOrAfterRetirement() public {
        bytes memory data = abi.encode(uint8(1), false, CAP, uint256(0));
        vm.prank(address(manager));
        vm.expectRevert(MedallionHook.UnexpectedUnlock.selector);
        hook.unlockCallback(data);
        _assertUnchanged();
        hook.retire();
        vm.prank(address(manager));
        vm.expectRevert(MedallionHook.UnexpectedUnlock.selector);
        hook.unlockCallback(data);
        assertEq(CREATOR.balance, CAP);
        assertEq(manager.balanceOf(address(hook), 0), FUNDS - CAP);
    }

    function _adversarialManager() internal returns (RetirementUnlockManager transport) {
        transport = new RetirementUnlockManager();
        hook = _deployHook(IPoolManager(address(transport)));
        launchKey.hooks = IHooks(address(hook));
        transport.initializeAndAccrue(hook, launchKey, FUNDS);
        vm.deal(address(transport), 10 ether);
    }

    function _assertTransportFailure(RetirementUnlockManager transport) internal view {
        assertFalse(hook.retired());
        assertEq(hook.creatorPaid(), 0);
        assertEq(nft.transfers(), 0);
        assertEq(nft.holder(), OWNER);
        assertEq(transport.balanceOf(address(hook), 0), FUNDS);
        assertEq(transport.burns(), 0);
        assertEq(transport.takes(), 0);
        assertEq(CREATOR.balance, 0);
    }

    function test_missingUnlockCallbackRollsBackAndCanRetry() public {
        RetirementUnlockManager transport = _adversarialManager();
        transport.configure(1, 0);
        vm.expectRevert(MedallionHook.UnexpectedUnlock.selector);
        hook.retire();
        _assertTransportFailure(transport);
        transport.configure(0, 0);
        hook.retire();
        assertEq(CREATOR.balance, CAP);
        assertEq(transport.burns(), 1);
        assertEq(transport.takes(), 1);
    }

    function testFuzz_unlockHashBindsEveryField(uint8 field) public {
        RetirementUnlockManager transport = _adversarialManager();
        transport.configure(2, uint8(bound(field, 0, 3)));
        vm.expectRevert(MedallionHook.UnexpectedUnlock.selector);
        hook.retire();
        _assertTransportFailure(transport);
        transport.configure(0, 0);
        hook.retire();
        assertEq(CREATOR.balance, CAP);
        assertEq(transport.balanceOf(address(hook), 0), FUNDS - CAP);
    }

    function test_unlockReplayCannotBurnClaimsOrPayCreatorTwice() public {
        RetirementUnlockManager transport = _adversarialManager();
        transport.configure(3, 0);
        hook.retire();
        assertEq(transport.rejectedCallback(), MedallionHook.UnexpectedUnlock.selector);
        assertEq(transport.burns(), 1);
        assertEq(transport.takes(), 1);
        assertEq(CREATOR.balance, CAP);
        assertEq(transport.balanceOf(address(hook), 0), FUNDS - CAP);
    }

    function test_rejectedAlteredCallbackDoesNotConsumeHonestRequest() public {
        RetirementUnlockManager transport = _adversarialManager();
        transport.configure(4, 2);
        hook.retire();
        assertEq(transport.rejectedCallback(), MedallionHook.UnexpectedUnlock.selector);
        assertEq(transport.burns(), 1);
        assertEq(transport.takes(), 1);
        assertEq(CREATOR.balance, CAP);
        assertEq(transport.balanceOf(address(hook), 0), FUNDS - CAP);
    }
}
