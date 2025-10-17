# Inflation Market - Smart Contracts

Decentralized perpetual futures protocol for trading real-world inflation data.

## Architecture

### Core Contracts

#### 🎯 PositionManager.sol (THE HEART)
The central contract managing the entire position lifecycle:
- Open/close perpetual positions
- Add/remove collateral
- Calculate PnL (Profit & Loss)
- Position health monitoring
- Liquidation triggers

**Key Features:**
- Leverage up to 20x
- Real-time PnL calculation
- Funding rate integration
- Health ratio monitoring

#### 💰 Vault.sol
Manages protocol liquidity and collateral:
- ERC20 vault shares for liquidity providers
- Collateral locking/unlocking
- Liquidity pool management
- Share-based accounting

#### 📊 IndexOracle.sol
Chainlink integration for inflation data:
- Fetches CPI/inflation indices
- Historical data tracking
- Price feed updates
- Oracle source management

#### 💸 FundingRateCalculator.sol
Maintains price peg through funding rates:
- Calculates funding rates based on mark vs. index price
- Time-based funding intervals
- Rate capping for stability
- Automatic updates

#### ⚡ Liquidator.sol
Protocol solvency through position liquidation:
- Liquidation eligibility checks
- Liquidator rewards (5% of collateral)
- Threshold management
- Automated liquidation execution

#### 🔄 vAMM.sol
Virtual Automated Market Maker for price discovery:
- Constant product formula (x * y = k)
- Virtual reserves (no actual tokens)
- Price calculation
- Slippage simulation

## Installation

```bash
npm install
```

## Configuration

Create `.env` file:
```bash
cp .env.example .env
```

Edit `.env` with your values:
- `SEPOLIA_RPC_URL` - Alchemy/Infura RPC endpoint
- `PRIVATE_KEY` - Deployer private key
- `ETHERSCAN_API_KEY` - For contract verification

## Usage

### Compile Contracts
```bash
npm run compile
```

### Run Tests
```bash
npm test
```

### Test Coverage
```bash
npm run test:coverage
```

### Gas Report
```bash
npm run test:gas
```

### Deploy to Localhost
```bash
# Terminal 1: Start local node
npm run node

# Terminal 2: Deploy
npm run deploy
```

### Deploy to Sepolia Testnet
```bash
npm run deploy:sepolia
```

## Contract Addresses (Sepolia Testnet)

Coming soon after deployment...

## Key Concepts

### Position Management
Users can open long or short positions on inflation indices:
- **Long**: Profit when inflation increases
- **Short**: Profit when inflation decreases

### Leverage
Amplify exposure up to 20x with collateral:
- Higher leverage = higher risk & reward
- Minimum: 1x, Maximum: 20x

### Funding Rates
Periodic payments between longs and shorts:
- Keeps perpetual price anchored to index
- Calculated based on mark vs. index price premium
- Paid/received every funding interval

### Liquidation
Undercollateralized positions can be liquidated:
- Liquidation threshold: 80% health ratio
- Liquidators receive 5% reward
- Protects protocol solvency

### Health Ratio
```
Health Ratio = Effective Collateral / Required Collateral
```
- Above 100%: Healthy position
- Below 80%: Liquidatable

## Security

- ✅ OpenZeppelin upgradeable contracts
- ✅ ReentrancyGuard on critical functions
- ✅ Pausable for emergency stops
- ✅ UUPS proxy pattern for upgradeability
- ✅ Access control with Ownable

## Testing

```bash
# Run all tests
npm test

# Run specific test file
npx hardhat test test/PositionManager.test.js

# Run with gas reporting
REPORT_GAS=true npm test
```

## Architecture Diagram

```
┌─────────────────┐
│  User (Trader)  │
└────────┬────────┘
         │
         ▼
┌─────────────────────┐      ┌──────────────┐
│  PositionManager    │◄─────┤    vAMM      │ (Price Discovery)
│    (THE HEART)      │      └──────────────┘
└──────────┬──────────┘
           │
    ┌──────┴──────┬────────────┬──────────────┐
    ▼             ▼            ▼              ▼
┌────────┐   ┌─────────┐  ┌─────────┐   ┌───────────┐
│ Vault  │   │ Oracle  │  │ Funding │   │Liquidator │
└────────┘   └─────────┘  └─────────┘   └───────────┘
    │             │            │              │
    ▼             ▼            ▼              ▼
  USDC       Chainlink    Rate Calc      Liquidations
```

## Development Roadmap

- [x] Core contracts implementation
- [ ] Comprehensive unit tests
- [ ] Integration tests
- [ ] Testnet deployment
- [ ] Security audit
- [ ] Mainnet deployment

## License

MIT

## Contact

- Twitter: [@inflationmarket](https://twitter.com/inflationmarket)
- Discord: [Join our community](https://discord.gg/inflationmarket)
- Website: [inflationmarket.com](https://inflationmarket.com)
