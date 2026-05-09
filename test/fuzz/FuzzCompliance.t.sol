// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";

import { ComplianceRegistry } from "../../src/ComplianceRegistry.sol";
import { ComplianceLib } from "../../src/libraries/ComplianceLib.sol";
import {
    AccreditationTier,
    ROOT_UPDATE_DELAY
} from "../../src/types/ComplianceTypes.sol";

/// @title  FuzzCompliance
/// @notice Property-based tests for the registry and verification helpers.
contract FuzzCompliance is Test {
    ComplianceRegistry internal registry;

    address internal admin      = address(0xAAA);
    address internal operator   = address(0xBBB);
    address internal compliance = address(0xCCC);

    function setUp() public {
        registry = new ComplianceRegistry(admin, operator, compliance);
    }

    /// @notice Property: any non-zero proposed root, after the timelock, applies cleanly.
    function testFuzz_proposeApply_anyNonZeroRoot(bytes32 newRoot) public {
        vm.assume(newRoot != bytes32(0));
        vm.prank(operator);
        registry.proposeRootUpdate(newRoot);
        skip(ROOT_UPDATE_DELAY + 1);
        registry.applyRootUpdate();
        assertEq(registry.merkleRoot(), newRoot);
    }

    /// @notice Property: leafHash never produces bytes32(0) for valid inputs.
    function testFuzz_leafHash_neverZero(address acct, uint8 rawTier) public pure {
        AccreditationTier tier = AccreditationTier(bound(rawTier, 0, 3));
        bytes32 h = ComplianceLib.leafHash(acct, tier);
        assertTrue(h != bytes32(0));
    }

    /// @notice Property: verifyMembership returns false against a wrong root.
    function testFuzz_verifyMembership_wrongRoot(bytes32 fakeRoot, address acct, uint8 rawTier) public pure {
        AccreditationTier tier = AccreditationTier(bound(rawTier, 0, 3));
        bytes32 leaf = ComplianceLib.leafHash(acct, tier);
        vm.assume(fakeRoot != leaf);
        bytes32[] memory emptyProof = new bytes32[](0);
        assertFalse(ComplianceLib.verifyMembership(fakeRoot, emptyProof, acct, tier));
    }
}
