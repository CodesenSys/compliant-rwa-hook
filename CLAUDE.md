# CLAUDE.md — compliant-rwa-hook

> Authoritative instruction file for any Claude (or other LLM agent) working on this codebase.
> Read this file in full before generating, modifying, or reviewing any code.
> Update the **Progress** section at the end of every working session.

---

## 0. Project Mission

Build a **production-grade, audit-structured Uniswap V4 hook** that turns a normal AMM pool into a **regulated trading venue** for Real World Asset (RWA) tokens. The hook enforces KYC/AML allowlisting, jurisdictional restrictions, lockup windows, and accreditation tiering at the swap and liquidity-provisioning level — without sacrificing gas efficiency or V4 composability.

**This is not a toy project.** The codebase must be:
- Compilable, lintable, and fully type-safe
- Tested with unit, fuzz, and invariant suites
- Audit-ready: NatSpec, custom errors, CEI pattern, no `delegatecall`, no upgradeable proxies
- Deployable to Sepolia / Base Sepolia with verifiable artifacts on Etherscan

**Strategic context (do not lose sight of this):**
The author (Haseeb, CodesenSys) is building this as a flagship portfolio piece to anchor CodesenSys's positioning as a compliant-RWA / DeFi-infrastructure boutique. Every architectural decision must be defensible to an institutional client. Every commit message, README detail, and gas snapshot is content fuel.

---

## 1. Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Uniswap V4 PoolManager                   │
│                       (singleton)                           │
└───────────────────────┬─────────────────────────────────────┘
                        │ hook callbacks
                        ▼
┌─────────────────────────────────────────────────────────────┐
│                   CompliantRWAHook.sol                      │
│  beforeSwap()  beforeAddLiquidity()  beforeRemoveLiquidity()│
│         │              │                    │               │
│         └──────────────┴────────────────────┘               │
│                        ▼                                    │
│           _verifyCompliance(account, proof, tier)           │
│                        │                                    │
│         ┌──────────────┼──────────────┐                     │
│         ▼              ▼              ▼                     │
│   MerkleProofLib  ComplianceLib  IdentityBridge             │
│   (Solady)        (pure helpers) (ERC-3643 adapter)         │
└─────────────────────────┬───────────────────────────────────┘
                          │ reads
                          ▼
