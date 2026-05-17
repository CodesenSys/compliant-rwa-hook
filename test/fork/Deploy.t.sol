// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test, console2 } from "forge-std/Test.sol";

import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { SwapParams } from "v4-core/src/types/PoolOperation.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { PoolIdLibrary } from "v4-core/src/types/PoolId.sol";
import { Currency } from "v4-core/src/types/Currency.sol";
import { IHooks } from "v4-core/src/interfaces/IHooks.sol";
import { Hooks } from "v4-core/src/libraries/Hooks.sol";

import { HookMiner } from "v4-hooks-public/src/utils/HookMiner.sol";

import { ComplianceRegistry } from "../../src/ComplianceRegistry.sol";
import { CompliantRWAHook } from "../../src/CompliantRWAHook.sol";
import { ComplianceLib } from "../../src/libraries/ComplianceLib.sol";
import { AccreditationTier, ROOT_UPDATE_DELAY, ComplianceViolation, ComplianceError } from "../../src/types/ComplianceTypes.sol";

import { MockERC20 } from "../../script/helpers/MockERC20.sol";
import { PoolInitializer } from "../../script/helpers/PoolInitializer.sol";

/// @title  DeployTest
/// @notice Fork test that exercises the full Deploy + SeedLiquidity flow against
///         a live chain fork. Skipped when POOL_MANAGER is not set.
/// @dev    Run with:
///         forge test --match-contract DeployTest --fork-url $BASE_SEPOLIA_RPC_URL -vvv
contract DeployTest is Test {
    using PoolIdLibrary for PoolKey;

    // ── Addresses ────────────────────────────────────────────────────────────

    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // Funded test accounts — use labelled addresses so traces are readable.
    address internal deployer = makeAddr("deployer");
    address internal whitelisted = makeAddr("whitelisted");
    address internal stranger = makeAddr("stranger");

    // ── Pool parameters ───────────────────────────────────────────────────────

    uint24 internal constant LP_FEE = 3000;
    int24 internal constant TICK_SPACING = 60;
    uint160 internal constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;

    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
    );

    // ── Deployed contracts (set during setUp) ─────────────────────────────────

    IPoolManager internal poolManager;
    ComplianceRegistry internal registry;
    CompliantRWAHook internal hook;
    MockERC20 internal rwaToken;
    MockERC20 internal usdc;
    PoolKey internal poolKey;

    /* ---------------------------------------------------------------------- */
    /*                                  Setup                                  */
    /* ---------------------------------------------------------------------- */

    function setUp() public {
        // Skip when no fork is configured (CI without RPC).
        address pm = vm.envOr("POOL_MANAGER", address(0));
        if (pm == address(0)) {
            console2.log("DeployTest: POOL_MANAGER not set - skipping fork tests.");
            return;
        }
        poolManager = IPoolManager(pm);

        vm.deal(deployer, 10 ether);
        vm.deal(whitelisted, 10 ether);

        // ── 1. Deploy registry ──────────────────────────────────────────────
        vm.startPrank(deployer);
        registry = new ComplianceRegistry(deployer, deployer, deployer);

        // ── 2. Mine + deploy hook ───────────────────────────────────────────
        (address hookAddr, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            HOOK_FLAGS,
            type(CompliantRWAHook).creationCode,
            abi.encode(poolManager, address(registry))
        );

        hook = new CompliantRWAHook{ salt: salt }(poolManager, registry);
        assertEq(address(hook), hookAddr, "hook address mismatch");

        // ── 3. Mock tokens ──────────────────────────────────────────────────
        rwaToken = new MockERC20("Mock RWA Token", "mRWA", 18);
        usdc = new MockERC20("Mock USDC", "mUSDC", 6);
        rwaToken.mint(deployer, 1_000_000e18);
        usdc.mint(deployer, 1_000_000e6);

        // ── 4. Pool key (currency0 < currency1) ─────────────────────────────
        (address token0, address token1) = address(rwaToken) < address(usdc)
            ? (address(rwaToken), address(usdc))
            : (address(usdc), address(rwaToken));

        poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        // ── 5. Initialize pool ───────────────────────────────────────────────
        poolManager.initialize(poolKey, SQRT_PRICE_1_1);

        // ── 6. Whitelist deployer and apply root (warp past timelock) ────────
        bytes32 deployerRoot = ComplianceLib.leafHash(deployer, AccreditationTier.Retail);
        registry.setAccreditation(deployer, AccreditationTier.Retail);
        registry.proposeRootUpdate(deployerRoot);
        vm.stopPrank();

        skip(ROOT_UPDATE_DELAY);
        registry.applyRootUpdate();

        // ── 7. Seed liquidity ─────────────────────────────────────────────────
        vm.startPrank(deployer);
        PoolInitializer initializer = new PoolInitializer(poolManager);

        MockERC20(token0).mint(address(initializer), 10_000e18);
        MockERC20(token1).mint(address(initializer), 10_000e18);

        bytes32[] memory emptyProof = new bytes32[](0);
        bytes memory hookData = abi.encode(deployer, emptyProof, AccreditationTier.Retail);

        initializer.addLiquidity(
            PoolInitializer.LiquidityParams({
                key: poolKey,
                tickLower: -600,
                tickUpper: 600,
                liquidityDelta: 1e18,
                hookData: hookData
            })
        );
        vm.stopPrank();
    }

    /* ---------------------------------------------------------------------- */
    /*                                  Tests                                   */
    /* ---------------------------------------------------------------------- */

    function test_hookPermissions_matchAddressBits() public {
        _skipIfNoFork();
        // Validate that the deployed hook address lower bits encode HOOK_FLAGS.
        assertEq(uint160(address(hook)) & uint160(Hooks.ALL_HOOK_MASK), HOOK_FLAGS & uint160(Hooks.ALL_HOOK_MASK));
    }

    function test_registry_isInitialised() public {
        _skipIfNoFork();
        // Merkle root must be non-zero after applyRootUpdate.
        bytes32 root = registry.merkleRoot();
        assertTrue(root != bytes32(0), "root is zero");
        assertEq(root, ComplianceLib.leafHash(deployer, AccreditationTier.Retail));
    }

    function test_whitelistUser_succeedsCompliance() public {
        _skipIfNoFork();
        // Build a two-leaf tree: deployer (already in root) + whitelisted.
        // For simplicity, whitelist the new user in a fresh root.
        bytes32 leafA = ComplianceLib.leafHash(deployer, AccreditationTier.Retail);
        bytes32 leafB = ComplianceLib.leafHash(whitelisted, AccreditationTier.Retail);

        bytes32 root = leafA < leafB
            ? keccak256(abi.encode(leafA, leafB))
            : keccak256(abi.encode(leafB, leafA));

        bytes32[] memory proofForWhitelisted = new bytes32[](1);
        proofForWhitelisted[0] = leafA;

        vm.startPrank(deployer);
        registry.setAccreditation(whitelisted, AccreditationTier.Retail);
        registry.proposeRootUpdate(root);
        vm.stopPrank();

        skip(ROOT_UPDATE_DELAY);
        registry.applyRootUpdate();

        // Whitelisted user's proof should now verify correctly.
        assertTrue(
            ComplianceLib.verifyMembership(registry.merkleRoot(), proofForWhitelisted, whitelisted, AccreditationTier.Retail)
        );
    }

    function test_nonWhitelistedUser_revertsOnSwapCallback() public {
        _skipIfNoFork();
        // A stranger with no Merkle proof should fail _verifyCompliance.
        // We test by calling beforeSwap from the fake pool manager context.
        // The hook is deployed at the permission-encoded address so we can
        // prank the pool manager directly.
        bytes32[] memory emptyProof = new bytes32[](0);
        bytes memory hookData = abi.encode(stranger, emptyProof, AccreditationTier.Retail);

        vm.prank(address(poolManager));
        vm.expectRevert(abi.encodeWithSelector(ComplianceViolation.selector, ComplianceError.NOT_WHITELISTED));
        hook.beforeSwap(
            stranger,
            poolKey,
            SwapParams({ zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0 }),
            hookData
        );
    }

    function test_pause_blocksAllSwaps() public {
        _skipIfNoFork();
        vm.prank(deployer); // deployer holds COMPLIANCE_ROLE
        registry.pause();

        bytes32[] memory emptyProof = new bytes32[](0);
        bytes memory hookData = abi.encode(deployer, emptyProof, AccreditationTier.Retail);

        vm.prank(address(poolManager));
        vm.expectRevert(abi.encodeWithSelector(ComplianceViolation.selector, ComplianceError.POOL_PAUSED));
        hook.beforeSwap(
            deployer,
            poolKey,
            SwapParams({ zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0 }),
            hookData
        );
    }

    /* ---------------------------------------------------------------------- */
    /*                             Internal helpers                             */
    /* ---------------------------------------------------------------------- */

    function _skipIfNoFork() internal {
        if (address(poolManager) == address(0)) {
            vm.skip(true);
        }
    }
}
