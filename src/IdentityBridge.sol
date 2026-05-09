// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC3643Bridge } from "./interfaces/IERC3643Bridge.sol";

/// @title  IdentityBridge
/// @author CodesenSys (https://codesensys.com)
/// @notice Optional adapter exposing a unified `isCompliant` view over an
///         existing ERC-3643 / T-REX IdentityRegistry. Protocols not using
///         T-REX can pass `address(0)` as the bridge and pay zero gas for
///         this layer.
/// @dev    Storage of jurisdictional flags lives here, NOT in T-REX, since
///         T-REX exposes country codes but not block lists. The bridge owns
///         the block list; the underlying registry owns identity verification.
contract IdentityBridge {
    /* -------------------------------- Storage -------------------------------- */

    /// @notice The underlying ERC-3643 IdentityRegistry. `address(0)` disables
    ///         the bridge and `isCompliant` short-circuits to `false`.
    IERC3643Bridge public immutable tRexRegistry;

    /// @notice Owner authorised to mutate jurisdictional blocks here. In
    ///         production wire this to the same address as the
    ///         ComplianceRegistry's COMPLIANCE_ROLE for consistency.
    address public immutable owner;

    /// @notice Blocked jurisdictions, keyed by ISO 3166-1 numeric code.
    mapping(uint16 country => bool blocked) internal _blockedJurisdictions;

    /* --------------------------------- Events -------------------------------- */

    event JurisdictionBlocked(uint16 indexed country, bool blocked);

    /* --------------------------------- Errors -------------------------------- */

    error NotOwner();
    error BridgeDisabled();

    /* ------------------------------ Constructor ------------------------------ */

    /// @notice Wire the bridge. Pass `address(0)` to deploy in disabled mode.
    /// @param  _tRexRegistry The ERC-3643 IdentityRegistry to read from.
    /// @param  _owner        Address authorised to mutate jurisdictional state.
    constructor(IERC3643Bridge _tRexRegistry, address _owner) {
        tRexRegistry = _tRexRegistry;
        owner = _owner;
    }

    /* ------------------------------- Mutators -------------------------------- */

    /// @notice Block or unblock a jurisdiction by ISO 3166-1 numeric code.
    function setJurisdictionBlocked(uint16 country, bool blocked) external {
        if (msg.sender != owner) revert NotOwner();
        _blockedJurisdictions[country] = blocked;
        emit JurisdictionBlocked(country, blocked);
    }

    /* --------------------------------- Views --------------------------------- */

    /// @notice Returns true if `account` is verified in the underlying T-REX
    ///         registry AND not resident in a blocked jurisdiction.
    /// @dev    Returns false unconditionally if the bridge is disabled
    ///         (`tRexRegistry == address(0)`). Callers can choose whether
    ///         disabled-bridge means "skip this layer" or "deny by default".
    /// @param  account      The address being checked.
    /// @param  jurisdiction Optional caller-supplied jurisdiction (e.g., from
    ///                      a separate KYC source). Pass `bytes2(0)` to skip
    ///                      and rely solely on the registry's `investorCountry`.
    function isCompliant(address account, bytes2 jurisdiction) external view returns (bool) {
        if (address(tRexRegistry) == address(0)) return false;

        if (!tRexRegistry.isVerified(account)) return false;

        // TODO: implement
        // - if `jurisdiction` is non-zero, check _blockedJurisdictions[uint16(jurisdiction)]
        // - else fetch tRexRegistry.investorCountry(account) and check
        // - return true only if NOT blocked
        revert("TODO: implement isCompliant jurisdictional path");
    }

    /// @notice True if a jurisdiction is on the bridge's blocklist.
    function isJurisdictionBlocked(uint16 country) external view returns (bool) {
        return _blockedJurisdictions[country];
    }
}
