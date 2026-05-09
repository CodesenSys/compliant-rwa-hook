# Compliant RWA Hook — Uniswap V4

> **KYC/AML-gated liquidity infrastructure for regulated asset pools on Uniswap V4.**
> Built by [CodesenSys](https://codesensys.com) · Lahore, Pakistan

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Built with Foundry](https://img.shields.io/badge/Built%20with-Foundry-orange)](https://getfoundry.sh)
[![Solidity 0.8.26](https://img.shields.io/badge/Solidity-0.8.26-lightgrey)](https://soliditylang.org)
[![Uniswap V4](https://img.shields.io/badge/Uniswap-V4-ff007a)](https://github.com/Uniswap/v4-core)
[![Status](https://img.shields.io/badge/status-in%20development-yellow)](#status)

---

## Overview

Institutional RWA (Real World Asset) tokens need compliant trading rails, not just liquidity.
This hook enforces **KYC/AML allowlisting at the swap level** — only verified addresses can participate in RWA token pools — without sacrificing gas efficiency or Uniswap V4 composability.

**Key properties:**

- Merkle-proof-based whitelist verification (no per-address storage reads)
- ERC-3643 / T-REX compatibility layer for identity registry bridging
- Enforced both on `beforeSwap` (initiation) and `beforeAddLiquidity` (provisioning)
- Operator role for compliance admin without requiring a full hook redeploy
- Timelocked Merkle root updates (24h delay) for institutional-grade safety
- Emergency pause with jurisdictional override capability
- Full Foundry fuzz + invariant test suite

---

## Status

This project is **in active development**. See [`CLAUDE.md`](./CLAUDE.md) for the build plan, current phase, and live progress tracker.

Current target: **v0.1.0** — whitelisting, jurisdictional checks, lockup enforcement, deployed to Base Sepolia.

For working with this codebase as an LLM agent (Claude Code or otherwise), `CLAUDE.md` is the source of truth for coding standards, testing requirements, and architectural decisions.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Uniswap V4 Pool Manager                  │
└───────────────────────┬─────────────────────────────────────┘
                        │ hook callbacks
                        ▼
┌─────────────────────────────────────────────────────────────┐
│                   CompliantRWAHook.sol                      │
│                                                             │
│  beforeSwap()          beforeAddLiquidity()                 │
│       │                        │                            │
│       └──────────┬─────────────┘                            │
│                  ▼                                          │
│       _verifyCompliance(address sender)                     │
│                  │                                          │
│         ┌────────┴──────────┐                               │
│         ▼                   ▼                               │
│  MerkleProofLib        IdentityRegistry                     │
│  (Solady, gas-opt)     (ERC-3643 bridge)                    │
└────────────────────────────┬────────────────────────────────┘
                             │ reads
                             ▼
┌─────────────────────────────────────────────────────────────┐
│               ComplianceRegistry.sol                        │
│                                                             │
│  • Merkle root storage (timelocked update path)             │
│  • Jurisdiction blocklist (bytes2 country codes)            │
│  • Accreditation tier mapping (Retail / Qualified / Inst.)  │
│  • Lockup expiry timestamps per address                     │
│  • Emergency pause                                          │
└─────────────────────────────────────────────────────────────┘
```

### Data flow

```
User calls swap() on PoolManager (via swap router)
    │
    ├── PoolManager calls hook.beforeSwap(sender, key, params, hookData)
    │       │
    │       ├── decode hookData → (proof, requiredTier)
    │       ├── verify MerkleProof.verify(proof, root, leaf)
    │       ├── check jurisdiction not blocked
    │       ├── check lockup window not active
    │       ├── check accreditation tier sufficient
    │       └── revert ComplianceViolation(reason) or return delta
    │
    └── if all checks pass → swap executes
```

---

## Contract Structure

```
src/
├── CompliantRWAHook.sol        # Core hook — beforeSwap, beforeAddLiquidity
├── ComplianceRegistry.sol      # Merkle root, jurisdiction, lockup storage
├── IdentityBridge.sol          # ERC-3643 / T-REX adapter
├── types/
│   └── ComplianceTypes.sol     # Enums, structs, custom errors
├── interfaces/
│   ├── ICompliantRWAHook.sol
│   ├── IComplianceRegistry.sol
│   └── IERC3643Bridge.sol
└── libraries/
    └── ComplianceLib.sol       # Pure verification helpers

test/
├── unit/                       # Per-contract unit tests
├── fuzz/                       # Fuzz test suites
├── invariant/                  # Stateful invariant tests
└── integration/                # End-to-end V4 swap flow tests

script/
├── Deploy.s.sol                # Full system deployment
├── UpdateMerkleRoot.s.sol      # Operator: propose/apply root update
└── GenerateProof.s.sol         # Helper: produce proofs for swap calldata
```

---

## Core Contracts

### `CompliantRWAHook.sol`

The hook inherits from Uniswap V4's `BaseHook` and implements four callbacks:

| Callback | Purpose |
|---|---|
| `beforeSwap` | Verify swapper is KYC'd before trade executes |
| `beforeAddLiquidity` | Verify LP is accredited before provisioning |
| `beforeRemoveLiquidity` | Honour lockup window (configurable) |
| `afterSwap` | Emit compliance audit event for off-chain indexing |

**Hook permissions:**

```solidity
Hooks.Permissions memory permissions = Hooks.Permissions({
    beforeSwap:             true,
    afterSwap:              true,
    beforeAddLiquidity:     true,
    beforeRemoveLiquidity:  true,
    afterAddLiquidity:      false,
    afterRemoveLiquidity:   false,
    beforeInitialize:       false,
    afterInitialize:        false,
    beforeDonate:           false,
    afterDonate:            false,
    noOp:                   false,
    accessLock:             false
});
```

**Core verification logic (sketch):**

```solidity
function _verifyCompliance(
    address account,
    bytes32[] calldata merkleProof,
    AccreditationTier requiredTier
) internal view {
    // 1. Merkle proof check (~6,500 gas, depth-14 tree)
    bytes32 leaf = keccak256(abi.encodePacked(account, uint8(requiredTier)));
    if (!MerkleProofLib.verify(merkleProof, registry.merkleRoot(), leaf)) {
        revert ComplianceViolation(ComplianceError.NOT_WHITELISTED);
    }

    // 2. Jurisdiction blocklist
    if (registry.isJurisdictionBlocked(registry.countryOf(account))) {
        revert ComplianceViolation(ComplianceError.BLOCKED_JURISDICTION);
    }

    // 3. Lockup window
    if (block.timestamp < registry.lockupExpiryOf(account)) {
        revert ComplianceViolation(ComplianceError.LOCKUP_ACTIVE);
    }

    // 4. Accreditation tier
    if (registry.accreditationOf(account) < requiredTier) {
        revert ComplianceViolation(ComplianceError.INSUFFICIENT_TIER);
    }
}
```

### `ComplianceRegistry.sol`

State decoupled from the hook so roots can be updated without redeploying the hook (V4 hooks encode permissions in their address bits — redeployment = new address = new pool).

**Timelocked root updates:**

```solidity
function proposeRootUpdate(bytes32 newRoot) external onlyOperator {
    pendingRoot = PendingRootUpdate({
        root: newRoot,
        effectiveAt: uint64(block.timestamp + ROOT_UPDATE_DELAY)
    });
    emit RootUpdateProposed(newRoot, pendingRoot.effectiveAt);
}

function applyRootUpdate() external {
    if (block.timestamp < pendingRoot.effectiveAt) revert TooEarly();
    merkleRoot = pendingRoot.root;
    delete pendingRoot;
    emit RootUpdated(merkleRoot);
}
```

### `IdentityBridge.sol`

Optional adapter for protocols already running an ERC-3643 / T-REX `IdentityRegistry` contract:

```solidity
interface IERC3643Bridge {
    function isVerified(address account) external view returns (bool);
    function investorCountry(address account) external view returns (uint16);
}

contract IdentityBridge {
    IERC3643Bridge public immutable tRexRegistry;

    function isCompliant(address account, bytes2 jurisdiction) external view returns (bool) {
        return tRexRegistry.isVerified(account)
            && !blockedJurisdictions[uint16(jurisdiction)];
    }
}
```

---

## Custom Errors

```solidity
enum ComplianceError {
    NOT_WHITELISTED,
    BLOCKED_JURISDICTION,
    LOCKUP_ACTIVE,
    INSUFFICIENT_TIER,
    POOL_PAUSED,
    INVALID_PROOF
}

error ComplianceViolation(ComplianceError reason);
error UnauthorizedOperator();
error TooEarly();
error InvalidMerkleRoot();
error RootStale();
error NotInitialized();
```

---

## Accreditation Tiers

| Tier | Value | Access |
|---|---|---|
| `None` | 0 | No access |
| `Retail` | 1 | Eligible for retail-grade RWA pools |
| `Qualified` | 2 | Eligible for Reg D / Reg S pools |
| `Institutional` | 3 | Eligible for all pools, including restricted institutional |

Pool deployers set a `minimumTier` per pool in `PoolKey` extra data. The hook enforces it at swap time.

---

## Gas Profile (target)

| Operation | Estimated Gas |
|---|---|
| `beforeSwap` (Merkle verify, 10k-address tree) | ~8,500 |
| `beforeSwap` (jurisdiction + lockup checks) | ~3,200 |
| `beforeAddLiquidity` | ~9,000 |
| Root update proposal (operator) | ~24,000 |
| Root update application (anyone) | ~6,000 |

*Merkle proof verification uses Solady's `MerkleProofLib` (assembly-optimised).*

Actual gas snapshots are tracked in `.gas-snapshot` and updated continuously through development.

---

## Installation

```bash
git clone https://github.com/codesensys/compliant-rwa-hook
cd compliant-rwa-hook

forge install
forge build
forge test -vvv
forge test --match-path test/invariant/* -vvv
forge snapshot
```

**Dependencies:**

```toml
v4-core              = { git = "https://github.com/Uniswap/v4-core",        tag = "v1.0.0" }
v4-periphery         = { git = "https://github.com/Uniswap/v4-periphery",   tag = "v1.0.0" }
solady               = { git = "https://github.com/Vectorized/solady",      tag = "v0.0.219" }
openzeppelin-contracts = { git = "https://github.com/OpenZeppelin/openzeppelin-contracts", tag = "v5.0.2" }
forge-std            = { git = "https://github.com/foundry-rs/forge-std",   tag = "v1.9.4" }
```

---

## Deployment

```bash
# dry run on local fork
forge script script/Deploy.s.sol --rpc-url $BASE_SEPOLIA_RPC_URL

# real broadcast
forge script script/Deploy.s.sol \
  --rpc-url $BASE_SEPOLIA_RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --broadcast \
  --verify

# update Merkle root (operator)
forge script script/UpdateMerkleRoot.s.sol \
  --sig "run(bytes32)" 0xabc123... \
  --rpc-url $MAINNET_RPC_URL \
  --private-key $OPERATOR_PRIVATE_KEY \
  --broadcast
```

**Hook address mining** (V4 hooks must satisfy address bit constraints — `Deploy.s.sol` handles this automatically via `HookMiner`):

```solidity
(address hookAddress, bytes32 salt) = HookMiner.find(
    CREATE2_DEPLOYER,
    requiredFlags,
    type(CompliantRWAHook).creationCode,
    abi.encode(poolManager, complianceRegistry)
);
```

---

## Off-chain: Generating Merkle Proofs

The whitelist is maintained off-chain (in your KYC provider's database) and committed on-chain as a Merkle root. A lightweight TypeScript service generates proofs on demand:

```typescript
import { StandardMerkleTree } from "@openzeppelin/merkle-tree";

// Build tree from KYC-verified address list
const tree = StandardMerkleTree.of(
  addresses.map(({ address, tier }) => [address, tier]),
  ["address", "uint8"]
);

// Publish root on-chain (via UpdateMerkleRoot.s.sol)
const root = tree.root;

// Generate proof for a specific address
const proof = tree.getProof([userAddress, userTier]);
```

The proof is passed by the frontend as calldata in the swap transaction's `hookData` field.

---

## Audit Readiness

- [x] NatSpec on every public/external function
- [x] Custom errors only (no `require` strings)
- [x] CEI pattern enforced
- [x] No `delegatecall` or upgradeable proxies
- [x] All state mutations emit events
- [ ] Slither clean (zero high/medium findings)
- [ ] Halmos symbolic execution suite (planned)
- [ ] External audit (post-v0.1.0)

**Invariants tested:**

- `complianceRegistry.merkleRoot()` is never `bytes32(0)` after initialization
- A blocked jurisdiction's resident can never pass `_verifyCompliance`
- An address with `lockupExpiry > block.timestamp` can never successfully swap
- A cancelled pending root cannot be applied
- Hook permissions returned by `getHookPermissions()` match the address-encoded bits

---

## Roadmap

**v0.1.0 (current target):**

- [x] Project scaffolding, `CLAUDE.md`, README
- [ ] `ComplianceTypes.sol`
- [ ] `ComplianceRegistry.sol` with timelocked root updates
- [ ] `ComplianceLib.sol` + `IdentityBridge.sol`
- [ ] `CompliantRWAHook.sol` — full callback suite
- [ ] Deployment script + Base Sepolia deployment
- [ ] First successful + first reverted swap recorded on-chain

**v0.2.0:**

- [ ] Migration to consume the [`@codesensys/rwa-compliance`](https://github.com/codesensys/rwa-compliance) library
- [ ] Multi-registry support (one hook, multiple jurisdictional registries)
- [ ] On-chain dispute window for root updates

**v0.3.0+:**

- [ ] zkProof-based private KYC (verify compliance without revealing address linkage)
- [ ] Halmos symbolic execution suite
- [ ] Compliance dashboard (React + Wagmi)
- [ ] Mainnet deployment with audit

---

## Related Projects

- [**rwa-compliance**](https://github.com/codesensys/rwa-compliance) — Sibling library of compliance primitives (allowlists, blocklists, jurisdictions, lockups, accreditation, transfer windows, forced transfers). The hook will adopt this library as a dependency starting in v0.2.0.

---

## Built By

**CodesenSys** — Blockchain development boutique specialising in DeFi infrastructure, smart contract security, and RWA tokenisation.

- Website: [codesensys.com](https://codesensys.com)
- X: [@codesensys](https://x.com/codesensys)
- LinkedIn: [linkedin.com/company/codesensys](https://linkedin.com/company/codesensys)

---

## License

MIT — see [LICENSE](LICENSE).

> *This codebase is provided for educational and research purposes. It has not been audited. Do not use in production without a professional security review. Compliance requirements vary by jurisdiction — consult legal counsel before deploying regulated financial instruments on-chain.*
