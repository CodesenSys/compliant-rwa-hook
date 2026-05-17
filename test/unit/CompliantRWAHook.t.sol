// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";

import { CompliantRWAHook } from "../../src/CompliantRWAHook.sol";
import { ComplianceRegistry } from "../../src/ComplianceRegistry.sol";
import { ComplianceLib } from "../../src/libraries/ComplianceLib.sol";
import { ICompliantRWAHook } from "../../src/interfaces/ICompliantRWAHook.sol";

import { Hooks } from "v4-core/src/libraries/Hooks.sol";
import { IHooks } from "v4-core/src/interfaces/IHooks.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/src/types/PoolId.sol";
import { Currency } from "v4-core/src/types/Currency.sol";
import { BalanceDelta, toBalanceDelta } from "v4-core/src/types/BalanceDelta.sol";
import { SwapParams, ModifyLiquidityParams } from "v4-core/src/types/PoolOperation.sol";

import {
    AccreditationTier,
    ComplianceError,
    ComplianceViolation,
    ROOT_UPDATE_DELAY
} from "../../src/types/ComplianceTypes.sol";

/// @title  CompliantRWAHookTest
/// @notice Unit tests for the V4 hook. Uses `deployCodeTo` to land the hook at
///         a permission-encoded address, then pranks the fake pool manager when
///         calling hook callbacks (the `onlyPoolManager` guard checks msg.sender).
contract CompliantRWAHookTest is Test {
    using PoolIdLibrary for PoolKey;

    // Permission bits for our hook: beforeSwap | afterSwap | beforeAddLiquidity | beforeRemoveLiquidity
    uint160 internal constant HOOK_FLAGS = Hooks.BEFORE_SWAP_FLAG
        | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG;

    CompliantRWAHook   internal hook;
    ComplianceRegistry internal registry;

    // Fake pool manager — we prank this address to pass `onlyPoolManager`.
    address internal manager    = address(0xD1D1D1D1);
    address internal admin      = address(0xAAA);
    address internal operator   = address(0xBBB);
    address internal compliance = address(0xCCC);
    address internal router     = address(0xF001); // plays the role of swap router (sender in callbacks)
    address internal user       = address(0x1111);

    // "US" is exactly 2 bytes — this cast never truncates.
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes2 internal constant COUNTRY_US = bytes2("US");

    PoolKey internal key;

    /* ----------------------------- Setup helpers ----------------------------- */

    function setUp() public {
        registry = new ComplianceRegistry(admin, operator, compliance);

        // Deploy the hook at the permission-encoded address using Foundry's
        // `deployCodeTo`. The address lower bits must match HOOK_FLAGS exactly
        // so that BaseHook.validateHookAddress does not revert.
        address hookAddr = address(HOOK_FLAGS);
        deployCodeTo(
            "CompliantRWAHook.sol",
            abi.encode(IPoolManager(manager), registry),
            hookAddr
        );
        hook = CompliantRWAHook(hookAddr);

        key = PoolKey({
            currency0:   Currency.wrap(address(0x1000)),
            currency1:   Currency.wrap(address(0x2000)),
            fee:         3000,
            tickSpacing: 60,
            hooks:       IHooks(address(hook))
        });
    }

    /// @dev Helper: propose + skip + apply a Merkle root so the registry is initialised.
    function _applyRoot(bytes32 root) internal {
        vm.prank(operator);
        registry.proposeRootUpdate(root);
        skip(ROOT_UPDATE_DELAY);
        registry.applyRootUpdate();
    }

    /// @dev Helper: set user's accreditation and compute a single-leaf Merkle root.
    ///      For a single-leaf tree: root == leaf, proof == [].
    function _whitelistUser(address account, AccreditationTier tier) internal returns (bytes32 root) {
        root = ComplianceLib.leafHash(account, tier);
        _applyRoot(root);
        vm.prank(operator);
        registry.setAccreditation(account, tier);
    }

    function _swapHookData(address account, bytes32[] memory proof, AccreditationTier tier)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(account, proof, tier);
    }

    function _liquidityHookData(address account, bytes32[] memory proof, AccreditationTier tier)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(account, proof, tier);
    }

    /* ----------------------- getHookPermissions ----------------------- */

    function test_getHookPermissions_returnsExpectedFlags() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeSwap);
        assertTrue(p.afterSwap);
        assertTrue(p.beforeAddLiquidity);
        assertTrue(p.beforeRemoveLiquidity);
        assertFalse(p.beforeInitialize);
        assertFalse(p.afterInitialize);
        assertFalse(p.afterAddLiquidity);
        assertFalse(p.afterRemoveLiquidity);
        assertFalse(p.beforeSwapReturnDelta);
        assertFalse(p.afterSwapReturnDelta);
    }

    /* ----------------------- beforeSwap tests ----------------------- */

    function test_beforeSwap_revertsWhenPaused() public {
        vm.prank(compliance);
        registry.pause();

        bytes memory hookData = _swapHookData(user, new bytes32[](0), AccreditationTier.None);
        SwapParams memory params = SwapParams({ zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0 });

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ComplianceViolation.selector, ComplianceError.POOL_PAUSED));
        hook.beforeSwap(router, key, params, hookData);
    }

    function test_beforeSwap_revertsWhenNotWhitelisted() public {
        // Root does not include the user — any non-matching root with empty proof fails.
        _applyRoot(keccak256("some other whitelist"));
        vm.prank(operator);
        registry.setAccreditation(user, AccreditationTier.Retail);

        bytes memory hookData = _swapHookData(user, new bytes32[](0), AccreditationTier.Retail);
        SwapParams memory params = SwapParams({ zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0 });

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ComplianceViolation.selector, ComplianceError.NOT_WHITELISTED));
        hook.beforeSwap(router, key, params, hookData);
    }

    function test_beforeSwap_succeedsForWhitelistedAddress() public {
        _whitelistUser(user, AccreditationTier.Retail);

        bytes memory hookData = _swapHookData(user, new bytes32[](0), AccreditationTier.Retail);
        SwapParams memory params = SwapParams({ zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0 });

        vm.prank(manager);
        (bytes4 selector,,) = hook.beforeSwap(router, key, params, hookData);
        assertEq(selector, IHooks.beforeSwap.selector);
    }

    function test_beforeSwap_revertsForBlockedJurisdiction() public {
        _whitelistUser(user, AccreditationTier.Retail);

        // Assign a blocked country to the user.
        vm.prank(operator);
        registry.setCountry(user, COUNTRY_US);
        vm.prank(compliance);
        registry.setJurisdictionBlocked(COUNTRY_US, true);

        bytes memory hookData = _swapHookData(user, new bytes32[](0), AccreditationTier.Retail);
        SwapParams memory params = SwapParams({ zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0 });

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ComplianceViolation.selector, ComplianceError.BLOCKED_JURISDICTION));
        hook.beforeSwap(router, key, params, hookData);
    }

    function test_beforeSwap_revertsDuringLockup() public {
        _whitelistUser(user, AccreditationTier.Retail);

        // Lock the user for 30 days.
        vm.prank(operator);
        registry.setLockup(user, uint64(block.timestamp + 30 days));

        bytes memory hookData = _swapHookData(user, new bytes32[](0), AccreditationTier.Retail);
        SwapParams memory params = SwapParams({ zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0 });

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ComplianceViolation.selector, ComplianceError.LOCKUP_ACTIVE));
        hook.beforeSwap(router, key, params, hookData);
    }

    function test_beforeSwap_revertsForInsufficientTier() public {
        // User is only Retail, but claims (and requires) Institutional.
        _whitelistUser(user, AccreditationTier.Retail);

        bytes memory hookData = _swapHookData(user, new bytes32[](0), AccreditationTier.Institutional);
        SwapParams memory params = SwapParams({ zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0 });

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ComplianceViolation.selector, ComplianceError.INSUFFICIENT_TIER));
        hook.beforeSwap(router, key, params, hookData);
    }

    /* ----------------------- afterSwap tests ----------------------- */

    function test_afterSwap_emitsAuditEvent() public {
        _whitelistUser(user, AccreditationTier.Retail);

        BalanceDelta delta = toBalanceDelta(int128(1e18), int128(-2e18));
        bytes memory hookData = _swapHookData(user, new bytes32[](0), AccreditationTier.Retail);
        SwapParams memory params = SwapParams({ zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0 });

        vm.expectEmit(true, true, false, true);
        emit ICompliantRWAHook.ComplianceAuditEvent(
            user,
            PoolId.unwrap(key.toId()),
            int256(int128(1e18)),
            int256(int128(-2e18)),
            AccreditationTier.Retail
        );

        vm.prank(manager);
        hook.afterSwap(router, key, params, delta, hookData);
    }

    /* ----------------------- beforeAddLiquidity tests ----------------------- */

    function test_beforeAddLiquidity_enforcesAccreditation() public {
        // User has Retail tier; root built for Retail.
        _whitelistUser(user, AccreditationTier.Retail);

        // Caller requests Institutional access in hookData, which exceeds user's tier.
        bytes memory hookData = _liquidityHookData(user, new bytes32[](0), AccreditationTier.Institutional);
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({ tickLower: -60, tickUpper: 60, liquidityDelta: 1e18, salt: bytes32(0) });

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ComplianceViolation.selector, ComplianceError.INSUFFICIENT_TIER));
        hook.beforeAddLiquidity(router, key, params, hookData);
    }

    function test_beforeAddLiquidity_succeedsForCompliantLP() public {
        _whitelistUser(user, AccreditationTier.Retail);

        bytes memory hookData = _liquidityHookData(user, new bytes32[](0), AccreditationTier.Retail);
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({ tickLower: -60, tickUpper: 60, liquidityDelta: 1e18, salt: bytes32(0) });

        vm.prank(manager);
        bytes4 selector = hook.beforeAddLiquidity(router, key, params, hookData);
        assertEq(selector, IHooks.beforeAddLiquidity.selector);
    }

    /* ----------------------- beforeRemoveLiquidity tests ----------------------- */

    function test_beforeRemoveLiquidity_honorsLockup() public {
        // Set a lockup in the future.
        vm.prank(operator);
        registry.setLockup(user, uint64(block.timestamp + 30 days));

        bytes memory hookData = abi.encode(user);
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({ tickLower: -60, tickUpper: 60, liquidityDelta: -1e18, salt: bytes32(0) });

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ComplianceViolation.selector, ComplianceError.LOCKUP_ACTIVE));
        hook.beforeRemoveLiquidity(router, key, params, hookData);
    }

    function test_beforeRemoveLiquidity_succeedsAfterLockupExpires() public {
        vm.prank(operator);
        registry.setLockup(user, uint64(block.timestamp + 30 days));

        skip(30 days + 1);

        bytes memory hookData = abi.encode(user);
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({ tickLower: -60, tickUpper: 60, liquidityDelta: -1e18, salt: bytes32(0) });

        vm.prank(manager);
        bytes4 selector = hook.beforeRemoveLiquidity(router, key, params, hookData);
        assertEq(selector, IHooks.beforeRemoveLiquidity.selector);
    }
}
