// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { AccreditationTier, LEAF_DOMAIN } from "../types/ComplianceTypes.sol";

/// @title  ComplianceLib
/// @author CodesenSys (https://codesensys.com)
/// @notice Pure verification helpers — leaf composition and Merkle membership.
/// @dev    Contains no storage. Every function must be `pure`. If you find
///         yourself reaching for state, you're in the wrong file.
library ComplianceLib {
    /// @notice Compose the canonical leaf hash for an (account, tier) pair.
    /// @dev    Includes the LEAF_DOMAIN separator to prevent leaf collisions
    ///         across protocol versions and chains.
    /// @param  account The address being attested to.
    /// @param  tier    The accreditation tier the off-chain process granted.
    /// @return leaf    The keccak256 hash to use as the Merkle leaf.
    function leafHash(address account, AccreditationTier tier) internal pure returns (bytes32 leaf) {
        // TODO: implement — keccak256(abi.encodePacked(LEAF_DOMAIN, account, uint8(tier)))
        // Choose abi.encode vs. abi.encodePacked deliberately. Document why.
        leaf = keccak256(abi.encodePacked(LEAF_DOMAIN, account, uint8(tier)));
    }

    /// @notice Verify a Merkle proof against a known root.
    /// @dev    Uses a hand-rolled hash chain rather than Solady to avoid the
    ///         calldata-vs-memory mismatch when callers pass `bytes32[] memory`.
    ///         For hot paths in the hook itself, prefer Solady's MerkleProofLib
    ///         directly to skip a copy.
    /// @param  root    The trusted root (from the ComplianceRegistry).
    /// @param  proof   The proof array.
    /// @param  account Address being verified.
    /// @param  tier    Tier being claimed.
    /// @return ok      True if the proof verifies.
    function verifyMembership(
        bytes32 root,
        bytes32[] memory proof,
        address account,
        AccreditationTier tier
    ) internal pure returns (bool ok) {
        // TODO: implement — compute leaf via leafHash, then walk the proof
        // hashing pairs in sorted order (matching @openzeppelin/merkle-tree's
        // StandardMerkleTree convention).
        bytes32 computed = leafHash(account, tier);
        for (uint256 i = 0; i < proof.length; i++) {
            bytes32 sibling = proof[i];
            computed = computed < sibling
                ? keccak256(abi.encode(computed, sibling))
                : keccak256(abi.encode(sibling, computed));
        }
        ok = (computed == root);
    }
}
