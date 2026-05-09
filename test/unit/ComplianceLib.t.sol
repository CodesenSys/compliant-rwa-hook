// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";

import { ComplianceLib } from "../../src/libraries/ComplianceLib.sol";
import { AccreditationTier, LEAF_DOMAIN } from "../../src/types/ComplianceTypes.sol";

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
        // TODO: implement
        // - construct a 1-leaf tree (root == leafHash(acct, tier))
        // - assert verifyMembership returns true with empty proof array
    }

    function test_verifyMembership_twoLeafTree() public pure {
        // TODO: implement
        // - build a 2-leaf tree manually (sort-then-hash pairs)
        // - verify each leaf with the other as proof
    }

    function testFuzz_verifyMembership_invalidProofRejects(bytes32 wrongRoot, address acct) public pure {
        // TODO: implement
        // - assume wrongRoot != computed root
        // - assert verifyMembership returns false
    }
}