┌─────────────────────────────────────────────────────────────┐
│              ComplianceRegistry.sol                         │
│  • merkleRoot (timelocked updates)                          │
│  • blockedJurisdictions[bytes2 country]                     │
│  • accreditationTier[address]                               │
│  • lockupExpiry[address]                                    │
│  • paused (emergency)                                       │
└─────────────────────────────────────────────────────────────┘
```

### Component responsibilities

| Component | Lives in | Responsibility |
|---|---|---|
| `CompliantRWAHook` | `src/` | V4 hook contract; routes pool callbacks through compliance verification |
| `ComplianceRegistry` | `src/` | Mutable compliance state (root, jurisdictions, tiers, lockups); operator-controlled with timelock |
| `IdentityBridge` | `src/` | Optional adapter for protocols already running an ERC-3643 / T-REX identity registry |
| `ComplianceTypes` | `src/types/` | Shared enums, structs, custom errors |
| `ComplianceLib` | `src/libraries/` | Pure verification helpers (leaf hashing, proof composition) — no storage access |

### Key architectural decisions (non-negotiable)

1. **Registry decoupled from hook.** The registry is its own contract. The hook reads from it via interface. This lets the operator update the Merkle root without redeploying the hook (which would require re-mining its address — V4 hooks encode permissions in their address bits).
2. **Timelocked root updates.** Root changes are proposed and applied after a 24h delay. This is non-optional for institutional credibility.
3. **No upgradeable proxies.** Audit and trust surface stays small. Migrations happen via new deployments.
4. **Custom errors only.** No `require(string)` anywhere. Errors carry typed parameters.
5. **CEI pattern enforced.** Checks → Effects → Interactions, in that order, every time.
6. **Solady for hot paths.** Merkle proof verification, role storage, and ERC-20 interactions use Solady (assembly-optimized) where it matters for gas.

---

## 2. Build Phases — The Five Components

Each phase has: **goal**, **scope**, **acceptance criteria**, **tests required**, **validation commands**, **learning checkpoints**, **marketing capture points**, **status**.

> **Status legend:** `[ ]` Not started · `[~]` In progress · `[x]` Complete · `[!]` Blocked

---

### Phase 1 — `ComplianceTypes.sol` (Foundation)

**Status:** `[ ]`

**Goal:** Define the shared vocabulary of the system — enums, structs, custom errors, constants. Everything else imports from here.

**Scope (this phase only):**
- `enum AccreditationTier { None, Retail, Qualified, Institutional }`
- `enum ComplianceError { NOT_WHITELISTED, BLOCKED_JURISDICTION, LOCKUP_ACTIVE, INSUFFICIENT_TIER, POOL_PAUSED, INVALID_PROOF }`
- `struct LockupSchedule { uint48 cliff; uint48 vestingEnd; uint128 amount; }`
- `struct PendingRootUpdate { bytes32 root; uint64 effectiveAt; }`
- Custom errors: `ComplianceViolation(ComplianceError)`, `UnauthorizedOperator()`, `TooEarly()`, `InvalidMerkleRoot()`, `RootStale()`, `NotInitialized()`
- Constants: `ROOT_UPDATE_DELAY` (24h), `MAX_LOCKUP_DURATION` (e.g., 10 years)

**Acceptance criteria:**
- File compiles in isolation (`forge build src/types/ComplianceTypes.sol`).
- All types are referenced by at least one downstream component.
- NatSpec on every public-facing element.

**Tests required:** None — types only. Tests live with the components that consume them.

**Validation commands:**
```bash
forge build
forge fmt --check src/types/ComplianceTypes.sol
```

**Learning checkpoints:**
- [ ] When to use `enum` vs. `bytes2`/`uint8` for compact identifiers (gas implications of enum storage)
- [ ] How custom errors with parameters compare to `require(string)` for gas and ABI clarity
- [ ] `uint48` for timestamps: pros (packing) and cons (year-2106 problem if used carelessly)

**Marketing capture:**
- Tweet draft: *"Day 1 of compliant-RWA-hook: shipping the type system. Custom errors with typed params, no string reverts. Audit-ready from line one."*
- Add gas reference once typed errors land.

---

### Phase 2 — `ComplianceRegistry.sol` (State)

**Status:** `[ ]`

**Goal:** A standalone contract storing all compliance state, with timelocked Merkle root updates, jurisdiction blocklists, accreditation tier mappings, and lockup expiries. Operator-controlled.

**Scope:**
- AccessControl roles: `OPERATOR_ROLE`, `COMPLIANCE_ROLE`, `DEFAULT_ADMIN_ROLE`
- Storage:
  - `bytes32 merkleRoot`
  - `PendingRootUpdate pendingRoot`
  - `mapping(bytes2 country => bool blocked) blockedJurisdictions`
  - `mapping(address => bytes2 country) countryOf`
  - `mapping(address => AccreditationTier) accreditationTier`
  - `mapping(address => uint64 expiry) lockupExpiry`
  - `bool paused`
- External functions:
  - `proposeRootUpdate(bytes32 newRoot)` (operator)
  - `applyRootUpdate()` (anyone — checks timelock)
  - `cancelPendingRoot()` (operator)
  - `setJurisdictionBlocked(bytes2 country, bool blocked)` (compliance)
  - `setCountry(address account, bytes2 country)` (operator)
  - `setAccreditation(address account, AccreditationTier tier)` (operator)
  - `setLockup(address account, uint64 expiry)` (operator)
  - `pause()` / `unpause()` (compliance)
- View functions:
  - `merkleRoot()`, `isJurisdictionBlocked(bytes2)`, `accreditationOf(address)`, `lockupExpiryOf(address)`, `paused()`
- Events for every mutation, all parameters indexed where useful.

**Acceptance criteria:**
- 100% of state mutations emit events.
- All admin functions revert with `UnauthorizedOperator()` for the wrong role.
- `applyRootUpdate` reverts with `TooEarly()` before `effectiveAt`.
- Cancelled pending roots cannot be applied.
- Constructor sets initial roles correctly and emits a deployment event.

**Tests required (`test/unit/ComplianceRegistry.t.sol`):**
- `test_constructor_setsInitialRoles`
- `test_proposeRootUpdate_onlyOperator`
- `test_applyRootUpdate_revertsBeforeDelay`
- `test_applyRootUpdate_succeedsAfterDelay`
- `test_cancelPendingRoot_onlyOperator`
- `test_setJurisdictionBlocked_emitsEvent`
- `test_setAccreditation_storesCorrectTier`
- `test_setLockup_storesExpiry`
- `test_pause_blocksAllReads` (decision: do view fns honor pause? lock this in tests)
- `test_revoke_role_preventsFurtherActions`

**Validation commands:**
```bash
forge build
forge test --match-contract ComplianceRegistryTest -vvv
forge snapshot --match-contract ComplianceRegistryTest
forge coverage --match-contract ComplianceRegistryTest
```

**Learning checkpoints:**
- [ ] OpenZeppelin `AccessControl` vs. `Ownable`: when each is appropriate
- [ ] Timelock pattern: why 24h, why not configurable, attack vectors of mutable delays
- [ ] Event indexing: which fields earn the `indexed` modifier (max 3 per event)
- [ ] Storage packing: `uint64 expiry` + `AccreditationTier tier` + `bytes2 country` in one slot
- [ ] Reading source: OpenZeppelin's `TimelockController.sol` (study the pattern)

**Marketing capture:**
- LinkedIn post draft: *"Why we timelock Merkle root updates in compliant RWA pools. Without a delay, a compromised operator key could exit-scam an entire user base in one transaction."*
- Screenshot the gas snapshot for `proposeRootUpdate` and `applyRootUpdate`.
- Tweet thread on the registry-vs-hook decoupling decision.

---

### Phase 3 — `ComplianceLib.sol` + `IdentityBridge.sol` (Verification primitives)

**Status:** `[ ]`

**Goal:** Pure functions for Merkle leaf composition + an optional bridge to existing ERC-3643 identity registries. These let the hook stay thin.

**Scope:**

`ComplianceLib.sol`:
- `function leafHash(address account, AccreditationTier tier) internal pure returns (bytes32)`
- `function verifyMembership(bytes32 root, bytes32[] calldata proof, address account, AccreditationTier tier) internal pure returns (bool)`
- Constants: leaf domain separator (e.g., `keccak256("CodesenSys.RWA.Compliance.v1")`)

`IdentityBridge.sol`:
- `interface IERC3643Bridge { function isVerified(address) external view returns (bool); function investorCountry(address) external view returns (uint16); }`
- Adapter contract that exposes a unified `isCompliant(address account, bytes2 jurisdiction)` view.
- Configurable: bridge can be disabled (zero-address sentinel) so projects without ERC-3643 don't pay the gas.

**Acceptance criteria:**
- All `ComplianceLib` functions are `pure` (verify with `forge inspect`).
- Leaf hashing uses a domain separator (prevents leaf collision across protocol versions).
- `IdentityBridge.isCompliant` is gas-bounded (under 5k gas with bridge enabled).
- Bridge gracefully short-circuits when underlying T-REX address is not set.

**Tests required:**
- `test/unit/ComplianceLib.t.sol`: leaf determinism, proof verification with crafted trees.
- `test/unit/IdentityBridge.t.sol`: bridge enabled/disabled paths, invalid country codes, mocked T-REX registry.

**Validation commands:**
```bash
forge build
forge test --match-path test/unit/ComplianceLib.t.sol -vvv
forge test --match-path test/unit/IdentityBridge.t.sol -vvv
```

**Learning checkpoints:**
- [ ] Why domain separators matter (replay attacks across versions / chains)
- [ ] `pure` vs `view` — what the EVM enforces vs. what Solidity claims
- [ ] OpenZeppelin Merkle tree (`@openzeppelin/merkle-tree`) vs Solady's `MerkleProofLib` — tree-construction off-chain, verification on-chain
- [ ] How ERC-3643 (T-REX) actually works at the contract level — read the spec

**Marketing capture:**
- Blog idea: *"Bridging Uniswap V4 hooks to ERC-3643 identity registries — a one-contract adapter pattern."* Long-form, technical.
- Tweet: *"Domain separators in Merkle leaves. If you're not using one, you have a versioning bug waiting to happen."*

---

### Phase 4 — `CompliantRWAHook.sol` (The Hook)

**Status:** `[ ]`

**Goal:** The Uniswap V4 hook contract. Implements `beforeSwap`, `beforeAddLiquidity`, `beforeRemoveLiquidity`, `afterSwap`. Calls into `ComplianceRegistry` and `ComplianceLib` for verification. Address-mined to encode permissions.

**Scope:**
- Inherits `BaseHook` from `v4-periphery`.
- `getHookPermissions()` returns:
  - `beforeSwap: true`
  - `beforeAddLiquidity: true`
  - `beforeRemoveLiquidity: true`
  - `afterSwap: true`
  - everything else `false`
- `_beforeSwap`: decodes `hookData` to extract `(bytes32[] proof, AccreditationTier tier)`. Resolves the actual swapper from the `sender` (be careful: `sender` here is the swap router, not necessarily the user; document this clearly). Calls `_verifyCompliance`. Reverts on violation.
- `_beforeAddLiquidity`: same pattern, with optional minimum-tier requirement read from pool extra-data (or hook-local config).
- `_beforeRemoveLiquidity`: honor lockup window for the LP; configurable per pool.
- `_afterSwap`: emit `ComplianceAuditEvent` for off-chain indexing (Subgraph, Ponder).
- Emergency pause respect: if registry says `paused`, all callbacks revert with `POOL_PAUSED`.

**Acceptance criteria:**
- Hook compiles against `v4-core` and `v4-periphery` at the version pinned in `foundry.toml`.
- Address mining works: deployment script computes the salt that lands the hook at a permission-encoded address.
- All four callbacks revert with the correct typed `ComplianceViolation` reason on bad inputs.
- `_afterSwap` emits an audit event with sender, pool key, and amount.
- Gas: `_beforeSwap` under 12k for a Merkle-only check (10k-address tree).

**Tests required:**

`test/unit/CompliantRWAHook.t.sol`:
- `test_getHookPermissions_returnsExpectedFlags`
- `test_beforeSwap_revertsWhenNotWhitelisted`
- `test_beforeSwap_succeedsForWhitelistedAddress`
- `test_beforeSwap_revertsForBlockedJurisdiction`
- `test_beforeSwap_revertsDuringLockup`
- `test_beforeSwap_revertsForInsufficientTier`
- `test_beforeSwap_revertsWhenPaused`
- `test_beforeAddLiquidity_enforcesAccreditation`
- `test_beforeRemoveLiquidity_honorsLockup`
- `test_afterSwap_emitsAuditEvent`

`test/integration/FullSwapFlow.t.sol`:
- `test_fullSwapFlow_whitelistedUser_succeeds` (deploy registry + hook + token + pool, do a real V4 swap)
- `test_fullSwapFlow_unwhitelistedUser_reverts`

**Validation commands:**
```bash
forge build
forge test --match-contract CompliantRWAHookTest -vvv
forge test --match-path test/integration/FullSwapFlow.t.sol -vvv
forge snapshot --match-contract CompliantRWAHookTest
```

**Learning checkpoints (the heavy ones — budget time here):**
- [ ] **V4 hook address mining**: read `HookMiner.sol`. Understand why permissions live in address bits and how `CREATE2` lets us aim for them.
- [ ] **`sender` vs. `tx.origin` vs. encoded-in-hookData swapper**: who is the hook actually authorizing? Document this clearly in NatSpec — most V4 hook bugs live here.
- [ ] **`hookData` encoding**: how the swap router passes calldata through to your hook. ABI encoding patterns.
- [ ] **`BeforeSwapDelta`**: V4's mechanism for hooks to alter swap deltas. We don't use it for v0.1 but understand it.
- [ ] **Pool keys and currency ordering**: `currency0 < currency1` invariant.
- [ ] Reading source: `v4-periphery/src/utils/BaseHook.sol`, `v4-core/src/libraries/Hooks.sol`.

**Marketing capture (this is the headline phase — be deliberate):**
- Twitter/X thread: walk through the hook architecture in 6-8 tweets, with code screenshots.
- LinkedIn long-form: *"How we built KYC-gated Uniswap V4 pools — the architecture, the gotchas, the gas profile."*
- Short demo video (Loom or screen-recorded): deploy the hook on Sepolia, attempt swap from non-whitelisted address, show the typed revert.
- Update CodesenSys company page with this as a featured case study.

---

### Phase 5 — Deployment Scripts + Sepolia / Base Sepolia Live Deployment

**Status:** `[ ]`

**Goal:** Forge scripts that deploy the full system to a testnet, verify on Etherscan, and produce a reusable artifact (deployment addresses JSON).

**Scope:**

`script/Deploy.s.sol`:
1. Deploy `ComplianceRegistry`.
2. Mine the `CompliantRWAHook` address against the target PoolManager.
3. Deploy hook with the correct salt.
4. Deploy a sample mock RWA token (plain ERC-20, paired with mock USDC).
5. Initialize a V4 pool with the hook attached.
6. Seed initial liquidity (small).
7. Write deployment addresses to `broadcast/Deploy.s.sol/<chainId>/run-latest.json` and a clean `deployments/<network>.json`.

`script/UpdateMerkleRoot.s.sol`:
- Operator-only: read the current allowlist from a JSON file, compute the Merkle root, propose update on-chain.

`script/GenerateProof.s.sol` (helper):
- Given an address + tier, output the Merkle proof bytes for use in swap calldata.

**Acceptance criteria:**
- `forge script script/Deploy.s.sol --rpc-url $BASE_SEPOLIA_RPC_URL --broadcast --verify` succeeds end-to-end.
- All contracts verified on Basescan.
- A whitelisted address can perform a swap on the deployed pool from a manual `cast send`.
- A non-whitelisted address gets a typed `ComplianceViolation` revert.
- Deployment addresses are checked into `deployments/base-sepolia.json`.

**Tests required:**
- `Deploy.s.sol` itself runs as a Foundry test against a local fork (`forge test --fork-url $BASE_SEPOLIA_RPC_URL --match-contract DeployTest`).

**Validation commands:**
```bash
# dry run on local fork
forge script script/Deploy.s.sol --rpc-url $BASE_SEPOLIA_RPC_URL

