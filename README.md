# Amagi Protocol V2 - Smart Contract Upgrade

This branch contains the **V2 Upgrade** of the Amagi Lending Protocol. The core focus of this version is the transition to a debt-based model, integration of an Interest Rate Mechanism (IRM), and a robust security testing suite.

## 🔧 Quick Start

```
git clone https://github.com/theonomiMC/amagi-protocol.git
forge install
forge test
forge coverage
```

## 🚀 Key Features in V2

- **Debt Model:** Users can now borrow USDC against their ETH collateral.
- **Dynamic Interest Rates:** Implemented a "Kinked" Interest Rate Model (IRM) based on pool utilization.
- **UUPS Upgradeability:** Protocol logic is upgradeable via the `UUPSUpgradeable` pattern.
- **Liquidation Engine:** Automated health factor calculations and liquidation incentives.

## 🛡️ Testing Suite

The protocol has been rigorously tested using a multi-layered approach:

### 1. Unit Testing

Located in `test/`, these tests cover specific function logic, edge cases, and access control.

- **Coverage:** Focus on new V2 functions (`borrow`, `repay`, `liquidate`).
- **Command:** `forge test --match-path test/*`

### 2. Invariant Testing (Fuzzing)

Located in `test/invariants/`, these tests ensure that the protocol's core properties hold true under any sequence of random transactions.

- **Handler-based Fuzzing:** A dedicated `HandlerV2.t.sol` manages actor interactions and state.
- **Key Invariants:**
  - `invariant_solvency`: Total Assets >= Total Liabilities.
  - `invariant_TotalDebtConsistency`: Sum of individual user shares == Total borrow shares.
  - `invariant_depositorBalances`: Depositors' assets remain protected and accrue interest.
- **Command:** `forge test --match-path test/invariants/*`

## 📊 Coverage Report

The current testing suite achieves high branch coverage for the core logic:

| File                                | % Lines    | % Branches  | % Funcs     |
| :---------------------------------- | :--------- | :---------- | :---------- |
| **src/AmagiPoolV2.sol**             | **98.28%** | **89.74%**  | **100.00%** |
| **test/invariants/HandlerV2.t.sol** | **92.98%** | **91.67%** | **85.71%**  |

## ⚙️ Deployment & Upgrade

The upgrade is managed via `DeployV2.s.sol`, which performs the following:

1. Deploys the new implementation.
2. Calls `upgradeToAndCall` on the existing Proxy.
3. Triggers `initializeV2()` to set IRM parameters.

---

_Developed as part of the Amagi Protocol security-first development cycle._
