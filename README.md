<!-- ![CI](https://github.com/theonomiMC/amagi-protocol/actions/workflows/CI.yml/badge.svg) -->
![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)
![Foundry](https://img.shields.io/badge/Built%20with-Foundry-FFDE00.svg)
![Coverage](https://img.shields.io/badge/Coverage-98%25-brightgreen.svg)

# Amagi Protocol

A lending protocol where users deposit ETH as collateral to borrow USDC, or provide USDC liquidity to earn interest. Built as a learning project to understand how DeFi lending works under the hood — collateral math, liquidations, interest accrual, and invariant testing.

---

## ⚙️ How it works

Depositors put USDC in, making it available for borrowers. Borrowers lock ETH as collateral and take out USDC loans. If a borrower's health factor drops below 1, anyone can liquidate their position.

- **75% LTV** — borrow up to 75% of your ETH collateral value
- **10% APR** — interest accrues continuously via a global borrow index
- **80% liquidation threshold** — positions become liquidatable below this
- **5% liquidation bonus** — incentive for liquidators

The protocol uses a share-based debt model. When you borrow, you receive debt shares rather than a fixed amount. As the global index grows over time, your shares represent more USDC owed — no per-user tracking needed.

---

## 🏗️ Architecture
```
AmagiPool.sol (UUPS Upgradeable)
├── deposit() / withdraw()           — USDC liquidity
├── depositCollateral() / withdrawCollateral() — ETH collateral
├── borrow() / repay()               — loan management
├── liquidate()                      — position liquidation
└── _updateIndex()                   — interest accrual
```

Chainlink ETH/USD oracle provides the price feed with staleness checks.

---

## 🔒 Security

- UUPS upgradeable proxy (OpenZeppelin)
- ReentrancyGuard on all state-changing functions
- SafeERC20 for token transfers
- Chainlink oracle with 24h staleness check
- SafeCast for uint256 → uint128 conversions

---

## 🧪 Testing

Three layers of tests:

**Unit tests** — one function at a time, covering happy paths, reverts, and edge cases.

**Invariant tests** — stateful fuzzer runs random sequences of deposit, borrow, repay, liquidate, and price changes. Four invariants checked after every call:
```
solvency:           pool balance >= net deposits - borrowed + repaid
noBadDebt:          healthy positions always have collateral >= debt  
healthFactorValid:  all borrowers maintain hf >= 1
indexMonotonicity:  global borrow index never decreases
```

Passed **65,536 calls** across **512 sequences** with **0 violations**.

**Coverage** (measured on `src/` only):

| Metric     | Rate   |
|------------|--------|
| Lines      | 98.36% |
| Statements | 98.79% |
| Branches   | 92.31% |
| Functions  | 92.86% |

---

## 🚀 Getting Started

### Prerequisites

Install [Foundry](https://book.getfoundry.sh/getting-started/installation).

### Installation
```bash
git clone https://github.com/theonomiMC/amagi-protocol.git
cd amagi-protocol
forge install
```

### Running tests
```bash
# unit tests
forge test

# invariant suite
forge test --match-contract AmagiInvariants

# coverage
forge coverage --report lcov
```

---

## Dependencies

- OpenZeppelin Contracts v5 (+ Upgradeable)
- Chainlink Brownie Contracts
- Foundry

---

## Deployments

*Sepolia testnet deployment coming in V2.*

---

## Roadmap

- ✅ Core lending/borrowing with ETH collateral
- ✅ Share-based debt model with global interest index
- ✅ Partial liquidations
- ✅ UUPS upgradeability
- ✅ Invariant test suite
- ⬜ Interest Rate Model (utilization-based)
- ⬜ Sepolia deployment
- ⬜ Multi-collateral support