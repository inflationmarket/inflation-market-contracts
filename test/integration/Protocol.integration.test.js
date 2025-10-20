const { expect } = require("chai");
const { ethers, upgrades, network } = require("hardhat");
const { loadFixture, time } = require("@nomicfoundation/hardhat-network-helpers");

const MAINNET_RPC_URL = process.env.MAINNET_RPC_URL;

const FORK_BLOCK = 20_500_000;
const USDC_ADDRESS = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
const USDC_WHALE = "0x28C6c06298d514Db089934071355E5743bf21d60"; // Binance hot wallet

// Reuse liquid Chainlink feeds so IndexOracle can pull real data.
const CHAINLINK_ETH_USD_FEED = "0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419";

const BASIS_POINTS = 10_000n;

if (!MAINNET_RPC_URL) {
  // eslint-disable-next-line no-console
  console.warn("MAINNET_RPC_URL env var missing - skipping integration tests.");
  describe.skip("Integration: Protocol", () => undefined);
} else {
  describe("Integration: Protocol Ecosystem (Mainnet Fork)", function () {
    this.timeout(600_000);

    before(async function () {
      await network.provider.request({
        method: "hardhat_reset",
        params: [
          {
            forking: {
              jsonRpcUrl: MAINNET_RPC_URL,
              blockNumber: FORK_BLOCK,
            },
          },
        ],
      });
    });

    async function deploySuite() {
      const accounts = await ethers.getSigners();
      const admin = accounts[0];
      const userA = accounts[1];
      const userB = accounts[2];
      const liquidator = accounts[3];
      const feeRecipient = accounts[4];

      const usdc = await ethers.getContractAt("IERC20", USDC_ADDRESS);

      // Fund test users with mainnet USDC via impersonation.
      await fundWithUSDC(admin, usdc, userA.address, ethers.parseUnits("200000", 6));
      await fundWithUSDC(admin, usdc, userB.address, ethers.parseUnits("200000", 6));
      await fundWithUSDC(admin, usdc, liquidator.address, ethers.parseUnits("10000", 6));

      const Vault = await ethers.getContractFactory("Vault");
      const vault = await upgrades.deployProxy(
        Vault,
        [
          admin.address,       // DEFAULT_ADMIN_ROLE
          feeRecipient.address, // Fee recipient / insurance destination
          10,                   // Trading fee rate (0.10%)
        ],
        { kind: "uups" },
      );
      await vault.waitForDeployment();

      // Register USDC as primary collateral.
      await vault.connect(admin).addCollateral(USDC_ADDRESS, 6, true);

      const IndexOracle = await ethers.getContractFactory("IndexOracle");
      const indexOracle = await upgrades.deployProxy(
        IndexOracle,
        [
          CHAINLINK_ETH_USD_FEED, // CPI placeholder feed
          CHAINLINK_ETH_USD_FEED, // Treasury yield placeholder feed
          3600,                  // update interval
          500                    // max deviation (5%)
        ],
        { kind: "uups" },
      );
      await indexOracle.waitForDeployment();
      await indexOracle.connect(admin).setIndexPriceManual(ethers.parseEther("2000"));

      const VAMM = await ethers.getContractFactory("vAMM");
      const initialBaseReserve = ethers.parseEther("500000");    // 500k base
      const initialQuoteReserve = ethers.parseEther("1_000_000_000"); // ensures price ~2000
      const vamm = await upgrades.deployProxy(
        VAMM,
        [initialBaseReserve, initialQuoteReserve],
        { kind: "uups" },
      );
      await vamm.waitForDeployment();

      const FundingRateCalculator = await ethers.getContractFactory("FundingRateCalculator");
      const fundingCalculator = await upgrades.deployProxy(
        FundingRateCalculator,
        [
          await vamm.getAddress(),
          await indexOracle.getAddress(),
          ethers.ZeroAddress, // position manager placeholder
          3600,               // funding interval (1h)
          ethers.parseEther("1"), // coefficient
          ethers.parseEther("0.001"), // max funding per interval (0.1%)
          ethers.parseEther("0.001"), // min funding (0.1%)
        ],
        { kind: "uups" },
      );
      await fundingCalculator.waitForDeployment();

      const PositionManager = await ethers.getContractFactory("PositionManager");
      const positionManager = await upgrades.deployProxy(
        PositionManager,
        [
          await vault.getAddress(),
          await indexOracle.getAddress(),
          await fundingCalculator.getAddress(),
          await vamm.getAddress(),
          feeRecipient.address,
          admin.address,
        ],
        { kind: "uups" },
      );
      await positionManager.waitForDeployment();

      // Wire dependencies.
      await fundingCalculator.setPositionManager(await positionManager.getAddress());
      await vamm.setPositionManager(await positionManager.getAddress());

      const POSITION_MANAGER_ROLE = await vault.POSITION_MANAGER_ROLE();
      await vault.connect(admin).grantRole(POSITION_MANAGER_ROLE, await positionManager.getAddress());

      const LIQUIDATOR_ROLE = await positionManager.LIQUIDATOR_ROLE();
      await positionManager.connect(admin).grantRole(LIQUIDATOR_ROLE, liquidator.address);

      // Approvals for deposits.
      await usdc.connect(userA).approve(await vault.getAddress(), ethers.MaxUint256);
      await usdc.connect(userB).approve(await vault.getAddress(), ethers.MaxUint256);
      await usdc.connect(liquidator).approve(await vault.getAddress(), ethers.MaxUint256);

      return {
        admin,
        userA,
        userB,
        liquidator,
        feeRecipient,
        usdc,
        vault,
        positionManager,
        indexOracle,
        fundingCalculator,
        vamm,
      };
    }

    describe("Scenario 1: Complete User Journey", function () {
      it("should execute full lifecycle and realize profits", async function () {
        const ctx = await loadFixture(deploySuite);
        const { userA, admin, usdc, vault, positionManager, indexOracle, fundingCalculator, vamm } = ctx;

        const depositAmount = ethers.parseUnits("20_000", 6);
        await vault.connect(userA).deposit(USDC_ADDRESS, depositAmount);

        const collateral = ethers.parseUnits("2_000", 6);
        const leverage = ethers.parseEther("5"); // 5x

        const tx = await positionManager.connect(userA).openPosition(true, collateral, leverage, 0, ethers.MaxUint256);
        const receipt = await tx.wait();
        const positionOpened = parseEvent(positionManager.interface, receipt, "PositionOpened");
        const positionId = positionOpened.args.positionId;

        // Push mark price upward by placing an additional long
        await positionManager.connect(userA).openPosition(true, collateral / 2n, leverage, 0, ethers.MaxUint256);

        // Update oracle (higher index price) and advance time for funding accrual
        await indexOracle.connect(admin).setIndexPriceManual(ethers.parseEther("2100"));
        await time.increase(3600);
        await triggerFundingUpdate(ctx);

        const pnlBeforeClose = await positionManager.calculatePnL(positionId);
        expect(pnlBeforeClose).to.be.gt(0n);

        const usdcBalanceBefore = await usdc.balanceOf(userA.address);
        await positionManager.connect(userA).closePosition(positionId);

        const availableAfterClose = await vault.availableBalance(userA.address, USDC_ADDRESS);
        await vault.connect(userA).withdraw(USDC_ADDRESS, availableAfterClose);
        const usdcBalanceAfter = await usdc.balanceOf(userA.address);

        expect(usdcBalanceAfter).to.be.gt(usdcBalanceBefore);
      });
    });

    describe("Scenario 2: Liquidation Flow", function () {
      it("should liquidate underwater position and distribute collateral", async function () {
        const ctx = await loadFixture(deploySuite);
        const { admin, userA, userB, liquidator, feeRecipient, usdc, vault, positionManager, indexOracle } = ctx;

        const userDeposit = ethers.parseUnits("50_000", 6);
        await vault.connect(userA).deposit(USDC_ADDRESS, userDeposit);
        await vault.connect(userB).deposit(USDC_ADDRESS, userDeposit);

        const collateral = ethers.parseUnits("5_000", 6);
        const leverage = ethers.parseEther("20"); // 20x leverage
        const tx = await positionManager.connect(userA).openPosition(true, collateral, leverage, 0, ethers.MaxUint256);
        const receipt = await tx.wait();
        const positionId = parseEvent(positionManager.interface, receipt, "PositionOpened").args.positionId;

        // Massive short from userB to push price down
        const shortCollateral = ethers.parseUnits("40_000", 6);
        await positionManager.connect(userB).openPosition(false, shortCollateral, ethers.parseEther("10"), 0, ethers.MaxUint256);

        // Force oracle price down to exacerbate loss
        await indexOracle.connect(admin).setIndexPriceManual(ethers.parseEther("1500"));

        const health = await positionManager.getPositionHealth(positionId);
        expect(health).to.be.lt(500n); // below maintenance

        const feeRecipientBalanceBefore = await vault.totalBalance(feeRecipient.address, USDC_ADDRESS);
        const liquidatorBalanceBefore = await vault.totalBalance(liquidator.address, USDC_ADDRESS);

        await positionManager.connect(liquidator).liquidatePosition(positionId);

        const feeRecipientBalanceAfter = await vault.totalBalance(feeRecipient.address, USDC_ADDRESS);
        const liquidatorBalanceAfter = await vault.totalBalance(liquidator.address, USDC_ADDRESS);

        expect(feeRecipientBalanceAfter).to.be.gt(feeRecipientBalanceBefore);
        expect(liquidatorBalanceAfter).to.be.gt(liquidatorBalanceBefore);
      });
    });

    describe("Scenario 3: Multi-User Funding Interactions", function () {
      it("should settle longs and shorts with zero-sum P&L (excluding fees)", async function () {
        const ctx = await loadFixture(deploySuite);
        const { admin, userA, userB, usdc, vault, positionManager, indexOracle } = ctx;

        const deposit = ethers.parseUnits("30_000", 6);
        await vault.connect(userA).deposit(USDC_ADDRESS, deposit);
        await vault.connect(userB).deposit(USDC_ADDRESS, deposit);

        const collateral = ethers.parseUnits("3_000", 6);
        const leverage = ethers.parseEther("8");

        const longTx = await positionManager.connect(userA).openPosition(true, collateral, leverage, 0, ethers.MaxUint256);
        const longId = parseEvent(positionManager.interface, await longTx.wait(), "PositionOpened").args.positionId;

        const shortTx = await positionManager.connect(userB).openPosition(false, collateral, leverage, 0, ethers.MaxUint256);
        const shortId = parseEvent(positionManager.interface, await shortTx.wait(), "PositionOpened").args.positionId;

        // Adjust oracle and time to accrue funding payments between the two sides
        await indexOracle.connect(admin).setIndexPriceManual(ethers.parseEther("2050"));
        await time.increase(7200); // two funding intervals
        await triggerFundingUpdate(ctx);

        const pnlLong = await positionManager.calculatePnL(longId);
        const pnlShort = await positionManager.calculatePnL(shortId);

        // PnLs should offset within a tolerance of combined trading fees
        const tolerance = ethers.parseUnits("50", 6); // $50 tolerance
        expect((pnlLong + pnlShort)).to.be.within(-tolerance, tolerance);

        await positionManager.connect(userA).closePosition(longId);
        await positionManager.connect(userB).closePosition(shortId);
      });
    });
  });
}

