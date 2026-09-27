// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @title SwapLotteryHook
/// @notice Uniswap v4 hook that runs an hourly swap lottery on a native-ETH pool.
///
/// @dev Mechanics, all keyed by `PoolId` and applying only to pools whose `currency0` is native ETH:
///
/// * Rounds: `round = block.timestamp / 3600` (UTC hours).
/// * Fee: 50 bps of every swap's ETH leg goes to the pot of the round the swap lands in. A buy is
///   `zeroForOne` (ETH in), a sell `oneForZero` (ETH out). The swapper's specified amount is always
///   honoured exactly: when ETH is the specified currency (exact-in buy, exact-out sell) the fee is a
///   positive specified `BeforeSwapDelta` of `floor(|amountSpecified| * 50 / 10_000)`; when ETH is the
///   unspecified currency (exact-out buy, exact-in sell) it is a positive unspecified delta returned by
///   `afterSwap` of `floor(ethMovedByThePool * 50 / 10_000)`. A fee that rounds to 0 is 0.
/// * Settlement: the hook resolves its positive delta by minting itself ERC-6909 claims on native ETH
///   (`poolManager.mint`) inside the swap. It never calls `take` or moves ETH in a swap callback, so the
///   very first buy into a pool that holds no ETH works. Payouts burn claims and take ETH inside the
///   hook's own `unlockCallback`, after the claimant's balance has been zeroed.
/// * Tickets: a swap whose ETH leg is at least 0.001 ETH pushes one ticket for the address encoded in
///   `hookData` (exactly 32 bytes, an ABI-encoded non-zero address). Any other swap pays the fee but is
///   credited to nobody. `hookData` is unauthenticated: whoever builds the swap chooses the identity.
/// * Draw: once round `r` has ended anyone calls `seal(key, r)`, which records `targetBlock =
///   block.number + 1` once. While `targetBlock < block.number <= targetBlock + 256` anyone calls
///   `draw(key, r)`; the winner is `tickets[uint256(keccak256(abi.encode(blockhash(targetBlock),
///   poolId, r))) % ticketCount]` and receives the whole pot as a claimable balance. If the round has no
///   tickets, or `draw` is first called after `targetBlock + 256`, the pot rolls into the round current
///   at that call. Each round draws or rolls exactly once.
/// * Partial fills (price limit reached before the specified amount was filled) revert with
///   `PartialFill`, so the fee base is always the full ETH leg.
///
/// Invariant: the hook's ERC-6909 ETH claim balance at the PoolManager equals `totalOwed`, the sum of
/// every undrawn pot plus every unclaimed winning.
///
/// There is no owner, no setter, no pause, no upgrade and no sweep. Randomness comes from a future
/// blockhash, which a block proposer can bias by withholding a block; that is acceptable only because
/// pots are test-toy sized on Sepolia.
contract SwapLotteryHook is IHooks, IUnlockCallback {
    using SafeCast for uint256;
    using SafeCast for int128;

    // ─────────────────────────────────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Fee on every swap's ETH leg, in basis points.
    uint256 public constant FEE_BPS = 50;
    /// @notice Basis-point denominator.
    uint256 public constant BPS_DENOMINATOR = 10_000;
    /// @notice Minimum ETH leg for a swap to earn a ticket.
    uint256 public constant TICKET_THRESHOLD = 0.001 ether;
    /// @notice Length of a round in seconds.
    uint256 public constant ROUND_DURATION = 3600;
    /// @notice Number of blocks after `targetBlock` during which `blockhash(targetBlock)` is available.
    uint256 public constant BLOCKHASH_WINDOW = 256;
    /// @notice ERC-6909 id of native ETH at the PoolManager.
    uint256 public constant NATIVE_ID = 0;

    /// @notice The PoolManager this hook is bound to; the only address allowed to call its callbacks.
    IPoolManager public immutable poolManager;

    // ─────────────────────────────────────────────────────────────────────────────────────────────
    // Types
    // ─────────────────────────────────────────────────────────────────────────────────────────────

    enum Status {
        Open,
        Sealed,
        Drawn,
        RolledOver
    }

    struct Round {
        Status status;
        uint256 pot;
        uint256 targetBlock;
        address winner;
        uint256 rolledInto;
        address[] tickets;
        mapping(address holder => uint256 count) ticketsOf;
    }

    /// @notice Snapshot of a round returned by `roundState`.
    struct RoundState {
        Status status;
        uint256 pot;
        uint256 ticketCount;
        uint256 targetBlock;
        address winner;
        uint256 rolledInto;
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────
    // Storage
    // ─────────────────────────────────────────────────────────────────────────────────────────────

    mapping(PoolId poolId => mapping(uint256 round => Round)) internal _rounds;

    /// @notice Claimable ETH per account, paid by `claim`.
    mapping(address account => uint256 amount) public winnings;

    /// @notice Everything the hook still owes: undrawn pots plus unclaimed winnings.
    uint256 public totalOwed;

    // ─────────────────────────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────────────────────────

    event Ticket(PoolId indexed poolId, uint256 indexed round, address indexed holder, uint256 index);
    event Sealed(PoolId indexed poolId, uint256 indexed round, uint256 targetBlock);
    event Drawn(PoolId indexed poolId, uint256 indexed round, address indexed winner, uint256 pot);
    event RolledOver(PoolId indexed poolId, uint256 indexed round, uint256 indexed toRound, uint256 pot);
    event Claimed(address indexed account, uint256 amount);

    // ─────────────────────────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────────────────────────

    error NotPoolManager();
    error HookNotImplemented();
    error PartialFill();
    error NotEthPool();
    error RoundNotEnded(uint256 round, uint256 currentRound);
    error RoundNotOpen(uint256 round, Status status);
    error RoundNotSealed(uint256 round, Status status);
    error TargetBlockNotReached(uint256 targetBlock, uint256 blockNumber);
    error NothingToClaim();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @param _poolManager The Uniswap v4 PoolManager (Sepolia: 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543).
    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────
    // Permissions
    // ─────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Exactly beforeSwap, afterSwap, beforeSwapReturnDelta and afterSwapReturnDelta (0x00CC).
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────
    // Swap callbacks
    // ─────────────────────────────────────────────────────────────────────────────────────────────

    /// @inheritdoc IHooks
    /// @dev When ETH is the specified currency the fee is charged here as a positive specified delta so
    /// the pool swaps `|amountSpecified| - fee` (exact-in buy) or `|amountSpecified| + fee` (exact-out
    /// sell) and the swapper's specified amount is honoured exactly. Claims are minted in `afterSwap`.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        view
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (!key.currency0.isAddressZero() || !_ethSpecified(params)) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        uint256 fee = _fee(_abs(params.amountSpecified));
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
    }

    /// @inheritdoc IHooks
    /// @dev Verifies the fill, charges the unspecified-ETH fee, mints the hook's ETH claims for the whole
    /// fee of this swap, funds the current round's pot and pushes a ticket when the swap qualifies.
    function afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, int128) {
        if (!key.currency0.isAddressZero()) return (IHooks.afterSwap.selector, 0);

        uint256 ethLeg;
        uint256 fee;
        int128 unspecifiedDelta = 0;

        if (_ethSpecified(params)) {
            ethLeg = _abs(params.amountSpecified);
            fee = _fee(ethLeg);
            // The pool moved the specified amount net of (buy) or gross of (sell) the fee, or it hit the
            // price limit first.
            uint256 expectedEthMoved = params.zeroForOne ? ethLeg - fee : ethLeg + fee;
            if (_abs(delta.amount0()) != expectedEthMoved) revert PartialFill();
        } else {
            if (int256(delta.amount1()) != params.amountSpecified) revert PartialFill();
            ethLeg = _abs(delta.amount0());
            fee = _fee(ethLeg);
            unspecifiedDelta = fee.toInt128();
        }

        PoolId poolId = key.toId();
        uint256 round = currentRound();
        Round storage rd = _rounds[poolId][round];

        if (fee > 0) {
            // Resolve the hook's positive delta as ERC-6909 ETH claims, never as an ETH transfer.
            poolManager.mint(address(this), NATIVE_ID, fee);
            rd.pot += fee;
            totalOwed += fee;
        }

        if (ethLeg >= TICKET_THRESHOLD) {
            address holder = _identity(hookData);
            if (holder != address(0)) {
                uint256 index = rd.tickets.length;
                rd.tickets.push(holder);
                rd.ticketsOf[holder] += 1;
                emit Ticket(poolId, round, holder, index);
            }
        }

        return (IHooks.afterSwap.selector, unspecifiedDelta);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────
    // Lottery
    // ─────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Seals an ended round, fixing `targetBlock = block.number + 1` as its randomness source.
    /// @dev Anyone may call, once per round. The round must have ended (`round < currentRound()`), so a
    /// sealed round can never gain tickets or pot.
    function seal(PoolKey calldata key, uint256 round) external {
        if (!key.currency0.isAddressZero()) revert NotEthPool();
        uint256 current = currentRound();
        if (round >= current) revert RoundNotEnded(round, current);

        PoolId poolId = key.toId();
        Round storage rd = _rounds[poolId][round];
        if (rd.status != Status.Open) revert RoundNotOpen(round, rd.status);

        uint256 targetBlock = block.number + 1;
        rd.status = Status.Sealed;
        rd.targetBlock = targetBlock;
        emit Sealed(poolId, round, targetBlock);
    }

    /// @notice Draws a sealed round: credits the pot to one winner, or rolls it into the current round.
    /// @dev Requires `targetBlock < block.number`. `blockhash(targetBlock)` is used only while
    /// `block.number <= targetBlock + 256`; later, or when the round has no tickets, the pot rolls over
    /// into the round current at this call. Either way the round is finished exactly once.
    function draw(PoolKey calldata key, uint256 round) external {
        PoolId poolId = key.toId();
        Round storage rd = _rounds[poolId][round];
        if (rd.status != Status.Sealed) revert RoundNotSealed(round, rd.status);

        uint256 targetBlock = rd.targetBlock;
        if (block.number <= targetBlock) revert TargetBlockNotReached(targetBlock, block.number);

        uint256 count = rd.tickets.length;
        uint256 amount = rd.pot;

        if (count > 0 && block.number <= targetBlock + BLOCKHASH_WINDOW) {
            uint256 index = uint256(keccak256(abi.encode(blockhash(targetBlock), poolId, round))) % count;
            address winner = rd.tickets[index];
            rd.status = Status.Drawn;
            rd.winner = winner;
            winnings[winner] += amount;
            emit Drawn(poolId, round, winner, amount);
        } else {
            uint256 toRound = currentRound();
            rd.status = Status.RolledOver;
            rd.rolledInto = toRound;
            _rounds[poolId][toRound].pot += amount;
            emit RolledOver(poolId, round, toRound, amount);
        }
    }

    /// @notice Pays the caller everything it has won. The balance is zeroed before any ETH moves.
    function claim() external {
        uint256 amount = winnings[msg.sender];
        if (amount == 0) revert NothingToClaim();
        winnings[msg.sender] = 0;
        totalOwed -= amount;
        emit Claimed(msg.sender, amount);
        poolManager.unlock(abi.encode(msg.sender, amount));
    }

    /// @inheritdoc IUnlockCallback
    /// @dev Only ever entered from `claim`: the PoolManager calls back the address that unlocked it.
    function unlockCallback(bytes calldata data) external override onlyPoolManager returns (bytes memory) {
        (address to, uint256 amount) = abi.decode(data, (address, uint256));
        poolManager.burn(address(this), NATIVE_ID, amount);
        poolManager.take(CurrencyLibrary.ADDRESS_ZERO, to, amount);
        return "";
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────
    // Views
    // ─────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice The round swaps land in right now.
    function currentRound() public view returns (uint256) {
        return block.timestamp / ROUND_DURATION;
    }

    /// @notice ETH accumulated by `round` of `poolId`, including anything rolled into it.
    function pot(PoolId poolId, uint256 round) external view returns (uint256) {
        return _rounds[poolId][round].pot;
    }

    /// @notice Number of tickets in `round` of `poolId`.
    function ticketCount(PoolId poolId, uint256 round) external view returns (uint256) {
        return _rounds[poolId][round].tickets.length;
    }

    /// @notice Number of tickets `user` holds in `round` of `poolId`.
    function ticketsOf(PoolId poolId, uint256 round, address user) external view returns (uint256) {
        return _rounds[poolId][round].ticketsOf[user];
    }

    /// @notice Holder of ticket `index` in `round` of `poolId`.
    function ticketAt(PoolId poolId, uint256 round, uint256 index) external view returns (address) {
        return _rounds[poolId][round].tickets[index];
    }

    /// @notice Full snapshot of `round` of `poolId`.
    function roundState(PoolId poolId, uint256 round) external view returns (RoundState memory state) {
        Round storage rd = _rounds[poolId][round];
        state = RoundState({
            status: rd.status,
            pot: rd.pot,
            ticketCount: rd.tickets.length,
            targetBlock: rd.targetBlock,
            winner: rd.winner,
            rolledInto: rd.rolledInto
        });
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────
    // Internal helpers
    // ─────────────────────────────────────────────────────────────────────────────────────────────

    /// @dev ETH (currency0) is the specified currency for exact-in buys and exact-out sells.
    function _ethSpecified(SwapParams calldata params) internal pure returns (bool) {
        return params.zeroForOne == (params.amountSpecified < 0);
    }

    function _fee(uint256 ethLeg) internal pure returns (uint256) {
        return ethLeg * FEE_BPS / BPS_DENOMINATOR;
    }

    function _abs(int256 x) internal pure returns (uint256) {
        return x < 0 ? uint256(-x) : uint256(x);
    }

    /// @dev `abi.decode(hookData, (address))` for a well-formed 32-byte word; anything else is nobody.
    /// A word with dirty upper bytes is treated as nobody rather than reverting the swap.
    function _identity(bytes calldata hookData) internal pure returns (address) {
        if (hookData.length != 32) return address(0);
        uint256 raw = uint256(bytes32(hookData));
        if (raw > type(uint160).max) return address(0);
        return address(uint160(raw));
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────
    // Callbacks this hook does not enable. Never reached through the PoolManager because the address
    // does not carry their bits; kept so the contract satisfies `IHooks` and refuses if called anyway.
    // ─────────────────────────────────────────────────────────────────────────────────────────────

    function beforeInitialize(address, PoolKey calldata, uint160) external pure override returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure override returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }
}
