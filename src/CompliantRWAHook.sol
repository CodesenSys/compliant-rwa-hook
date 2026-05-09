// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { BaseHook } from "v4-periphery/src/utils/BaseHook.sol";
import { Hooks } from "v4-core/src/libraries/Hooks.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/src/types/PoolId.sol";
import { BalanceDelta } from "v4-core/src/types/BalanceDelta.sol";
import { BeforeSwapDelta, BeforeSwapDeltaLibrary } from "v4-core/src/types/BeforeSwapDelta.sol";

import { IComplianceRegistry } from "./interfaces/IComplianceRegistry.sol";
import { ICompliantRWAHook } from "./interfaces/ICompliantRWAHook.sol";
import { ComplianceLib } from "./libraries/ComplianceLib.sol";
import {
    AccreditationTier,
    ComplianceError,
    ComplianceViolation
} from "./types/ComplianceTypes.sol";

/// @title  CompliantRWAHook
/// @author CodesenSys (https://codesensys.com)
/// @notice Uniswap V4 hook that gates swap and liquidity actions on a
///         compliance check (Merkle-proven KYC, jurisdiction, lockup, tier).
/// @dev    Reads compliance state from a separate ComplianceRegistry so that
///         the registry can be updated without redeploying the hook (the
///         hook's address encodes its V4 permissions and is therefore tied
///         to its bytecode and salt forever).
///
///         IMPORTANT — V4 hook address mining: this contract MUST be deployed
///         to an address whose lower bits encode the permissions returned by
///         `getHookPermissions()`. Use `HookMiner.find(...)` in the deploy
///         script to compute the correct CREATE2 salt before deployment.
///
///         IMPORTANT — `sender` semantics: in V4, the `sender` parameter
///         passed to hook callbacks is the *swap router*, not the user. The
///         actual user/swapper must be passed explicitly through `hookData`.
///         Most V4 hook bugs in the wild live exactly here; do not skim.
contract CompliantRWAHook is BaseHook, ICompliantRWAHook {
    using PoolIdLibrary for PoolKey;

    /* -------------------------------- Storage -------------------------------- */

    /// @notice The compliance state oracle.
    IComplianceRegistry public immutable registry;

    /// @notice Per-pool minimum accreditation tier override. If unset
    ///         (Tier.None), the hook falls back to the tier encoded in
    ///         `hookData` per call.
    mapping(PoolId poolId => AccreditationTier minTier) public minTierByPool;

    /* ------------------------------ Constructor ------------------------------ */

    /// @notice Deploy the hook. The `_poolManager` and `_registry` references
    ///         are immutable — re-pointing requires a fresh hook deployment
    ///         (and re-mined address).
    constructor(IPoolManager _poolManager, IComplianceRegistry _registry) BaseHook(_poolManager) {
        registry = _registry;
    }

    /* ------------------------------ Permissions ------------------------------ */

    /// @inheritdoc BaseHook
    /// @dev The address-bit pattern for these permissions must be enforced at
    ///      deploy time via HookMiner. If the deployed address doesn't match,
    ///      `BaseHook.validateHookAddress` will revert during construction.
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /* ----------------------------- Hook callbacks ---------------------------- */

    /// @notice Verify swapper compliance before the swap is settled.
    /// @dev    `sender` is the swap router. The actual user must be encoded
    ///         in `hookData` as `(address user, bytes32[] proof, AccreditationTier tier)`.
    function _beforeSwap(
        address, /* sender (router) */
        PoolKey calldata key,
        IPoolManager.SwapParams calldata, /* params */
        bytes calldata hookData
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        if (registry.paused()) revert ComplianceViolation(ComplianceError.POOL_PAUSED);

        // TODO: implement
        // - decode hookData -> (address user, bytes32[] proof, AccreditationTier tier)
        // - resolve effective minimum tier: minTierByPool[key.toId()] OR tier from hookData
        // - call _verifyCompliance(user, proof, effectiveTier)
        revert("TODO: implement _beforeSwap");
    }

    /// @notice Emit a compliance audit event after a successful swap.
    function _afterSwap(
        address, /* sender */
        PoolKey calldata key,
        IPoolManager.SwapParams calldata, /* params */
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        // TODO: implement
        // - decode hookData enough to recover `user` and `tier`
        // - emit ComplianceAuditEvent(user, key.toId(), delta.amount0(), delta.amount1(), tier)
        revert("TODO: implement _afterSwap");
    }

    /// @notice Verify LP compliance before liquidity is added.
    function _beforeAddLiquidity(
        address, /* sender */
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata, /* params */
        bytes calldata hookData
    ) internal override returns (bytes4) {
        if (registry.paused()) revert ComplianceViolation(ComplianceError.POOL_PAUSED);

        // TODO: implement
        // - decode hookData -> (address lp, bytes32[] proof, AccreditationTier tier)
        // - call _verifyCompliance(lp, proof, tier)
        // - additionally enforce a minimum tier if minTierByPool[key.toId()] is set
        revert("TODO: implement _beforeAddLiquidity");
    }

    /// @notice Honour lockup window before liquidity is removed.
    function _beforeRemoveLiquidity(
        address, /* sender */
        PoolKey calldata, /* key */
        IPoolManager.ModifyLiquidityParams calldata, /* params */
        bytes calldata hookData
    ) internal override returns (bytes4) {
        // TODO: implement
        // - decode hookData -> (address lp)
        // - check registry.lockupExpiryOf(lp) <= block.timestamp
        // - revert ComplianceViolation(ComplianceError.LOCKUP_ACTIVE) otherwise
        revert("TODO: implement _beforeRemoveLiquidity");
    }

    /* --------------------------- Internal compliance ------------------------- */

    /// @notice The four-step verification chain run on every gated callback.
    /// @dev    Order matters: cheaper checks first to fail fast on the
    ///         common case. Merkle verification is the most expensive step
    ///         (~6.5k gas at depth 14), so it goes last.
    function _verifyCompliance(
        address account,
        bytes32[] memory proof,
        AccreditationTier requiredTier
    ) internal view {
        // 1. Lockup
        if (block.timestamp < registry.lockupExpiryOf(account)) {
            revert ComplianceViolation(ComplianceError.LOCKUP_ACTIVE);
        }

        // 2. Jurisdiction
        if (registry.isJurisdictionBlocked(registry.countryOf(account))) {
            revert ComplianceViolation(ComplianceError.BLOCKED_JURISDICTION);
        }

        // 3. Tier (read on-chain accreditation; a Merkle leaf can claim a
        //    higher tier than the registry holds — that's an attack vector)
        if (uint8(registry.accreditationOf(account)) < uint8(requiredTier)) {
            revert ComplianceViolation(ComplianceError.INSUFFICIENT_TIER);
        }

        // 4. Membership (Merkle proof against current root)
        if (!ComplianceLib.verifyMembership(registry.merkleRoot(), proof, account, requiredTier)) {
            revert ComplianceViolation(ComplianceError.NOT_WHITELISTED);
        }
    }

    /* -------------------------------- Admin ---------------------------------- */

    // NOTE: per the architecture, the hook itself is intentionally minimal in
    // admin surface. Per-pool minimum tier configuration COULD live here, but
    // for v0.1 it lives in PoolKey extra-data parsing. Revisit in v0.2.

    /* --------------------------------- Views --------------------------------- */

    /// @inheritdoc ICompliantRWAHook
    function complianceRegistry() external view returns (address) {
        return address(registry);
    }
}
