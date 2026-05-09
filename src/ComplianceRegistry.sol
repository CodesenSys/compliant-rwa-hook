// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { AccessControl } from "openzeppelin-contracts/access/AccessControl.sol";

import { IComplianceRegistry } from "./interfaces/IComplianceRegistry.sol";
import {
    AccreditationTier,
    PendingRootUpdate,
    UnauthorizedOperator,
    TooEarly,
    InvalidMerkleRoot,
    RootStale,
    NotInitialized,
    ROOT_UPDATE_DELAY
} from "./types/ComplianceTypes.sol";

/// @title  ComplianceRegistry
/// @author CodesenSys (https://codesensys.com)
/// @notice Decoupled storage for compliance state read by the CompliantRWAHook.
///         Operator-controlled with timelocked Merkle root updates.
/// @dev    The hook reads from this contract via IComplianceRegistry.
///         Updating the root does NOT require redeploying the hook (the hook's
///         address encodes its V4 permissions and is therefore immutable).
contract ComplianceRegistry is IComplianceRegistry, AccessControl {
    /* --------------------------------- Roles --------------------------------- */

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");

    /* -------------------------------- Storage -------------------------------- */

    bytes32 internal _merkleRoot;
    PendingRootUpdate internal _pendingRoot;

    mapping(bytes2 country => bool blocked) internal _blockedJurisdictions;
    mapping(address account => bytes2 country) internal _countryOf;
    mapping(address account => AccreditationTier tier) internal _accreditation;
    mapping(address account => uint64 expiry) internal _lockupExpiry;

    bool internal _paused;

    /* ------------------------------ Constructor ------------------------------ */

    /// @notice Set initial roles. Deployer becomes admin and grants the
    ///         operator and compliance roles to provided addresses.
    /// @dev    A first Merkle root must be set via proposeRootUpdate +
    ///         applyRootUpdate before reads succeed.
    constructor(address admin, address operator, address complianceOfficer) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, operator);
        _grantRole(COMPLIANCE_ROLE, complianceOfficer);
    }

    /* --------------------------- Modifiers (local) --------------------------- */

    modifier onlyOperator() {
        if (!hasRole(OPERATOR_ROLE, msg.sender)) revert UnauthorizedOperator();
        _;
    }

    modifier onlyCompliance() {
        if (!hasRole(COMPLIANCE_ROLE, msg.sender)) revert UnauthorizedOperator();
        _;
    }

    /* --------------------------- Root update flow ---------------------------- */

    /// @inheritdoc IComplianceRegistry
    function proposeRootUpdate(bytes32 newRoot) external onlyOperator {
        if (newRoot == bytes32(0)) revert InvalidMerkleRoot();
        // TODO: implement
        // - record _pendingRoot with effectiveAt = now + ROOT_UPDATE_DELAY
        // - emit RootUpdateProposed
        revert("TODO: implement proposeRootUpdate");
    }

    /// @inheritdoc IComplianceRegistry
    function applyRootUpdate() external {
        // TODO: implement
        // - revert TooEarly if block.timestamp < _pendingRoot.effectiveAt
        // - revert RootStale if pendingRoot.root == bytes32(0)
        // - assign _merkleRoot = _pendingRoot.root, clear _pendingRoot
        // - emit RootUpdated
        revert("TODO: implement applyRootUpdate");
    }

    /// @inheritdoc IComplianceRegistry
    function cancelPendingRoot() external onlyOperator {
        // TODO: implement
        // - emit RootUpdateCancelled with the cancelled root
        // - delete _pendingRoot
        revert("TODO: implement cancelPendingRoot");
    }

    /* ------------------------------ Setters --------------------------------- */

    /// @inheritdoc IComplianceRegistry
    function setJurisdictionBlocked(bytes2 country, bool blocked) external onlyCompliance {
        // TODO: implement + emit JurisdictionBlockedSet
        revert("TODO: implement setJurisdictionBlocked");
    }

    /// @inheritdoc IComplianceRegistry
    function setCountry(address account, bytes2 country) external onlyOperator {
        // TODO: implement + emit CountrySet
        revert("TODO: implement setCountry");
    }

    /// @inheritdoc IComplianceRegistry
    function setAccreditation(address account, AccreditationTier tier) external onlyOperator {
        // TODO: implement + emit AccreditationSet
        revert("TODO: implement setAccreditation");
    }

    /// @inheritdoc IComplianceRegistry
    function setLockup(address account, uint64 expiry) external onlyOperator {
        // TODO: implement + emit LockupSet
        revert("TODO: implement setLockup");
    }

    /// @inheritdoc IComplianceRegistry
    function pause() external onlyCompliance {
        _paused = true;
        emit PausedSet(true);
    }

    /// @inheritdoc IComplianceRegistry
    function unpause() external onlyCompliance {
        _paused = false;
        emit PausedSet(false);
    }

    /* ------------------------------- Views ---------------------------------- */

    /// @inheritdoc IComplianceRegistry
    function merkleRoot() external view returns (bytes32) {
        if (_merkleRoot == bytes32(0)) revert NotInitialized();
        return _merkleRoot;
    }

    /// @inheritdoc IComplianceRegistry
    function pendingRoot() external view returns (PendingRootUpdate memory) {
        return _pendingRoot;
    }

    /// @inheritdoc IComplianceRegistry
    function isJurisdictionBlocked(bytes2 country) external view returns (bool) {
        return _blockedJurisdictions[country];
    }

    /// @inheritdoc IComplianceRegistry
    function countryOf(address account) external view returns (bytes2) {
        return _countryOf[account];
    }

    /// @inheritdoc IComplianceRegistry
    function accreditationOf(address account) external view returns (AccreditationTier) {
        return _accreditation[account];
    }

    /// @inheritdoc IComplianceRegistry
    function lockupExpiryOf(address account) external view returns (uint64) {
        return _lockupExpiry[account];
    }

    /// @inheritdoc IComplianceRegistry
    function paused() external view returns (bool) {
        return _paused;
    }
}
