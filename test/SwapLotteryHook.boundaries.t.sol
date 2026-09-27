// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LotteryTestBase} from "./utils/LotteryTestBase.sol";
import {SwapLotteryHook} from "../src/SwapLotteryHook.sol";

/// @notice Boundary checks include accounting snapshots around rejected transitions.
contract SwapLotteryHookBoundaryTest is LotteryTestBase {
    function setUp() public override {
        super.setUp();
        launch();
    }

    function test_ticketExactOutSellAtThresholdAndOneWeiBelow() public {
        // Fund ETH reserves without creating any ticket; the sell's gross pool movement is
        // above the threshold in BOTH cases, so using that instead of specified ETH would fail.
        swapAs(alice, true, -int256(1 ether), "", 1 ether);
        uint256 claimsBefore = hookClaims();
        uint256 bobBefore = bob.balance;
        sellExactOut(bob, 0.001 ether - 1);
        assertEq(bob.balance - bobBefore, 0.001 ether - 1);
        assertEq(hook.ticketCount(poolId, START_ROUND), 0);
        assertEq(hook.ticketsOf(poolId, START_ROUND, bob), 0);
        assertEq(hookClaims() - claimsBefore, uint256(0.001 ether - 1) * 50 / 10_000);

        vm.expectEmit(true, true, true, true, address(hook));
        emit SwapLotteryHook.Ticket(poolId, START_ROUND, bob, 0);
        sellExactOut(bob, 0.001 ether);
        assertEq(hook.ticketCount(poolId, START_ROUND), 1);
        assertEq(hook.ticketsOf(poolId, START_ROUND, bob), 1);
        assertEq(hook.ticketAt(poolId, START_ROUND, 0), bob);
        assertEq(bob.balance - bobBefore, 2 * 0.001 ether - 1);
        assertEq(hook.pot(poolId, START_ROUND), fee(1 ether) + fee(0.001 ether - 1) + fee(0.001 ether));
        assertSolvent();
    }

    function testFuzz_sealBeforeEndRevertsWithoutMutation(uint256 secondsIntoRound, uint256 amount) public {
        secondsIntoRound = bound(secondsIntoRound, 0, 3599);
        amount = bound(amount, 1, 1 ether);
        vm.warp(START_TIMESTAMP + secondsIntoRound);
        buyExactIn(alice, amount);
        bytes32 before = _snapshot(START_ROUND);
        vm.expectRevert(abi.encodeWithSelector(SwapLotteryHook.RoundNotEnded.selector, START_ROUND, START_ROUND));
        hook.seal(key, START_ROUND);
        assertEq(_snapshot(START_ROUND), before);

        vm.warp(START_TIMESTAMP + 3600);
        hook.seal(key, START_ROUND);
        assertEq(hook.roundState(poolId, START_ROUND).targetBlock, block.number + 1);
        assertEq(uint8(hook.roundState(poolId, START_ROUND).status), uint8(SwapLotteryHook.Status.Sealed));
        before = _snapshot(START_ROUND);
        vm.expectRevert(
            abi.encodeWithSelector(SwapLotteryHook.RoundNotOpen.selector, START_ROUND, SwapLotteryHook.Status.Sealed)
        );
        vm.prank(bob);
        hook.seal(key, START_ROUND);
        assertEq(_snapshot(START_ROUND), before);
    }

    function testFuzz_drawAtTargetPlusOne(uint256 amount, bytes32 entropy) public {
        _drawAt(1, amount, entropy);
    }

    function testFuzz_drawAtTargetPlus256(uint256 amount, bytes32 entropy) public {
        _drawAt(256, amount, entropy);
    }

    function _drawAt(uint256 offset, uint256 amount, bytes32 entropy) internal {
        amount = bound(amount, 0.001 ether, 1 ether);
        address[4] memory holders = [alice, bob, alice, carol];
        for (uint256 i; i < holders.length; i++) {
            buyExactIn(holders[i], amount);
        }
        uint256 expectedPot = 4 * (amount * 50 / 10_000);
        nextRound();
        vm.prank(carol);
        hook.seal(key, START_ROUND);
        uint256 target = hook.roundState(poolId, START_ROUND).targetBlock;

        vm.roll(target);
        bytes32 before = _snapshot(START_ROUND);
        vm.expectRevert(abi.encodeWithSelector(SwapLotteryHook.TargetBlockNotReached.selector, target, target));
        hook.draw(key, START_ROUND);
        assertEq(_snapshot(START_ROUND), before, "early draw mutated accounting");

        vm.roll(target + offset);
        // Explicit nonzero entropy exercises the actual target hash rather than Foundry's default.
        bytes32 targetHash = keccak256(abi.encode("target block", entropy));
        vm.setBlockhash(target, targetHash);
        assertEq(blockhash(target), targetHash);
        address expected = holders[uint256(keccak256(abi.encode(targetHash, poolId, START_ROUND))) % 4];
        vm.expectEmit(true, true, true, true, address(hook));
        emit SwapLotteryHook.Drawn(poolId, START_ROUND, expected, expectedPot);
        hook.draw(key, START_ROUND);
        SwapLotteryHook.RoundState memory state = hook.roundState(poolId, START_ROUND);
        assertEq(uint8(state.status), uint8(SwapLotteryHook.Status.Drawn));
        assertEq(state.winner, expected);
        assertEq(hook.winnings(expected), expectedPot);
        assertEq(hook.pot(poolId, hook.currentRound()), 0);
        assertEq(hookClaims(), expectedPot);
        assertSolvent();

        before = _snapshot(START_ROUND);
        vm.expectRevert(
            abi.encodeWithSelector(SwapLotteryHook.RoundNotSealed.selector, START_ROUND, SwapLotteryHook.Status.Drawn)
        );
        hook.draw(key, START_ROUND);
        assertEq(_snapshot(START_ROUND), before, "double draw mutated accounting");
    }

    function testFuzz_drawAtTargetPlus257RollsIntoFundedCurrentRound(uint256 amount, uint256 gap) public {
        amount = bound(amount, 0.001 ether, 1 ether);
        buyExactIn(alice, amount);
        _rollIntoFundedRound(amount * 50 / 10_000, 257, gap);
        assertEq(hook.winnings(alice), 0, "expired tickets must not win");
    }

    function testFuzz_emptyRoundRollsIntoFundedCurrentRound(uint256 amount, uint256 gap) public {
        // Includes zero-pot rounds and fee-paying rounds with no qualifying ticket.
        amount = bound(amount, 0, 0.001 ether - 1);
        if (amount != 0) buyExactIn(alice, amount);
        assertEq(hook.ticketCount(poolId, START_ROUND), 0);
        _rollIntoFundedRound(amount * 50 / 10_000, 1, gap);
    }

    function _rollIntoFundedRound(uint256 rollingPot, uint256 offset, uint256 gap) internal {
        gap = bound(gap, 2, 10);
        nextRound();
        hook.seal(key, START_ROUND);
        uint256 target = hook.roundState(poolId, START_ROUND).targetBlock;
        // Destination is selected at draw time, even when seal happened several hours earlier.
        vm.warp(START_TIMESTAMP + gap * 3600);
        vm.roll(target + offset);
        if (offset == 257) assertEq(blockhash(target), bytes32(0));
        buyExactIn(bob, 0.01 ether);
        uint256 destination = START_ROUND + gap;
        uint256 ownPot = 0.01 ether * 50 / 10_000;
        assertEq(hook.pot(poolId, destination), ownPot);
        uint256 claimsBefore = hookClaims();
        vm.expectEmit(true, true, true, true, address(hook));
        emit SwapLotteryHook.RolledOver(poolId, START_ROUND, destination, rollingPot);
        hook.draw(key, START_ROUND);
        SwapLotteryHook.RoundState memory state = hook.roundState(poolId, START_ROUND);
        assertEq(uint8(state.status), uint8(SwapLotteryHook.Status.RolledOver));
        assertEq(state.rolledInto, destination);
        assertEq(state.winner, address(0));
        assertEq(hook.pot(poolId, destination), ownPot + rollingPot);
        assertEq(hook.pot(poolId, START_ROUND + 1), 0);
        assertEq(hook.ticketCount(poolId, destination), 1, "rollover must not copy tickets");
        assertEq(hook.ticketsOf(poolId, destination, alice), 0);
        assertEq(hookClaims(), claimsBefore, "moving a pot must not mint claims");
        assertEq(hookClaims(), ownPot + rollingPot);

        bytes32 before = _snapshot(START_ROUND);
        vm.expectRevert(
            abi.encodeWithSelector(
                SwapLotteryHook.RoundNotSealed.selector, START_ROUND, SwapLotteryHook.Status.RolledOver
            )
        );
        hook.draw(key, START_ROUND);
        assertEq(_snapshot(START_ROUND), before);
        vm.expectRevert(
            abi.encodeWithSelector(
                SwapLotteryHook.RoundNotOpen.selector, START_ROUND, SwapLotteryHook.Status.RolledOver
            )
        );
        hook.seal(key, START_ROUND);
        assertEq(_snapshot(START_ROUND), before);
        assertSolvent();
    }

    function _snapshot(uint256 round) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                hook.roundState(poolId, round),
                hook.roundState(poolId, hook.currentRound()),
                hook.winnings(alice),
                hook.winnings(bob),
                hook.winnings(carol),
                hook.totalOwed(),
                hookClaims(),
                address(manager).balance
            )
        );
    }
}
