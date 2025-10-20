# PositionManager.sol Security Fixes Implementation Guide

## Status: IN PROGRESS

This document tracks the critical security fixes being applied to PositionManager.sol

## ✅ COMPLETED FIXES

### 1. Added New State Variables (Lines 72-74, 91-94)
```solidity
// FIX #4: O(1) position lookup to prevent DoS
mapping(address => mapping(bytes32 => uint256)) private positionIndex;

// FIX #15: Prevent position ID collisions
mapping(address => uint256) private userNonces;

// FIX #1: Maximum position size (1 billion USDC)
uint256 public constant MAX_POSITION_SIZE = 1_000_000_000e6;

// FIX #7: Maximum positions per user (prevent DoS)
uint256 public constant MAX_POSITIONS_PER_USER = 50;

// FIX #10: Maintenance margin bounds
uint256 public constant MIN_MAINTENANCE_MARGIN = 100; // 1%
uint256 public constant MAX_MAINTENANCE_MARGIN = 2000; // 20%
```

### 2. Added New Custom Errors (Lines 168-172)
```solidity
error PositionTooLarge(); // FIX #1
error TooManyPositions(); // FIX #7
error SlippageExceeded(); // FIX #2
error InvalidMaintenanceMargin(); // FIX #10
error SwapFailed(bytes data); // FIX #13
```

### 3. Added Missing Events (Lines 155-156)
```solidity
event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
event MinCollateralUpdated(uint256 oldAmount, uint256 newAmount);
```

### 4. Updated openPosition Signature (Line 279-285)
```solidity
function openPosition(
    bool isLong,
    uint256 collateralAmount,
    uint256 leverage,
    uint256 minPrice,  // NEW: Slippage protection
    uint256 maxPrice   // NEW: Slippage protection
) external nonReentrant whenNotPaused returns (bytes32 positionId)
```

### 5. Added Position Limits Check (Lines 291-294)
```solidity
// FIX #7: Check maximum positions per user
if (userPositions[msg.sender].length >= MAX_POSITIONS_PER_USER) {
    revert TooManyPositions();
}
```

### 6. Added Position Size Validation (Lines 317-318)
```solidity
// FIX #1: Validate position size doesn't exceed maximum
if (size > MAX_POSITION_SIZE) revert PositionTooLarge();
```

## 🔄 PENDING FIXES (NEED TO APPLY)

### FIX #2: Add Slippage Protection to openPosition
**Location**: After line 353 (after getting entryPrice)
```solidity
uint256 entryPrice = vamm.getPrice();

// FIX #2: SLIPPAGE PROTECTION
if (isLong && entryPrice > maxPrice) revert SlippageExceeded();
if (!isLong && entryPrice < minPrice) revert SlippageExceeded();
```

### FIX #5: Reorganize openPosition for Checks-Effects-Interactions
**Current Order** (WRONG):
1. Checks (validation) ✅
2. ❌ Interactions (vault.lockCollateral)
3. ❌ Interactions (vault.releaseCollateral for fees)
4. ❌ Interactions (vamm.swap)
5. ❌ Interactions (vamm.getPrice)
6. Effects (state changes - position storage)

**Correct Order**:
1. Checks (validation)
2. Effects (generate position ID, store position state)
3. Interactions (ALL external calls LAST)

**Implementation**:
```solidity
function openPosition(...) external nonReentrant whenNotPaused returns (bytes32 positionId) {
    // ========== CHECKS ==========
    if (userPositions[msg.sender].length >= MAX_POSITIONS_PER_USER) revert TooManyPositions();
    if (collateralAmount < minCollateral) revert InsufficientCollateral();
    if (leverage < MIN_LEVERAGE || leverage > maxLeverage) revert InvalidLeverage();

    uint256 size = (collateralAmount * leverage) / PRECISION;
    if (size > MAX_POSITION_SIZE) revert PositionTooLarge();

    // Get price (read-only, safe before effects)
    uint256 entryPrice = vamm.getPrice();

    // Slippage protection
    if (isLong && entryPrice > maxPrice) revert SlippageExceeded();
    if (!isLong && entryPrice < minPrice) revert SlippageExceeded();

    uint256 fee = (size * tradingFee) / BASIS_POINTS;
    uint256 entryFundingIndex = _getCurrentFundingIndex();
    uint256 liquidationPrice = _calculateLiquidationPrice(entryPrice, leverage, isLong);

    // ========== EFFECTS ==========
    // Generate position ID with user nonce
    positionId = keccak256(
        abi.encodePacked(
            msg.sender,
            block.timestamp,
            totalPositions,
            isLong,
            userNonces[msg.sender]++ // FIX #15
        )
    );

    // Store position
    positions[positionId] = Position({
        trader: msg.sender,
        isLong: isLong,
        size: size,
        collateral: collateralAmount,
        leverage: leverage,
        entryPrice: entryPrice,
        entryFundingIndex: entryFundingIndex,
        timestamp: block.timestamp,
        liquidationPrice: liquidationPrice
    });

    // Update user position tracking with index
    uint256 index = userPositions[msg.sender].length;
    userPositions[msg.sender].push(positionId);
    positionIndex[msg.sender][positionId] = index; // FIX #4

    totalPositions++;

    // ========== INTERACTIONS ==========
    // Lock collateral
    vault.lockCollateral(msg.sender, collateralAmount);

    // Handle fees
    if (fee > 0) {
        vault.lockCollateral(msg.sender, fee);
        vault.releaseCollateral(feeRecipient, fee);
    }

    // Execute swap with better error handling
    try vamm.swap(size, isLong) returns (uint256) {
        // Success
    } catch Error(string memory reason) {
        revert(string(abi.encodePacked("vAMM swap failed: ", reason)));
    } catch (bytes memory lowLevelData) {
        revert SwapFailed(lowLevelData); // FIX #13
    }

    emit PositionOpened(positionId, msg.sender, isLong, collateralAmount, size, leverage, entryPrice, block.timestamp);
}
```

