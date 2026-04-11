# Amagi Protocol V2 - Smart Contract Upgrade

This branch contains the **V2 Upgrade** of the Amagi Lending Protocol. The core focus of this version is the transition to a debt-based model, integration of an Interest Rate Mechanism (IRM), and a robust security testing suite.

## 🔗 Contract Addresses (Sepolia)

- **Proxy (Entry Point):** `0xfA7f34169E182737fa06abAC901E361b42b445A4`
- **Implementation (V2):** `0x4f8C9893122BDcF0835f4d0200D51C752a63D1d1`
- **Underlying Asset (USDC):** `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238`

## 🔧 Quick Start

```bash
git clone https://github.com/theonomiMC/amagi-protocol.git
cd amagi-protocol
forge install
forge test
```

## 🚀 Key Features in V2

- **Debt Model:** Users can now borrow USDC against their ETH collateral.
- **Dynamic Interest Rates:** Implemented a "Kinked" Interest Rate Model (IRM) based on pool utilization.
- **UUPS Upgradeability:** Protocol logic is upgradeable via the `UUPSUpgradeable` pattern.
- **Liquidation Engine:** Automated health factor calculations and liquidation incentives.

## Security Considerations
### Oracle Risk
AmagiPool uses a single Chainlink ETH/USD price feed with the following 
protections:
- Reverts if price is zero or negative
- Reverts if price data is older than 24 hours (`PriceExpired`)
- Reverts if the Chainlink round did not complete (`answeredInRound < roundId`)

**Known Limitation:** The protocol uses a single oracle source with no 
fallback. In production, a dual-oracle setup (Chainlink primary + Uniswap 
V3 TWAP fallback) is recommended. If the two feeds diverge by more than a 
set threshold, the protocol would pause automatically. This is a planned 
improvement for V3.

Emergency pausing by the owner or guardian address mitigates oracle 
manipulation risk in the interim.

### Admin Controls
- `owner` — can upgrade contract, change IRM parameters, set guardian
- `guardian` — can pause/unpause protocol only (limited trust role)
- All admin actions emit on-chain events for transparency

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

| File                                | % Lines    | % Branches | % Funcs     |
| :---------------------------------- | :--------- | :--------- | :---------- |
| **src/AmagiPoolV2.sol**             | **98.52%** | **90.70%** | **100.00%** |
| **test/invariants/HandlerV2.t.sol** | **92.98%** | **91.67%** | **85.71%**  |

## ⚙️ Deployment & Upgrade

The upgrade was managed via `DeployV2.s.sol`, which performed the following:

1. Deployed the new `AmagiPoolV2` implementation.
2. Executed `upgradeToAndCall` on the existing Proxy.
3. Triggered `initializeV2()` to set IRM parameters (Base Rate: 2%, Optimal Util: 80%).

---

_Developed as part of the Amagi Protocol security-first development cycle._
