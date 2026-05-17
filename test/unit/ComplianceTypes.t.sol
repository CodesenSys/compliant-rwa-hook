// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";

import {
    AccreditationTier,
    ComplianceError,
    LockupSchedule,
    PendingRootUpdate,
    ComplianceViolation,
    UnauthorizedOperator,
    TooEarly,
    InvalidMerkleRoot,
    RootStale,
    NotInitialized,
    ROOT_UPDATE_DELAY,
    MAX_LOCKUP_DURATION,
    LEAF_DOMAIN
} from "../../src/types/ComplianceTypes.sol";

/// @title  ComplianceTypesTest
/// @notice Validates every declaration in ComplianceTypes.sol in plain,
///         readable assertions. No logic under test here — just the
///         vocabulary the system is built on.
contract ComplianceTypesTest is Test {

    // -------------------------------------------------------------------------
    // AccreditationTier — numeric ordering
    // -------------------------------------------------------------------------

    /// Tiers must be numeric 0-3 in the declared order.
    /// The hook uses uint8 comparisons: uint8(Institutional) > uint8(Retail).
    function test_accreditationTier_numericOrdering() public pure {
        assertEq(uint8(AccreditationTier.None),          0);
        assertEq(uint8(AccreditationTier.Retail),        1);
        assertEq(uint8(AccreditationTier.Qualified),     2);
        assertEq(uint8(AccreditationTier.Institutional), 3);
    }

    /// Institutional must outrank every lower tier — this is the invariant
    /// the hook's tier-gating relies on.
    function test_accreditationTier_institutionalOutranksAll() public pure {
        assertTrue(uint8(AccreditationTier.Institutional) > uint8(AccreditationTier.Qualified));
        assertTrue(uint8(AccreditationTier.Institutional) > uint8(AccreditationTier.Retail));
        assertTrue(uint8(AccreditationTier.Institutional) > uint8(AccreditationTier.None));
    }

    // -------------------------------------------------------------------------
    // ComplianceError — all six rejection reasons exist and are distinct
    // -------------------------------------------------------------------------

    function test_complianceError_valuesAreDistinct() public pure {
        uint8[6] memory vals = [
            uint8(ComplianceError.NOT_WHITELISTED),
            uint8(ComplianceError.BLOCKED_JURISDICTION),
            uint8(ComplianceError.LOCKUP_ACTIVE),
            uint8(ComplianceError.INSUFFICIENT_TIER),
            uint8(ComplianceError.POOL_PAUSED),
            uint8(ComplianceError.INVALID_PROOF)
        ];
        // Brute-force uniqueness check: no two values are the same.
        for (uint256 i = 0; i < vals.length; i++) {
            for (uint256 j = i + 1; j < vals.length; j++) {
                assertTrue(vals[i] != vals[j], "ComplianceError values must be unique");
            }
        }
    }

    // -------------------------------------------------------------------------
    // LockupSchedule — storage packing
    // -------------------------------------------------------------------------

    /// The struct should accept realistic vesting timestamps and amounts
    /// without overflow. Also confirms the field types match what callers expect.
    function test_lockupSchedule_packsCorrectly() public view {
        LockupSchedule memory s = LockupSchedule({
            cliff:      uint48(block.timestamp + 365 days),
            vestingEnd: uint48(block.timestamp + 4 * 365 days),
            amount:     1_000_000e18
        });

        // cliff is before vestingEnd
        assertTrue(s.cliff < s.vestingEnd);
        // amount survives the round-trip through uint128
        assertEq(s.amount, 1_000_000e18);
        // uint48 can hold timestamps well past year 2100
        // max uint48 = 281474976710655 ≈ year 10895 in Unix time
        assertTrue(type(uint48).max > block.timestamp + 200 * 365 days);
    }

    // -------------------------------------------------------------------------
    // PendingRootUpdate — fields accessible and correctly typed
    // -------------------------------------------------------------------------

    function test_pendingRootUpdate_fieldsRoundTrip() public view {
        bytes32 root = keccak256("example root");
        uint64 eta   = uint64(block.timestamp) + ROOT_UPDATE_DELAY;

        PendingRootUpdate memory p = PendingRootUpdate({ root: root, effectiveAt: eta });

        assertEq(p.root,        root);
        assertEq(p.effectiveAt, eta);
    }

    // -------------------------------------------------------------------------
    // Custom errors — selectors are stable (ABI surface)
    // -------------------------------------------------------------------------

    /// Verify each error can be thrown and caught with the correct selector.
    /// This protects against accidental renaming that would silently break
    /// off-chain error decoders.

    function test_error_complianceViolation_isThrowable() public {
        vm.expectRevert(abi.encodeWithSelector(
            ComplianceViolation.selector,
            ComplianceError.NOT_WHITELISTED
        ));
        this._throwComplianceViolation(ComplianceError.NOT_WHITELISTED);
    }

    function test_error_unauthorizedOperator_isThrowable() public {
        vm.expectRevert(UnauthorizedOperator.selector);
        this._throwUnauthorizedOperator();
    }

    function test_error_tooEarly_isThrowable() public {
        vm.expectRevert(TooEarly.selector);
        this._throwTooEarly();
    }

    function test_error_invalidMerkleRoot_isThrowable() public {
        vm.expectRevert(InvalidMerkleRoot.selector);
        this._throwInvalidMerkleRoot();
    }

    function test_error_rootStale_isThrowable() public {
        vm.expectRevert(RootStale.selector);
        this._throwRootStale();
    }

    function test_error_notInitialized_isThrowable() public {
        vm.expectRevert(NotInitialized.selector);
        this._throwNotInitialized();
    }

    // -------------------------------------------------------------------------
    // Constants — values match the documented intentions
    // -------------------------------------------------------------------------

    function test_constant_rootUpdateDelay_is24Hours() public pure {
        assertEq(ROOT_UPDATE_DELAY, 24 * 60 * 60);
    }

    function test_constant_maxLockupDuration_isApprox10Years() public pure {
        // 3650 days = 10 years (ignoring leap years, intentional)
        assertEq(MAX_LOCKUP_DURATION, 3650 days);
        // sanity: fits in uint64 with room to spare
        assertTrue(uint64(MAX_LOCKUP_DURATION) < type(uint64).max);
    }

    /// LEAF_DOMAIN must be a non-zero hash — it's the namespace that prevents
    /// Merkle proofs from this protocol being replayed against another.
    function test_constant_leafDomain_isNonZero() public pure {
        assertNotEq(LEAF_DOMAIN, bytes32(0));
        // And it must equal the documented preimage.
        assertEq(LEAF_DOMAIN, keccak256("CodesenSys.RWA.Compliance.v1"));
    }

    // -------------------------------------------------------------------------
    // Helper targets for vm.expectRevert (must be external)
    // -------------------------------------------------------------------------

    function _throwComplianceViolation(ComplianceError reason) external pure {
        revert ComplianceViolation(reason);
    }

    function _throwUnauthorizedOperator() external pure {
        revert UnauthorizedOperator();
    }

    function _throwTooEarly() external pure {
        revert TooEarly();
    }

    function _throwInvalidMerkleRoot() external pure {
        revert InvalidMerkleRoot();
    }

    function _throwRootStale() external pure {
        revert RootStale();
    }

    function _throwNotInitialized() external pure {
        revert NotInitialized();
    }
}
