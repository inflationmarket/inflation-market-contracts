# PositionManager Test Suite

Comprehensive unit and integration tests for the Inflation Market `PositionManager` contract.

## Coverage Breakdown

1. **Deployment (5 tests)** – verifies initial configuration, role assignments, and parameter bounds.
2. **Position Opening (14 tests)** – validates leverage limits, collateral checks, event emission, and slippage guards.
3. **Position Closing (7 tests)** – confirms owner-only access, profit/loss scenarios, and list maintenance.
4. **P&L Calculations (3 tests)** – ensures deterministic outcomes for price changes and missing positions.
5. **Margin Management (6 tests)** – covers add/remove margin flows and rejection of unsafe operations.
6. **Liquidations (4 tests)** – checks eligibility, role enforcement, and healthy-position protection.
7. **Integration (3 tests)** – exercises full user journeys and multi-position handling.
8. **Security (5 tests)** – focuses on pause controls, access control, upgrade safety, and reentrancy guards.
9. **Edge Cases (7 tests)** – stress tests extreme leverage, collateral, and rapid trading loops.
10. **View Helpers (3 tests)** – ensures read-only functions report accurate state.

Total: **57 tests**.

## Commands

```bash
npm test                  # run entire suite
npm run test:gas          # include gas metrics
npm run test:coverage     # produce coverage report
npx hardhat test --verbose
npx hardhat test test/PositionManager.test.js
```

## Fixtures & Utilities

- `deployFixture` – deploys the full protocol stack with base configuration.
- `openPositionFixture` – seeds an open position for downstream tests.
- `positionForMarginTests` – prepares scenarios for add/remove margin paths.

### Mock Contracts

- `MockERC20.sol` – 6-decimal USDC replacement that exposes unrestricted minting for test accounts.

## Best Practices

- Follow the Arrange / Act / Assert structure in new specs.
- Prefer fixtures to isolate state between tests.
- Use Hardhat's `expectRevert` helpers with custom error selectors to keep expectations strict.

## Planned Enhancements

- Fuzz testing of leverage and funding calculations.
- Invariant testing around vault solvency.
- Scenario tests for oracle delays and stale data.
