// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { AccreditationTier } from "../types/ComplianceTypes.sol";

/// @title  ICompliantRWAHook
/// @author CodesenSys (https://codesensys.com)
/// @notice External interface for the CompliantRWAHook contract.
interface ICompliantRWAHook {
    /// @notice Emitted on every successful (post-checks) swap routed through the hook.
    event ComplianceAuditEvent(
        address indexed swapper,
        bytes32 indexed poolId,
        int256 amount0Delta,
        int256 amount1Delta,
        AccreditationTier tier
    );

    /// @notice Returns the address of the ComplianceRegistry the hook reads from.
    function complianceRegistry() external view returns (address);
}
