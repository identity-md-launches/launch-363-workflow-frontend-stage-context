// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {Ticket} from "../../src/Ticket.sol";
import {SwapLotteryHook} from "../../src/SwapLotteryHook.sol";
import {HookMiner} from "../../src/HookMiner.sol";
import {HookFlags} from "../../src/HookFlags.sol";
import {LaunchParams} from "../../src/LaunchParams.sol";

/// @dev A local factory-style harness, not a copy of the service's deployment factory.
/// It owns the whole initial supply and settles its own one-sided position in one launch call.
contract FactoryLaunchHarness is IUnlockCallback {
    IPoolManager public immutable manager;
    Ticket public token;
    SwapLotteryHook public hook;
    PoolKey internal key;
    bytes32 public salt;
    uint256 public supplyBeforeSeed;
    BalanceDelta public seedDelta;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function launch() external returns (PoolKey memory) {
        require(address(token) == address(0), "already launched");
        token = new Ticket();
        supplyBeforeSeed = token.balanceOf(address(this));
        bytes memory code = abi.encodePacked(type(SwapLotteryHook).creationCode, abi.encode(manager));
        (, bytes32 minedSalt) = HookMiner.find(address(this), HookFlags.SWAP_LOTTERY, code);
        salt = minedSalt;
        hook = new SwapLotteryHook{salt: minedSalt}(manager);
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 3000, 60, IHooks(address(hook)));
        manager.initialize(key, LaunchParams.initialSqrtPriceX96());
        seedDelta = abi.decode(manager.unlock(""), (BalanceDelta));
        return key;
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(msg.sender == address(manager), "only manager");
        (BalanceDelta delta,) = manager.modifyLiquidity(
            key,
            ModifyLiquidityParams(
                LaunchParams.SEED_TICK_LOWER,
                LaunchParams.SEED_TICK_UPPER,
                int256(uint256(LaunchParams.seedLiquidity())),
                bytes32(0)
            ),
            ""
        );
        require(delta.amount0() == 0 && delta.amount1() < 0, "seed must use only TIKT");
        manager.sync(key.currency1);
        require(token.transfer(address(manager), uint256(-int256(delta.amount1()))));
        manager.settle();
        return abi.encode(delta);
    }
}
