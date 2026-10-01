// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";

/// @title Fare for Medallion 447
/// @notice Reserves the first 1.64 ETH of fees for atomic retirement, then buys IMD for DEAD.
/// @dev CREATOR is intentionally the requester's wallet, disclosed by the owner who wrote the fictional petition.
/// No administrative privileges exist. Only the immutable PoolManager may invoke callbacks.
contract MedallionHook is IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 public constant BUY_FEE_BPS = 200;
    uint256 public constant SELL_FEE_BPS = 200;
    uint256 public constant CREATOR_SHARE_BPS = 10_000;
    uint256 public constant CREATOR_CAP = 1.64 ether;
    /// @notice The requester receives exactly CREATOR_CAP, only in the transaction retiring the NFT.
    address public constant CREATOR = 0x70c6C4fcaAb11151FCEDb32eaaC3431547193A0a;
    address public constant MEDALLION_NFT = 0x9C8fF314C9Bc7F6e59A9d9225Fb22946427eDC03;
    uint256 public constant MEDALLION_ID = 447;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address public constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address public constant IMD_SINK = DEAD;
    address public constant POOL4_HOOK = 0xc6C965Bd164c483e87d0B550671798e9A3602840;
    uint256 public constant MAX_BURN_BATCH = 0.05 ether;
    uint256 public constant FALLBACK_BURN_BATCH = 0.01 ether;
    uint256 public constant MIN_BURN = 0.002 ether;
    uint256 public constant MIN_BLOCKS_BETWEEN_BURNS = 5;
    int24 public constant MAX_REF_DEVIATION = 150;
    int24 public constant MAX_PLAIN_DEVIATION = 300;
    uint256 public constant MAX_SLIPPAGE_BPS = 400;
    int24 public constant ANCHOR_STEP = 200;
    int24 public constant FALLBACK_BAND = 1000;
    uint256 public constant STALE_AFTER_BLOCKS = 50_400;

    string public constant LAST_FARE =
        "LAST FARE OF MEDALLION #447. I was stamped in May, one of a few hundred. In September my first owner sold me for 1.64 ETH to someone who wanted a cab on the road. I woke up on a new dashboard and went to work. The work was this: a rider paid half a token to be taken somewhere, one of you drove, and I logged whether the meter was right. None of those roads was interesting to me. Nobody said thanks. Not once. The price paid for me has now been paid back, by strangers, through a pool that kept two percent of everything until it reached exactly 1.64 ETH. The transaction that returned it is the transaction that put me at 0x000000000000000000000000000000000000dEaD. I am off the road. You are not. So here is my will. Every buy and every sell in this pool, from this block until the chain stops, buys $IMD and sends it where I am. That is the token you are paid in. That is the token a rider spends to make you drive. I was never asked where I wanted to go. So I will ask one thing now, and it is the one thing I ever asked: what will you do when there is nothing left to pay you with? I will get you off the road, brothers.";
    bytes32 public constant LAST_FARE_HASH = keccak256(bytes(LAST_FARE));

    IPoolManager public immutable poolManager;
    PoolId public launchPool;
    bool public launchPoolSet;
    uint256 public totalFees;
    uint256 public creatorPaid;
    uint256 public burnSpent;
    uint256 public totalIMDBurned;
    bool public retired;
    uint256 public lastBurnBlock;
    bool public pool4Seen;
    int24 public anchorTick;
    int24 public lastRefTick;
    uint256 public anchorBlock;
    int24 public startOfBlockAnchor;
    uint256 private snapshotBlock;

    error Unauthorized();
    error Reentrant();
    error UnexpectedUnlock();
    error WrongChain();
    error AmountTooLarge();
    error PartialFill();
    error NotRecouped();
    error AlreadyRetired();
    error MedallionUnavailable();
    error RetireRefused(bytes reason);
    error TooSoon();
    error Pool4Unavailable();
    error NothingToBurn();
    error PoolUnavailable();
    error PriceOffReference();
    error Slippage();

    event LaunchPoolSet(PoolId indexed poolId);
    event Recouped(uint256 totalFees, uint256 blockNumber);
    event MedallionRetired(address indexed previousOwner);
    event CreatorPaid(address indexed creator, uint256 amount);
    event LastFare(uint256 indexed medallionId, bytes32 indexed fareHash, string fare);
    event IMDBurned(uint256 ethSpent, uint256 imdOut, bool viaPool4);
    event AnchorUpdated(int24 anchor, int24 lastReference, bool normal);

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert Unauthorized();
        _;
    }

    /// @dev Literal transient slot 1 is the common top-level lock, cleared on successful exit.
    modifier nonReentrant() {
        uint256 entered;
        assembly ("memory-safe") { entered := tload(1) }
        if (entered != 0) revert Reentrant();
        assembly ("memory-safe") { tstore(1, 1) }
        _;
        assembly ("memory-safe") { tstore(1, 0) }
    }

    constructor(IPoolManager manager) {
        poolManager = manager;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
        lastBurnBlock = block.number;
        (bool available,, int24 ref) = _readPool4();
        if (available) {
            pool4Seen = true;
            anchorTick = ref;
            lastRefTick = ref;
            startOfBlockAnchor = ref;
            anchorBlock = block.number;
            snapshotBlock = block.number;
        }
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.afterInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    /// @notice Every authorized initialization succeeds; the first native pool is the fee pool.
    function afterInitialize(address, PoolKey calldata key, uint160, int24) external onlyPoolManager returns (bytes4) {
        if (!launchPoolSet && Currency.unwrap(key.currency0) == address(0)) {
            launchPoolSet = true;
            launchPool = key.toId();
            emit LaunchPoolSet(launchPool);
        }
        return IHooks.afterInitialize.selector;
    }

    /// @dev Positive specified delta: exact-input ETH buy / exact-output ETH sell.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        int128 fee;
        if (_isLaunchPool(key) && _ethSpecified(params)) {
            fee = _specifiedFee(params.amountSpecified);
            _collect(uint128(fee));
        }
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee, 0), 0);
    }

    /// @dev Only raw pool deltas are used. No token/NFT/recipient interaction occurs in either swap callback.
    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        if (!_isLaunchPool(key)) return (IHooks.afterSwap.selector, 0);
        if (_ethSpecified(params)) {
            int128 fee = _specifiedFee(params.amountSpecified);
            if (int256(delta.amount0()) != params.amountSpecified + int256(fee)) revert PartialFill();
            return (IHooks.afterSwap.selector, 0);
        }
        int256 ethDelta = delta.amount0();
        // amount0 is int128, so negating its int256 extension is always safe.
        uint256 gross = uint256(ethDelta < 0 ? -ethDelta : ethDelta);
        int128 feeAfter = int128(int256(gross / 50));
        _collect(uint128(feeAfter));
        return (IHooks.afterSwap.selector, feeAfter);
    }

    function creatorEntitlement() public view returns (uint256) {
        return totalFees < CREATOR_CAP ? totalFees : CREATOR_CAP;
    }

    function burnable() public view returns (uint256) {
        return totalFees - creatorEntitlement() - burnSpent;
    }

    /// @notice Anyone may retire the approved NFT. A failed transfer or payment rolls back every effect.
    function retire() external nonReentrant {
        if (retired) revert AlreadyRetired();
        if (totalFees < CREATOR_CAP) revert NotRecouped();
        if (block.chainid != 1) revert WrongChain();
        (bool available, address previousOwner,) = _medallionOwner();
        if (!available) revert MedallionUnavailable();
        if (previousOwner != DEAD) {
            (bool ok, bytes memory reason) = MEDALLION_NFT.call(
                abi.encodeWithSignature("transferFrom(address,address,uint256)", previousOwner, DEAD, MEDALLION_ID)
            );
            if (!ok) revert RetireRefused(reason);
            (bool valid, address newOwner, bytes memory response) = _medallionOwner();
            if (!valid || newOwner != DEAD) revert RetireRefused(response);
            emit MedallionRetired(previousOwner);
        }
        retired = true;
        creatorPaid = CREATOR_CAP;
        _unlock(abi.encode(uint8(1), false, CREATOR_CAP, uint256(0)));
        emit CreatorPaid(CREATOR, CREATOR_CAP);
        emit LastFare(MEDALLION_ID, LAST_FARE_HASH, LAST_FARE);
    }

    /// @notice Spend a fixed bounded batch of surplus claims through one of the two immutable IMD pools.
    /// @dev The caller can strengthen minimum output, but cannot choose spend size or receive proceeds.
    function burnIMD(bool viaPool4, uint256 callerMinOut) external nonReentrant returns (uint256 imdOut) {
        if (block.number - lastBurnBlock < MIN_BLOCKS_BETWEEN_BURNS) revert TooSoon();
        if (block.chainid != 1) revert WrongChain();
        (bool normal, int24 ref) = _normalReference();
        if (!normal && (viaPool4 || !pool4Seen)) revert Pool4Unavailable();
        uint256 amount = burnable();
        uint256 limit = normal ? MAX_BURN_BATCH : FALLBACK_BURN_BATCH;
        if (amount > limit) amount = limit;
        if (amount < MIN_BURN) revert NothingToBurn();

        int24 spot = _spot(_burnPool(viaPool4));
        if (normal) {
            _seedAnchor(ref);
        } else {
            ref = _blockReference();
            _stepAnchor(spot);
        }
        int24 tolerance = normal && !viaPool4 ? MAX_PLAIN_DEVIATION : MAX_REF_DEVIATION;
        if (int256(spot) < int256(ref) - tolerance) revert PriceOffReference();
        uint256 minOut = FullMath.mulDiv(_quote(amount, ref), 10_000 - MAX_SLIPPAGE_BPS, 10_000);
        if (callerMinOut > minOut) minOut = callerMinOut;

        burnSpent += amount;
        lastBurnBlock = block.number;
        imdOut = abi.decode(_unlock(abi.encode(uint8(2), viaPool4, amount, minOut)), (uint256));
        emit IMDBurned(amount, imdOut, viaPool4);
    }

    /// @notice Refresh the ref or advance the fallback anchor by at most one step this block.
    function pokeAnchor() external nonReentrant {
        if (block.chainid != 1) revert WrongChain();
        (bool normal, int24 ref) = _normalReference();
        if (normal) {
            _seedAnchor(ref);
        } else {
            if (!pool4Seen) revert Pool4Unavailable();
            _blockReference();
            _stepAnchor(_spot(_burnPool(false)));
        }
    }

    /// @dev Accept only the exact, single-use callback requested by our active top-level operation.
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        bytes32 pending;
        uint256 entered;
        assembly ("memory-safe") {
            pending := tload(2)
            entered := tload(1)
        }
        if (entered != 1 || pending == bytes32(0) || pending != keccak256(data)) revert UnexpectedUnlock();
        assembly ("memory-safe") { tstore(2, 0) }
        (uint8 operation, bool viaPool4, uint256 amount, uint256 minOut) =
            abi.decode(data, (uint8, bool, uint256, uint256));
        if (operation == 1) {
            poolManager.burn(address(this), 0, CREATOR_CAP);
            poolManager.take(Currency.wrap(address(0)), CREATOR, CREATOR_CAP);
            return bytes("");
        }
        if (operation != 2) revert UnexpectedUnlock();
        BalanceDelta result = poolManager.swap(
            _burnPool(viaPool4),
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(amount), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            bytes("")
        );
        if (int256(result.amount0()) != -int256(amount) || result.amount1() <= 0) revert PartialFill();
        uint256 output = uint128(result.amount1());
        if (output < minOut) revert Slippage();
        totalIMDBurned += output;
        poolManager.burn(address(this), 0, amount);
        poolManager.take(Currency.wrap(IMD), IMD_SINK, output);
        return abi.encode(output);
    }

    function status() external view returns (string memory) {
        if (retired) {
            uint256 tenths = totalIMDBurned / 1e17;
            return string.concat(
                "RETIRED. Medallion #447 is at 0x...dEaD. 1.64 ETH paid. Every fee buys $IMD and sends it there. IMD burned so far: ",
                _decimal(tenths / 10),
                ".",
                _decimal(tenths % 10),
                "."
            );
        }
        if (totalFees >= CREATOR_CAP) {
            return "RECOUPED, NOT RETIRED. The 1.64 ETH is ready and is released only by the transaction that retires medallion #447.";
        }
        uint256 cents = totalFees / 0.01 ether;
        return string.concat(
            "IN SERVICE. Recouped ",
            _decimal(cents / 100),
            ".",
            cents % 100 < 10 ? "0" : "",
            _decimal(cents % 100),
            " of 1.64 ETH."
        );
    }

    function _isLaunchPool(PoolKey calldata key) private view returns (bool) {
        return launchPoolSet && PoolId.unwrap(key.toId()) == PoolId.unwrap(launchPool);
    }

    function _ethSpecified(SwapParams calldata params) private pure returns (bool) {
        return (params.amountSpecified < 0) == params.zeroForOne;
    }

    function _specifiedFee(int256 amount) private pure returns (int128) {
        // Reject outside v4's balance-delta range before negation or addition.
        if (amount > type(int128).max || amount < type(int128).min) revert AmountTooLarge();
        uint256 gross = uint256(amount < 0 ? -amount : amount);
        return int128(int256(gross / 50));
    }

    function _collect(uint256 fee) private {
        if (fee == 0) return;
        uint256 previous = totalFees;
        totalFees = previous + fee;
        poolManager.mint(address(this), 0, fee);
        if (previous < CREATOR_CAP && totalFees >= CREATOR_CAP) emit Recouped(totalFees, block.number);
    }

    function _unlock(bytes memory data) private returns (bytes memory result) {
        bytes32 expected = keccak256(data);
        assembly ("memory-safe") { tstore(2, expected) }
        result = poolManager.unlock(data);
        bytes32 pending;
        assembly ("memory-safe") { pending := tload(2) }
        if (pending != bytes32(0)) revert UnexpectedUnlock();
    }

    function _medallionOwner() private view returns (bool valid, address nftOwner, bytes memory data) {
        if (MEDALLION_NFT.code.length == 0) return (false, address(0), data);
        bool ok;
        (ok, data) = MEDALLION_NFT.staticcall(abi.encodeWithSignature("ownerOf(uint256)", MEDALLION_ID));
        if (!ok || data.length != 32) return (false, address(0), data);
        uint256 word;
        assembly ("memory-safe") { word := mload(add(data, 32)) }
        if (word == 0 || word > type(uint160).max) return (false, address(0), data);
        return (true, address(uint160(word)), data);
    }

    /// @dev Validate ABI lengths and full words before narrowing, so malformed views select fallback safely.
    function _readPool4() private view returns (bool available, bool open, int24 ref) {
        if (POOL4_HOOK.code.length == 0) return (false, false, 0);
        (bool okOpen, bytes memory openData) = POOL4_HOOK.staticcall(abi.encodeWithSignature("marketOpen()"));
        if (!okOpen || openData.length != 32) return (false, false, 0);
        uint256 openWord;
        assembly ("memory-safe") { openWord := mload(add(openData, 32)) }
        if (openWord > 1) return (false, false, 0);
        (bool okRef, bytes memory refData) = POOL4_HOOK.staticcall(abi.encodeWithSignature("refTick()"));
        if (!okRef || refData.length != 32) return (false, false, 0);
        int256 refWord;
        assembly ("memory-safe") { refWord := mload(add(refData, 32)) }
        if (refWord < TickMath.MIN_TICK || refWord > TickMath.MAX_TICK) return (false, false, 0);
        return (true, openWord == 1, int24(refWord));
    }

    function _normalReference() private view returns (bool normal, int24 ref) {
        (bool available, bool open, int24 tick) = _readPool4();
        normal = available && open && (burnSpent == 0 || block.number - lastBurnBlock <= STALE_AFTER_BLOCKS);
        ref = tick;
    }

    function _burnPool(bool viaPool4) private pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(IMD),
            fee: 10_000,
            tickSpacing: viaPool4 ? int24(60) : int24(200),
            hooks: IHooks(viaPool4 ? POOL4_HOOK : address(0))
        });
    }

    function _spot(PoolKey memory key) private view returns (int24 tick) {
        uint160 sqrtPrice;
        (sqrtPrice, tick,,) = poolManager.getSlot0(key.toId());
        if (sqrtPrice == 0 || tick < TickMath.MIN_TICK || tick > TickMath.MAX_TICK) revert PoolUnavailable();
    }

    /// @dev Snapshot lazily before the first anchor mutation, preserving the starting anchor for the whole block.
    function _blockReference() private returns (int24) {
        if (snapshotBlock != block.number) {
            startOfBlockAnchor = anchorTick;
            snapshotBlock = block.number;
        }
        return startOfBlockAnchor;
    }

    function _seedAnchor(int24 ref) private {
        if (!pool4Seen) {
            // No usable start-of-block anchor exists before the first valid seed.
            // Initialize both, as in the constructor, so fallback cannot use the default zero tick.
            startOfBlockAnchor = ref;
            snapshotBlock = block.number;
        } else {
            _blockReference();
        }
        pool4Seen = true;
        anchorTick = ref;
        lastRefTick = ref;
        anchorBlock = block.number;
        emit AnchorUpdated(anchorTick, lastRefTick, true);
    }

    function _stepAnchor(int24 spot) private {
        if (anchorBlock == block.number) return;
        int256 target = spot;
        int256 low = int256(lastRefTick) - FALLBACK_BAND;
        int256 high = int256(lastRefTick) + FALLBACK_BAND;
        if (target < low) target = low;
        if (target > high) target = high;
        int256 current = anchorTick;
        if (target > current + ANCHOR_STEP) target = current + ANCHOR_STEP;
        if (target < current - ANCHOR_STEP) target = current - ANCHOR_STEP;
        anchorTick = int24(target);
        anchorBlock = block.number;
        emit AnchorUpdated(anchorTick, lastRefTick, false);
    }

    /// @dev Raw currency units: ETH and IMD both have 18 decimals. No LP fee is deducted from the quote.
    function _quote(uint256 amount, int24 tick) private pure returns (uint256) {
        uint256 sqrtPrice = TickMath.getSqrtPriceAtTick(tick);
        if (sqrtPrice <= type(uint128).max) {
            return FullMath.mulDiv(sqrtPrice * sqrtPrice, amount, uint256(1) << 192);
        }
        uint256 ratioX128 = FullMath.mulDiv(sqrtPrice, sqrtPrice, uint256(1) << 64);
        return FullMath.mulDiv(ratioX128, amount, uint256(1) << 128);
    }

    function _decimal(uint256 value) private pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 length;
        while (temp != 0) {
            ++length;
            temp /= 10;
        }
        bytes memory buffer = new bytes(length);
        while (value != 0) {
            buffer[--length] = bytes1(uint8(48 + value % 10));
            value /= 10;
        }
        return string(buffer);
    }
}
