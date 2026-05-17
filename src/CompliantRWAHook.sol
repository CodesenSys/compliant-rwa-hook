// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { BaseHook } from "v4-periphery/src/utils/BaseHook.sol";
import { Hooks } from "v4-core/src/libraries/Hooks.sol";
import { IHooks } from "v4-core/src/interfaces/IHooks.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/src/types/PoolId.sol";
import { BalanceDelta } from "v4-core/src/types/BalanceDelta.sol";
import { BeforeSwapDelta, BeforeSwapDeltaLibrary } from "v4-core/src/types/BeforeSwapDelta.sol";
import { SwapParams, ModifyLiquidityParams } from "v4-core/src/types/PoolOperation.sol";

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
///         the REGISTRY can be updated without redeploying the hook (the
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
    IComplianceRegistry public immutable REGISTRY;

    /// @notice Per-pool minimum accreditation tier override. If unset
    ///         (Tier.None), the hook falls back to the tier encoded in
    ///         `hookData` per call.
    mapping(PoolId poolId => AccreditationTier minTier) public minTierByPool;

    /* ------------------------------ Constructor ------------------------------ */

    /// @notice Deploy the hook. The `_poolManager` and `_REGISTRY` references
    ///         are immutable — re-pointing requires a fresh hook deployment
    ///         (and re-mined address).
    constructor(IPoolManager _poolManager, IComplianceRegistry _registry) BaseHook(_poolManager) {
        REGISTRY = _registry;
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
    ///         The effective tier is max(minTierByPool[pool], tier from hookData).
    function _beforeSwap(
        address, /* sender (router — NOT the user) */
        PoolKey calldata key,
        SwapParams calldata, /* params */
        bytes calldata hookData
    ) internal view override returns (bytes4, BeforeSwapDelta, uint24) {
        if (REGISTRY.paused()) revert ComplianceViolation(ComplianceError.POOL_PAUSED);

        (address user, bytes32[] memory proof, AccreditationTier tier) =
            abi.decode(hookData, (address, bytes32[], AccreditationTier));

        // Pool-level minimum overrides caller-supplied tier when it's stricter.
        AccreditationTier effectiveTier = minTierByPool[key.toId()];
        if (uint8(effectiveTier) < uint8(tier)) effectiveTier = tier;

        _verifyCompliance(user, proof, effectiveTier);

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @notice Emit a compliance audit event after a successful swap.
    /// @dev    Re-decodes hookData to recover user and tier for the event.
    ///         Gas cost is marginal since the bytes are already in calldata.
    function _afterSwap(
        address, /* sender */
        PoolKey calldata key,
        SwapParams calldata, /* params */
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        (address user,, AccreditationTier tier) =
            abi.decode(hookData, (address, bytes32[], AccreditationTier));

        emit ComplianceAuditEvent(
            user,
            PoolId.unwrap(key.toId()),
            int256(delta.amount0()),
            int256(delta.amount1()),
            tier
        );

        return (IHooks.afterSwap.selector, 0);
    }

    /// @notice Verify LP compliance before liquidity is added.
    /// @dev    hookData format: `(address lp, bytes32[] proof, AccreditationTier tier)`.
    ///         Effective tier = max(minTierByPool[pool], tier from hookData).
    function _beforeAddLiquidity(
        address, /* sender */
        PoolKey calldata key,
        ModifyLiquidityParams calldata, /* params */
        bytes calldata hookData
    ) internal view override returns (bytes4) {
        if (REGISTRY.paused()) revert ComplianceViolation(ComplianceError.POOL_PAUSED);

        (address lp, bytes32[] memory proof, AccreditationTier tier) =
            abi.decode(hookData, (address, bytes32[], AccreditationTier));

        AccreditationTier effectiveTier = minTierByPool[key.toId()];
        if (uint8(effectiveTier) < uint8(tier)) effectiveTier = tier;

        _verifyCompliance(lp, proof, effectiveTier);

        return IHooks.beforeAddLiquidity.selector;
    }

    /// @notice Honour lockup window before liquidity is removed.
    /// @dev    hookData format: `(address lp)`. Only the address is needed;
    ///         the lockup state is read entirely from the REGISTRY.
    function _beforeRemoveLiquidity(
        address, /* sender */
        PoolKey calldata, /* key */
        ModifyLiquidityParams calldata, /* params */
        bytes calldata hookData
    ) internal view override returns (bytes4) {
        address lp = abi.decode(hookData, (address));

        if (block.timestamp < REGISTRY.lockupExpiryOf(lp)) {
            revert ComplianceViolation(ComplianceError.LOCKUP_ACTIVE);
        }

        return IHooks.beforeRemoveLiquidity.selector;
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
        if (block.timestamp < REGISTRY.lockupExpiryOf(account)) {
            revert ComplianceViolation(ComplianceError.LOCKUP_ACTIVE);
        }

        // 2. Jurisdiction
        if (REGISTRY.isJurisdictionBlocked(REGISTRY.countryOf(account))) {
            revert ComplianceViolation(ComplianceError.BLOCKED_JURISDICTION);
        }

        // 3. Tier (read on-chain accreditation; a Merkle leaf can claim a
        //    higher tier than the REGISTRY holds — that's an attack vector)
        if (uint8(REGISTRY.accreditationOf(account)) < uint8(requiredTier)) {
            revert ComplianceViolation(ComplianceError.INSUFFICIENT_TIER);
        }

        // 4. Membership (Merkle proof against current root)
        if (!ComplianceLib.verifyMembership(REGISTRY.merkleRoot(), proof, account, requiredTier)) {
            revert ComplianceViolation(ComplianceError.NOT_WHITELISTED);
        }
    }

    /* --------------------------------- Views --------------------------------- */

    /// @inheritdoc ICompliantRWAHook
    function complianceRegistry() external view returns (address) {
        return address(REGISTRY);
    }
}
