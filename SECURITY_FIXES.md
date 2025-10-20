# PositionManager.sol Security Fixes Tracker

Status: **in progress** – 6 of 11 identified fixes are implemented.

This document tracks the security hardening tasks for `contracts/PositionManager.sol` that are specific to the Inflation Market protocol.

## Completed Fixes

1. **Maximum position size**  
   - Added `MAX_POSITION_SIZE` constant (1B USDC) and validation in `openPosition` to reject oversize trades.  
   - Prevents overflow risk during fee and funding calculations.

2. **Custom errors and events**  
   - Introduced dedicated errors (`PositionTooLarge`, `TooManyPositions`, `SlippageExceeded`, `InvalidMaintenanceMargin`, `SwapFailed`).  
   - Added admin events (`FeeRecipientUpdated`, `MinCollateralUpdated`) for better monitoring.

3. **Slippage protection parameters**  
   - `openPosition` now accepts `minPrice`/`maxPrice` bounds to mitigate front-running and extreme price swings.

4. **Position limits per trader**  
   - Added `MAX_POSITIONS_PER_USER` guard (50) and a mapping-based index to remove positions in O(1) time.

5. **User nonce for position IDs**  
   - Added `userNonces` to ensure unique `positionId` values even across rapid position churn.

6. **Precision upgrade for PnL calculation**  
   - Adjusted price delta scaling to minimize rounding error in `_calculatePnL`.

## Pending Fixes

7. **Checks-Effects-Interactions refactor**  
   - Reorder `openPosition` to store state before calling external contracts (`vault`, `vAMM`) to reduce reentrancy surface.

8. **Maintenance margin bounds**  
   - Guard `setRiskParameters` to enforce `MIN_MAINTENANCE_MARGIN` ≤ margin ≤ `MAX_MAINTENANCE_MARGIN`.

9. **Admin event coverage**  
   - Emit events from `setFeeRecipient` and `setMinCollateral` after value updates.

10. **Liquidation equity accounting**  
    - Calculate liquidation rewards using remaining equity instead of original collateral.

11. **Storage gap**  
    - Reserve upgradeable storage slots (`uint256[50] private __gap`) before the contract footer.

## Required Test Updates

Because the `openPosition` signature changed, all tests invoking it must pass the new price bounds:

```javascript
await positionManager.connect(trader).openPosition(
  true,                // isLong
  collateralAmount,
  leverage,
  0n,                  // minPrice (0 = no lower bound for longs)
  ethers.MaxUint256    // maxPrice
);
```

Short positions should set a realistic `minPrice` instead of `0n`.

## Next Steps

1. Implement the five pending fixes in `PositionManager.sol`.
2. Update Hardhat tests and fixtures to use the expanded `openPosition` signature.
3. Run the full test suite (preferably inside WSL/Linux due to Windows Hardhat bug #4828).
4. Capture gas and coverage reports for regression tracking.
5. Prepare changelog and coordinate redeployments once all fixes pass review.
