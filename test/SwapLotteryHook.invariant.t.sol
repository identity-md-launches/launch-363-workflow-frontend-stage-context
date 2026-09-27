// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

import {LotteryTestBase} from "./utils/LotteryTestBase.sol";
import {SwapLotteryHook} from "../src/SwapLotteryHook.sol";
import {Ticket} from "../src/Ticket.sol";

/// @notice Drives the hook through random swaps, time, seals, draws and claims.
/// @dev Every action that may legitimately revert (partial fill, wrong timing, nothing to claim) is
/// wrapped so the fuzzer keeps exploring; the invariants are checked after each call.
contract LotteryHandler is Test {
    IPoolManager immutable manager;
    SwapLotteryHook immutable hook;
    PoolSwapTest immutable router;
    Ticket immutable token;
    PoolKey key;
    PoolId poolId;

    address[] public actors;
    uint256[] public rounds; // every round that ever received a fee, ticket or rollover
    mapping(uint256 => bool) seen;

    uint256 public ghostFees;
    uint256 public ghostClaimed;
    uint256 public ghostDraws;
    uint256 public ghostRollovers;

    constructor(
        IPoolManager _manager,
        SwapLotteryHook _hook,
        PoolSwapTest _router,
        Ticket _token,
        PoolKey memory _key,
        address[] memory _actors
    ) {
        manager = _manager;
        hook = _hook;
        router = _router;
        token = _token;
        key = _key;
        poolId = key.toId();
        actors = _actors;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _touch(uint256 round) internal {
        if (!seen[round]) {
            seen[round] = true;
            rounds.push(round);
        }
    }

    function _swap(address who, bool zeroForOne, int256 amount, uint256 value) internal {
        uint256 claimsBefore = manager.balanceOf(address(hook), 0);
        SwapParams memory p = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amount,
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        vm.prank(who);
        try router.swap{value: value}(key, p, PoolSwapTest.TestSettings(false, false), abi.encode(who)) {
            ghostFees += manager.balanceOf(address(hook), 0) - claimsBefore;
            _touch(hook.currentRound());
        } catch {}
    }

    function buyExactIn(uint256 seed, uint256 ethIn) external {
        address who = _actor(seed);
        ethIn = bound(ethIn, 1, who.balance / 4 + 1);
        if (ethIn > who.balance) return;
        _swap(who, true, -int256(ethIn), ethIn);
    }

    function buyExactOut(uint256 seed, uint256 tiktOut) external {
        address who = _actor(seed);
        tiktOut = bound(tiktOut, 1, 5_000_000e18);
        uint256 budget = who.balance / 4;
        if (budget == 0) return;
        _swap(who, true, int256(tiktOut), budget);
    }

    function sellExactIn(uint256 seed, uint256 tiktIn) external {
        address who = _actor(seed);
        uint256 bal = token.balanceOf(who);
        if (bal == 0) return;
        tiktIn = bound(tiktIn, 1, bal);
        _swap(who, false, -int256(tiktIn), 0);
    }

    function sellExactOut(uint256 seed, uint256 ethOut) external {
        address who = _actor(seed);
        ethOut = bound(ethOut, 1, 2 ether);
        _swap(who, false, int256(ethOut), 0);
    }

    function passTime(uint256 secs) external {
        secs = bound(secs, 1, 3 hours);
        vm.roll(block.number + secs / 12 + 1);
        vm.warp(block.timestamp + secs);
    }

    function passBlocks(uint256 blocks) external {
        blocks = bound(blocks, 1, 300);
        vm.roll(block.number + blocks);
        vm.warp(block.timestamp + blocks * 12);
    }

    function seal(uint256 roundSeed) external {
        if (rounds.length == 0) return;
        uint256 round = rounds[roundSeed % rounds.length];
        try hook.seal(key, round) {} catch {}
    }

    function draw(uint256 roundSeed) external {
        if (rounds.length == 0) return;
        uint256 round = rounds[roundSeed % rounds.length];
        try hook.draw(key, round) {
            SwapLotteryHook.RoundState memory s = hook.roundState(poolId, round);
            if (s.status == SwapLotteryHook.Status.Drawn) {
                ghostDraws++;
            } else {
                ghostRollovers++;
                _touch(s.rolledInto);
            }
        } catch {}
    }

    function claim(uint256 seed) external {
        address who = _actor(seed);
        uint256 amount = hook.winnings(who);
        vm.prank(who);
        try hook.claim() {
            ghostClaimed += amount;
        } catch {}
    }

    function roundsLength() external view returns (uint256) {
        return rounds.length;
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }
}

contract SwapLotteryHookInvariantTest is LotteryTestBase {
    LotteryHandler handler;

    function setUp() public override {
        super.setUp();
        launch();

        address[] memory actors = new address[](3);
        actors[0] = alice;
        actors[1] = bob;
        actors[2] = carol;
        handler = new LotteryHandler(manager, hook, swapRouter, token, key, actors);

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = LotteryHandler.buyExactIn.selector;
        selectors[1] = LotteryHandler.buyExactOut.selector;
        selectors[2] = LotteryHandler.sellExactIn.selector;
        selectors[3] = LotteryHandler.sellExactOut.selector;
        selectors[4] = LotteryHandler.passTime.selector;
        selectors[5] = LotteryHandler.passBlocks.selector;
        selectors[6] = LotteryHandler.seal.selector;
        selectors[7] = LotteryHandler.draw.selector;
        selectors[8] = LotteryHandler.claim.selector;
        selectors[9] = LotteryHandler.passTime.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice The hook's ETH claims at the PoolManager equal everything it still owes.
    function invariant_claimsEqualTotalOwed() public view {
        assertEq(hookClaims(), hook.totalOwed());
        assertEq(hook.totalOwed(), handler.ghostFees() - handler.ghostClaimed());
        assertGe(address(manager).balance, hookClaims());
        assertEq(address(hook).balance, 0);
    }

    /// @notice Open and sealed pots plus unclaimed winnings account for the whole debt: no pot is lost
    /// and no pot is counted twice through a rollover.
    function invariant_potsPlusWinningsEqualTotalOwed() public view {
        uint256 outstanding;
        uint256 n = handler.roundsLength();
        for (uint256 i = 0; i < n; i++) {
            SwapLotteryHook.RoundState memory s = hook.roundState(poolId, handler.rounds(i));
            if (s.status == SwapLotteryHook.Status.Open || s.status == SwapLotteryHook.Status.Sealed) {
                outstanding += s.pot;
            }
            if (s.status == SwapLotteryHook.Status.Sealed || s.status == SwapLotteryHook.Status.Drawn) {
                assertGt(s.targetBlock, 0);
            }
            if (s.status == SwapLotteryHook.Status.Drawn) {
                assertTrue(s.winner != address(0));
                assertGt(s.ticketCount, 0);
            }
        }
        uint256 actors = handler.actorsLength();
        for (uint256 i = 0; i < actors; i++) {
            outstanding += hook.winnings(handler.actors(i));
        }
        assertEq(outstanding, hook.totalOwed());
    }

    /// @notice A round that has ended and been sealed never changes size afterwards; the current round
    /// is never sealed.
    function invariant_currentRoundIsNeverSealed() public view {
        SwapLotteryHook.RoundState memory s = hook.roundState(poolId, hook.currentRound());
        assertEq(uint8(s.status), uint8(SwapLotteryHook.Status.Open));
    }
}
