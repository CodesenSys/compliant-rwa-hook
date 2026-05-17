# Compliant RWA Hook — Uniswap V4

> **KYC/AML-gated liquidity infrastructure for regulated asset pools on Uniswap V4.**
> Built by [CodesenSys](https://codesensys.com) · Lahore, Pakistan

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Built with Foundry](https://img.shields.io/badge/Built%20with-Foundry-orange)](https://getfoundry.sh)
[![Solidity 0.8.26](https://img.shields.io/badge/Solidity-0.8.26-lightgrey)](https://soliditylang.org)
[![Uniswap V4](https://img.shields.io/badge/Uniswap-V4-ff007a)](https://github.com/Uniswap/v4-core)
[![Status](https://img.shields.io/badge/status-contracts%20complete%2C%20deployment%20pending-yellow)](#status)

---

## Overview

Institutional RWA (Real World Asset) tokens need compliant trading rails, not just liquidity. This hook enforces **KYC/AML allowlisting at the swap level** — only verified addresses can participate in RWA token pools — without sacrificing gas efficiency or Uniswap V4 composability.

**What it enforces, on every swap and liquidity action:**

- Merkle-proof membership (address is on the KYC whitelist)
- Jurisdictional blocklist (ISO 3166-1 country codes)
- Lockup windows (time-based transfer restrictions)
- Accreditation tier (Retail / Qualified / Institutional gating per pool)
- Emergency pause (compliance officer can halt all activity instantly)

**What makes it production-grade:**

- Registry is decoupled from the hook — root updates never require redeploying the hook (which would lose its V4 address-encoded permissions)
- All root updates have a mandatory 24-hour timelock — a compromised operator key cannot drain a pool in one transaction
- No upgradeable proxies — audit surface stays minimal
- Custom errors only, CEI pattern throughout, full NatSpec

---

## Status

**Contracts: complete. Live deployment: pending.**

All five implementation phases are finished and passing tests locally. The next step is a live Sepolia deployment, after which this section will be updated with verified contract addresses.

| Phase | Component | State |
|---|---|---|
| 1 | `ComplianceTypes.sol` — enums, structs, errors, constants | Complete |
| 2 | `ComplianceRegistry.sol` — timelocked root storage, roles | Complete |
| 3 | `ComplianceLib.sol` + `IdentityBridge.sol` — verification primitives | Complete |
| 4 | `CompliantRWAHook.sol` — V4 hook, all four callbacks | Complete |
| 5 | Deployment scripts + Sepolia deployment | Scripts complete, live deployment pending |

> **Note:** This codebase has not been audited and does not have live deployment addresses yet. It is not production-ready. See [Contributing](#contributing) if you want to help get it there.

---

## Architecture

```
+-------------------------------------------------------------+
|                    Uniswap V4 PoolManager                   |
|                       (singleton)                           |
+----------------------------+--------------------------------+
                             | hook callbacks
                             v
+-------------------------------------------------------------+
|                   CompliantRWAHook.sol                      |
|                                                             |
|  beforeSwap()   beforeAddLiquidity()  beforeRemoveLiquidity |
|       |                 |                     |             |
|       +--------+--------+                     |             |
|                v                              v             |
|     _verifyCompliance(account, proof, tier)  lockupCheck   |
|                |                                            |
|       +--------+--------+                                   |
|       v                 v                                   |
|  ComplianceLib      ComplianceLib                           |
|  (leaf hash)        (Merkle verify)                         |
+---------------------+---------------------------------------+
                      | reads
                      v
+-------------------------------------------------------------+
|              ComplianceRegistry.sol                         |
|  merkleRoot         (timelocked update path)                |
|  blockedJurisdictions[bytes2 country]                       |
|  accreditationTier[address]                                 |
|  lockupExpiry[address]                                      |
|  paused                                                     |
+-------------------------------------------------------------+
```

### Verification order in `_verifyCompliance`

Checks are ordered cheapest-first to fail fast:

```
1. Lockup window     (~800 gas)   — one SLOAD
2. Jurisdiction      (~1,600 gas) — two SLOADs
3. Accreditation tier(~800 gas)   — one SLOAD
4. Merkle proof      (~6,500 gas) — log(n) hashes
```

### `sender` vs. user in V4 callbacks

In Uniswap V4, the `sender` parameter passed to hook callbacks is the **swap router**, not the end user. The actual user address must be passed explicitly through `hookData`. This is the most common source of bugs in V4 hooks.

```solidity
// hookData format for beforeSwap / beforeAddLiquidity:
(address user, bytes32[] memory proof, AccreditationTier tier) =
    abi.decode(hookData, (address, bytes32[], AccreditationTier));

// hookData format for beforeRemoveLiquidity (lockup check only):
address lp = abi.decode(hookData, (address));
```

---

## Contract Structure

```
src/
├── CompliantRWAHook.sol           # V4 hook — beforeSwap, afterSwap,
│                                  #   beforeAddLiquidity, beforeRemoveLiquidity
├── ComplianceRegistry.sol         # Operator-controlled compliance state
├── IdentityBridge.sol             # Optional ERC-3643 / T-REX adapter
├── types/
│   └── ComplianceTypes.sol        # Enums, structs, custom errors, constants
├── interfaces/
│   ├── ICompliantRWAHook.sol
│   ├── IComplianceRegistry.sol
│   └── IERC3643Bridge.sol
└── libraries/
    └── ComplianceLib.sol          # Pure leaf hash + Merkle verify

test/
├── unit/                          # Per-contract unit tests (67 tests)
│   ├── ComplianceTypes.t.sol
│   ├── ComplianceRegistry.t.sol
│   ├── ComplianceLib.t.sol
│   ├── IdentityBridge.t.sol
│   └── CompliantRWAHook.t.sol
├── fuzz/                          # Property-based tests
│   └── FuzzCompliance.t.sol
├── invariant/                     # Stateful multi-actor invariant tests
│   └── InvariantCompliance.t.sol
├── integration/                   # End-to-end V4 swap flow
│   └── FullSwapFlow.t.sol
└── fork/                          # Fork tests against live chain (requires RPC)
    └── Deploy.t.sol

script/
├── Deploy.s.sol                   # Full system deployment (step 1 of 2)
├── SeedLiquidity.s.sol            # Apply root + seed liquidity (step 2, after 24h)
├── UpdateMerkleRoot.s.sol         # Operator: propose / apply root updates
├── GenerateProof.s.sol            # Helper: print leaf hash for a given address + tier
└── helpers/
    ├── MockERC20.sol              # Testnet-only mintable ERC-20
    └── PoolInitializer.sol        # IUnlockCallback impl for seeding liquidity
```

---

## Core Contracts

### `CompliantRWAHook.sol`

Inherits from Uniswap V4 `BaseHook`. Deployed at a CREATE2-mined address whose lower 14 bits encode the permission flags — this is V4's mechanism for verifying hook declarations at runtime.

| Callback | What it enforces |
|---|---|
| `beforeSwap` | Full compliance check: lockup, jurisdiction, tier, Merkle proof |
| `beforeAddLiquidity` | Same as beforeSwap — LP must be KYC'd to provide liquidity |
| `beforeRemoveLiquidity` | Lockup check only — LP cannot exit before expiry |
| `afterSwap` | Emits `ComplianceAuditEvent` for off-chain indexing (Subgraph / Ponder) |

```solidity
function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
    return Hooks.Permissions({
        beforeSwap:                    true,
        afterSwap:                     true,
        beforeAddLiquidity:            true,
        beforeRemoveLiquidity:         true,
        afterAddLiquidity:             false,
        afterRemoveLiquidity:          false,
        beforeInitialize:              false,
        afterInitialize:               false,
        beforeDonate:                  false,
        afterDonate:                   false,
        beforeSwapReturnDelta:         false,
        afterSwapReturnDelta:          false,
        afterAddLiquidityReturnDelta:  false,
        afterRemoveLiquidityReturnDelta: false
    });
}
```

### `ComplianceRegistry.sol`

Stores all mutable compliance state. Decoupled from the hook so roots can be updated without redeploying the hook (redeployment = new address = all pools must migrate).

**Roles:** `DEFAULT_ADMIN_ROLE`, `OPERATOR_ROLE`, `COMPLIANCE_ROLE` via OpenZeppelin `AccessControl`.

**Timelocked root update flow:**

```solidity
// Step 1 — operator proposes (root is NOT active yet)
function proposeRootUpdate(bytes32 newRoot) external onlyOperator {
    uint64 effectiveAt = uint64(block.timestamp) + ROOT_UPDATE_DELAY; // 24 hours
    _pendingRoot = PendingRootUpdate({ root: newRoot, effectiveAt: effectiveAt });
    emit RootUpdateProposed(newRoot, effectiveAt);
}

// Step 2 — anyone can apply after the delay (permissionless)
function applyRootUpdate() external {
    PendingRootUpdate memory pending = _pendingRoot;
    if (pending.root == bytes32(0)) revert RootStale();
    if (block.timestamp < pending.effectiveAt) revert TooEarly();
    _merkleRoot = pending.root;
    delete _pendingRoot;
    emit RootUpdated(pending.root);
}
```

### `ComplianceLib.sol`

Pure library. No storage access. Contains the canonical leaf hash formula — **this must match your off-chain tree builder exactly.**

```solidity
// Domain separator prevents leaf collisions across protocol versions and chains.
bytes32 constant LEAF_DOMAIN = keccak256("CodesenSys.RWA.Compliance.v1");

function leafHash(address account, AccreditationTier tier) internal pure returns (bytes32) {
    return keccak256(abi.encodePacked(LEAF_DOMAIN, account, uint8(tier)));
}

function verifyMembership(
    bytes32 root,
    bytes32[] memory proof,
    address account,
    AccreditationTier tier
) internal pure returns (bool) {
    bytes32 computed = leafHash(account, tier);
    for (uint256 i = 0; i < proof.length; i++) {
        bytes32 sibling = proof[i];
        computed = computed < sibling
            ? keccak256(abi.encode(computed, sibling))
            : keccak256(abi.encode(sibling, computed));
    }
    return computed == root;
}
```

### `IdentityBridge.sol`

Optional adapter. Protocols running ERC-3643 / T-REX identity registries can wire this bridge instead of managing a separate Merkle tree. Pass `address(0)` to disable it; `isCompliant` short-circuits to `false` and callers treat disabled as "skip this layer".

---

## Accreditation Tiers

```solidity
enum AccreditationTier { None, Retail, Qualified, Institutional }
```

| Tier | Value | Intended use |
|---|---|---|
| `None` | 0 | No access |
| `Retail` | 1 | Standard KYC-verified participants |
| `Qualified` | 2 | Qualified investor (Reg D / Reg S pools) |
| `Institutional` | 3 | All pools, including restricted institutional |

Pools can set a per-pool minimum tier via `minTierByPool[poolId]` on the hook. The hook uses `max(minTierByPool, tier from hookData)` as the effective required tier.

---

## Custom Errors

```solidity
enum ComplianceError {
    NOT_WHITELISTED,      // address not in current Merkle tree
    BLOCKED_JURISDICTION, // resident of a blocked country
    LOCKUP_ACTIVE,        // within lockup/vesting window
    INSUFFICIENT_TIER,    // accreditation below pool minimum
    POOL_PAUSED,          // emergency pause is active
    INVALID_PROOF         // proof structurally invalid
}

error ComplianceViolation(ComplianceError reason); // all compliance failures
error UnauthorizedOperator();                       // missing role
error TooEarly();                                   // timelock not matured
error InvalidMerkleRoot();                          // proposed root is zero
error RootStale();                                  // no pending root to apply
error NotInitialized();                             // root never set
```

---

## Off-chain: Building the Merkle Tree

The whitelist is maintained off-chain and committed on-chain as a Merkle root. The on-chain leaf hash uses a **domain separator** — your off-chain tree builder must use the same encoding.

**Important:** The leaf format is NOT compatible with `@openzeppelin/merkle-tree`'s `StandardMerkleTree` (which uses a different internal encoding). You must build leaves manually to match `ComplianceLib.leafHash`:

```typescript
import { keccak256, encodePacked, concat } from "viem";
import { MerkleTree } from "merkletreejs";

const LEAF_DOMAIN = keccak256(toBytes("CodesenSys.RWA.Compliance.v1"));

// Must match ComplianceLib.leafHash exactly
function leafHash(account: `0x${string}`, tier: number): `0x${string}` {
  return keccak256(
    concat([LEAF_DOMAIN, account, encodePacked(["uint8"], [tier])])
  );
}

// Build the tree (sort pairs before hashing — matches verifyMembership)
const leaves = whitelist.map(({ address, tier }) => leafHash(address, tier));
const tree = new MerkleTree(leaves, keccak256, { sort: true });

const root = tree.getHexRoot();            // propose this on-chain
const proof = tree.getHexProof(leafHash(userAddress, userTier)); // pass in hookData
```

The proof is passed by the frontend as part of the swap transaction's `hookData`:

```typescript
const hookData = encodeAbiParameters(
  [{ type: "address" }, { type: "bytes32[]" }, { type: "uint8" }],
  [userAddress, proof, tier]
);
```

---

## Installation

```bash
git clone https://github.com/codesensys/compliant-rwa-hook
cd compliant-rwa-hook
git submodule update --init --recursive

forge build
forge test
```

**Dependencies** (managed as git submodules via `foundry.toml`):

| Library | Purpose |
|---|---|
| `Uniswap/v4-core` | PoolManager, hook interfaces, pool types |
| `Uniswap/v4-periphery` | BaseHook, PositionManager |
| `OpenZeppelin/openzeppelin-contracts` | AccessControl, ERC-20 |
| `Vectorized/solady` | MerkleProofLib, gas-optimised utilities |
| `foundry-rs/forge-std` | Testing framework |

---

## Running Tests

```bash
# Unit + fuzz + invariant + integration (no RPC required)
forge test

# Verbose output for a specific contract
forge test --match-contract CompliantRWAHookTest -vvvv

# Fork tests (requires a live RPC)
POOL_MANAGER=0x7Da1D65F8B249183667cdE74C5CBD46dD38aa829 \
  forge test --match-contract DeployTest \
  --fork-url $SEPOLIA_RPC_URL -vvv

# Gas snapshot
forge snapshot
```

---

## Deployment

Deployment is a two-step process due to the 24-hour Merkle root timelock.

### Environment

```bash
# Required
export DEPLOYER_PRIVATE_KEY=0x...
export SEPOLIA_RPC_URL=https://eth-sepolia.g.alchemy.com/v2/<key>
export POOL_MANAGER=0x7Da1D65F8B249183667cdE74C5CBD46dD38aa829
export ETHERSCAN_API_KEY=...

# Optional (default to deployer address)
export OPERATOR_ADDRESS=0x...
export COMPLIANCE_ADDRESS=0x...
```

### Step 1 — Deploy (run once)

```bash
forge script script/Deploy.s.sol \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --broadcast \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  -vvvv
```

Deploys: `ComplianceRegistry` → `CompliantRWAHook` (CREATE2-mined) → `MockRWAToken` + `MockUSDC` → V4 pool initialisation → Merkle root proposal.

Writes contract addresses to `deployments/sepolia.json`.

### Step 2 — Seed liquidity (run 24 hours later)

```bash
export COMPLIANCE_REGISTRY=<from deployments/sepolia.json>
export HOOK=<from deployments/sepolia.json>
export TOKEN0=<lower token address>
export TOKEN1=<higher token address>

forge script script/SeedLiquidity.s.sol \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --broadcast \
  -vvvv
```

Applies the Merkle root and seeds the initial liquidity position.

### Updating the whitelist

```bash
# Propose a new root (operator key required)
forge script script/UpdateMerkleRoot.s.sol \
  --sig "propose(bytes32)" <new-root-hex> \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast

# Apply after 24 hours (permissionless)
forge script script/UpdateMerkleRoot.s.sol \
  --sig "applyUpdate()" \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast
```

### Generating a leaf hash for a given address

```bash
forge script script/GenerateProof.s.sol \
  --sig "run(address,uint8)" <address> <tier>
# tier: 0=None, 1=Retail, 2=Qualified, 3=Institutional
```

---

## Live Deployments

> Live deployment addresses will be added here after the Sepolia deployment is complete and verified.

| Network | Contract | Address |
|---|---|---|
| Sepolia | ComplianceRegistry | — |
| Sepolia | CompliantRWAHook | — |

---

## Audit Readiness

This codebase is structured to be audit-ready from day one, not retrofitted.

- [x] NatSpec on every public/external function
- [x] Custom errors only — no `require(condition, "string")`
- [x] CEI pattern enforced throughout
- [x] No `delegatecall`, no upgradeable proxies
- [x] Every state mutation emits an event
- [x] Zero compiler warnings
- [ ] Slither static analysis (zero high/medium findings target)
- [ ] External audit — planned post v0.1.0 deployment

**Invariants under continuous testing:**

1. `merkleRoot` is never `bytes32(0)` after the first `applyRootUpdate`
2. A blocked jurisdiction's resident always fails `_verifyCompliance`
3. An address with `lockupExpiry > block.timestamp` always fails the lockup check
4. A cancelled pending root can never be applied
5. Hook permissions from `getHookPermissions()` match the address-encoded permission bits

---

## Roadmap

**v0.1.0 (current):**

- [x] Shared type system — `ComplianceTypes.sol`
- [x] `ComplianceRegistry.sol` with timelocked root updates and role-based access
- [x] `ComplianceLib.sol` — domain-separated leaf hashing, Merkle verification
- [x] `IdentityBridge.sol` — ERC-3643 / T-REX adapter
- [x] `CompliantRWAHook.sol` — full V4 callback suite
- [x] Deployment scripts (`Deploy.s.sol`, `SeedLiquidity.s.sol`, `UpdateMerkleRoot.s.sol`)
- [ ] Live Sepolia deployment + on-chain verification
- [ ] First successful swap (whitelisted) + first denied swap (not whitelisted) on-chain

**v0.2.0:**

- [ ] Migrate to `@codesensys/rwa-compliance` library (sibling project)
- [ ] Multi-registry support (one hook, multiple jurisdictional registries)
- [ ] On-chain dispute window for root updates

**v0.3.0+:**

- [ ] zkProof-based private KYC (compliance without revealing address linkage)
- [ ] Halmos symbolic execution suite
- [ ] Mainnet deployment with audit

---

## Contributing

Contributions are welcome. This is an open-source project — pull requests, issue reports, and security disclosures are all appreciated.

**Before opening a PR:**

1. Run `forge build` — must compile with zero warnings
2. Run `forge test` — all tests must pass
3. Run `forge fmt` — code must be formatted
4. Follow the coding standards documented below — naming conventions (`camelCase` functions, `UPPER_SNAKE_CASE` constants, `_camelCase` internals), CEI pattern, NatSpec on every public function, and `test_<function>_<condition>` test naming

**Opening issues:**

- Bug reports: include a minimal reproducing test case if possible
- Feature requests: describe the institutional use case being addressed
- Security vulnerabilities: see the security disclosure policy below

**What we are particularly looking for:**

- Correctness issues in the compliance logic
- Gas optimisation opportunities with benchmarks
- Off-chain tooling (TypeScript / Python Merkle tree builders that match the on-chain leaf format)
- Integration examples (front-end hookData encoding, subgraph schemas)

---

## Security

**This code has not been audited. Do not deploy to mainnet or use with real assets.**

If you discover a security vulnerability, please do not open a public GitHub issue. Contact the maintainers directly:

- Email: codesensys@gmail.com
- Subject line: `[SECURITY] compliant-rwa-hook`

Include a description of the vulnerability, reproduction steps, and your assessment of severity. We will acknowledge within 48 hours and aim to publish a fix within 7 days for critical issues.

---

## Related Projects

- [**rwa-compliance**](https://github.com/codesensys/rwa-compliance) — Sibling library of standalone compliance primitives. Starting in v0.2.0, this hook will consume that library as a dependency rather than maintaining its own registry.

---

## Built By

[CodesenSys](https://codesensys.com) — Blockchain development boutique specialising in DeFi infrastructure, smart contract security, and RWA tokenisation.

- Website: [codesensys.com](https://codesensys.com)
- X: [@codesensys](https://x.com/codesensys)
- LinkedIn: [linkedin.com/company/codesensys](https://linkedin.com/company/codesensys)

---

## License

MIT — see [LICENSE](LICENSE).

> This codebase is provided for educational and research purposes. It has not been audited. Do not use in production without a professional security review. Compliance requirements vary by jurisdiction — consult legal counsel before deploying regulated financial instruments on-chain.
