// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title  IERC3643Bridge
/// @author CodesenSys (https://codesensys.com)
/// @notice Minimal interface to an ERC-3643 / T-REX IdentityRegistry, exposing
///         only the calls the IdentityBridge adapter needs.
interface IERC3643Bridge {
    function isVerified(address account) external view returns (bool);
    function investorCountry(address account) external view returns (uint16);
}
