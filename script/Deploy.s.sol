// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

import {Ticket} from "../src/Ticket.sol";
import {SwapLotteryHook} from "../src/SwapLotteryHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {HookMiner} from "../src/HookMiner.sol";
import {LaunchParams} from "../src/LaunchParams.sol";

/// @title Deploy
/// @notice Rehearsal-only deployment of the launch's two contracts.
/// @dev The real Sepolia launch goes through the factory, which deploys the token, mines the hook salt,
/// initializes the pool and seeds it. This script does the first two of those with the same creation
/// code so the same bytes can be rehearsed on a fork or a local node. It does not authorize a launch and
/// controls no funded wallet.
///
/// `run()` reads the environment; `deploy()` takes its configuration as arguments so tests call it
/// directly with no environment at all.
contract Deploy is Script {
    struct Deployment {
        Ticket token;
        SwapLotteryHook hook;
        bytes32 hookSalt;
    }

    /// @dev Environment: `POOL_MANAGER` (defaults to the Sepolia PoolManager). When broadcasting, `new
    /// X{salt: ...}` goes through the deterministic CREATE2 factory, so the salt is mined for it.
    function run() external returns (Deployment memory d) {
        IPoolManager pm = IPoolManager(vm.envOr("POOL_MANAGER", LaunchParams.SEPOLIA_POOL_MANAGER));
        vm.startBroadcast();
        d = deploy(pm, CREATE2_FACTORY);
        vm.stopBroadcast();
        console.log("Ticket:", address(d.token));
        console.log("SwapLotteryHook:", address(d.hook));
        console.log("salt:", vm.toString(d.hookSalt));
    }

    /// @param pm The PoolManager the hook binds to.
    /// @param create2Deployer The address that will execute the CREATE2 (the caller of this function, or
    /// the deterministic factory when broadcasting).
    function deploy(IPoolManager pm, address create2Deployer) public returns (Deployment memory d) {
        d.token = new Ticket();
        bytes memory creationCode = abi.encodePacked(type(SwapLotteryHook).creationCode, abi.encode(address(pm)));
        (address predicted, bytes32 salt) = HookMiner.find(create2Deployer, HookFlags.SWAP_LOTTERY, creationCode);
        d.hookSalt = salt;
        d.hook = new SwapLotteryHook{salt: salt}(pm);
        require(address(d.hook) == predicted, "hook landed at an unexpected address");
    }
}
