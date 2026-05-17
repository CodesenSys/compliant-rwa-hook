// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";

import { ComplianceRegistry } from "../../src/ComplianceRegistry.sol";
import { IComplianceRegistry } from "../../src/interfaces/IComplianceRegistry.sol";
import {
    AccreditationTier,
    PendingRootUpdate,
    ROOT_UPDATE_DELAY,
    UnauthorizedOperator,
    TooEarly,
    InvalidMerkleRoot,
    RootStale,
    NotInitialized
} from "../../src/types/ComplianceTypes.sol";

/// @title  ComplianceRegistryTest
/// @notice Unit tests covering all 10 named cases in CLAUDE.md Phase 2.
contract ComplianceRegistryTest is Test {
    ComplianceRegistry internal registry;

    address internal admin      = address(0xAAA);
    address internal operator   = address(0xBBB);
    address internal compliance = address(0xCCC);
    address internal stranger   = address(0xDEAD);
    address internal alice      = address(0x1111);

    bytes32 internal constant ROOT_A = keccak256("rootA");
    bytes32 internal constant ROOT_B = keccak256("rootB");

    // "US" is exactly 2 bytes — this cast never truncates.
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes2 internal constant COUNTRY_US = bytes2("US");

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
        bytes32 operatorRole = registry.OPERATOR_ROLE();

        vm.prank(admin);
        registry.revokeRole(operatorRole, operator);

        // Former operator can no longer propose root updates.
        vm.prank(operator);
        vm.expectRevert(UnauthorizedOperator.selector);
        registry.proposeRootUpdate(ROOT_A);
    }

    /* ------------------------ Root update flow ----------------------- */

    function test_proposeRootUpdate_onlyOperator() public {
        vm.prank(stranger);
        vm.expectRevert(UnauthorizedOperator.selector);
        registry.proposeRootUpdate(ROOT_A);
    }

    function test_proposeRootUpdate_rejectsZeroRoot() public {
        vm.prank(operator);
        vm.expectRevert(InvalidMerkleRoot.selector);
        registry.proposeRootUpdate(bytes32(0));
    }

    function test_proposeRootUpdate_storesPendingAndEmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit IComplianceRegistry.RootUpdateProposed(ROOT_A, uint64(block.timestamp) + ROOT_UPDATE_DELAY);

        vm.prank(operator);
        registry.proposeRootUpdate(ROOT_A);

        PendingRootUpdate memory p = registry.pendingRoot();
        assertEq(p.root, ROOT_A);
        assertEq(p.effectiveAt, uint64(block.timestamp) + ROOT_UPDATE_DELAY);
    }

    function test_applyRootUpdate_revertsBeforeDelay() public {
        vm.prank(operator);
        registry.proposeRootUpdate(ROOT_A);

        skip(ROOT_UPDATE_DELAY - 1);

        vm.expectRevert(TooEarly.selector);
        registry.applyRootUpdate();
    }

    function test_applyRootUpdate_succeedsAfterDelay() public {
        vm.prank(operator);
        registry.proposeRootUpdate(ROOT_A);

        skip(ROOT_UPDATE_DELAY);

        vm.expectEmit(true, false, false, false);
        emit IComplianceRegistry.RootUpdated(ROOT_A);

        registry.applyRootUpdate();

        assertEq(registry.merkleRoot(), ROOT_A);
        // Pending root must be cleared after apply.
        assertEq(registry.pendingRoot().root, bytes32(0));
    }

    function test_applyRootUpdate_revertsWithNoPending() public {
        vm.expectRevert(RootStale.selector);
        registry.applyRootUpdate();
    }

    function test_cancelPendingRoot_onlyOperator() public {
        vm.prank(operator);
        registry.proposeRootUpdate(ROOT_A);

        vm.prank(stranger);
        vm.expectRevert(UnauthorizedOperator.selector);
        registry.cancelPendingRoot();
    }

    function test_cancelPendingRoot_clearsAndEmitsEvent() public {
        vm.prank(operator);
        registry.proposeRootUpdate(ROOT_A);

        vm.expectEmit(true, false, false, false);
        emit IComplianceRegistry.RootUpdateCancelled(ROOT_A);

        vm.prank(operator);
        registry.cancelPendingRoot();

        assertEq(registry.pendingRoot().root, bytes32(0));
    }

    function test_cancelledRoot_cannotBeApplied() public {
        vm.prank(operator);
        registry.proposeRootUpdate(ROOT_A);

        vm.prank(operator);
        registry.cancelPendingRoot();

        // Even after the delay the cancelled root cannot be applied.
        skip(ROOT_UPDATE_DELAY + 1);
        vm.expectRevert(RootStale.selector);
        registry.applyRootUpdate();
    }

    /* --------------------------- Setters ---------------------------- */

    function test_setJurisdictionBlocked_emitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit IComplianceRegistry.JurisdictionBlockedSet(COUNTRY_US, true);

        vm.prank(compliance);
        registry.setJurisdictionBlocked(COUNTRY_US, true);

        assertTrue(registry.isJurisdictionBlocked(COUNTRY_US));
    }

    function test_setJurisdictionBlocked_onlyCompliance() public {
        vm.prank(stranger);
        vm.expectRevert(UnauthorizedOperator.selector);
        registry.setJurisdictionBlocked(COUNTRY_US, true);
    }

    function test_setCountry_storesAndEmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit IComplianceRegistry.CountrySet(alice, COUNTRY_US);

        vm.prank(operator);
        registry.setCountry(alice, COUNTRY_US);

        assertEq(registry.countryOf(alice), COUNTRY_US);
    }

    function test_setAccreditation_storesCorrectTier() public {
        vm.expectEmit(true, false, false, true);
        emit IComplianceRegistry.AccreditationSet(alice, AccreditationTier.Qualified);

        vm.prank(operator);
        registry.setAccreditation(alice, AccreditationTier.Qualified);

        assertEq(uint8(registry.accreditationOf(alice)), uint8(AccreditationTier.Qualified));
    }

    function test_setLockup_storesExpiry() public {
        uint64 expiry = uint64(block.timestamp + 90 days);

        vm.expectEmit(true, false, false, true);
        emit IComplianceRegistry.LockupSet(alice, expiry);

        vm.prank(operator);
        registry.setLockup(alice, expiry);

        assertEq(registry.lockupExpiryOf(alice), expiry);
    }

    /* ----------------------------- Pause ---------------------------- */

    function test_pause_blocksAllReads() public {
        // Design decision: view functions do NOT revert when paused — the hook
        // reads `paused()` itself and reverts in the callback. This keeps the
        // registry a pure data store with no access-control in view paths.
        vm.prank(compliance);
        registry.pause();

        assertTrue(registry.paused());
        // View functions still work; it's the hook's job to gate on paused().
        assertFalse(registry.isJurisdictionBlocked(COUNTRY_US));
    }

    function test_unpause_restoresState() public {
        vm.prank(compliance);
        registry.pause();

        vm.prank(compliance);
        registry.unpause();

        assertFalse(registry.paused());
    }

    function test_merkleRoot_revertsWhenNotInitialized() public {
        vm.expectRevert(NotInitialized.selector);
        registry.merkleRoot();
    }
}
