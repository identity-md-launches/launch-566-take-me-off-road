// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @dev Structural manager mock models claims and zero-sum unlock settlement, with controllable fills.
contract FareManagerMock {
    using PoolIdLibrary for PoolKey;

    mapping(address => mapping(uint256 => uint256)) public balanceOf;
    mapping(bytes32 => bytes32) internal words;
    mapping(address => int256) public currencyDelta;
    bool public unlocked;
    address public unlocker;
    uint256 public fillBps = 10_000;
    uint256 public outputBps = 10_000;
    uint256 public fixedOutput;
    uint256 public swapCount;
    uint256 public unlockCount;
    bool public attemptReentry;
    bytes4 public burnReentryError;
    bytes4 public retireReentryError;
    bytes4 public pokeReentryError;
    PoolKey public lastKey;
    SwapParams public lastParams;

    receive() external payable {}

    function initializeHook(IHooks hook, PoolKey calldata key) external {
        hook.afterInitialize(msg.sender, key, uint160(1 << 96), 0);
    }

    function accrue(IHooks hook, PoolKey calldata key, uint256 fee) external {
        uint256 input = fee * 50;
        SwapParams memory params = SwapParams(true, -int256(input), TickMath.MIN_SQRT_PRICE + 1);
        hook.beforeSwap(msg.sender, key, params, "");
        hook.afterSwap(msg.sender, key, params, toBalanceDelta(-int128(int256(input - fee)), 1), "");
    }

    function donateClaims(address to, uint256 amount) external {
        balanceOf[to][0] += amount;
    }

    function mint(address to, uint256 id, uint256 amount) external {
        require(id == 0, "ETH claims only");
        balanceOf[to][id] += amount;
    }

    function burn(address from, uint256 id, uint256 amount) external {
        require(unlocked && msg.sender == unlocker && from == msg.sender && id == 0, "invalid burn");
        balanceOf[from][id] -= amount;
        currencyDelta[address(0)] += int256(amount);
    }

    function unlock(bytes calldata data) external returns (bytes memory result) {
        require(!unlocked, "manager already unlocked");
        unlocked = true;
        unlocker = msg.sender;
        unlockCount++;
        result = IUnlockCallback(msg.sender).unlockCallback(data);
        require(currencyDelta[address(0)] == 0, "ETH not settled");
        require(currencyDelta[address(0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7)] == 0, "IMD not settled");
        unlocked = false;
        unlocker = address(0);
    }

    function swap(PoolKey calldata key, SwapParams calldata params, bytes calldata) external returns (BalanceDelta) {
        require(unlocked && msg.sender == unlocker, "swap outside own unlock");
        require(params.zeroForOne && params.amountSpecified < 0, "expected ETH exact input");
        lastKey = key;
        lastParams = params;
        swapCount++;
        if (attemptReentry) {
            burnReentryError = _reenter(abi.encodeWithSignature("burnIMD(bool,uint256)", false, 0));
            retireReentryError = _reenter(abi.encodeWithSignature("retire()"));
            pokeReentryError = _reenter(abi.encodeWithSignature("pokeAnchor()"));
        }
        uint256 amount = uint256(-params.amountSpecified) * fillBps / 10_000;
        uint256 output = fixedOutput == 0 ? amount * outputBps / 10_000 : fixedOutput;
        currencyDelta[Currency.unwrap(key.currency0)] -= int256(amount);
        currencyDelta[Currency.unwrap(key.currency1)] += int256(output);
        return toBalanceDelta(-int128(int256(amount)), int128(int256(output)));
    }

    function take(Currency currency, address to, uint256 amount) external {
        require(unlocked && msg.sender == unlocker, "take outside own unlock");
        currencyDelta[Currency.unwrap(currency)] -= int256(amount);
        if (Currency.unwrap(currency) == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            require(ok, "ETH recipient refused");
        } else {
            require(FareIMDMock(Currency.unwrap(currency)).transfer(to, amount), "IMD transfer refused");
        }
    }

    function extsload(bytes32 slot) external view returns (bytes32) {
        return words[slot];
    }

    function setTick(PoolKey calldata key, int24 tick) external {
        bytes32 slot = keccak256(abi.encode(PoolId.unwrap(key.toId()), uint256(6)));
        words[slot] = bytes32(uint256(TickMath.getSqrtPriceAtTick(tick)) | uint256(uint24(tick)) << 160);
    }

    function setFill(uint256 bps) external {
        fillBps = bps;
    }

    function setReentry(bool enabled) external {
        attemptReentry = enabled;
    }

    function _reenter(bytes memory data) internal returns (bytes4) {
        (bool ok, bytes memory result) = unlocker.call(data);
        require(!ok, "reentry unexpectedly succeeded");
        return bytes4(result);
    }

    function setOutput(uint256 bps, uint256 fixedAmount) external {
        outputBps = bps;
        fixedOutput = fixedAmount;
    }

    function lastPoolId() external view returns (PoolId) {
        return lastKey.toId();
    }
}

contract FareIMDMock {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Selector-aware arbitrary return mock exercises low-level oracle decoding.
contract FarePool4Mock {
    bytes4 private constant MARKET = bytes4(keccak256("marketOpen()"));
    bytes4 private constant REF = bytes4(keccak256("refTick()"));
    bool internal open;
    int256 internal tick;
    uint256 internal malformed;

    function configure(bool market, int256 referenceTick, uint256 returnMode) external {
        open = market;
        tick = referenceTick;
        malformed = returnMode;
    }

    fallback() external {
        require(malformed != 1, "oracle unavailable");
        uint256 value;
        if (msg.sig == MARKET) value = malformed == 3 ? 2 : (open ? 1 : 0);
        else if (msg.sig == REF) value = uint256(tick);
        else revert("unknown selector");
        uint256 size = malformed == 2 ? 31 : 32;
        assembly ("memory-safe") {
            mstore(0, value)
            return(0, size)
        }
    }
}

contract FareNFTMock {
    address public holder;
    bool public approved;
    bool public noMove;
    bool public badOwner;
    address public reenterHook;
    bytes4 public reentryError;
    uint256 public transferCount;

    function configure(address owner, bool approval) external {
        holder = owner;
        approved = approval;
    }

    function setBadOwner(bool bad) external {
        badOwner = bad;
    }

    function setNoMove(bool stay) external {
        noMove = stay;
    }

    function setReenter(address hook) external {
        reenterHook = hook;
    }

    function ownerOf(uint256 id) external view returns (address) {
        require(id == 447, "wrong medallion");
        if (badOwner) {
            assembly ("memory-safe") {
                mstore(0, 1)
                return(0, 1)
            }
        }
        return holder;
    }

    function transferFrom(address from, address to, uint256 id) external {
        require(approved, "NO_APPROVAL");
        require(from == holder && id == 447, "wrong medallion");
        transferCount++;
        if (reenterHook != address(0)) {
            (bool ok, bytes memory result) = reenterHook.call(abi.encodeWithSignature("retire()"));
            require(!ok, "reentry unexpectedly succeeded");
            reentryError = bytes4(result);
        }
        if (!noMove) holder = to;
    }
}

contract FareReceiverMock {
    address public hook;
    bool public reject;
    bytes4 public reentryError;

    function configure(address target, bool refuses) external {
        hook = target;
        reject = refuses;
    }

    receive() external payable {
        require(!reject, "receiver refused");
        if (hook != address(0)) {
            (bool ok, bytes memory result) = hook.call(abi.encodeWithSignature("retire()"));
            require(!ok, "reentry unexpectedly succeeded");
            reentryError = bytes4(result);
        }
    }
}
