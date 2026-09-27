// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFlags} from "./HookFlags.sol";

/// @title HookMiner
/// @notice Finds a CREATE2 salt that places a hook at an address carrying the required permission bits.
/// @dev Pure and loop-bounded; usable from tests and scripts alike. Roughly one in 2^14 salts matches a
/// full 14-bit pattern, so `MAX_LOOP` leaves ample headroom.
library HookMiner {
    uint256 internal constant MAX_LOOP = 200_000;

    error NoSaltFound(uint160 flags);

    /// @param deployer The address that will execute CREATE2 (the caller of `new X{salt: ...}`).
    /// @param flags The permission bits the address must carry (all other flag bits must be clear).
    /// @param creationCode The contract creation code including ABI-encoded constructor arguments.
    /// @return hookAddress The address CREATE2 will produce.
    /// @return salt The salt to use.
    function find(address deployer, uint160 flags, bytes memory creationCode)
        internal
        pure
        returns (address hookAddress, bytes32 salt)
    {
        bytes32 initCodeHash = keccak256(creationCode);
        for (uint256 i = 0; i < MAX_LOOP; i++) {
            salt = bytes32(i);
            hookAddress = computeAddress(deployer, salt, initCodeHash);
            if (HookFlags.matches(hookAddress, flags)) return (hookAddress, salt);
        }
        revert NoSaltFound(flags);
    }

    function computeAddress(address deployer, bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }
}
