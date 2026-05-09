// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script, console2 } from "forge-std/Script.sol";

import { ComplianceLib } from "../src/libraries/ComplianceLib.sol";
import { AccreditationTier } from "../src/types/ComplianceTypes.sol";

/// @title  GenerateProof
/// @notice Helper script: given an address + tier, prints the Merkle leaf
///         hash. The full proof must be generated off-chain (TypeScript with
///         @openzeppelin/merkle-tree). This script exists so a developer can
///         confirm the on-chain leaf encoding matches their off-chain tooling.
contract GenerateProof is Script {
    function run(address account, uint8 rawTier) external view {
        AccreditationTier tier = AccreditationTier(rawTier);
        bytes32 leaf = ComplianceLib.leafHash(account, tier);

        console2.log("Account:");
        console2.logAddress(account);
        console2.log("Tier:");
        console2.logUint(rawTier);
        console2.log("Leaf hash:");
        console2.logBytes32(leaf);

        // Use this leaf in your off-chain Merkle tree builder, e.g.:
        //
        //   import { StandardMerkleTree } from "@openzeppelin/merkle-tree";
        //   const tree = StandardMerkleTree.of([[account, tier]], ["address", "uint8"]);
        //   console.log("root:", tree.root);
        //   console.log("proof:", tree.getProof([account, tier]));
    }
}
