// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

import {LotteryTestBase} from "./utils/LotteryTestBase.sol";
import {SwapLotteryHook} from "../src/SwapLotteryHook.sol";

/// @notice A winner that re-enters `claim` from its ETH receive hook and swallows the failure.
contract ReentrantWinner {
    SwapLotteryHook immutable hook;
    uint256 public received;
    uint256 public reentries;

    constructor(SwapLotteryHook _hook) {
        hook = _hook;
    }

    function claim() external {
        hook.claim();
    }

    receive() external payable {
        received += msg.value;
        reentries += 1;
        if (reentries < 3) {
            try hook.claim() {} catch {}
        }
    }
}

/// @notice A winner that cannot receive ETH.
contract RejectingWinner {
    SwapLotteryHook immutable hook;

    constructor(SwapLotteryHook _hook) {
        hook = _hook;
    }

    function claim() external {
        hook.claim();
    }
}

/// @notice Tickets, rounds, seal / draw timing, the blockhash window, rollovers, claims and
/// conservation of funds.
contract SwapLotteryHookLotteryTest is LotteryTestBase {
    function setUp() public override {
        super.setUp();
        launch();
    }

    // ── tickets ────────────────────────────────────────────────────────────────────────────────

    function test_ticket_thresholdIsInclusive() public {
        buyExactIn(alice, 0.001 ether - 1);
        assertEq(hook.ticketCount(poolId, START_ROUND), 0, "just under the threshold: no ticket");
        assertEq(hook.pot(poolId, START_ROUND), fee(0.001 ether - 1), "but the fee is still charged");

        vm.expectEmit(true, true, true, true, address(hook));
        emit SwapLotteryHook.Ticket(poolId, START_ROUND, alice, 0);
        buyExactIn(alice, 0.001 ether);
        assertEq(hook.ticketCount(poolId, START_ROUND), 1, "exactly the threshold: one ticket");
        assertEq(hook.ticketsOf(poolId, START_ROUND, alice), 1);
        assertEq(hook.ticketAt(poolId, START_ROUND, 0), alice);
    }

    function test_ticket_thresholdUsesTheEthLegForUnspecifiedEth() public {
        // Exact-out buy: the ETH leg is what the pool moved, not the specified TIKT.
        buyExactOut(bob, 1_000e18, 1 ether); // tiny: ETH leg well under 0.001
        assertEq(hook.ticketCount(poolId, START_ROUND), 0);
        buyExactOut(bob, 1_000_000e18, 1 ether); // ~0.1 ETH
        assertEq(hook.ticketCount(poolId, START_ROUND), 1);
        assertEq(hook.ticketsOf(poolId, START_ROUND, bob), 1);

        // Exact-out sell of exactly the threshold: ETH leg is the specified amount.
        sellExactOut(alice, 0.001 ether);
        assertEq(hook.ticketsOf(poolId, START_ROUND, alice), 1);
        assertEq(hook.ticketCount(poolId, START_ROUND), 2);
    }

    function test_ticket_oneTicketPerQualifyingSwapAndIndicesAreSequential() public {
        buyExactIn(alice, 1 ether);
        buyExactIn(alice, 1 ether);
        buyExactIn(bob, 1 ether);
        assertEq(hook.ticketCount(poolId, START_ROUND), 3);
        assertEq(hook.ticketsOf(poolId, START_ROUND, alice), 2);
        assertEq(hook.ticketsOf(poolId, START_ROUND, bob), 1);
        assertEq(hook.ticketAt(poolId, START_ROUND, 0), alice);
        assertEq(hook.ticketAt(poolId, START_ROUND, 1), alice);
        assertEq(hook.ticketAt(poolId, START_ROUND, 2), bob);
    }

    function test_identity_onlyAWellFormedNonZeroAddressIsCredited() public {
        uint256 ethIn = 1 ether;
        // Empty hookData: a router that forwards nothing can never claim.
        swapAs(alice, true, -int256(ethIn), "", ethIn);
        // 64 bytes.
        swapAs(alice, true, -int256(ethIn), abi.encode(alice, uint256(1)), ethIn);
        // 20 raw bytes.
        swapAs(alice, true, -int256(ethIn), abi.encodePacked(alice), ethIn);
        // 32 bytes encoding the zero address.
        swapAs(alice, true, -int256(ethIn), abi.encode(address(0)), ethIn);
        // 32 bytes with dirty upper bytes: not a valid address encoding, credits nobody, does not revert.
        swapAs(alice, true, -int256(ethIn), abi.encodePacked(bytes12(0xffffffffffffffffffffffff), alice), ethIn);

        assertEq(hook.ticketCount(poolId, START_ROUND), 0, "none of these swaps earned a ticket");
        assertEq(hook.pot(poolId, START_ROUND), 5 * fee(ethIn), "all of them paid the fee");

        // The identity is whatever hookData says, not who sent the transaction.
        swapAs(alice, true, -int256(ethIn), abi.encode(carol), ethIn);
        assertEq(hook.ticketsOf(poolId, START_ROUND, carol), 1);
        assertEq(hook.ticketsOf(poolId, START_ROUND, alice), 0);
        assertSolvent();
    }

    // ── rounds ─────────────────────────────────────────────────────────────────────────────────

    function test_round_isTheUtcHourOfTheSwap() public {
        assertEq(hook.currentRound(), START_ROUND);
        vm.warp(START_TIMESTAMP + 3599);
        buyExactIn(alice, 1 ether);
        assertEq(hook.ticketCount(poolId, START_ROUND), 1);
        assertEq(hook.pot(poolId, START_ROUND), fee(1 ether));

        vm.warp(START_TIMESTAMP + 3600);
        assertEq(hook.currentRound(), START_ROUND + 1);
        buyExactIn(alice, 1 ether);
        assertEq(hook.ticketCount(poolId, START_ROUND), 1, "the closed round gained nothing");
        assertEq(hook.pot(poolId, START_ROUND), fee(1 ether));
        assertEq(hook.ticketCount(poolId, START_ROUND + 1), 1);
        assertEq(hook.pot(poolId, START_ROUND + 1), fee(1 ether));
    }

    function test_round_sealedRoundCannotGainTicketsOrPot() public {
        buyExactIn(alice, 1 ether);
        nextRound();
        hook.seal(key, START_ROUND);
        buyExactIn(bob, 1 ether);
        assertEq(hook.ticketCount(poolId, START_ROUND), 1);
        assertEq(hook.pot(poolId, START_ROUND), fee(1 ether));
        assertEq(hook.ticketCount(poolId, START_ROUND + 1), 1);
    }

    // ── seal ───────────────────────────────────────────────────────────────────────────────────

    function test_seal_revertsWhileTheRoundIsRunning() public {
        buyExactIn(alice, 1 ether);
        vm.warp(START_TIMESTAMP + 3599);
        vm.expectRevert(abi.encodeWithSelector(SwapLotteryHook.RoundNotEnded.selector, START_ROUND, START_ROUND));
        hook.seal(key, START_ROUND);

        // A future round cannot be sealed either.
        vm.expectRevert(abi.encodeWithSelector(SwapLotteryHook.RoundNotEnded.selector, START_ROUND + 5, START_ROUND));
        hook.seal(key, START_ROUND + 5);
    }

    function test_seal_recordsTargetBlockOnceAndEmits() public {
        buyExactIn(alice, 1 ether);
        vm.warp(START_TIMESTAMP + 3600);
        vm.roll(START_BLOCK + 300);

        vm.expectEmit(true, true, true, true, address(hook));
        emit SwapLotteryHook.Sealed(poolId, START_ROUND, START_BLOCK + 301);
        vm.prank(carol); // anyone
        hook.seal(key, START_ROUND);

        SwapLotteryHook.RoundState memory s = hook.roundState(poolId, START_ROUND);
        assertEq(uint8(s.status), uint8(SwapLotteryHook.Status.Sealed));
        assertEq(s.targetBlock, START_BLOCK + 301);
        assertEq(s.pot, fee(1 ether));
        assertEq(s.ticketCount, 1);
        assertEq(s.winner, address(0));

        vm.roll(START_BLOCK + 400);
        vm.expectRevert(
            abi.encodeWithSelector(SwapLotteryHook.RoundNotOpen.selector, START_ROUND, SwapLotteryHook.Status.Sealed)
        );
        hook.seal(key, START_ROUND);
        assertEq(hook.roundState(poolId, START_ROUND).targetBlock, START_BLOCK + 301, "unchanged");
    }

    function test_seal_afterDrawOrRolloverReverts() public {
        buyExactIn(alice, 1 ether);
        nextRound();
        hook.seal(key, START_ROUND);
        vm.roll(block.number + 2); // past targetBlock = sealBlock + 1
        hook.draw(key, START_ROUND);
        vm.expectRevert(
            abi.encodeWithSelector(SwapLotteryHook.RoundNotOpen.selector, START_ROUND, SwapLotteryHook.Status.Drawn)
        );
        hook.seal(key, START_ROUND);
    }

    // ── draw ───────────────────────────────────────────────────────────────────────────────────

    function test_draw_requiresSeal() public {
        buyExactIn(alice, 1 ether);
        nextRound();
        vm.expectRevert(
            abi.encodeWithSelector(SwapLotteryHook.RoundNotSealed.selector, START_ROUND, SwapLotteryHook.Status.Open)
        );
        hook.draw(key, START_ROUND);
    }

    function test_draw_revertsAtOrBeforeTargetBlock() public {
        buyExactIn(alice, 1 ether);
        nextRound();
        hook.seal(key, START_ROUND);
        uint256 target = hook.roundState(poolId, START_ROUND).targetBlock;
        assertEq(target, block.number + 1);

        // Same block as the seal.
        vm.expectRevert(abi.encodeWithSelector(SwapLotteryHook.TargetBlockNotReached.selector, target, block.number));
        hook.draw(key, START_ROUND);

        // The target block itself: its hash is not known yet.
        vm.roll(target);
        vm.expectRevert(abi.encodeWithSelector(SwapLotteryHook.TargetBlockNotReached.selector, target, target));
        hook.draw(key, START_ROUND);
    }

    function test_draw_atTargetPlusOneUsesTheBlockhashFormula() public {
        buyExactIn(alice, 1 ether);
        buyExactIn(bob, 1 ether);
        buyExactIn(carol, 1 ether);
        buyExactIn(bob, 1 ether);
        uint256 potSize = hook.pot(poolId, START_ROUND);
        nextRound();
        hook.seal(key, START_ROUND);
        uint256 target = hook.roundState(poolId, START_ROUND).targetBlock;

        vm.roll(target + 1);
        uint256 index = uint256(keccak256(abi.encode(blockhash(target), poolId, START_ROUND))) % 4;
        address expected = hook.ticketAt(poolId, START_ROUND, index);

        vm.expectEmit(true, true, true, true, address(hook));
        emit SwapLotteryHook.Drawn(poolId, START_ROUND, expected, potSize);
        vm.prank(carol); // anyone
        hook.draw(key, START_ROUND);

        SwapLotteryHook.RoundState memory s = hook.roundState(poolId, START_ROUND);
        assertEq(uint8(s.status), uint8(SwapLotteryHook.Status.Drawn));
        assertEq(s.winner, expected);
        assertEq(hook.winnings(expected), potSize);
        assertEq(hook.totalOwed(), potSize);
        assertSolvent();
    }

    function test_draw_atTargetPlus256StillDraws() public {
        buyExactIn(alice, 1 ether);
        nextRound();
        hook.seal(key, START_ROUND);
        uint256 target = hook.roundState(poolId, START_ROUND).targetBlock;
        vm.roll(target + 256);
        assertTrue(blockhash(target) != bytes32(0), "hash still available");
        hook.draw(key, START_ROUND);
        SwapLotteryHook.RoundState memory s = hook.roundState(poolId, START_ROUND);
        assertEq(uint8(s.status), uint8(SwapLotteryHook.Status.Drawn));
        assertEq(s.winner, alice);
        assertEq(hook.winnings(alice), fee(1 ether));
    }

    function test_draw_atTargetPlus257RollsOverInsteadOfUsingAZeroHash() public {
        buyExactIn(alice, 1 ether);
        uint256 potSize = hook.pot(poolId, START_ROUND);
        nextRound();
        hook.seal(key, START_ROUND);
        uint256 target = hook.roundState(poolId, START_ROUND).targetBlock;
        vm.roll(target + 257);
        assertEq(blockhash(target), bytes32(0), "hash is gone");
        uint256 current = hook.currentRound();

        vm.expectEmit(true, true, true, true, address(hook));
        emit SwapLotteryHook.RolledOver(poolId, START_ROUND, current, potSize);
        hook.draw(key, START_ROUND);

        SwapLotteryHook.RoundState memory s = hook.roundState(poolId, START_ROUND);
        assertEq(uint8(s.status), uint8(SwapLotteryHook.Status.RolledOver));
        assertEq(s.rolledInto, current);
        assertEq(s.winner, address(0));
        assertEq(hook.winnings(alice), 0);
        assertEq(hook.pot(poolId, current), potSize);
        assertEq(hook.totalOwed(), potSize, "nothing was lost");
        assertSolvent();
    }

    function test_draw_emptyRoundRollsThePotIntoTheCurrentRound() public {
        // Fee but no ticket.
        buyExactIn(alice, 0.0005 ether);
        uint256 potSize = hook.pot(poolId, START_ROUND);
        assertGt(potSize, 0);
        assertEq(hook.ticketCount(poolId, START_ROUND), 0);

        nextRound();
        nextRound(); // draw happens two rounds later; the pot goes to the round current *at the draw*
        hook.seal(key, START_ROUND);
        vm.roll(block.number + 2); // past targetBlock = sealBlock + 1
        uint256 current = hook.currentRound();
        assertEq(current, START_ROUND + 2);

        vm.expectEmit(true, true, true, true, address(hook));
        emit SwapLotteryHook.RolledOver(poolId, START_ROUND, current, potSize);
        hook.draw(key, START_ROUND);

        assertEq(hook.pot(poolId, current), potSize);
        assertEq(hook.pot(poolId, START_ROUND + 1), 0);
        assertSolvent();
    }

    function test_draw_emptyRoundWithZeroPotFinishesCleanly() public {
        nextRound();
        hook.seal(key, START_ROUND);
        vm.roll(block.number + 2); // past targetBlock = sealBlock + 1
        hook.draw(key, START_ROUND);
        assertEq(uint8(hook.roundState(poolId, START_ROUND).status), uint8(SwapLotteryHook.Status.RolledOver));
        assertEq(hook.totalOwed(), 0);
    }

    function test_draw_exactlyOnce() public {
        buyExactIn(alice, 1 ether);
        nextRound();
        hook.seal(key, START_ROUND);
        vm.roll(block.number + 2); // past targetBlock = sealBlock + 1
        hook.draw(key, START_ROUND);
        vm.expectRevert(
            abi.encodeWithSelector(SwapLotteryHook.RoundNotSealed.selector, START_ROUND, SwapLotteryHook.Status.Drawn)
        );
        hook.draw(key, START_ROUND);
        assertEq(hook.winnings(alice), fee(1 ether), "credited once");
    }

    function test_rollover_exactlyOnceAndThenPaidToOneWinner() public {
        buyExactIn(alice, 0.0005 ether); // pot, no ticket
        uint256 pot0 = hook.pot(poolId, START_ROUND);
        nextRound();
        hook.seal(key, START_ROUND);
        vm.roll(block.number + 2); // past targetBlock = sealBlock + 1
        hook.draw(key, START_ROUND);
        vm.expectRevert(
            abi.encodeWithSelector(
                SwapLotteryHook.RoundNotSealed.selector, START_ROUND, SwapLotteryHook.Status.RolledOver
            )
        );
        hook.draw(key, START_ROUND);

        uint256 r1 = START_ROUND + 1;
        assertEq(hook.pot(poolId, r1), pot0);
        buyExactIn(bob, 1 ether);
        assertEq(hook.pot(poolId, r1), pot0 + fee(1 ether));

        nextRound();
        hook.seal(key, r1);
        vm.roll(block.number + 2); // past targetBlock = sealBlock + 1
        hook.draw(key, r1);
        assertEq(hook.winnings(bob), pot0 + fee(1 ether), "the rolled pot was paid with the new one");
        assertEq(hook.totalOwed(), pot0 + fee(1 ether));
        assertSolvent();
    }

    function test_rollover_chainsAcrossSeveralEmptyRounds() public {
        buyExactIn(alice, 0.0005 ether);
        uint256 pot0 = hook.pot(poolId, START_ROUND);
        for (uint256 i = 0; i < 3; i++) {
            nextRound();
            hook.seal(key, START_ROUND + i);
            vm.roll(block.number + 2); // past targetBlock = sealBlock + 1
            hook.draw(key, START_ROUND + i);
            assertEq(hook.pot(poolId, START_ROUND + i + 1), pot0);
        }
        assertEq(hook.totalOwed(), pot0);
        assertSolvent();
    }

    function test_draw_winnerSelectionFollowsTicketWeights() public {
        // Alice holds 9 of 10 tickets; over many independent rounds she should win most of them.
        uint256 aliceWins;
        for (uint256 r = 0; r < 20; r++) {
            for (uint256 i = 0; i < 9; i++) {
                buyExactIn(alice, 0.01 ether);
            }
            buyExactIn(bob, 0.01 ether);
            uint256 round = hook.currentRound();
            nextRound();
            hook.seal(key, round);
            vm.roll(block.number + 2); // past targetBlock = sealBlock + 1
            hook.draw(key, round);
            if (hook.roundState(poolId, round).winner == alice) aliceWins++;
        }
        assertGt(aliceWins, 10);
        assertSolvent();
    }

    // ── claim ──────────────────────────────────────────────────────────────────────────────────

    function _winRound(address winner, uint256 ethIn) internal returns (uint256 potSize) {
        buyExactIn(winner, ethIn);
        uint256 round = hook.currentRound();
        potSize = hook.pot(poolId, round);
        nextRound();
        hook.seal(key, round);
        vm.roll(block.number + 2); // past targetBlock = sealBlock + 1
        hook.draw(key, round);
        assertEq(hook.roundState(poolId, round).winner, winner);
    }

    function test_claim_paysTheWinnerAndZeroesFirst() public {
        uint256 potSize = _winRound(alice, 4 ether);
        uint256 before = alice.balance;
        uint256 managerBefore = address(manager).balance;

        vm.expectEmit(true, true, true, true, address(hook));
        emit SwapLotteryHook.Claimed(alice, potSize);
        vm.prank(alice);
        hook.claim();

        assertEq(alice.balance - before, potSize);
        assertEq(managerBefore - address(manager).balance, potSize);
        assertEq(hook.winnings(alice), 0);
        assertEq(hook.totalOwed(), 0);
        assertEq(hookClaims(), 0);
        assertEq(address(hook).balance, 0);
        assertSolvent();

        vm.expectRevert(SwapLotteryHook.NothingToClaim.selector);
        vm.prank(alice);
        hook.claim();
    }

    function test_claim_nothingToClaimForNonWinners() public {
        _winRound(alice, 1 ether);
        vm.expectRevert(SwapLotteryHook.NothingToClaim.selector);
        vm.prank(bob);
        hook.claim();
    }

    function test_claim_accumulatesAcrossRounds() public {
        uint256 p1 = _winRound(alice, 1 ether);
        uint256 p2 = _winRound(alice, 2 ether);
        assertEq(hook.winnings(alice), p1 + p2);
        uint256 before = alice.balance;
        vm.prank(alice);
        hook.claim();
        assertEq(alice.balance - before, p1 + p2);
        assertSolvent();
    }

    function test_claim_reentrancyCannotPayTwice() public {
        ReentrantWinner attacker = new ReentrantWinner(hook);
        vm.deal(address(attacker), 10 ether);
        // The attacker swaps with hookData naming itself.
        swapAs(address(attacker), true, -int256(2 ether), abi.encode(address(attacker)), 2 ether);
        uint256 round = hook.currentRound();
        uint256 potSize = hook.pot(poolId, round);
        nextRound();
        hook.seal(key, round);
        vm.roll(block.number + 2); // past targetBlock = sealBlock + 1
        hook.draw(key, round);
        assertEq(hook.winnings(address(attacker)), potSize);

        attacker.claim();

        assertEq(attacker.received(), potSize, "paid exactly once");
        assertGe(attacker.reentries(), 1, "the receive hook did run");
        assertEq(hook.winnings(address(attacker)), 0);
        assertEq(hook.totalOwed(), 0);
        assertSolvent();
    }

    function test_claim_settlementFailureLeavesWinningsIntact() public {
        RejectingWinner winner = new RejectingWinner(hook);
        vm.deal(address(winner), 10 ether);
        swapAs(address(winner), true, -int256(2 ether), abi.encode(address(winner)), 2 ether);
        uint256 round = hook.currentRound();
        uint256 potSize = hook.pot(poolId, round);
        nextRound();
        hook.seal(key, round);
        vm.roll(block.number + 2); // past targetBlock = sealBlock + 1
        hook.draw(key, round);

        vm.expectRevert();
        winner.claim();

        assertEq(hook.winnings(address(winner)), potSize, "the failed claim changed nothing");
        assertEq(hook.totalOwed(), potSize);
        assertSolvent();
    }

    // ── conservation ───────────────────────────────────────────────────────────────────────────

    function test_conservation_potsPlusWinningsEqualClaimsThroughALifecycle() public {
        // Round 0: three swappers.
        buyExactIn(alice, 1 ether);
        buyExactOut(bob, 2_000_000e18, 5 ether);
        sellExactIn(carol, 500_000e18);
        // Round 1: pot but nobody qualifies.
        nextRound();
        buyExactIn(alice, 0.0002 ether);
        // Round 2: seal + draw round 0 (winner), seal round 1 later.
        nextRound();
        hook.seal(key, START_ROUND);
        hook.seal(key, START_ROUND + 1);
        buyExactIn(bob, 3 ether);
        vm.roll(block.number + 2); // past targetBlock = sealBlock + 1
        hook.draw(key, START_ROUND);
        hook.draw(key, START_ROUND + 1); // no tickets: rolls into round 2
        _assertConserved(3);

        // Round 3: winner claims; round 2 drawn late (past the window) so it rolls into round 3.
        nextRound();
        address w0 = hook.roundState(poolId, START_ROUND).winner;
        vm.prank(w0);
        hook.claim();
        hook.seal(key, START_ROUND + 2);
        vm.roll(hook.roundState(poolId, START_ROUND + 2).targetBlock + 300);
        hook.draw(key, START_ROUND + 2);
        buyExactIn(carol, 0.5 ether);
        _assertConserved(4);

        // Round 4: draw round 3 and let everyone claim.
        nextRound();
        hook.seal(key, START_ROUND + 3);
        vm.roll(block.number + 2); // past targetBlock = sealBlock + 1
        hook.draw(key, START_ROUND + 3);
        _assertConserved(5);
        address w3 = hook.roundState(poolId, START_ROUND + 3).winner;
        vm.prank(w3);
        hook.claim();
        _assertConserved(5);
        assertEq(hook.totalOwed(), hook.pot(poolId, START_ROUND + 4), "only the open round remains");
    }

    function _assertConserved(uint256 roundsToScan) internal view {
        uint256 outstanding;
        for (uint256 i = 0; i < roundsToScan; i++) {
            SwapLotteryHook.RoundState memory s = hook.roundState(poolId, START_ROUND + i);
            if (s.status == SwapLotteryHook.Status.Open || s.status == SwapLotteryHook.Status.Sealed) {
                outstanding += s.pot;
            }
        }
        outstanding += hook.winnings(alice) + hook.winnings(bob) + hook.winnings(carol);
        assertEq(outstanding, hook.totalOwed(), "open pots + winnings != totalOwed");
        assertSolvent();
    }
}
