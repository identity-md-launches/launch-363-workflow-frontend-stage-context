// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SwapLotteryHook} from "../../src/SwapLotteryHook.sol";

/// @notice Independent ledger driven by swap inputs and requested lifecycle actions.
/// @dev Fees are computed from exact-in ETH, never from claims or totalOwed. Expected tickets,
/// winners, rollovers and payouts are computed without reading the hook's round state.
/// Unexpected reverts persist as a failing invariant even with fail_on_revert=false in the repo.
contract LotteryAccountingModel is Test {
    struct Round {
        SwapLotteryHook.Status status;
        uint256 pot;
        uint256 target;
        uint256 destination;
        address winner;
        address[] tickets;
    }

    IPoolManager internal immutable manager;
    PoolSwapTest internal immutable router;
    SwapLotteryHook internal immutable hook;
    PoolKey internal key;
    PoolId internal id;
    address[3] internal actors;
    uint256[] internal rounds;
    mapping(uint256 => bool) internal seen;
    mapping(uint256 => Round) internal model;
    mapping(address => uint256) internal claimable;

    uint256 public fees;
    uint256 public paid;
    uint256 public draws;
    uint256 public rollovers;
    uint256 public swaps;
    uint256 public unexpectedFailures;
    bytes public lastFailure;

    constructor(
        IPoolManager manager_,
        PoolSwapTest router_,
        SwapLotteryHook hook_,
        PoolKey memory key_,
        address[3] memory actors_
    ) {
        manager = manager_;
        router = router_;
        hook = hook_;
        key = key_;
        id = key_.toId();
        actors = actors_;
        _touch(vm.getBlockTimestamp() / 3600);
    }

    function _touch(uint256 round) internal {
        if (!seen[round]) {
            rounds.push(round);
            seen[round] = true;
        }
    }

    function buy(uint256 actorSeed, uint256 amount, bool identify) public {
        _buy(actors[actorSeed % 3], bound(amount, 1, 0.1 ether), identify);
    }

    function _buy(address who, uint256 amount, bool identify) internal {
        uint256 round = vm.getBlockTimestamp() / 3600;
        vm.prank(who);
        try router.swap{value: amount}(
            key,
            SwapParams(true, -int256(amount), TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            identify ? abi.encode(who) : bytes("")
        ) returns (
            BalanceDelta delta
        ) {
            if (int256(delta.amount0()) != -int256(amount)) unexpectedFailures++;
            _touch(round);
            uint256 fee = amount * 50 / 10_000;
            fees += fee;
            model[round].pot += fee;
            if (identify && amount >= 0.001 ether) model[round].tickets.push(who);
            swaps++;
        } catch (bytes memory reason) {
            _failure(reason);
        }
    }

    function advance(uint256 secondsSeed) public {
        uint256 secondsForward = bound(secondsSeed, 1, 3 hours);
        vm.warp(vm.getBlockTimestamp() + secondsForward);
        vm.roll(vm.getBlockNumber() + secondsForward / 12 + 1);
    }

    function _endRound() internal {
        uint256 elapsed = 3600 - vm.getBlockTimestamp() % 3600;
        vm.warp(vm.getBlockTimestamp() + elapsed);
        vm.roll(vm.getBlockNumber() + elapsed / 12 + 1);
    }

    function seal(uint256 seed) public {
        for (uint256 i; i < rounds.length; i++) {
            uint256 round = rounds[(seed % rounds.length + i) % rounds.length];
            if (model[round].status == SwapLotteryHook.Status.Open && round < vm.getBlockTimestamp() / 3600) {
                _seal(round);
                return;
            }
        }
        // Always make progress, even if the fuzzer selected seal before advancing time.
        uint256 current = vm.getBlockTimestamp() / 3600;
        _touch(current);
        _endRound();
        _seal(current);
    }

    function _seal(uint256 round) internal {
        if (_call(abi.encodeCall(hook.seal, (key, round)))) {
            model[round].status = SwapLotteryHook.Status.Sealed;
            model[round].target = vm.getBlockNumber() + 1;
        }
    }

    function resolve(uint256 seed, uint256 offsetSeed, bytes32 entropy) public {
        // Bias toward all three meaningful edges, while also exploring the whole window.
        uint256 offset =
            offsetSeed % 4 == 0 ? 1 : offsetSeed % 4 == 1 ? 256 : offsetSeed % 4 == 2 ? 257 : bound(offsetSeed, 1, 400);
        for (uint256 i; i < rounds.length; i++) {
            uint256 round = rounds[(seed % rounds.length + i) % rounds.length];
            if (model[round].status == SwapLotteryHook.Status.Sealed) {
                _resolve(round, offset, entropy);
                return;
            }
        }
        // Seal and resolve a fresh ended round if no sealed one is waiting.
        uint256 current = vm.getBlockTimestamp() / 3600;
        _touch(current);
        _endRound();
        _seal(current);
        if (model[current].status == SwapLotteryHook.Status.Sealed) _resolve(current, offset, entropy);
    }

    function _resolve(uint256 round, uint256 offset, bytes32 entropy) internal {
        Round storage expected = model[round];
        uint256 drawBlock = expected.target + offset;
        if (drawBlock > vm.getBlockNumber()) {
            vm.warp(vm.getBlockTimestamp() + (drawBlock - vm.getBlockNumber()) * 12);
            vm.roll(drawBlock);
        }
        bool canWin = expected.tickets.length != 0 && vm.getBlockNumber() <= expected.target + 256;
        address winner;
        if (canWin) {
            bytes32 targetHash = keccak256(abi.encode(entropy, round));
            vm.setBlockhash(expected.target, targetHash);
            winner = expected.tickets[uint256(keccak256(abi.encode(targetHash, id, round))) % expected.tickets.length];
        }
        if (!_call(abi.encodeCall(hook.draw, (key, round)))) return;
        if (canWin) {
            expected.status = SwapLotteryHook.Status.Drawn;
            expected.winner = winner;
            claimable[winner] += expected.pot;
            draws++;
        } else {
            uint256 destination = vm.getBlockTimestamp() / 3600;
            _touch(destination);
            model[destination].pot += expected.pot;
            expected.status = SwapLotteryHook.Status.RolledOver;
            expected.destination = destination;
            rollovers++;
        }
    }

    function claim(uint256 seed) public {
        address who = actors[seed % 3];
        uint256 amount = claimable[who];
        uint256 before = who.balance;
        vm.prank(who);
        (bool ok, bytes memory reason) = address(hook).call(abi.encodeCall(hook.claim, ()));
        if (amount == 0) {
            if (ok || keccak256(reason) != keccak256(abi.encodeWithSelector(SwapLotteryHook.NothingToClaim.selector))) {
                _failure(reason);
            }
        } else if (!ok) {
            _failure(reason);
        } else {
            if (who.balance != before + amount) unexpectedFailures++;
            paid += amount;
            claimable[who] = 0;
        }
    }

    /// @dev A complete valid lifecycle guarantees deep transitions occur even at short fuzz depths.
    function cycle(uint256 actorSeed, uint256 amount, bool expire, bytes32 entropy) public {
        uint256 round = vm.getBlockTimestamp() / 3600;
        _buy(actors[actorSeed % 3], bound(amount, 0.001 ether, 0.1 ether), true);
        _endRound();
        _seal(round);
        if (model[round].status == SwapLotteryHook.Status.Sealed) {
            _resolve(round, expire ? 257 : 1, entropy);
        }
    }

    function _call(bytes memory data) internal returns (bool ok) {
        bytes memory reason;
        (ok, reason) = address(hook).call(data);
        if (!ok) _failure(reason);
    }

    function _failure(bytes memory reason) internal {
        unexpectedFailures++;
        lastFailure = reason;
    }

    function assertAccounting() external view {
        assertEq(unexpectedFailures, 0, "valid modeled action failed");
        uint256 outstanding;
        for (uint256 i; i < rounds.length; i++) {
            uint256 round = rounds[i];
            Round storage expected = model[round];
            SwapLotteryHook.RoundState memory actual = hook.roundState(id, round);
            assertEq(uint8(actual.status), uint8(expected.status), "round status");
            assertEq(actual.pot, expected.pot, "round pot");
            assertEq(hook.pot(id, round), expected.pot, "pot view");
            assertEq(actual.targetBlock, expected.target, "sealed target");
            assertEq(actual.winner, expected.winner, "winner");
            assertEq(actual.rolledInto, expected.destination, "rollover destination");
            assertEq(actual.ticketCount, expected.tickets.length, "ticket count");
            assertEq(hook.ticketCount(id, round), expected.tickets.length, "ticket count view");
            uint256[3] memory counts;
            for (uint256 j; j < expected.tickets.length; j++) {
                assertEq(hook.ticketAt(id, round, j), expected.tickets[j], "ticket order");
                for (uint256 a; a < 3; a++) {
                    if (expected.tickets[j] == actors[a]) counts[a]++;
                }
            }
            for (uint256 a; a < 3; a++) {
                assertEq(hook.ticketsOf(id, round, actors[a]), counts[a], "holder count");
            }
            // Terminal pots are historical; their debt now lives in a destination pot or winnings.
            if (expected.status == SwapLotteryHook.Status.Open || expected.status == SwapLotteryHook.Status.Sealed) {
                outstanding += expected.pot;
            }
        }
        for (uint256 a; a < 3; a++) {
            assertEq(hook.winnings(actors[a]), claimable[actors[a]], "unclaimed winnings");
            outstanding += claimable[actors[a]];
        }
        assertEq(outstanding, fees - paid, "model conservation");
        assertEq(hook.totalOwed(), outstanding, "total debt");
        assertEq(manager.balanceOf(address(hook), 0), outstanding, "ETH claims");
        assertGe(address(manager).balance, outstanding, "ETH backing");
        assertEq(address(hook).balance, 0, "hook must hold claims, not ETH");
        assertEq(hook.winnings(address(router)), 0, "router is not a ticket holder");
    }
}
