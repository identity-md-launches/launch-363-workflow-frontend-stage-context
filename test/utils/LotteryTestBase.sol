// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";

import {Ticket} from "../../src/Ticket.sol";
import {SwapLotteryHook} from "../../src/SwapLotteryHook.sol";
import {HookFlags} from "../../src/HookFlags.sol";
import {HookMiner} from "../../src/HookMiner.sol";
import {LaunchParams} from "../../src/LaunchParams.sol";

/// @notice Shared fixture: a real v4-core PoolManager, the TIKT token, the hook at a mined address and
/// the same PoolSwapTest / PoolModifyLiquidityTest routers the launch uses.
/// @dev The pool is NOT opened in `setUp`; tests call `launch()` so the rehearsal can observe each step.
abstract contract LotteryTestBase is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @dev 1_800_000_000 is an exact multiple of 3600, so the fixture starts on a round boundary.
    uint256 internal constant START_TIMESTAMP = 1_800_000_000;
    uint256 internal constant START_BLOCK = 10_000;
    uint256 internal constant START_ROUND = START_TIMESTAMP / 3600;

    uint256 internal constant FEE_BPS = 50;
    uint256 internal constant BPS = 10_000;

    IPoolManager internal manager;
    Ticket internal token;
    SwapLotteryHook internal hook;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal lpRouter;

    PoolKey internal key;
    PoolId internal poolId;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    bytes32 internal constant SWAP_EVENT_SIG =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    function setUp() public virtual {
        vm.warp(START_TIMESTAMP);
        vm.roll(START_BLOCK);

        manager = IPoolManager(address(new PoolManager(address(this))));
        token = new Ticket();
        hook = deployHook(manager);
        swapRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);

        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: LaunchParams.POOL_FEE,
            tickSpacing: LaunchParams.TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        poolId = key.toId();

        token.approve(address(lpRouter), type(uint256).max);

        address[3] memory users = [alice, bob, carol];
        for (uint256 i = 0; i < users.length; i++) {
            vm.deal(users[i], 1_000 ether);
            token.transfer(users[i], 10_000_000e18);
            vm.prank(users[i]);
            token.approve(address(swapRouter), type(uint256).max);
        }
    }

    // ── deployment ─────────────────────────────────────────────────────────────────────────────

    /// @dev Mines a CREATE2 salt for the 0x00CC bits and deploys, exactly as the factory must.
    function deployHook(IPoolManager pm) internal returns (SwapLotteryHook deployed) {
        bytes memory creationCode = abi.encodePacked(type(SwapLotteryHook).creationCode, abi.encode(address(pm)));
        (address predicted, bytes32 salt) = HookMiner.find(address(this), HookFlags.SWAP_LOTTERY, creationCode);
        deployed = new SwapLotteryHook{salt: salt}(pm);
        assertEq(address(deployed), predicted, "mined address mismatch");
    }

    // ── launch steps, mirroring the factory ────────────────────────────────────────────────────

    function openPool() internal returns (int24 tick) {
        tick = manager.initialize(key, LaunchParams.initialSqrtPriceX96());
    }

    function seedPool() internal returns (BalanceDelta delta) {
        delta = lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: LaunchParams.SEED_TICK_LOWER,
                tickUpper: LaunchParams.SEED_TICK_UPPER,
                liquidityDelta: int256(uint256(LaunchParams.seedLiquidity())),
                salt: bytes32(0)
            }),
            ""
        );
    }

    function launch() internal {
        openPool();
        seedPool();
    }

    // ── swaps ──────────────────────────────────────────────────────────────────────────────────

    function swapAs(address user, bool zeroForOne, int256 amountSpecified, bytes memory hookData, uint256 value)
        internal
        returns (BalanceDelta delta)
    {
        return swapAs(
            user,
            zeroForOne,
            amountSpecified,
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
            hookData,
            value
        );
    }

    function swapAs(
        address user,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes memory hookData,
        uint256 value
    ) internal returns (BalanceDelta delta) {
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: sqrtPriceLimitX96
        });
        vm.prank(user);
        delta = swapRouter.swap{value: value}(
            key, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), hookData
        );
    }

    /// @dev Exact-in buy: ETH specified.
    function buyExactIn(address user, uint256 ethIn) internal returns (BalanceDelta) {
        return swapAs(user, true, -int256(ethIn), abi.encode(user), ethIn);
    }

    /// @dev Exact-out buy: TIKT specified, ETH unspecified. Leftover ETH is refunded by the router.
    function buyExactOut(address user, uint256 tiktOut, uint256 maxEth) internal returns (BalanceDelta) {
        return swapAs(user, true, int256(tiktOut), abi.encode(user), maxEth);
    }

    /// @dev Exact-in sell: TIKT specified, ETH unspecified.
    function sellExactIn(address user, uint256 tiktIn) internal returns (BalanceDelta) {
        return swapAs(user, false, -int256(tiktIn), abi.encode(user), 0);
    }

    /// @dev Exact-out sell: ETH specified.
    function sellExactOut(address user, uint256 ethOut) internal returns (BalanceDelta) {
        return swapAs(user, false, int256(ethOut), abi.encode(user), 0);
    }

    // ── observations ───────────────────────────────────────────────────────────────────────────

    function hookClaims() internal view returns (uint256) {
        return manager.balanceOf(address(hook), 0);
    }

    function assertSolvent() internal view {
        assertEq(hookClaims(), hook.totalOwed(), "claims != totalOwed");
        assertGe(address(manager).balance, hookClaims(), "manager holds less ETH than the hook's claims");
    }

    function currentTick() internal view returns (int24 tick) {
        (, tick,,) = manager.getSlot0(poolId);
    }

    function fee(uint256 ethLeg) internal pure returns (uint256) {
        return ethLeg * FEE_BPS / BPS;
    }

    function abs(int256 x) internal pure returns (uint256) {
        return x < 0 ? uint256(-x) : uint256(x);
    }

    /// @dev The pool's own view of the last swap (before the hook's delta is applied to the swapper).
    function lastPoolSwap(Vm.Log[] memory logs) internal pure returns (int128 amount0, int128 amount1) {
        for (uint256 i = logs.length; i > 0; i--) {
            if (logs[i - 1].topics[0] == SWAP_EVENT_SIG) {
                (amount0, amount1,,,,) = abi.decode(logs[i - 1].data, (int128, int128, uint160, uint128, int24, uint24));
                return (amount0, amount1);
            }
        }
        revert("no Swap event");
    }

    /// @dev The ERC-7751 wrapped revert the PoolManager produces when a hook callback reverts.
    function hookRevert(bytes4 callback, bytes memory reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            callback,
            reason,
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    // ── time ───────────────────────────────────────────────────────────────────────────────────

    /// @dev Advances to the first second of the next round and moves the chain a plausible number of blocks.
    function nextRound() internal {
        uint256 target = (block.timestamp / 3600 + 1) * 3600;
        vm.roll(block.number + (target - block.timestamp) / 12 + 1);
        vm.warp(target);
    }

    receive() external payable {}
}
