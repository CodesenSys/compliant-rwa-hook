// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title  ComplianceTypes
/// @author CodesenSys (https://codesensys.com)
/// @notice Shared types and errors for the Compliant RWA Hook system.
/// @dev    Every module imports from this file. Keep it minimal and stable —
///         changes here ripple across the entire codebase.

/// @notice Investor accreditation tiers. Numeric ordering establishes privilege:
///         Institutional (3) > Qualified (2) > Retail (1) > None (0).
enum AccreditationTier {
    None,
    Retail,
    Qualified,
    Institutional
}

/// @notice Categorical reasons for compliance violations. Carried by the
///         `ComplianceViolation` error so off-chain consumers can branch.
enum ComplianceError {
    NOT_WHITELISTED,
    BLOCKED_JURISDICTION,
    LOCKUP_ACTIVE,
    INSUFFICIENT_TIER,
    POOL_PAUSED,
    INVALID_PROOF
}

/// @notice Vesting schedule attached to a lockup position. Tracks cliff,
///         full-vest timestamp, and the notional amount locked.
/// @dev    cliff + vestingEnd (96 bits) + amount (128 bits) = 224 bits,
///         fitting in one slot with 32 bits to spare for future extension.
struct LockupSchedule {
    uint48 cliff; // earliest timestamp at which any amount may move
    uint48 vestingEnd; // timestamp at which the full amount is released
    uint128 amount; // token amount subject to this schedule
}

/// @notice Storage record for a pending Merkle root update. Updates are
///         timelocked to prevent operator key compromise from instantly
///         draining a regulated pool.
/// @dev    Packed into a single 32-byte slot.
struct PendingRootUpdate {
    bytes32 root; // 32 bytes — occupies one slot
    uint64 effectiveAt; // packs into the next slot with other fields if extended later
}

/* -------------------------------------------------------------------------- */
/*                               Custom Errors                                */
/* -------------------------------------------------------------------------- */

/// @notice Thrown when any compliance check fails. The `reason` enum lets the
///         caller and indexers distinguish failure modes without parsing strings.
error ComplianceViolation(ComplianceError reason);

/// @notice Thrown when an unprivileged caller invokes an admin function.
error UnauthorizedOperator();

/// @notice Thrown when `applyRootUpdate` is called before the timelock matures.
error TooEarly();

/// @notice Thrown when an invariant on the Merkle root is broken
///         (e.g., setting `bytes32(0)`).
error InvalidMerkleRoot();

/// @notice Thrown if a stale or already-applied root is somehow re-applied.
error RootStale();

/// @notice Thrown when reads occur before the registry's first root is set.
error NotInitialized();

/* -------------------------------------------------------------------------- */
/*                                  Constants                                 */
/* -------------------------------------------------------------------------- */

// Delay between proposing and applying a Merkle root update.
// 24 hours. Non-configurable by design — predictability is the point.
uint64 constant ROOT_UPDATE_DELAY = 24 hours;

// Hard cap on lockup durations to prevent griefing/admin error.
uint64 constant MAX_LOCKUP_DURATION = 3650 days; // ~10 years

// Domain separator for Merkle leaf hashing. Versioned to allow
// non-conflicting reuse across protocol revisions.
bytes32 constant LEAF_DOMAIN = keccak256("CodesenSys.RWA.Compliance.v1");
