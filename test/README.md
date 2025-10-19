# PositionManager Test Suite

Comprehensive unit and integration tests for the PositionManager contract.

## Test Coverage

### 1. Deployment Tests (5 tests)
- ✅ Verify initial state
- ✅ Check role assignments
- ✅ Validate contract addresses
- ✅ Confirm risk parameters
- ✅ Test zero address validation

### 2. Position Opening Tests (14 tests)
- ✅ Open long position successfully
- ✅ Open short position successfully
- ✅ Calculate position size correctly
- ✅ Test leverage validation (1x, 10x, 20x)
- ✅ Reject zero leverage
- ✅ Reject leverage above maximum (25x)
- ✅ Reject insufficient collateral
- ✅ Lock collateral in vault
- ✅ Emit PositionOpened event
- ✅ Generate unique position IDs
- ✅ Reject when paused

### 3. Position Closing Tests (7 tests)
- ✅ Close position successfully
- ✅ Handle profitable close
- ✅ Emit PositionClosed event
- ✅ Reject if not position owner
- ✅ Reject if position doesn't exist
- ✅ Remove from user's position list
- ✅ Handle multiple positions

### 4. P&L Calculation Tests (3 tests)
- ✅ Calculate P&L for existing position
- ✅ Revert for non-existent position
- ✅ Return zero P&L when price hasn't moved

### 5. Margin Management Tests (6 tests)
- ✅ Add margin to position
- ✅ Remove margin from position
- ✅ Reject zero amount operations
- ✅ Reject removing all collateral
- ✅ Reject operations on non-existent position

### 6. Liquidation Tests (4 tests)
- ✅ Check if position is liquidatable
- ✅ Return false for non-existent position
- ✅ Only allow liquidator role
- ✅ Reject liquidation of healthy position

### 7. Integration Tests (3 tests)
- ✅ Complete user flow (open → close)
- ✅ Multiple positions per user
- ✅ Track positions across multiple users

### 8. Security Tests (5 tests)
- ✅ Reentrancy protection
- ✅ Pause functionality
- ✅ Restrict admin functions
- ✅ Prevent unauthorized upgrades
- ✅ Validate risk parameter updates

### 9. Edge Cases (7 tests)
- ✅ Minimum collateral edge case
- ✅ Maximum leverage edge case
- ✅ Closing already closed position
- ✅ Extreme position sizes
- ✅ Rapid open/close cycles
- ✅ Insufficient vault balance

### 10. View Functions (3 tests)
- ✅ Return position details
- ✅ Return empty array for no positions
- ✅ Return correct total positions count

## Total: 57 Comprehensive Tests

## Running Tests

```bash
# Run all tests
npm test

# Run with gas reporting
npm run test:gas

# Run with coverage
npm run test:coverage

# Run specific test file
npx hardhat test test/PositionManager.test.js

# Run with detailed output
npx hardhat test --verbose
```

## Test Fixtures

The test suite uses Hardhat fixtures for efficient test setup:

- `deployFixture()`: Deploys all contracts with proper initialization
- `openPositionFixture()`: Creates a fixture with an open position
- `positionForMarginTests()`: Sets up position for margin management tests

## Mock Contracts

- `MockERC20.sol`: Mock USDC token with 6 decimals
- Allows unrestricted minting for test scenarios

## Prerequisites

Before running tests, ensure:
1. Node.js installed (v18+ recommended)
2. Dependencies installed: `npm install`
3. Hardhat properly configured

## Known Issues

If you encounter `Error HH18` (corrupted lockfile):
```bash
rm -rf node_modules package-lock.json
npm cache clean --force
npm install
```

## Test Structure

Each test follows the pattern:
1. **Arrange**: Set up test data using fixtures
2. **Act**: Execute the function under test
3. **Assert**: Verify expected outcomes using Chai assertions

## Key Testing Patterns Used

- ✅ Fixture-based setup for efficiency
- ✅ Descriptive test names
- ✅ Event emission verification
- ✅ Revert testing with custom errors
- ✅ State change verification
- ✅ Role-based access control testing
- ✅ Edge case coverage
- ✅ Integration testing

## Future Test Enhancements

Potential additions:
- Fuzzing tests for extreme values
- Invariant tests
- Fork testing against mainnet
- Gas optimization benchmarks
- Liquidation scenario simulations
