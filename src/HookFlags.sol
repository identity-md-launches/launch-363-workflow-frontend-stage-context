// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Hooks} from "v4-core/src/libraries/Hooks.sol";

/// @title HookFlags
/// @notice The permission bits a Uniswap v4 hook address carries, and helpers to compare them.
/// @dev Values mirror `Hooks` in v4-core exactly; they are re-exported here so deployment tooling and
/// the admission tests can reason about an address without importing the whole library.
library HookFlags {
    uint160 internal constant BEFORE_INITIALIZE = Hooks.BEFORE_INITIALIZE_FLAG;
    uint160 internal constant AFTER_INITIALIZE = Hooks.AFTER_INITIALIZE_FLAG;
    uint160 internal constant BEFORE_ADD_LIQUIDITY = Hooks.BEFORE_ADD_LIQUIDITY_FLAG;
    uint160 internal constant AFTER_ADD_LIQUIDITY = Hooks.AFTER_ADD_LIQUIDITY_FLAG;
    uint160 internal constant BEFORE_REMOVE_LIQUIDITY = Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG;
    uint160 internal constant AFTER_REMOVE_LIQUIDITY = Hooks.AFTER_REMOVE_LIQUIDITY_FLAG;
    uint160 internal constant BEFORE_SWAP = Hooks.BEFORE_SWAP_FLAG;
    uint160 internal constant AFTER_SWAP = Hooks.AFTER_SWAP_FLAG;
    uint160 internal constant BEFORE_DONATE = Hooks.BEFORE_DONATE_FLAG;
    uint160 internal constant AFTER_DONATE = Hooks.AFTER_DONATE_FLAG;
    uint160 internal constant BEFORE_SWAP_RETURN_DELTA = Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;
    uint160 internal constant AFTER_SWAP_RETURN_DELTA = Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    uint160 internal constant AFTER_ADD_LIQUIDITY_RETURN_DELTA = Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG;
    uint160 internal constant AFTER_REMOVE_LIQUIDITY_RETURN_DELTA = Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG;

    /// @notice Mask covering all fourteen permission bits.
    uint160 internal constant ALL = Hooks.ALL_HOOK_MASK;

    /// @notice The bits `SwapLotteryHook` requires: beforeSwap, afterSwap and both swap return deltas.
    uint160 internal constant SWAP_LOTTERY =
        BEFORE_SWAP | AFTER_SWAP | BEFORE_SWAP_RETURN_DELTA | AFTER_SWAP_RETURN_DELTA;

    /// @notice The permission bits present in `hook`'s address.
    function flagsOf(address hook) internal pure returns (uint160) {
        return uint160(hook) & ALL;
    }

    /// @notice True when `hook`'s address carries exactly `flags` (ignoring bits outside the mask).
    function matches(address hook, uint160 flags) internal pure returns (bool) {
        return flagsOf(hook) == (flags & ALL);
    }
}
