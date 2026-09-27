// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

import {LotteryTestBase} from "./utils/LotteryTestBase.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {SwapLotteryHook} from "../src/SwapLotteryHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {HookMiner} from "../src/HookMiner.sol";
import {LaunchParams} from "../src/LaunchParams.sol";

/// @notice The launch, step by step, the way the factory performs it on Sepolia.
contract LaunchRehearsalTest is LotteryTestBase {
    using StateLibrary for IPoolManager;

    function test_rehearsal_initializeSeedAndFirstBuyIntoAnEthLessPool() public {
        // 1. The factory holds the whole supply after deploying the token.
        assertEq(token.balanceOf(address(this)), token.TOTAL_SUPPLY() - 3 * 10_000_000e18);

        // 2. The hook sits at an address carrying exactly the 0x00CC bits.
        assertEq(HookFlags.flagsOf(address(hook)), 0x00CC);
        assertEq(address(hook.poolManager()), address(manager));

        // 3. Initialize at the manifest price. The hook has no initialize permission, so it cannot revert.
        int24 tick = openPool();
        assertEq(tick, LaunchParams.INITIAL_TICK);
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(poolId);
        assertEq(sqrtPriceX96, LaunchParams.initialSqrtPriceX96());

        // 4. Seed one-sided TIKT liquidity: the pool takes TIKT only and holds no ETH.
        BalanceDelta seed = seedPool();
        assertEq(seed.amount0(), 0, "seed must not require ETH");
        assertLt(seed.amount1(), 0, "seed must deposit TIKT");
        assertLe(uint256(uint128(-seed.amount1())), LaunchParams.SEED_TIKT);
        assertEq(address(manager).balance, 0, "pool holds no ETH before the first buy");
        // The position is entirely below the current tick, so it is not active yet ...
        assertEq(manager.getLiquidity(poolId), 0, "no liquidity is active at the initial price");
        // ... but it exists, and the first buy walks the price down into it.
        (uint128 positionLiquidity,,) = manager.getPositionInfo(
            poolId, address(lpRouter), LaunchParams.SEED_TICK_LOWER, LaunchParams.SEED_TICK_UPPER, bytes32(0)
        );
        assertEq(positionLiquidity, LaunchParams.seedLiquidity());

        // 5. The first buy lands in a pool with no ETH. The fee is settled as claims, never taken.
        uint256 ethIn = 1 ether;
        uint256 aliceTiktBefore = token.balanceOf(alice);
        BalanceDelta delta = buyExactIn(alice, ethIn);

        assertEq(delta.amount0(), -int256(ethIn), "swapper paid exactly what was specified");
        assertGt(delta.amount1(), 0, "swapper received TIKT");
        assertEq(token.balanceOf(alice) - aliceTiktBefore, uint256(uint128(delta.amount1())));
        assertEq(alice.balance, 1_000 ether - ethIn);

        uint256 expectedFee = fee(ethIn);
        assertEq(hookClaims(), expectedFee, "fee held as ERC-6909 ETH claims");
        assertEq(hook.pot(poolId, START_ROUND), expectedFee);
        assertEq(hook.ticketCount(poolId, START_ROUND), 1);
        assertEq(hook.ticketsOf(poolId, START_ROUND, alice), 1);
        assertEq(address(hook).balance, 0, "the hook never holds ETH itself");
        assertEq(address(manager).balance, ethIn);
        assertGt(manager.getLiquidity(poolId), 0, "the buy moved the price into the seeded range");
        assertLt(currentTick(), LaunchParams.INITIAL_TICK);
        assertSolvent();
    }

    function test_rehearsal_deployScriptProducesTheSameShape() public {
        Deploy script = new Deploy();
        Deploy.Deployment memory d = script.deploy(manager, address(script));

        assertEq(d.token.totalSupply(), 1_000_000_000e18);
        assertEq(d.token.balanceOf(address(script)), 1_000_000_000e18, "token mints to its deployer");
        assertEq(HookFlags.flagsOf(address(d.hook)), HookFlags.SWAP_LOTTERY);
        assertEq(address(d.hook.poolManager()), address(manager));

        bytes memory creationCode = abi.encodePacked(type(SwapLotteryHook).creationCode, abi.encode(address(manager)));
        assertEq(address(d.hook), HookMiner.computeAddress(address(script), d.hookSalt, keccak256(creationCode)));
    }

    function test_rehearsal_seedLiquidityFitsTheBudget() public pure {
        uint128 liquidity = LaunchParams.seedLiquidity();
        assertGt(liquidity, 0);
        // A position with tickUpper == current tick holds only currency1.
        assertEq(LaunchParams.SEED_TICK_UPPER, LaunchParams.INITIAL_TICK);
        assertEq(LaunchParams.SEED_TICK_LOWER, TickMath.minUsableTick(LaunchParams.TICK_SPACING));
    }

    function test_rehearsal_secondBuyAndFirstSellWorkAfterLaunch() public {
        launch();
        buyExactIn(alice, 5 ether);
        buyExactOut(bob, 1_000_000e18, 5 ether);
        sellExactIn(alice, 1_000_000e18);
        sellExactOut(bob, 0.1 ether);
        assertEq(hook.ticketCount(poolId, START_ROUND), 4);
        assertSolvent();
    }
}
