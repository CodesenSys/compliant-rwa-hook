// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";

import { ComplianceLib } from "../../src/libraries/ComplianceLib.sol";
import { AccreditationTier } from "../../src/types/ComplianceTypes.sol";

/// @title  ComplianceLibTest
/// @notice Pure library tests — leaf determinism and Merkle proof correctness.
contract ComplianceLibTest is Test {
    function test_leafHash_isDeterministic() public pure {
        address acct = address(0x1234);
        bytes32 a = ComplianceLib.leafHash(acct, AccreditationTier.Qualified);
        bytes32 b = ComplianceLib.leafHash(acct, AccreditationTier.Qualified);
        assertEq(a, b);
    }

    function test_leafHash_differsAcrossTiers() public pure {
        address acct = address(0x1234);
        bytes32 retail       = ComplianceLib.leafHash(acct, AccreditationTier.Retail);
        bytes32 qualified    = ComplianceLib.leafHash(acct, AccreditationTier.Qualified);
        bytes32 institutional = ComplianceLib.leafHash(acct, AccreditationTier.Institutional);
        assertTrue(retail != qualified);
        assertTrue(qualified != institutional);
    }

    function test_leafHash_includesDomainSeparator() public pure {
        // Sanity-check: a same-input keccak WITHOUT the domain prefix must
        // not match the library's leaf — otherwise the domain isn't being applied.
        address acct = address(0x1234);
        bytes32 withDomain = ComplianceLib.leafHash(acct, AccreditationTier.Retail);
        bytes32 naive      = keccak256(abi.encodePacked(acct, uint8(AccreditationTier.Retail)));
        assertTrue(withDomain != naive, "domain separator missing");
    }

    function test_verifyMembership_singleLeafTree() public pure {
        address acct = address(0x1234);
        AccreditationTier tier = AccreditationTier.Retail;
        // Single-leaf tree: root == the leaf itself; empty proof suffices.
        bytes32 root = ComplianceLib.leafHash(acct, tier);
        assertTrue(ComplianceLib.verifyMembership(root, new bytes32[](0), acct, tier));
    }

    function test_verifyMembership_twoLeafTree() public pure {
        address acct0 = address(0x1111);
        address acct1 = address(0x2222);
        AccreditationTier tier = AccreditationTier.Qualified;

        bytes32 leafA = ComplianceLib.leafHash(acct0, tier);
        bytes32 leafB = ComplianceLib.leafHash(acct1, tier);

        // Root follows StandardMerkleTree: sort siblings before hashing.
        bytes32 root = leafA < leafB
            ? keccak256(abi.encode(leafA, leafB))
            : keccak256(abi.encode(leafB, leafA));

        // Proof for acct0 is [leafB]; proof for acct1 is [leafA].
        bytes32[] memory proofA = new bytes32[](1);
        proofA[0] = leafB;
        bytes32[] memory proofB = new bytes32[](1);
        proofB[0] = leafA;

        assertTrue(ComplianceLib.verifyMembership(root, proofA, acct0, tier));
        assertTrue(ComplianceLib.verifyMembership(root, proofB, acct1, tier));
    }

    function testFuzz_verifyMembership_invalidProofRejects(bytes32 wrongRoot, address acct) public pure {
        AccreditationTier tier = AccreditationTier.Retail;
        bytes32 correctRoot = ComplianceLib.leafHash(acct, tier);
        vm.assume(wrongRoot != correctRoot);
        assertFalse(ComplianceLib.verifyMembership(wrongRoot, new bytes32[](0), acct, tier));
    }
}
