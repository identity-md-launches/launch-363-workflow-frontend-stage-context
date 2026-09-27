// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FactoryLaunchHarness} from "./utils/FactoryLaunchHarness.sol";
import {Ticket} from "../src/Ticket.sol";
import {SwapLotteryHook} from "../src/SwapLotteryHook.sol";
import {LaunchParams} from "../src/LaunchParams.sol";

contract FactoryLaunchTest is Test {
    using StateLibrary for IPoolManager;

    IPoolManager internal manager;
    PoolSwapTest internal router;
    FactoryLaunchHarness internal factory;
    Ticket internal token;
    SwapLotteryHook internal hook;
    PoolKey internal key;
    PoolId internal id;
    address internal buyer = makeAddr("factory rehearsal buyer");

    function setUp() public {
        vm.warp(1_800_000_000);
        vm.roll(10_000);
        manager = IPoolManager(address(new PoolManager(address(this))));
        factory = new FactoryLaunchHarness(manager);
        key = factory.launch();
        id = key.toId();
        hook = factory.hook();
        token = factory.token();
        router = new PoolSwapTest(manager);
        vm.deal(buyer, 100 ether);
    }

    function test_factoryOwnsSupplyAndPositionBeforeFirstBuyer() public view {
        assertEq(factory.supplyBeforeSeed(), 1_000_000_000 ether);
        BalanceDelta seed = factory.seedDelta();
        assertEq(seed.amount0(), 0);
        assertLt(seed.amount1(), 0);
        uint256 deposited = uint256(-int256(seed.amount1()));
        assertLe(deposited, 500_000_000 ether);
        assertEq(token.balanceOf(address(manager)), deposited);
        assertEq(token.balanceOf(address(factory)), token.totalSupply() - deposited);
        assertEq(token.balanceOf(buyer), 0);
        assertEq(address(manager).balance, 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        assertEq(hook.totalOwed(), 0);
        assertEq(uint160(address(hook)) & ((1 << 14) - 1), 0x00cc);
        assertEq(address(hook.poolManager()), address(manager));

        // Literal pins make changing the proposed launch price visible to this rehearsal.
        (uint160 price, int24 tick,,) = manager.getSlot0(id);
        assertEq(price, 250178251749461638198017379368160);
        assertEq(tick, 161160);
        assertEq(manager.getLiquidity(id), 0);
        (uint128 liquidity,,) = manager.getPositionInfo(id, address(factory), -887220, 161160, bytes32(0));
        assertEq(liquidity, LaunchParams.seedLiquidity());

        bytes32 codeHash = keccak256(abi.encodePacked(type(SwapLotteryHook).creationCode, abi.encode(manager)));
        address predicted = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), factory.salt(), codeHash))))
        );
        assertEq(address(hook), predicted);
    }

    function testFuzz_factoryFirstBuyAndPayout(uint256 amount) public {
        amount = bound(amount, 0.001 ether, 20 ether);
        uint256 round = vm.getBlockTimestamp() / 3600;
        uint256 buyerBefore = buyer.balance;
        uint256 expectedFee = amount * 50 / 10_000;
        assertEq(address(manager).balance, 0);
        vm.prank(buyer);
        BalanceDelta delta = router.swap{value: amount}(
            key,
            SwapParams(true, -int256(amount), TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            abi.encode(buyer)
        );
        assertEq(delta.amount0(), -int256(amount));
        assertGt(delta.amount1(), 0);
        assertEq(token.balanceOf(buyer), uint256(int256(delta.amount1())));
        assertEq(buyerBefore - buyer.balance, amount);
        assertEq(address(manager).balance, amount);
        assertEq(manager.balanceOf(address(hook), 0), expectedFee);
        assertEq(hook.pot(id, round), expectedFee);
        assertEq(hook.ticketsOf(id, round, buyer), 1);
        assertEq(hook.ticketsOf(id, round, address(factory)), 0);
        assertEq(hook.ticketsOf(id, round, address(router)), 0);
        assertGt(manager.getLiquidity(id), 0);

        vm.warp((round + 1) * 3600);
        hook.seal(key, round);
        vm.roll(hook.roundState(id, round).targetBlock + 1);
        hook.draw(key, round);
        assertEq(hook.winnings(buyer), expectedFee);
        vm.prank(buyer);
        hook.claim();
        assertEq(buyer.balance, buyerBefore - amount + expectedFee);
        assertEq(address(manager).balance, amount - expectedFee);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        assertEq(hook.totalOwed(), 0);
        assertEq(hook.winnings(buyer), 0);
        assertEq(address(hook).balance, 0);
        vm.expectRevert(SwapLotteryHook.NothingToClaim.selector);
        vm.prank(buyer);
        hook.claim();
    }
}
