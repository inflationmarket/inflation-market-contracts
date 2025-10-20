# Inflation Market Smart Contracts

Inflation Market is a decentralized perpetual futures protocol that lets traders take long or short exposure to real-world inflation indices. This repository contains the core smart contracts, deployment scripts, and test suites that power the protocol.

## Core Components

- `contracts/PositionManager.sol` – central contract orchestrating the full position lifecycle (open, adjust, close, liquidate).
- `contracts/Vault.sol` – collateral vault responsible for custody, accounting, and share issuance for liquidity providers.
- `contracts/IndexOracle.sol` – oracle adapter that pulls Chainlink CPI feeds and maintains historical inflation data.
- `contracts/FundingRateCalculator.sol` – calculates funding payments that keep perpetual prices anchored to the inflation index.
- `contracts/Liquidator.sol` – enforces solvency by liquidating unhealthy positions and distributing incentives.
- `contracts/vAMM.sol` – virtual AMM that simulates inflation perpetual pricing via a constant-product curve.

Helper contracts live under `contracts/interfaces` and `contracts/mocks` for external integrations and testing support.

## Getting Started

Install dependencies:

```bash
npm install
```

Copy the environment template and configure network credentials if you plan to deploy:

```bash
cp .env.example .env
```

Required variables:
- `SEPOLIA_RPC_URL` – RPC endpoint for Sepolia testnet.
- `PRIVATE_KEY` – deployer key (never commit secrets).
- `ETHERSCAN_API_KEY` – optional, for contract verification.

## Common Tasks

Compile contracts:
```bash
npm run compile
```

Run the test suite:
```bash
npm test
```

Generate coverage and gas reports:
```bash
npm run test:coverage
npm run test:gas
```

Launch a local Hardhat node and deploy:
```bash
# Terminal 1
npm run node

# Terminal 2
npm run deploy
```

Deploy to Sepolia:
```bash
npm run deploy:sepolia
```

## Protocol Concepts

- **Positions** – traders use `PositionManager` to open leveraged long or short exposure to inflation indices. PnL is tracked in real time using virtual pricing from the vAMM.
- **Leverage** – configurable leverage up to 20x. Risk parameters (min collateral, leverage caps, liquidation thresholds) are controlled via admin roles.
- **Funding Rates** – `FundingRateCalculator` compares mark price versus index price and produces time-based funding payments exchanged between longs and shorts.
- **Liquidations** – if a position’s health drops below the maintenance threshold, the `Liquidator` pays off debt, redistributes remaining collateral, and awards a bounty.
- **Oracle Data** – `IndexOracle` consumes Chainlink CPI feeds to keep the protocol aligned with real-world inflation metrics.

## Security Practices

- Upgradeable pattern via UUPS and OpenZeppelin libraries.
- Role-based access control (`ADMIN_ROLE`, `LIQUIDATOR_ROLE`) for sensitive operations.
- Reentrancy guards, pausable failsafes, and granular custom errors for safer interaction.
- Extensive tests covering position management, margin adjustments, liquidations, and funding flows.

## Roadmap

- [x] Core contract implementation
- [ ] Expand test coverage for edge and integration scenarios
- [ ] Deploy to public testnet with monitoring
- [ ] Commission external security audit
- [ ] Mainnet launch

## License

MIT
