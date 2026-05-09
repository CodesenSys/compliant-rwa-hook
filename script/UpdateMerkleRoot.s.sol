// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script, console2 } from "forge-std/Script.sol";

import { ComplianceRegistry } from "../src/ComplianceRegistry.sol";

/// @title  UpdateMerkleRoot
/// @notice Operator action: propose a new Merkle root, then (after the 24h
///         timelock) call applyRootUpdate. Two separate `forge script`
///         invocations are required by design — that's the safety mechanism.
contract UpdateMerkleRoot is Script {
    function propose(bytes32 newRoot) external {
        uint256 operatorKey = vm.envUint("OPERATOR_PRIVATE_KEY");
        ComplianceRegistry registry = ComplianceRegistry(vm.envAddress("COMPLIANCE_REGISTRY"));

        vm.startBroadcast(operatorKey);
        registry.proposeRootUpdate(newRoot);
        vm.stopBroadcast();

        console2.log("Proposed root update. Apply after the 24h timelock with:");
        console2.log("forge script script/UpdateMerkleRoot.s.sol --sig 'apply()' --broadcast");
    }

    function applyUpdate() external {
        ComplianceRegistry registry = ComplianceRegistry(vm.envAddress("COMPLIANCE_REGISTRY"));
        // applyRootUpdate is permissionless; anyone can land it after the timelock.
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        registry.applyRootUpdate();
        vm.stopBroadcast();
        console2.log("Root applied:");
        console2.logBytes32(registry.merkleRoot());
    }
}
