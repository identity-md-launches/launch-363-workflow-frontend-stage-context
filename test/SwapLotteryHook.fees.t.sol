// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

import {LotteryTestBase} from "./utils/LotteryTestBase.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {SwapLotteryHook} from "../src/SwapLotteryHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {HookMiner} from "../src/HookMiner.sol";
import {LaunchParams} from "../src/LaunchParams.sol";

/// @notice Permissions, access control, the four swap modes, dust, partial fills and non-ETH pools.
contract SwapLotteryHookFeesTest is LotteryTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function setUp() public override {
        super.setUp();
        launch();
    }

    // ── permissions ────────────────────────────────────────────────────────────────────────────

    function test_permissions_exactlyTheFourSwapFlags() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeSwap);
        assertTrue(p.afterSwap);
        assertTrue(p.beforeSwapReturnDelta);
        assertTrue(p.afterSwapReturnDelta);
        assertFalse(p.beforeInitialize);
        assertFalse(p.afterInitialize);
        assertFalse(p.beforeAddLiquidity);
        assertFalse(p.afterAddLiquidity);
        assertFalse(p.beforeRemoveLiquidity);
        assertFalse(p.afterRemoveLiquidity);
        assertFalse(p.beforeDonate);
        assertFalse(p.afterDonate);
        assertFalse(p.afterAddLiquidityReturnDelta);
        assertFalse(p.afterRemoveLiquidityReturnDelta);
        assertEq(HookFlags.SWAP_LOTTERY, 0x00CC);
        assertEq(HookFlags.flagsOf(address(hook)), 0x00CC);
        assertTrue(HookFlags.matches(address(hook), HookFlags.SWAP_LOTTERY));
    }

    function test_permissions_constructorRejectsAnAddressWithTheWrongBits() public {
        bytes memory creationCode = abi.encodePacked(type(SwapLotteryHook).creationCode, abi.encode(address(manager)));
        // Missing the return-delta bits.
        uint160 wrongFlags = HookFlags.BEFORE_SWAP | HookFlags.AFTER_SWAP;
        (address predicted, bytes32 salt) = HookMiner.find(address(this), wrongFlags, creationCode);
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new SwapLotteryHook{salt: salt}(manager);
    }

    function test_permissions_constructorRejectsExtraBits() public {
        bytes memory creationCode = abi.encodePacked(type(SwapLotteryHook).creationCode, abi.encode(address(manager)));
        uint160 wrongFlags = HookFlags.SWAP_LOTTERY | HookFlags.BEFORE_INITIALIZE;
        (address predicted, bytes32 salt) = HookMiner.find(address(this), wrongFlags, creationCode);
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new SwapLotteryHook{salt: salt}(manager);
    }

    // ── access control ─────────────────────────────────────────────────────────────────────────

    function test_callbacks_refuseCallersOtherThanThePoolManager() public {
        SwapParams memory params = SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1);
        bytes memory data = abi.encode(alice);

        vm.expectRevert(SwapLotteryHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, params, data);

        vm.expectRevert(SwapLotteryHook.NotPoolManager.selector);
        hook.afterSwap(address(this), key, params, toBalanceDelta(-1 ether, 1 ether), data);

        vm.expectRevert(SwapLotteryHook.NotPoolManager.selector);
        hook.unlockCallback(abi.encode(alice, 1 ether));

        // A prank as the manager is accepted by the modifier (and the view returns a delta).
        vm.prank(address(manager));
        (bytes4 sel,,) = hook.beforeSwap(address(this), key, params, data);
        assertEq(sel, IHooks.beforeSwap.selector);
    }

    function test_callbacks_unusedOnesRevertEvenFromThePoolManager() public {
        ModifyLiquidityParams memory lp = ModifyLiquidityParams(-60, 60, 1 ether, bytes32(0));
        vm.startPrank(address(manager));
        vm.expectRevert(SwapLotteryHook.HookNotImplemented.selector);
        hook.beforeInitialize(address(this), key, 0);
        vm.expectRevert(SwapLotteryHook.HookNotImplemented.selector);
        hook.afterInitialize(address(this), key, 0, 0);
        vm.expectRevert(SwapLotteryHook.HookNotImplemented.selector);
        hook.beforeAddLiquidity(address(this), key, lp, "");
        vm.expectRevert(SwapLotteryHook.HookNotImplemented.selector);
        hook.afterAddLiquidity(address(this), key, lp, toBalanceDelta(0, 0), toBalanceDelta(0, 0), "");
        vm.expectRevert(SwapLotteryHook.HookNotImplemented.selector);
        hook.beforeRemoveLiquidity(address(this), key, lp, "");
        vm.expectRevert(SwapLotteryHook.HookNotImplemented.selector);
        hook.afterRemoveLiquidity(address(this), key, lp, toBalanceDelta(0, 0), toBalanceDelta(0, 0), "");
        vm.expectRevert(SwapLotteryHook.HookNotImplemented.selector);
        hook.beforeDonate(address(this), key, 0, 0, "");
        vm.expectRevert(SwapLotteryHook.HookNotImplemented.selector);
        hook.afterDonate(address(this), key, 0, 0, "");
        vm.stopPrank();
    }

    function test_noAdminSurface() public {
        string[8] memory signatures = [
            "owner()",
            "setFee(uint256)",
            "pause()",
            "unpause()",
            "sweep(address)",
            "withdraw(uint256)",
            "upgradeTo(address)",
            "transferOwnership(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            (bool ok,) = address(hook).call(abi.encodeWithSignature(signatures[i], address(this), uint256(1)));
            assertFalse(ok, signatures[i]);
        }
    }

    // ── the four swap modes ────────────────────────────────────────────────────────────────────

    function test_exactInBuy_feeIsSpecifiedDeltaAndSwapperPaysExactlyTheInput() public {
        uint256 ethIn = 2 ether;
        uint256 ethBefore = alice.balance;
        uint256 tiktBefore = token.balanceOf(alice);

        vm.recordLogs();
        BalanceDelta delta = buyExactIn(alice, ethIn);
        (int128 poolAmount0,) = lastPoolSwap(vm.getRecordedLogs());

        uint256 expectedFee = fee(ethIn);
        assertEq(ethBefore - alice.balance, ethIn, "paid exactly the specified input");
        assertEq(delta.amount0(), -int256(ethIn));
        assertEq(uint256(-int256(poolAmount0)), ethIn - expectedFee, "pool swapped the input net of the fee");
        assertEq(token.balanceOf(alice) - tiktBefore, uint256(uint128(delta.amount1())));
        assertEq(hookClaims(), expectedFee);
        assertEq(hook.pot(poolId, START_ROUND), expectedFee);
        assertSolvent();
    }

    function test_exactOutBuy_feeIsUnspecifiedDeltaAndSwapperGetsExactlyTheOutput() public {
        uint256 tiktOut = 3_000_000e18;
        uint256 ethBefore = bob.balance;
        uint256 tiktBefore = token.balanceOf(bob);

        vm.recordLogs();
        BalanceDelta delta = buyExactOut(bob, tiktOut, 10 ether);
        (int128 poolAmount0,) = lastPoolSwap(vm.getRecordedLogs());

        uint256 ethMoved = uint256(-int256(poolAmount0));
        uint256 expectedFee = fee(ethMoved);
        assertGt(expectedFee, 0);
        assertEq(token.balanceOf(bob) - tiktBefore, tiktOut, "received exactly the specified output");
        assertEq(delta.amount1(), int256(tiktOut));
        assertEq(uint256(-int256(delta.amount0())), ethMoved + expectedFee, "paid the pool's ETH plus the fee");
        assertEq(ethBefore - bob.balance, ethMoved + expectedFee, "router refunded the rest");
        assertEq(hookClaims(), expectedFee);
        assertEq(hook.pot(poolId, START_ROUND), expectedFee);
        assertSolvent();
    }

    function test_exactInSell_feeIsUnspecifiedDeltaAndSwapperPaysExactlyTheInput() public {
        buyExactIn(alice, 10 ether); // put ETH in the pool
        uint256 potBefore = hook.pot(poolId, START_ROUND);

        uint256 tiktIn = 2_000_000e18;
        uint256 ethBefore = bob.balance;
        uint256 tiktBefore = token.balanceOf(bob);

        vm.recordLogs();
        BalanceDelta delta = sellExactIn(bob, tiktIn);
        (int128 poolAmount0,) = lastPoolSwap(vm.getRecordedLogs());

        uint256 ethMoved = uint256(int256(poolAmount0));
        uint256 expectedFee = fee(ethMoved);
        assertGt(expectedFee, 0);
        assertEq(tiktBefore - token.balanceOf(bob), tiktIn, "paid exactly the specified input");
        assertEq(delta.amount1(), -int256(tiktIn));
        assertEq(uint256(int256(delta.amount0())), ethMoved - expectedFee, "received the pool's ETH minus the fee");
        assertEq(bob.balance - ethBefore, ethMoved - expectedFee);
        assertEq(hook.pot(poolId, START_ROUND) - potBefore, expectedFee);
        assertSolvent();
    }

    function test_exactOutSell_feeIsSpecifiedDeltaAndSwapperGetsExactlyTheOutput() public {
        buyExactIn(alice, 10 ether);
        uint256 potBefore = hook.pot(poolId, START_ROUND);

        uint256 ethOut = 1 ether;
        uint256 ethBefore = bob.balance;
        uint256 tiktBefore = token.balanceOf(bob);

        vm.recordLogs();
        BalanceDelta delta = sellExactOut(bob, ethOut);
        (int128 poolAmount0,) = lastPoolSwap(vm.getRecordedLogs());

        uint256 expectedFee = fee(ethOut);
        assertEq(bob.balance - ethBefore, ethOut, "received exactly the specified output");
        assertEq(delta.amount0(), int256(ethOut));
        assertEq(uint256(int256(poolAmount0)), ethOut + expectedFee, "pool paid the output plus the fee");
        assertEq(tiktBefore - token.balanceOf(bob), uint256(-int256(delta.amount1())));
        assertEq(hook.pot(poolId, START_ROUND) - potBefore, expectedFee);
        assertSolvent();
    }

    // ── dust ───────────────────────────────────────────────────────────────────────────────────

    function test_dust_feeRoundsToZeroWithoutReverting() public {
        // 199 wei * 50 / 10_000 == 0
        BalanceDelta delta = buyExactIn(alice, 199);
        assertEq(delta.amount0(), -199);
        assertEq(hookClaims(), 0);
        assertEq(hook.pot(poolId, START_ROUND), 0);
        assertEq(hook.ticketCount(poolId, START_ROUND), 0, "dust earns no ticket");

        // 200 wei is the smallest input that pays 1 wei.
        buyExactIn(alice, 200);
        assertEq(hookClaims(), 1);
        assertEq(hook.pot(poolId, START_ROUND), 1);
        assertSolvent();
    }

    function test_dust_exactInSellOfOneWeiTikt() public {
        buyExactIn(alice, 1 ether);
        BalanceDelta delta = sellExactIn(bob, 1);
        assertEq(delta.amount1(), -1);
        assertEq(hook.pot(poolId, START_ROUND), fee(1 ether), "no fee on a zero ETH leg");
        assertSolvent();
    }

    function test_dust_exactOutBuyOfOneWeiTikt() public {
        BalanceDelta delta = buyExactOut(alice, 1, 1 ether);
        assertEq(delta.amount1(), 1);
        assertEq(hook.pot(poolId, START_ROUND), 0);
        assertEq(hook.ticketCount(poolId, START_ROUND), 0);
        assertSolvent();
    }

    // ── partial fills ──────────────────────────────────────────────────────────────────────────

    function test_partialFill_exactInBuyHittingThePriceLimitReverts() public {
        uint160 limit = TickMath.getSqrtPriceAtTick(LaunchParams.INITIAL_TICK - 60);
        vm.expectRevert(
            hookRevert(IHooks.afterSwap.selector, abi.encodeWithSelector(SwapLotteryHook.PartialFill.selector))
        );
        swapAs(alice, true, -int256(100 ether), limit, abi.encode(alice), 100 ether);
    }

    function test_partialFill_exactOutBuyHittingThePriceLimitReverts() public {
        uint160 limit = TickMath.getSqrtPriceAtTick(LaunchParams.INITIAL_TICK - 60);
        vm.expectRevert(
            hookRevert(IHooks.afterSwap.selector, abi.encodeWithSelector(SwapLotteryHook.PartialFill.selector))
        );
        swapAs(alice, true, int256(100_000_000e18), limit, abi.encode(alice), 500 ether);
    }

    function test_partialFill_sellBeyondThePoolsEthReverts() public {
        buyExactIn(alice, 1 ether);
        // The pool holds ~1 ETH; asking for 5 ETH out runs off the top of the seeded range.
        vm.expectRevert(
            hookRevert(IHooks.afterSwap.selector, abi.encodeWithSelector(SwapLotteryHook.PartialFill.selector))
        );
        sellExactOut(bob, 5 ether);

        vm.expectRevert(
            hookRevert(IHooks.afterSwap.selector, abi.encodeWithSelector(SwapLotteryHook.PartialFill.selector))
        );
        swapAs(
            bob,
            false,
            -int256(10_000_000e18),
            TickMath.getSqrtPriceAtTick(LaunchParams.INITIAL_TICK - 30),
            abi.encode(bob),
            0
        );
    }

    // ── fuzzed sizes ───────────────────────────────────────────────────────────────────────────

    function testFuzz_exactInBuy(uint256 ethIn) public {
        ethIn = bound(ethIn, 1, 500 ether);
        BalanceDelta delta = buyExactIn(alice, ethIn);
        uint256 expectedFee = fee(ethIn);
        assertEq(delta.amount0(), -int256(ethIn));
        assertEq(hookClaims(), expectedFee);
        assertEq(hook.pot(poolId, START_ROUND), expectedFee);
        assertEq(hook.ticketCount(poolId, START_ROUND), ethIn >= 0.001 ether ? 1 : 0);
        assertSolvent();
    }

    function testFuzz_exactOutBuy(uint256 tiktOut) public {
        tiktOut = bound(tiktOut, 1, 100_000_000e18);
        vm.recordLogs();
        BalanceDelta delta = buyExactOut(alice, tiktOut, 900 ether);
        (int128 poolAmount0,) = lastPoolSwap(vm.getRecordedLogs());
        uint256 ethMoved = uint256(-int256(poolAmount0));
        uint256 expectedFee = fee(ethMoved);
        assertEq(delta.amount1(), int256(tiktOut));
        assertEq(uint256(-int256(delta.amount0())), ethMoved + expectedFee);
        assertEq(hookClaims(), expectedFee);
        assertEq(hook.ticketCount(poolId, START_ROUND), ethMoved >= 0.001 ether ? 1 : 0);
        assertSolvent();
    }

    function testFuzz_exactInSell(uint256 tiktIn) public {
        buyExactIn(alice, 50 ether);
        uint256 potBefore = hook.pot(poolId, START_ROUND);
        tiktIn = bound(tiktIn, 1, 10_000_000e18);
        vm.recordLogs();
        BalanceDelta delta = sellExactIn(bob, tiktIn);
        (int128 poolAmount0,) = lastPoolSwap(vm.getRecordedLogs());
        uint256 ethMoved = uint256(int256(poolAmount0));
        uint256 expectedFee = fee(ethMoved);
        assertEq(delta.amount1(), -int256(tiktIn));
        assertEq(uint256(int256(delta.amount0())), ethMoved - expectedFee);
        assertEq(hook.pot(poolId, START_ROUND) - potBefore, expectedFee);
        assertSolvent();
    }

    function testFuzz_exactOutSell(uint256 ethOut) public {
        buyExactIn(alice, 50 ether);
        uint256 potBefore = hook.pot(poolId, START_ROUND);
        ethOut = bound(ethOut, 1, 3 ether);
        uint256 before = bob.balance;
        BalanceDelta delta = sellExactOut(bob, ethOut);
        assertEq(delta.amount0(), int256(ethOut));
        assertEq(bob.balance - before, ethOut);
        assertEq(hook.pot(poolId, START_ROUND) - potBefore, fee(ethOut));
        assertSolvent();
    }

    // ── a pool whose currency0 is not ETH ──────────────────────────────────────────────────────

    function test_nonEthPool_zeroDeltasAndNoEffect() public {
        MockERC20 a = new MockERC20("A", "A", 1_000_000 ether);
        MockERC20 b = new MockERC20("B", "B", 1_000_000 ether);
        (MockERC20 t0, MockERC20 t1) = address(a) < address(b) ? (a, b) : (b, a);
        PoolKey memory erc20Key = PoolKey({
            currency0: Currency.wrap(address(t0)),
            currency1: Currency.wrap(address(t1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        PoolId erc20Id = erc20Key.toId();
        manager.initialize(erc20Key, TickMath.getSqrtPriceAtTick(0));
        t0.approve(address(lpRouter), type(uint256).max);
        t1.approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity(erc20Key, ModifyLiquidityParams(-600, 600, 1_000 ether, bytes32(0)), "");

        t0.transfer(alice, 10 ether);
        vm.startPrank(alice);
        t0.approve(address(swapRouter), type(uint256).max);
        BalanceDelta delta = swapRouter.swap(
            erc20Key,
            SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            abi.encode(alice)
        );
        vm.stopPrank();

        assertEq(delta.amount0(), -1 ether, "no fee was charged");
        assertEq(manager.balanceOf(address(hook), uint256(uint160(address(t0)))), 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        assertEq(hook.pot(erc20Id, START_ROUND), 0);
        assertEq(hook.ticketCount(erc20Id, START_ROUND), 0);
        assertEq(hook.ticketsOf(erc20Id, START_ROUND, alice), 0);
        assertEq(hook.totalOwed(), 0);

        nextRound();
        vm.expectRevert(SwapLotteryHook.NotEthPool.selector);
        hook.seal(erc20Key, START_ROUND);
    }

    // ── gas ────────────────────────────────────────────────────────────────────────────────────

    function test_gas_ticketPushStaysBoundedAsTheRoundGrows() public {
        uint256 first = gasleft();
        buyExactIn(alice, 0.01 ether);
        first -= gasleft();
        for (uint256 i = 0; i < 50; i++) {
            buyExactIn(bob, 0.01 ether);
        }
        uint256 later = gasleft();
        buyExactIn(alice, 0.01 ether);
        later -= gasleft();
        // Pushing the 52nd ticket costs no more than the 1st plus a small margin: no per-ticket loops.
        assertLe(later, first + 10_000);
    }
}
