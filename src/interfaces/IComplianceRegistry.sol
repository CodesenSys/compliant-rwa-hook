// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { AccreditationTier, PendingRootUpdate } from "../types/ComplianceTypes.sol";

/// @title  IComplianceRegistry
/// @author CodesenSys (https://codesensys.com)
/// @notice External interface for the ComplianceRegistry — read by the hook
///         and any consumer that needs compliance state.
interface IComplianceRegistry {
    /* ----------------------------------- Events ----------------------------------- */
    event RootUpdateProposed(bytes32 indexed newRoot, uint64 effectiveAt);
    event RootUpdated(bytes32 indexed newRoot);
    event RootUpdateCancelled(bytes32 indexed cancelledRoot);
    event JurisdictionBlockedSet(bytes2 indexed country, bool blocked);
    event CountrySet(address indexed account, bytes2 country);
    event AccreditationSet(address indexed account, AccreditationTier tier);
    event LockupSet(address indexed account, uint64 expiry);
    event PausedSet(bool paused);

    /* ----------------------------------- Mutators --------------------------------- */
    function proposeRootUpdate(bytes32 newRoot) external;
    function applyRootUpdate() external;
    function cancelPendingRoot() external;
    function setJurisdictionBlocked(bytes2 country, bool blocked) external;
    function setCountry(address account, bytes2 country) external;
    function setAccreditation(address account, AccreditationTier tier) external;
    function setLockup(address account, uint64 expiry) external;
    function pause() external;
    function unpause() external;

    /* ----------------------------------- Views ------------------------------------ */
    function merkleRoot() external view returns (bytes32);
    function pendingRoot() external view returns (PendingRootUpdate memory);
    function isJurisdictionBlocked(bytes2 country) external view returns (bool);
    function countryOf(address account) external view returns (bytes2);
    function accreditationOf(address account) external view returns (AccreditationTier);
    function lockupExpiryOf(address account) external view returns (uint64);
    function paused() external view returns (bool);
}
