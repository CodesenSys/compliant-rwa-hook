// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

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
        _checkOperator();
        _;
    }

    modifier onlyCompliance() {
        _checkCompliance();
        _;
    }

    function _checkOperator() internal view {
        if (!hasRole(OPERATOR_ROLE, msg.sender)) revert UnauthorizedOperator();
    }

    function _checkCompliance() internal view {
        if (!hasRole(COMPLIANCE_ROLE, msg.sender)) revert UnauthorizedOperator();
    }

    /* --------------------------- Root update flow ---------------------------- */

    /// @inheritdoc IComplianceRegistry
    function proposeRootUpdate(bytes32 newRoot) external onlyOperator {
        if (newRoot == bytes32(0)) revert InvalidMerkleRoot();
        uint64 effectiveAt = uint64(block.timestamp) + ROOT_UPDATE_DELAY;
        _pendingRoot = PendingRootUpdate({ root: newRoot, effectiveAt: effectiveAt });
        emit RootUpdateProposed(newRoot, effectiveAt);
    }

    /// @inheritdoc IComplianceRegistry
    /// @dev CEI: read pending root into memory first, then validate (Checks),
    ///      then mutate storage (Effects). No external calls (no Interactions needed).
    function applyRootUpdate() external {
        PendingRootUpdate memory pending = _pendingRoot;
        if (pending.root == bytes32(0)) revert RootStale();
        if (block.timestamp < pending.effectiveAt) revert TooEarly();
        _merkleRoot = pending.root;
        delete _pendingRoot;
        emit RootUpdated(pending.root);
    }

    /// @inheritdoc IComplianceRegistry
    function cancelPendingRoot() external onlyOperator {
        bytes32 cancelled = _pendingRoot.root;
        delete _pendingRoot;
        emit RootUpdateCancelled(cancelled);
    }

    /* ------------------------------ Setters --------------------------------- */

    /// @inheritdoc IComplianceRegistry
    function setJurisdictionBlocked(bytes2 country, bool blocked) external onlyCompliance {
        _blockedJurisdictions[country] = blocked;
        emit JurisdictionBlockedSet(country, blocked);
    }

    /// @inheritdoc IComplianceRegistry
    function setCountry(address account, bytes2 country) external onlyOperator {
        _countryOf[account] = country;
        emit CountrySet(account, country);
    }

    /// @inheritdoc IComplianceRegistry
    function setAccreditation(address account, AccreditationTier tier) external onlyOperator {
        _accreditation[account] = tier;
        emit AccreditationSet(account, tier);
    }

    /// @inheritdoc IComplianceRegistry
    function setLockup(address account, uint64 expiry) external onlyOperator {
        _lockupExpiry[account] = expiry;
        emit LockupSet(account, expiry);
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