### FIX #4: Update _removeUserPosition with O(1) Lookup
**Location**: Lines 1702-1714
```solidity
function _removeUserPosition(address user, bytes32 positionId) internal {
    bytes32[] storage positions = userPositions[user];
    uint256 index = positionIndex[user][positionId];
    uint256 lastIndex = positions.length - 1;

    if (index != lastIndex) {
        bytes32 lastPositionId = positions[lastIndex];
        positions[index] = lastPositionId;
        positionIndex[user][lastPositionId] = index; // Update moved position's index
    }

    positions.pop();
    delete positionIndex[user][positionId];
}
```

### FIX #6: Fix Precision Loss in P&L Calculation
**Location**: Line 1262
```solidity
// BEFORE (precision loss)
pnl = (priceDelta * int256(position.size)) / int256(position.entryPrice);

// AFTER (better precision)
int256 scaledDelta = (priceDelta * int256(PRECISION)) / int256(position.entryPrice);
pnl = (scaledDelta * int256(position.size)) / int256(PRECISION);
```

### FIX #10: Add Maintenance Margin Validation
**Location**: Lines 1727-1748 (setRiskParameters function)
```solidity
function setRiskParameters(...) external onlyRole(ADMIN_ROLE) {
    if (_maxLeverage > MAX_LEVERAGE_CAP) revert InvalidLeverage();

    // FIX #10: Validate maintenance margin bounds
    if (_maintenanceMargin < MIN_MAINTENANCE_MARGIN ||
        _maintenanceMargin > MAX_MAINTENANCE_MARGIN) {
        revert InvalidMaintenanceMargin();
    }

    if (_tradingFee > 1000) revert FeeTooHigh();
    if (_liquidationFee > 1000) revert FeeTooHigh();

    // ... rest
}
```

### FIX #9: Add Events to Admin Functions
**Location**: Lines 1793-1803
```solidity
function setFeeRecipient(address _feeRecipient) external onlyRole(ADMIN_ROLE) {
    if (_feeRecipient == address(0)) revert ZeroAddress();
    address oldRecipient = feeRecipient;
    feeRecipient = _feeRecipient;
    emit FeeRecipientUpdated(oldRecipient, _feeRecipient); // FIX #9
}

function setMinCollateral(uint256 _minCollateral) external onlyRole(ADMIN_ROLE) {
    uint256 oldAmount = minCollateral;
    minCollateral = _minCollateral;
    emit MinCollateralUpdated(oldAmount, _minCollateral); // FIX #9
}
```

### FIX #14: Add Storage Gap for Upgradeability
**Location**: End of contract (before closing brace)
```solidity
    // ============================================================================
    // UPGRADE SAFETY
    // ============================================================================

    /**
     * @dev Gap for future storage variables in upgrades
     * Reserves 50 storage slots to allow adding new state variables
     * in future upgrades without breaking storage layout
     */
    uint256[50] private __gap;
}
```

### FIX #11: Improve Liquidation Collateral Calculation
**Location**: Lines 948-966 (liquidatePosition function)
```solidity
// BEFORE (uses original collateral)
uint256 reward = (position.collateral * liquidationFee) / BASIS_POINTS;

// AFTER (uses actual remaining equity)
int256 pnl = _calculatePnL(position);
int256 equity = int256(position.collateral) + pnl;
uint256 actualCollateral = equity > 0 ? uint256(equity) : 0;

uint256 reward = (actualCollateral * liquidationFee) / BASIS_POINTS;
uint256 remaining = actualCollateral - reward;

// Distribute equity, not original collateral
if (reward > 0) {
    vault.releaseCollateral(msg.sender, reward);
}
if (remaining > 0) {
    vault.releaseCollateral(feeRecipient, remaining);
}
```

## 📋 TEST UPDATES NEEDED

Since we changed the `openPosition` function signature, all tests need to be updated:

```javascript
// OLD
await positionManager.connect(trader1).openPosition(
    true,
    collateralAmount,
    leverage
);

// NEW
await positionManager.connect(trader1).openPosition(
    true,
    collateralAmount,
    leverage,
    0,              // minPrice (0 = no minimum for longs)
    ethers.MaxUint256  // maxPrice (max = no limit for longs)
);

// For shorts:
await positionManager.connect(trader1).openPosition(
    false,              // short
    collateralAmount,
    leverage,
    ethers.parseEther("1900"), // minPrice (short needs minimum)
    ethers.MaxUint256           // maxPrice
);
```

## 🎯 NEXT STEPS

1. Apply remaining fixes to PositionManager.sol
2. Update all test files with new function signatures
3. Run full test suite in WSL
4. Fix any test failures
5. Commit and push changes
6. Deploy to testnet for further testing

## 📊 PROGRESS

- **Completed**: 6/11 fixes (55%)
- **Remaining**: 5/11 fixes (45%)
- **Status**: Partially implemented, needs completion