// ------------------------------------------------------------
// Utility helpers
// ------------------------------------------------------------

async function fundWithUSDC(admin, usdc, recipient, amount) {
  await network.provider.request({ method: "hardhat_impersonateAccount", params: [USDC_WHALE] });
  const whale = await ethers.getSigner(USDC_WHALE);
  await admin.sendTransaction({ to: USDC_WHALE, value: ethers.parseEther("2") });
  await usdc.connect(whale).transfer(recipient, amount);
  await network.provider.request({ method: "hardhat_stopImpersonatingAccount", params: [USDC_WHALE] });
}

async function triggerFundingUpdate(ctx) {
  const { admin, positionManager, fundingCalculator, vamm, indexOracle } = ctx;
  const pmAddress = await positionManager.getAddress();
  const markPrice = await vamm.getMarkPrice();
  const indexPrice = await indexOracle.getIndexPrice();

  await admin.sendTransaction({ to: pmAddress, value: ethers.parseEther("1") });
  await network.provider.request({ method: "hardhat_impersonateAccount", params: [pmAddress] });
  const pmSigner = await ethers.getSigner(pmAddress);
  await fundingCalculator.connect(pmSigner).updateFundingRate(markPrice, indexPrice);
  await network.provider.request({ method: "hardhat_stopImpersonatingAccount", params: [pmAddress] });
}

function parseEvent(iface, receipt, eventName) {
  for (const log of receipt.logs) {
    try {
      const parsed = iface.parseLog(log);
      if (parsed && parsed.name === eventName) {
        return parsed;
      }
    } catch (err) {
      // ignore parsing errors for unrelated logs
    }
  }
  throw new Error(`Event ${eventName} not found in transaction logs`);
}
