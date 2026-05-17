// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script, console2 } from "forge-std/Script.sol";

import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/src/types/PoolId.sol";
import { Currency } from "v4-core/src/types/Currency.sol";
import { IHooks } from "v4-core/src/interfaces/IHooks.sol";

import { ComplianceRegistry } from "../src/ComplianceRegistry.sol";
import { AccreditationTier } from "../src/types/ComplianceTypes.sol";

import { MockERC20 } from "./helpers/MockERC20.sol";
import { PoolInitializer } from "./helpers/PoolInitializer.sol";

/// @title  SeedLiquidity
/// @author CodesenSys (https://codesensys.com)
/// @notice Step 2 of deployment: apply the timelocked Merkle root and seed
///         an initial liquidity position in the compliant RWA pool.
/// @dev    Must be run at least 24 hours after Deploy.s.sol to satisfy the
///         ROOT_UPDATE_DELAY timelock in ComplianceRegistry.
///
///         Required env vars:
///           DEPLOYER_PRIVATE_KEY  — same key used in Deploy.s.sol
///           POOL_MANAGER          — V4 PoolManager address
///           COMPLIANCE_REGISTRY   — ComplianceRegistry address (from deploy manifest)
///           HOOK                  — CompliantRWAHook address (from deploy manifest)
///           TOKEN0                — currency0 address (lower of the two tokens)
///           TOKEN1                — currency1 address (higher of the two tokens)
contract SeedLiquidity is Script {
    using PoolIdLibrary for PoolKey;

    // Liquidity position parameters — a narrow ±600-tick band around the 1:1 price.
    int24 internal constant TICK_LOWER = -600;
    int24 internal constant TICK_UPPER = 600;

    // Liquidity units to seed. At the 1:1 price and this tick range, roughly
    // equal amounts of token0 and token1 will be consumed.
    int256 internal constant LIQUIDITY_DELTA = 1e18;

    // Generous token buffer to cover the seed position plus rounding.
    uint256 internal constant TOKEN_BUFFER_18 = 10_000e18;
    uint256 internal constant TOKEN_BUFFER_6 = 10_000e6;

    uint24 internal constant LP_FEE = 3000;
    int24 internal constant TICK_SPACING = 60;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        IPoolManager poolManager = IPoolManager(vm.envAddress("POOL_MANAGER"));
        ComplianceRegistry registry = ComplianceRegistry(vm.envAddress("COMPLIANCE_REGISTRY"));
        address hookAddr = vm.envAddress("HOOK");
        address token0Addr = vm.envAddress("TOKEN0");
        address token1Addr = vm.envAddress("TOKEN1");

        vm.startBroadcast(deployerKey);

        // ── 1. Apply the timelocked Merkle root ──────────────────────────────
        // Anyone can call applyRootUpdate — no operator key required.
        registry.applyRootUpdate();
        console2.log("Merkle root applied:", vm.toString(registry.merkleRoot()));

        // ── 2. Deploy PoolInitializer ─────────────────────────────────────────
        PoolInitializer initializer = new PoolInitializer(poolManager);
        console2.log("PoolInitializer:     ", address(initializer));

        // ── 3. Transfer seed tokens to the PoolInitializer ───────────────────
        // The PoolInitializer will settle directly from its own balance during
        // the unlock callback, so no approval to the PoolManager is needed.
        MockERC20 t0 = MockERC20(token0Addr);
        MockERC20 t1 = MockERC20(token1Addr);

        // Determine the correct buffer per token based on decimals.
        uint256 buf0 = t0.decimals() == 18 ? TOKEN_BUFFER_18 : TOKEN_BUFFER_6;
        uint256 buf1 = t1.decimals() == 18 ? TOKEN_BUFFER_18 : TOKEN_BUFFER_6;

        t0.mint(address(initializer), buf0);
        t1.mint(address(initializer), buf1);
        console2.log("Tokens minted to PoolInitializer.");

        // ── 4. Reconstruct the pool key ───────────────────────────────────────
        // TOKEN0 / TOKEN1 env vars must already be sorted (token0 < token1)
        // as written by Deploy.s.sol.
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(token0Addr),
            currency1: Currency.wrap(token1Addr),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hookAddr)
        });

        // ── 5. Build hookData for beforeAddLiquidity ──────────────────────────
        // Single-leaf proof: root = leafHash(deployer, Retail), proof = [].
        bytes32[] memory proof = new bytes32[](0);
        bytes memory hookData = abi.encode(deployer, proof, AccreditationTier.Retail);

        // ── 6. Seed the position ──────────────────────────────────────────────
        PoolInitializer.LiquidityParams memory params = PoolInitializer.LiquidityParams({
            key: key,
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            liquidityDelta: LIQUIDITY_DELTA,
            hookData: hookData
        });

        initializer.addLiquidity(params);
        console2.log("Initial liquidity seeded. Pool ready.");
        console2.log("PoolId:");
        console2.logBytes32(PoolId.unwrap(key.toId()));

        vm.stopBroadcast();
    }
}
