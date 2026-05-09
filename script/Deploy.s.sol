// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script, console2 } from "forge-std/Script.sol";

import { ComplianceRegistry } from "../src/ComplianceRegistry.sol";
import { CompliantRWAHook } from "../src/CompliantRWAHook.sol";

import { Hooks } from "v4-core/src/libraries/Hooks.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";

/// @title  Deploy
/// @notice Full system deployment for testnet (Base Sepolia / Sepolia).
/// @dev    Steps:
///         1) Deploy ComplianceRegistry
///         2) Mine the hook address using HookMiner against the target permissions
///         3) Deploy CompliantRWAHook at the mined address (CREATE2 + salt)
///         4) Deploy mock RWA token + mock USDC
///         5) Initialize a V4 pool with the hook
///         6) Seed initial liquidity
///         7) Write deployment manifest to deployments/<network>.json
contract Deploy is Script {
    /// @notice CREATE2 deployer used by Forge by default.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address admin       = vm.addr(deployerKey);
        address operator    = vm.envOr("OPERATOR_ADDRESS", admin);
        address compliance  = vm.envOr("COMPLIANCE_ADDRESS", admin);

        IPoolManager poolManager = IPoolManager(vm.envAddress("POOL_MANAGER"));

        vm.startBroadcast(deployerKey);

        // 1) ComplianceRegistry
        ComplianceRegistry registry = new ComplianceRegistry(admin, operator, compliance);
        console2.log("ComplianceRegistry:", address(registry));

        // 2) Mine hook address
        // TODO: implement HookMiner call and CREATE2 deployment.
        //
        // uint160 flags = uint160(
        //     Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        //   | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        // );
        // (address hookAddr, bytes32 salt) = HookMiner.find(
        //     CREATE2_DEPLOYER,
        //     flags,
        //     type(CompliantRWAHook).creationCode,
        //     abi.encode(poolManager, registry)
        // );

        // 3) Deploy hook
        // CompliantRWAHook hook = new CompliantRWAHook{ salt: salt }(poolManager, registry);
        // require(address(hook) == hookAddr, "hook address mismatch");
        // console2.log("CompliantRWAHook:", address(hook));

        // 4) Mock tokens (RWA + USDC) — TODO

        // 5) Initialize V4 pool with hook — TODO

        // 6) Seed liquidity — TODO

        // 7) Write deployments/<network>.json — TODO via vm.writeJson

        vm.stopBroadcast();
    }
}
