# Vault-Based Staking System

A staking system with isolated per-prover vaults, time-delayed unstaking, slashing protection, and reward distribution.

## Table of Contents

- [1. System Overview](#1-system-overview)
- [2. Prover Lifecycle](#2-prover-lifecycle)
- [3. Staking & Unstaking](#3-staking--unstaking)
- [4. Rewards & Commission](#4-rewards--commission)
- [5. Slashing Model](#5-slashing-model)
- [6. Parameters & Admin Controls](#6-parameters--admin-controls)
- [7. Security Considerations](#7-security-considerations)
- [Appendix A. API Reference](#appendix-a-api-reference)
- [Appendix B. Core Data Structures](#appendix-b-core-data-structures)

---

## 1. System Overview

The staking system consists of three main components:

### **StakingController** (Central Orchestrator)
- Orchestrates lifecycle: delegation, rewards, slashing, state transitions.
- Custodies pending unstakes and slashed funds (treasury).
- Provides O(1) share accounting and enforces minimum self-stake + optional authorization.

### **ProverVault** (Per-Prover Isolation)
- Per-prover ERC4626 vault; only controller can deposit/withdraw underlying.
- Shares are transferable ERC20 (self-stake minimum portion non‑transferable).
- Rewards are donated (no new shares), raising share price for all.

### **VaultFactory** (Deterministic Deployment)
- Creates predictable vault addresses using CREATE2 (supports pre-registration & off-chain discovery)

### **Key Properties**
- Constant-time accounting: per-prover O(1) core operations
- Capital-efficient: rewards auto-compound; shares remain liquid (minus locked self-stake)
- Two-phase unstake: requests burn shares immediately; value remains slashable until completion

---

## 2. Prover Lifecycle

### **States & Transitions**

**States:**
- **Null:** Not initialized
- **Active:** Accepting delegations, participating in consensus, slashable
- **Deactivated:** Not accepting new delegations, can still complete unstakes
- **Jailed:** Admin penalty state, stronger than deactivated

**State Transitions:**
- `initializeProver()` -> **Active** (requires minimum self-stake)
- Full self-stake exit -> **Deactivated** (automatic)
- Slashing below minimum -> **Deactivated** (automatic)  
- Admin actions -> **Deactivated**/**Jailed**/**Active**
- `retireProver()` -> **Null** (only if vault empty and no pending unstakes)

### **Self-Stake Policy**

- **Minimum Enforcement:** Provers must maintain `MinSelfStake` in active vault shares
- **Partial Restrictions:** Cannot reduce self-stake to (0, MinSelfStake) range
- **Full Exit Allowed:** Complete self-stake removal permitted (triggers deactivation)
- **Pending Exclusion:** Only vault shares count, not assets in pending unstakes
- **Dynamic Enforcement:** Changes to `MinSelfStake` don't force immediate deactivation

---

## 3. Staking & Unstaking

### **Staking Flow**
1. **Validation:** Prover exists and (if delegator) state is Active.
2. **Token Transfer & Deposit:** Controller pulls user tokens and deposits into the prover's vault, receiving shares.
3. **Accounting & Event:** Share balances updated via hooks; emit `Staked` (prover, staker, assets, shares).

### **Two-Phase Unstaking**

**Phase 1: Request (`requestUnstake`)**
- **Share Burning:** Shares immediately burned, stop accruing rewards  
- **Request Recording:** Creates `UnstakeRequest` with current slashing scale snapshot
- **Self-Stake Check:** Enforces minimum requirements for prover
- **Request Limits:** Maximum 10 pending requests per (prover, staker) pair
- **Auto-Deactivation:** Triggers if prover exits all self-stake

**Phase 2: Completion (`completeUnstake`)**  
- **Delay Enforcement:** Must wait at least `unstakeDelay` seconds
- **Current Slashing:** Effective amount computed via slashing scale (see Section 5)
- **Batch Processing:** Processes all ready requests from oldest first
- **Asset Transfer:** Transfers effective amounts to user
- **Continuous Slashing:** Assets remain slashable until completion transaction

**Critical Behaviors:**
- **Post-Maturity Slashing:** Ready requests continue to be affected by slashing
- **Zero Delay Still Two-Step:** Even with `unstakeDelay = 0`, completion required
- **Scale Continues:** No "freezing" of value at maturity time

---

## 4. Rewards & Commission

### **Reward Distribution**
- Caller invokes `addRewards(prover, totalAmount)` (`msg.sender` = reward source)
- Lookup rate: `rate = getCommissionRate(prover, msg.sender)` (basis points)
- Split: `commission = totalAmount * rate / 10000`; `remainder = totalAmount - commission`
- Accrue: add `commission` to `pendingCommission`
- Donate: send `remainder` to the vault (no new shares minted)
- Effect: vault share price increases for all existing holders; reverts if vault has zero shares (windfall guard)

### **Commission Management**
- **Resolution:** `rate = commissionRates[msg.sender] if set else commissionRates[address(0)]` (basis points)
- **Rationale:** Aligns commission with heterogeneous source cost profiles (heavy proof fees vs baseline) while avoiding over/under‑charging and vault proliferation

---

## 5. Slashing Model

### **Dual-Target Slashing**
```
slash(prover, factor) // factor in basis points (0-10000)
├── Pending Unstakes: Apply factor to slashingScale, reduce totalUnstaking
├── Vault Assets: Proportional removal via vault.controllerSlash()  
└── Treasury Transfer: All slashed amounts moved to controller treasury
```

### **Slashing Scale & Application**
- **Initial Scale:** 10000 bps (100%).
- **Cumulative Scaling:** Each slash: `newScale = currentScale × (10000 - factor) ÷ 10000` (then bounded by floor).
- **Floor:** `MIN_SCALE_FLOOR` (2000 = 20%) prevents total value wipeout.
- **Deactivation:** Triggers if scale < `DEACTIVATION_SCALE` (4000 = 40%) or self-stake < minimum (see [Section 2](#2-prover-lifecycle)).
- **Future Requests:** Snapshot current scale at request time.
- **Pending Requests:** Effective withdrawal = `original × currentScale ÷ snapshotScale` at completion.
- **Continuous Impact:** Scale changes propagate to all pending requests until completed.

---

## 6. Parameters & Admin Controls

### **Economic Parameters**
| Parameter | Units / Format | Description |
|-----------|----------------|-------------|
| `MinSelfStake` | tokens | Minimum self-stake a prover must maintain to stay Active |
| `MaxSlashFactor` | bps (0–10000) | Max fraction removable in a single slashing event |
| `UnstakeDelay` | seconds | Minimum wait between request and completion of unstake |
| `AuthorizationRequired` | bool | If true, `initializeProver` requires `AUTHORIZED_PROVER_ROLE` |

### **Authorization**
- **Toggle:** When `authorizationRequired = true`, `initializeProver` requires `AUTHORIZED_PROVER_ROLE`
- **Role Lifecycle:** Admin grants/revokes `AUTHORIZED_PROVER_ROLE` independently of the toggle

### **Admin Capabilities**
- **Parameter Updates:** All economic parameters adjustable by owner
- **Treasury Management:** Withdraw accumulated slashed funds
- **Emergency Powers:** Pause protocol, recover tokens (when paused)
- **Role Management:** Grant/revoke slasher and authorized prover roles
- **Prover Control:** Force deactivation, jailing, and retirement

### **Trust Model**
- **Owner Privileges:** Significant economic control, no built-in timelock
- **Assumptions:** Governance/multisig provides off-chain assurances
- **Emergency Recovery:** Requires paused state, used for stuck tokens

---

## 7. Security Considerations

### **Built-In Protections**

**Smart Contract Safety:**
- **Reentrancy Protection:** All external calls protected by OpenZeppelin ReentrancyGuard
- **State Consistency:** Share-transfer hook syncs controller balances on every mint/burn/transfer
- **Access Controls:** Role-based permissions prevent unauthorized operations
- **Input Validation:** All operations validate prover existence, state requirements, and parameter bounds

**Economic Safeguards (summarized):** Core protections are specified in earlier functional sections (slashing floor, windfall guard, request limit, self‑stake minimum, two‑phase unstake with continued slashability) and not repeated here to avoid redundancy; see Sections 3–5.

### **Operational & Governance Risks**

**Admin Powers**
- Owner can change economic parameters without timelock
- Emergency token recovery (when paused) is powerful; scope carefully
- Role mismanagement (slasher / authorized prover) can enable unintended actions

**Parameter Abuse**
- Adverse adjustments to `MinSelfStake`, `MaxSlashFactor`, or `UnstakeDelay` can shift economics suddenly
- Governance process (off‑chain) needed for parameter change review

**Commission Front‑Running**
- Provers may raise per‑source commission just before large reward distributions (monitor recent changes)

**Implementation Drift**
- Future vault/controller code changes could desynchronize accounting assumptions
- Maintain invariant tests around share/asset accounting and slashing math

**Underlying Asset Risk**
- Underlying token pause / upgrade / depeg impacts all vaults
- Consider whitelisting only battle‑tested assets and monitoring token events

**Monitoring Practices**
- Track cumulative slashing scale for extreme penalties
- Periodically withdraw & account treasury balances
- Audit commission rate changes for anomalous timing
- Rotate slasher roles; review access lists regularly

---

## Appendix A. API Reference

**Complete function documentation:** [`IStakingController.sol`](../src/staking/interfaces/IStakingController.sol)

The interface is organized into logical sections:
- [Prover Management](../src/staking/interfaces/IStakingController.sol#L100) - Initialization, state changes, retirement
- [Staking Operations](../src/staking/interfaces/IStakingController.sol#L136) - Stake, unstake, complete withdrawal  
- [Reward & Commission](../src/staking/interfaces/IStakingController.sol#L163) - Reward distribution and commission claims
- [Slashing](../src/staking/interfaces/IStakingController.sol#L197) - Penalty mechanisms
- [View Functions](../src/staking/interfaces/IStakingController.sol#L209) - Query prover info, staking data, and unstaking status
- [Vault Integration](../src/staking/interfaces/IStakingController.sol#L411) - Vault interaction controls
- [Admin Functions](../src/staking/interfaces/IStakingController.sol#L465) - Parameter management and emergency controls

---

## Appendix B. Core Data Structures

### **ProverInfo**
```solidity
struct ProverInfo {
    ProverState state;                               // Null | Active | Deactivated | Jailed
    address vault;                                   // Dedicated ERC4626 vault address
    mapping(address => uint256) shares;              // Fast O(1) share lookups
    EnumerableSet.AddressSet stakers;                // Efficient staker enumeration
    uint256 pendingCommission;                       // Unclaimed commission accumulated
    EnumerableMap.AddressToUintMap commissionRates;  // Source-specific commission rates in basis points (0-10000)
                                                     // address(0) = default rate for unknown sources
}
```

### **ProverPendingUnstakes**
```solidity
struct ProverPendingUnstakes {
    uint256 totalUnstaking;                         // Current effective total (post-slashing)
    uint256 slashingScale;                          // Cumulative scale remaining (basis points, starts at 10000)
    mapping(address => UnstakeRequest[]) requests;  // Per-staker request arrays
    EnumerableSet.AddressSet stakers;               // Stakers with pending requests
}
```

### **UnstakeRequest**
```solidity
struct UnstakeRequest {
    uint256 amount;         // Original amount when requested
    uint256 requestTime;    // Timestamp of unstake request
    uint256 scaleSnapshot;  // Slashing scale when request was made
}
```

---

**See [`IStakingController.sol`](../src/staking/interfaces/IStakingController.sol) for complete function signatures and parameter documentation.**
