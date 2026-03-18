# Amagi Protocol 🏔️

Decentralized lending and borrowing protocol built on Ethereum. Users can deposit ETH as collateral to borrow USDC, or provide USDC liquidity to the pool.

## Features

* **Lending:** Deposit USDC to provide liquidity.
* **Borrowing:** Use ETH as collateral to borrow USDC (75% LTV).
* **Liquidation:** Integrated health factor checks with a 5% liquidation bonus.
* **Interest:** Automated 10% APR calculated per block.
* **Security:** Built using OpenZeppelin's `SafeERC20` and `ReentrancyGuard`.

## Technical Stack

* **Language:** Solidity 0.8.24
* **Framework:** Foundry
* **Oracle:** Chainlink Price Feeds (ETH/USD)
* **Token:** USDC (6 Decimals)

## Getting Started

### Prerequisites

Make sure you have [Foundry](https://book.getfoundry.sh/getting-started/installation) installed.

### Installation

1. Clone the repository:
   ```bash
   git clone [https://github.com/theonomiMC/amagi-protocol.git](https://github.com/theonomiMC/amagi-protocol.git)
   cd amagi-protocol