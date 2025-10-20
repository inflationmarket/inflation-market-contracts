# Testing Guide

This document captures the current state of automated testing for Inflation Market smart contracts and recommended workflows for contributors.

## Test Suite Overview

- **Total specs**: 57 Hardhat tests covering deployment, leverage management, funding, liquidations, and edge cases.
- **Mocks**: `contracts/mocks/MockERC20.sol` (USDC stand-in) and additional fixtures used by the test suite.
- **Location**: All tests live inside the `test/` directory, with `test/PositionManager.test.js` providing the majority of coverage.

## Known Issue: Hardhat + npm on Windows

Running `npm test` on Windows can trigger:

```
Error HH18: You installed Hardhat with a corrupted lockfile due to the NPM bug #4828.
```

This stems from an npm bug affecting optional native dependencies (`@nomicfoundation/solidity-analyzer-*`). The contracts compile correctly, but the full test suite may fail to execute on Windows hosts.

### Workarounds

1. **Use WSL2 (Recommended)**
   ```bash
   wsl --install
   # inside WSL
   cd /mnt/c/Users/<user>/inflation-market-contracts
   npm install
   npm test
   ```

2. **Docker**
   ```dockerfile
   FROM node:18-alpine
   WORKDIR /app
   COPY package*.json ./
   RUN npm install
   COPY . .
   CMD ["npm", "test"]
   ```
   ```bash
   docker build -t inflation-market-tests .
   docker run inflation-market-tests
   ```

3. **GitHub Actions / CI**
   - Tests pass on Linux runners. See `.github/workflows/test.yml` for an example job.

4. **Compilation Check**
   ```bash
   npx hardhat compile
   npx hardhat check
   ```
   Use this when you only need syntax validation.

## Running Tests

```bash
npm test               # run entire suite
npm run test:gas       # include gas report
npm run test:coverage  # produce Istanbul coverage report
npx hardhat test test/PositionManager.test.js  # target a single file
```

Use `npx hardhat test --verbose` for detailed logging during debugging.

## Test Structure & Patterns

- Fixture-based setup for quick deployments and isolated state.
- Explicit custom error checks to ensure revert reasons remain stable.
- Event assertions to verify observability requirements.
- Integration-style flows that exercise open → adjust → close cycles under different leverage and funding scenarios.

## Future Enhancements

- Add fuzz and invariant tests around funding rate math and liquidation thresholds.
- Simulate Chainlink oracle latency and failure scenarios.
- Expand coverage for multi-user liquidation and vault accounting edge cases.
