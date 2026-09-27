// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";

/// @title LaunchParams
/// @notice The launch's deployment parameters, in one place so the tests, the rehearsal script and the
/// manifest all read the same numbers.
/// @dev The pool is `currency0 = native ETH`, `currency1 = TIKT`, so its price is TIKT per ETH. The
/// factory initializes it at `INITIAL_SQRT_PRICE_X96` and seeds one-sided TIKT liquidity in a range
/// entirely at or below the initial tick, which is the only shape a TIKT-only position can take. The
/// first buy (ETH in) walks the price down into that range.
library LaunchParams {
    /// @notice Chain the launch is approved for.
    uint256 internal constant CHAIN_ID = 11155111;
    /// @notice Sepolia PoolManager, the hook's single constructor argument.
    address internal constant SEPOLIA_POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;

    /// @notice Pool key fields.
    uint24 internal constant POOL_FEE = 3000;
    int24 internal constant TICK_SPACING = 60;

    /// @notice Initial tick: 1.0001^161160 ≈ 9,985,000 TIKT per ETH, aligned to the tick spacing.
    int24 internal constant INITIAL_TICK = 161_160;

    /// @notice Lower bound of the one-sided seed position (the lowest usable tick for spacing 60).
    int24 internal constant SEED_TICK_LOWER = -887_220;
    /// @notice Upper bound of the seed position: the initial tick itself, so the position holds only TIKT.
    int24 internal constant SEED_TICK_UPPER = INITIAL_TICK;

    /// @notice TIKT the factory places in the pool (half the supply). The rest stays with the deployer.
    uint256 internal constant SEED_TIKT = 500_000_000e18;

    /// @notice The manifest price.
    function initialSqrtPriceX96() internal pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(INITIAL_TICK);
    }

    /// @notice Liquidity of a TIKT-only position holding at most `SEED_TIKT` over the seed range.
    function seedLiquidity() internal pure returns (uint128) {
        uint160 lower = TickMath.getSqrtPriceAtTick(SEED_TICK_LOWER);
        uint160 upper = TickMath.getSqrtPriceAtTick(SEED_TICK_UPPER);
        uint256 liquidity = FullMath.mulDiv(SEED_TIKT, FixedPoint96.Q96, upper - lower);
        // Round the liquidity down until the amount the pool will pull (rounded up) fits the budget.
        while (SqrtPriceMath.getAmount1Delta(lower, upper, uint128(liquidity), true) > SEED_TIKT) {
            liquidity -= 1;
        }
        return uint128(liquidity);
    }
}