# real broadcast
forge script script/Deploy.s.sol --rpc-url $BASE_SEPOLIA_RPC_URL --broadcast --verify

# end-to-end smoke
cast send <hook-pool-address> "swap(...)" --rpc-url $BASE_SEPOLIA_RPC_URL --private-key $WHITELISTED_KEY
```

**Learning checkpoints:**
- [ ] Foundry scripting (`vm.broadcast`, `vm.startBroadcast`, transaction batching)
- [ ] How V4 PoolManager's `initialize` and `unlock` callbacks work
- [ ] Etherscan verification with constructor args + libraries
- [ ] Deployment manifest patterns (treat addresses as data, not code)

**Marketing capture:**
- Tweet: deployed address + Basescan link + "first compliant RWA pool, here's what just shipped."
- Update `README.md` with a **Live Deployments** section.
- Add a tagged release on GitHub: `v0.1.0`.

---

## 3. Coding Standards (enforced)

### Solidity

- **Pragma:** `pragma solidity 0.8.26;` exact, not floating.
- **License:** `// SPDX-License-Identifier: MIT` on every file.
- **Imports:** named imports only — `import { Foo } from "./Foo.sol";`. No wildcard imports.
- **Errors:** custom errors only. No `require(condition, "string")`. Errors carry typed parameters where useful.
- **Events:** every state mutation emits an event. Up to 3 indexed parameters per event. Indexed should be addresses and IDs, not amounts (unless you specifically want amount-based filters).
- **NatSpec:** `@notice` on every external/public function. `@dev` for implementation details. `@param` and `@return` on every parameter and return.
- **Visibility:** explicit on every function and state variable. No defaults.
- **Storage layout:** pack carefully. Document slot allocations in comments for non-trivial structs.
- **CEI:** Checks → Effects → Interactions. Always.
- **Reentrancy:** when external calls happen, justify why a guard isn't needed in `@dev`. Use Solady's `ReentrancyGuard` if needed.

