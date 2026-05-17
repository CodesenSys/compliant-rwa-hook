// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";

import { ComplianceRegistry } from "../../src/ComplianceRegistry.sol";
import { ROOT_UPDATE_DELAY } from "../../src/types/ComplianceTypes.sol";

/// @notice Stateful handler — constrains the action space for the invariant runner.
///         Without a handler, Foundry's invariant runner will call any external
///         function with random calldata, including `revoke role` chains that
///         trivially break invariants. Keep the action surface meaningful.
contract Handler is Test {
    ComplianceRegistry public registry;
    address public operator;
    address public compliance;
    bytes32 public lastAppliedRoot;

    constructor(ComplianceRegistry _r, address _op, address _co) {
        registry   = _r;
        operator   = _op;
        compliance = _co;
    }

    function proposeAndApply(bytes32 newRoot) external {
        if (newRoot == bytes32(0)) return;
        vm.prank(operator);
        registry.proposeRootUpdate(newRoot);
        skip(ROOT_UPDATE_DELAY + 1);
        registry.applyRootUpdate();
        lastAppliedRoot = newRoot;
    }

    function blockJurisdiction(bytes2 country) external {
        vm.prank(compliance);
        registry.setJurisdictionBlocked(country, true);
    }
}

/// @title  InvariantComplianceTest
/// @notice Invariants documented at the top of CLAUDE.md Section 4.
contract InvariantComplianceTest is Test {
    ComplianceRegistry internal registry;
    Handler            internal handler;

    address internal admin       = address(0xAAA);
    address internal operator    = address(0xBBB);
    address internal compliance  = address(0xCCC);

    function setUp() public {
        registry = new ComplianceRegistry(admin, operator, compliance);
        handler  = new Handler(registry, operator, compliance);
        targetContract(address(handler));
    }

    /// @dev Invariant: merkleRoot is never zero AFTER it has been initialised.
    function invariant_merkleRoot_neverZero_afterInit() public view {
        if (handler.lastAppliedRoot() == bytes32(0)) return; // not yet initialised
        assertTrue(registry.merkleRoot() != bytes32(0));
    }

    /// @dev Invariant: lockup expiry, once set, is monotonically respected
    ///      by reads (no silent reset).
    function invariant_lockupExpiry_monotonic() public {
        // TODO: extend handler to also call setLockup, then compare reads.
    }
}
