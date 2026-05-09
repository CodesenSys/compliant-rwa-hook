// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";

import { ComplianceRegistry } from "../../src/ComplianceRegistry.sol";
import {
    AccreditationTier,
    PendingRootUpdate,
    ROOT_UPDATE_DELAY,
    UnauthorizedOperator,
    TooEarly,
    InvalidMerkleRoot,
    NotInitialized
} from "../../src/types/ComplianceTypes.sol";

/// @title  ComplianceRegistryTest
/// @notice Unit tests covering all 10 named cases in CLAUDE.md Phase 2.
contract ComplianceRegistryTest is Test {
    ComplianceRegistry internal registry;

    address internal admin       = address(0xAAA);
    address internal operator    = address(0xBBB);
    address internal compliance  = address(0xCCC);
    address internal stranger    = address(0xDEAD);

    bytes32 internal constant ROOT_A = keccak256("rootA");
    bytes32 internal constant ROOT_B = keccak256("rootB");

    function setUp() public {
        registry = new ComplianceRegistry(admin, operator, compliance);
    }

    /* ----------------------------- Roles ----------------------------- */

    function test_constructor_setsInitialRoles() public view {
        assertTrue(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(registry.hasRole(registry.OPERATOR_ROLE(), operator));
        assertTrue(registry.hasRole(registry.COMPLIANCE_ROLE(), compliance));
    }

    function test_revoke_role_preventsFurtherActions() public {
        // TODO: implement — admin revokes operator role, then operator's call should revert
    }

    /* ------------------------ Root update flow ----------------------- */

    function test_proposeRootUpdate_onlyOperator() public {
        vm.prank(stranger);
        vm.expectRevert(UnauthorizedOperator.selector);
        registry.proposeRootUpdate(ROOT_A);
    }

    function test_applyRootUpdate_revertsBeforeDelay() public {
        // TODO: implement
        // vm.prank(operator); registry.proposeRootUpdate(ROOT_A);
        // skip(ROOT_UPDATE_DELAY - 1);
        // vm.expectRevert(TooEarly.selector); registry.applyRootUpdate();
    }

    function test_applyRootUpdate_succeedsAfterDelay() public {
        // TODO: implement
    }

    function test_cancelPendingRoot_onlyOperator() public {
        // TODO: implement
    }

    /* --------------------------- Setters ---------------------------- */

    function test_setJurisdictionBlocked_emitsEvent() public {
        // TODO: implement
        // vm.expectEmit(true, false, false, true);
        // emit JurisdictionBlockedSet(bytes2("US"), true);
        // vm.prank(compliance); registry.setJurisdictionBlocked(bytes2("US"), true);
    }

    function test_setAccreditation_storesCorrectTier() public {
        // TODO: implement
    }

    function test_setLockup_storesExpiry() public {
        // TODO: implement
    }

    /* ----------------------------- Pause ---------------------------- */

    function test_pause_blocksAllReads() public {
        // TODO: implement — decision: do view fns honour pause? lock the answer in this test.
    }
}