### Naming

- Storage variables: `camelCase` for public, `_camelCase` for internal/private.
- Functions: `camelCase` for external, `_camelCase` for internal/private helpers.
- Constants: `UPPER_SNAKE_CASE`.
- Events: `PastTenseAction` (e.g., `RootUpdated`, `JurisdictionBlocked`).
- Errors: `NounDescriptionOfFailure` (e.g., `JurisdictionBlocked`, `LockupActive`).

### File header template

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title  <Component Name>
/// @author CodesenSys (https://codesensys.com)
/// @notice <One-sentence purpose.>
/// @dev    <Architectural notes, invariants, gotchas.>
```

---

## 4. Testing Standards

### Unit tests (`test/unit/`)
- One test contract per source contract.
- Naming: `test_<function>_<condition>_<expectation>`.
- Use Foundry's `expectRevert(<custom error selector>)` — match the typed error.
- Use `expectEmit` for every event-emitting test.

### Fuzz tests (`test/fuzz/`)
- Naming: `testFuzz_<function>_<property>`.
- Default 10,000 runs (set in `[profile.ci]`).
- Bound inputs aggressively to keep runs meaningful.
- Test invariants that hold for *all* valid inputs.

### Invariant tests (`test/invariant/`)
- Stateful, multi-actor.
- Document the invariant being asserted in a top-of-file comment.
- Use handler contracts to constrain the action space.

### Required invariants for this codebase

1. A blocked jurisdiction's resident can never pass `_verifyCompliance`.
2. An address whose `lockupExpiry > block.timestamp` can never successfully swap.
3. `merkleRoot` is never `bytes32(0)` after constructor.
4. A pending root, once cancelled, cannot be applied.
5. Hook permissions returned by `getHookPermissions()` match the address-encoded bits.

### Coverage targets
- Lines: ≥ 95%
- Branches: ≥ 90%
- Run `forge coverage --report lcov` before any tagged release.

---

## 5. Validation Workflow

After every meaningful change:

```bash
forge build              # must succeed
forge fmt --check        # must pass
forge test -vvv          # all green
forge snapshot           # commit the diff to track gas drift
```

Before any commit:

```bash
slither . --exclude-dependencies      # zero high/medium findings
forge fmt
```

Before any tagged release:

```bash
forge coverage --report lcov          # ≥ 95% lines
forge test --match-path test/invariant/* --fuzz-runs 100000
# Optional: halmos --solver-timeout-assertion 60000
```

---

## 6. Common Gotchas (read this before debugging)

- **Hook address mining failures.** If `forge script` deploys a hook to an address that doesn't satisfy the permission bits, every callback will revert with `Hooks.HookAddressNotValid`. Use `HookMiner.find(...)` to compute the salt before deploying.
- **`sender` in `beforeSwap`.** The `sender` parameter is the **swap router**, not the user. The user's address must be passed explicitly via `hookData`. Many community hooks have this wrong.
- **`hookData` is `bytes calldata`.** Decoding it is `abi.decode(hookData, (bytes32[], AccreditationTier))`. Get the type tuple wrong and you'll get silent garbage.
- **PoolManager unlock pattern.** All V4 state-changing operations route through `PoolManager.unlock`. Test setups must call this correctly.
- **`currency0 < currency1`.** V4 enforces ordering. Pool keys with reversed currencies will revert at `initialize`.
- **`BeforeSwapDelta` ABI.** V4 uses a packed int256 for delta. Returning the wrong shape breaks the hook contract interface.
- **Solady version drift.** Pin Solady tightly. Their assembly changes between minor versions.

---

## 7. Reference Material

### Primary
- Uniswap V4 docs: https://docs.uniswap.org/contracts/v4/overview
- V4 core source: https://github.com/Uniswap/v4-core
- V4 periphery source: https://github.com/Uniswap/v4-periphery
- BaseHook: `v4-periphery/src/utils/BaseHook.sol`
- Hooks library: `v4-core/src/libraries/Hooks.sol`

### Supporting
- ERC-3643 (T-REX) standard: https://github.com/TokenySolutions/T-REX
- OpenZeppelin AccessControl: https://docs.openzeppelin.com/contracts/5.x/access-control
- Solady MerkleProofLib: https://github.com/Vectorized/solady/blob/main/src/utils/MerkleProofLib.sol
- OpenZeppelin Merkle Tree (off-chain): https://github.com/OpenZeppelin/merkle-tree

### Companion
- The CodesenSys `rwa-compliance` library (sibling project): the modules in that library should eventually replace the hook's local `ComplianceRegistry` once both projects are stable. v0.1 of the hook ships with its own registry to avoid coupling.

---

## 8. Progress Log

> Update this section at the end of every working session. Date format: `YYYY-MM-DD`.

| Phase | Component | Status | Date | Notes |
|---|---|---|---|---|
| 1 | `ComplianceTypes.sol` | `[ ]` | — | — |
| 2 | `ComplianceRegistry.sol` | `[ ]` | — | — |
| 3 | `ComplianceLib.sol` | `[ ]` | — | — |
| 3 | `IdentityBridge.sol` | `[ ]` | — | — |
| 4 | `CompliantRWAHook.sol` | `[ ]` | — | — |
| 5 | `Deploy.s.sol` | `[ ]` | — | — |
| 5 | Live deployment | `[ ]` | — | — |

---

## 9. Definition of Done — v0.1.0

The project is releasable as `v0.1.0` when **all** of the following are true:

- [ ] All five components (Phases 1–5) marked `[x]` Complete
- [ ] `forge build` clean, no warnings
- [ ] `forge test` 100% green, ≥95% line coverage
- [ ] `forge fmt --check` passes
- [ ] `slither .` returns zero high/medium findings
- [ ] Deployed and verified on Base Sepolia
- [ ] At least one successful + one reverted swap recorded on-chain
- [ ] README updated with deployment addresses
- [ ] Architecture diagram in `docs/architecture.svg`
- [ ] Tagged GitHub release `v0.1.0` with changelog
- [ ] At least one marketing asset published (Twitter thread or LinkedIn post)

When v0.1.0 ships, open an issue titled "v0.2 scope" and start the next iteration: jurisdictional rules, ERC-3643 integration, attestation provider hooks.
