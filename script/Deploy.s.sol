// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script, console2 } from "forge-std/Script.sol";

import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/src/types/PoolId.sol";
import { Currency } from "v4-core/src/types/Currency.sol";
import { IHooks } from "v4-core/src/interfaces/IHooks.sol";
import { Hooks } from "v4-core/src/libraries/Hooks.sol";

import { HookMiner } from "v4-hooks-public/src/utils/HookMiner.sol";

import { ComplianceRegistry } from "../src/ComplianceRegistry.sol";
import { CompliantRWAHook } from "../src/CompliantRWAHook.sol";
import { ComplianceLib } from "../src/libraries/ComplianceLib.sol";
import { AccreditationTier } from "../src/types/ComplianceTypes.sol";

import { MockERC20 } from "./helpers/MockERC20.sol";

/// @title  Deploy
/// @author CodesenSys (https://codesensys.com)
/// @notice Full system deployment: ComplianceRegistry → hook (CREATE2-mined) →
///         mock tokens → V4 pool initialisation → initial Merkle root proposal.
/// @dev    Run order:
///         1.  forge script script/Deploy.s.sol --rpc-url $BASE_SEPOLIA_RPC_URL --broadcast --verify
///         2.  Wait 24 h for the timelock to mature.
///         3.  forge script script/SeedLiquidity.s.sol --rpc-url $BASE_SEPOLIA_RPC_URL --broadcast
///
///         Required env vars:
///           DEPLOYER_PRIVATE_KEY  — private key of the deploying EOA
///           POOL_MANAGER          — address of the V4 PoolManager on the target chain
///
///         Optional env vars (default to deployer address):
///           OPERATOR_ADDRESS      — address granted OPERATOR_ROLE
///           COMPLIANCE_ADDRESS    — address granted COMPLIANCE_ROLE
contract Deploy is Script {
    using PoolIdLibrary for PoolKey;

    // Foundry's deterministic CREATE2 factory — pre-deployed on all major networks.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // Pool parameters for the demo RWA/USDC pool.
    uint24 internal constant LP_FEE = 3000; // 0.30 %
    int24 internal constant TICK_SPACING = 60;

    // sqrt(1) * 2^96 — represents a 1:1 exchange rate between token0 and token1.
    uint160 internal constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;

    // Seed amounts minted to the deployer for later liquidity provision.
    uint256 internal constant SEED_RWA = 1_000_000e18; // 1 M RWA tokens
    uint256 internal constant SEED_USDC = 1_000_000e6; // 1 M mock USDC

    // Hook permission flags — must match getHookPermissions() exactly.
    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
    );

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address operator = vm.envOr("OPERATOR_ADDRESS", deployer);
        address compliance = vm.envOr("COMPLIANCE_ADDRESS", deployer);
        IPoolManager poolManager = IPoolManager(vm.envAddress("POOL_MANAGER"));

        // ── 1. ComplianceRegistry ────────────────────────────────────────────
        vm.startBroadcast(deployerKey);

        ComplianceRegistry registry = new ComplianceRegistry(deployer, operator, compliance);
        console2.log("ComplianceRegistry:  ", address(registry));

        vm.stopBroadcast();

        // ── 2. Mine hook address (off-chain — no broadcast needed) ───────────
        // HookMiner iterates CREATE2 salts until the resulting address has the
        // permission bits encoded in its lower 14 bits. This is V4's mechanism
        // for validating that a hook declares its callbacks honestly.
        (address hookAddr, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            HOOK_FLAGS,
            type(CompliantRWAHook).creationCode,
            abi.encode(poolManager, address(registry))
        );
        console2.log("Mined hook address:  ", hookAddr);
        console2.log("CREATE2 salt:        ");
        console2.logBytes32(salt);

        // ── 3. Deploy hook at mined address (CREATE2) ────────────────────────
        vm.startBroadcast(deployerKey);

        CompliantRWAHook hook = new CompliantRWAHook{ salt: salt }(poolManager, registry);
        require(address(hook) == hookAddr, "Deploy: hook address mismatch");
        console2.log("CompliantRWAHook:    ", address(hook));

        // ── 4. Mock tokens (RWA + USDC) ─────────────────────────────────────
        MockERC20 rwaToken = new MockERC20("Mock RWA Token", "mRWA", 18);
        MockERC20 usdc = new MockERC20("Mock USDC", "mUSDC", 6);

        // Mint seed amounts to the deployer for subsequent liquidity provision.
        rwaToken.mint(deployer, SEED_RWA);
        usdc.mint(deployer, SEED_USDC);

        console2.log("MockRWAToken:        ", address(rwaToken));
        console2.log("MockUSDC:            ", address(usdc));

        // ── 5. Initialize V4 pool ────────────────────────────────────────────
        // V4 requires currency0 < currency1 by address value.
        (address token0Addr, address token1Addr) = address(rwaToken) < address(usdc)
            ? (address(rwaToken), address(usdc))
            : (address(usdc), address(rwaToken));

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(token0Addr),
            currency1: Currency.wrap(token1Addr),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        // initialize() does not route through beforeInitialize (we don't implement it),
        // so no hookData is required here.
        poolManager.initialize(key, SQRT_PRICE_1_1);
        console2.log("Pool initialized.    PoolId:");
        console2.logBytes32(PoolId.unwrap(key.toId()));

        // ── 6. Propose initial Merkle root (deployer whitelisted at Retail) ──
        // Single-leaf tree: root == leafHash(deployer, Retail).
        // Proof for the deployer is the empty array.
        // Apply via SeedLiquidity.s.sol after the 24 h timelock.
        bytes32 initialRoot = ComplianceLib.leafHash(deployer, AccreditationTier.Retail);
        registry.setAccreditation(deployer, AccreditationTier.Retail);
        registry.proposeRootUpdate(initialRoot);
        console2.log("Root proposed (apply after 24 h):");
        console2.logBytes32(initialRoot);

        vm.stopBroadcast();

        // ── 7. Write deployment manifest ─────────────────────────────────────
        _writeManifest(
            address(registry),
            address(hook),
            address(rwaToken),
            address(usdc),
            PoolId.unwrap(key.toId()),
            initialRoot
        );

        console2.log("");
        console2.log("=== NEXT STEPS ===");
        console2.log("1. Wait 24 h for the Merkle root timelock to mature.");
        console2.log("2. Run: forge script script/SeedLiquidity.s.sol \\");
        console2.log("        --rpc-url $BASE_SEPOLIA_RPC_URL --broadcast");
        console2.log("   with env: COMPLIANCE_REGISTRY=", address(registry));
        console2.log("   with env: POOL_MANAGER=", address(poolManager));
        console2.log("   with env: HOOK=", address(hook));
        console2.log("   with env: TOKEN0=", token0Addr);
        console2.log("   with env: TOKEN1=", token1Addr);
    }

    /* ─────────────────────────── Manifest helpers ─────────────────────────── */

    function _writeManifest(
        address registry,
        address hook,
        address rwaToken,
        address usdc,
        bytes32 poolId,
        bytes32 initialRoot
    ) internal {
        string memory obj = "deploy";
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeAddress(obj, "ComplianceRegistry", registry);
        vm.serializeAddress(obj, "CompliantRWAHook", hook);
        vm.serializeAddress(obj, "MockRWAToken", rwaToken);
        vm.serializeAddress(obj, "MockUSDC", usdc);
        vm.serializeBytes32(obj, "poolId", poolId);
        string memory final_ = vm.serializeBytes32(obj, "initialMerkleRoot", initialRoot);

        string memory path = string.concat("deployments/", _networkName(block.chainid), ".json");
        vm.writeJson(final_, path);
        console2.log("Manifest written to:", path);
    }

    function _networkName(uint256 chainId) internal pure returns (string memory) {
        if (chainId == 84_532) return "base-sepolia";
        if (chainId == 11_155_111) return "sepolia";
        if (chainId == 8453) return "base";
        if (chainId == 1) return "mainnet";
        return string.concat("chain-", vm.toString(chainId));
    }
}
