const hre = require("hardhat");
const config = require("./config");
const { loadDeployments, saveDeployments, logPostDeploymentCheck } = require("./utils");

async function main() {
  const network = hre.network.name;
  const cfg = config[network];
  if (!cfg) {
    throw new Error(`No deployment config defined for ${network}.`);
  }

  const deployments = loadDeployments(network);
  const required = ["vault", "indexOracle", "fundingCalculator", "vamm", "positionManager"];
  for (const key of required) {
    if (!deployments[key]) {
      throw new Error(`Missing ${key} deployment. Deploy contracts before initialization.`);
    }
  }

  const vault = await hre.ethers.getContractAt("Vault", deployments.vault);
  const indexOracle = await hre.ethers.getContractAt("IndexOracle", deployments.indexOracle);
  const fundingCalculator = await hre.ethers.getContractAt("FundingRateCalculator", deployments.fundingCalculator);
  const vamm = await hre.ethers.getContractAt("vAMM", deployments.vamm);
  const positionManager = await hre.ethers.getContractAt("PositionManager", deployments.positionManager);
  const liquidator = deployments.liquidator
    ? await hre.ethers.getContractAt("Liquidator", deployments.liquidator)
    : null;

  const [deployer] = await hre.ethers.getSigners();
  console.log(`Initializing protocol components on ${network} with signer ${deployer.address}...`);

  await configureVault(cfg, vault, positionManager);
  await configureOracle(cfg, indexOracle);
  await configureVamm(cfg, vamm, positionManager);
  await configureFunding(cfg, fundingCalculator, positionManager);
  await configurePositionManager(cfg, positionManager, vault, liquidator);
  if (liquidator) {
    await configureLiquidator(cfg, liquidator, positionManager);
  } else {
    console.log("⚠ Liquidator deployment not found. Skipping Liquidator initialization.");
  }

  saveDeployments(network, deployments);
  console.log("System initialization complete.");
}

async function configureVault(cfg, vault, positionManager) {
  const collateralToken = cfg.collateral.token;
  const decimals = cfg.collateral.decimals;
  const positionManagerAddress = await positionManager.getAddress();

  const supported = await vault.supportedCollateral(collateralToken);
  const assetAddress = await vault.asset();

  if (!supported) {
    const setAsPrimary = assetAddress === hre.ethers.ZeroAddress;
    await (await vault.addCollateral(collateralToken, decimals, setAsPrimary)).wait();
    console.log(`✓ Vault collateral registered: ${collateralToken}`);
  } else {
    console.log("ℹ Vault collateral already registered");
  }

  if ((await vault.asset()).toLowerCase() !== collateralToken.toLowerCase()) {
    await (await vault.addCollateral(collateralToken, decimals, true)).wait();
    console.log("✓ Vault primary collateral updated");
  }

  if (!(await vault.depositsEnabled())) {
    await (await vault.setDepositsEnabled(true)).wait();
    console.log("✓ Deposits enabled");
  }

  if (!(await vault.withdrawalsEnabled())) {
    await (await vault.setWithdrawalsEnabled(true)).wait();
    console.log("✓ Withdrawals enabled");
  }

  const vaultFeeRecipient = cfg.vault.feeRecipient;
  if (vaultFeeRecipient && (await vault.feeRecipient()).toLowerCase() !== vaultFeeRecipient.toLowerCase()) {
    await (await vault.setFeeRecipient(vaultFeeRecipient)).wait();
    console.log(`✓ Vault fee recipient set to ${vaultFeeRecipient}`);
  }

  const role = await vault.POSITION_MANAGER_ROLE();
  if (!(await vault.hasRole(role, positionManagerAddress))) {
    await (await vault.grantRole(role, positionManagerAddress)).wait();
    console.log("✓ PositionManager granted vault role");
  }

  logPostDeploymentCheck("Vault configuration", true);
}

async function configureOracle(cfg, oracle) {
  const { chainlink } = cfg;
  const storedInterval = Number(await oracle.updateInterval());
  if (storedInterval !== chainlink.updateInterval) {
    await (await oracle.setUpdateInterval(chainlink.updateInterval)).wait();
    console.log(`✓ Oracle update interval set to ${chainlink.updateInterval}`);
  }

  if (oracle.setMaxPriceDeviation) {
    await (await oracle.setMaxPriceDeviation(chainlink.maxDeviation)).wait();
    console.log(`✓ Oracle max price deviation set to ${chainlink.maxDeviation}`);
  }
}

async function configureVamm(cfg, vamm, positionManager) {
  const positionManagerAddress = await positionManager.getAddress();
  await (await vamm.setPositionManager(positionManagerAddress)).wait();
  console.log("✓ vAMM position manager wired");

  if (vamm.setMaxPriceImpact) {
    await (await vamm.setMaxPriceImpact(cfg.vamm.maxPriceImpactBps)).wait();
    console.log(`✓ vAMM max price impact set to ${cfg.vamm.maxPriceImpactBps}`);
  }
}

async function configureFunding(cfg, fundingCalculator, positionManager) {
  const positionManagerAddress = await positionManager.getAddress();
  const currentPM = await fundingCalculator.positionManager();
  if (currentPM.toLowerCase() !== positionManagerAddress.toLowerCase()) {
    await (await fundingCalculator.setPositionManager(positionManagerAddress)).wait();
    console.log("✓ Funding calculator wired to position manager");
  }
}

async function configurePositionManager(cfg, positionManager, vault, liquidator) {
  const adminRole = await positionManager.ADMIN_ROLE();
  const [deployer] = await hre.ethers.getSigners();
  if (!(await positionManager.hasRole(adminRole, deployer.address))) {
    await (await positionManager.grantRole(adminRole, deployer.address)).wait();
    console.log("✓ PositionManager admin role granted to deployer");
  }

  const risk = cfg.positionManager;
  const currentMaxLev = await positionManager.maxLeverage();
  const currentMaintenance = await positionManager.maintenanceMargin();
  const currentTradingFee = await positionManager.tradingFee();
  const currentLiqFee = await positionManager.liquidationFee();

  if (
    currentMaxLev !== BigInt(risk.maxLeverage) ||
    currentMaintenance !== BigInt(risk.maintenanceMarginBps) ||
    currentTradingFee !== BigInt(risk.tradingFeeBps) ||
    currentLiqFee !== BigInt(risk.liquidationFeeBps)
  ) {
    await (
      await positionManager.setRiskParameters(
        risk.maxLeverage,
        risk.maintenanceMarginBps,
        risk.tradingFeeBps,
        risk.liquidationFeeBps,
      )
    ).wait();
    console.log("✓ PositionManager risk parameters configured");
  }

  const currentMinCollateral = await positionManager.minCollateral();
  if (currentMinCollateral !== BigInt(risk.minCollateral)) {
    await (await positionManager.setMinCollateral(risk.minCollateral)).wait();
    console.log(`✓ PositionManager min collateral set to ${risk.minCollateral}`);
  }

  // Grant liquidator contract the LIQUIDATOR_ROLE if present.
  if (liquidator) {
    const role = await positionManager.LIQUIDATOR_ROLE();
    const liquidatorAddress = await liquidator.getAddress();
    if (!(await positionManager.hasRole(role, liquidatorAddress))) {
      await (await positionManager.grantRole(role, liquidatorAddress)).wait();
      console.log("✓ Liquidator contract granted LIQUIDATOR_ROLE");
    }
  }

  // Ensure fee recipient matches configuration if provided.
  const desiredFeeRecipient = cfg.vault.feeRecipient;
  if (desiredFeeRecipient && (await positionManager.feeRecipient()).toLowerCase() !== desiredFeeRecipient.toLowerCase()) {
    await (await positionManager.setFeeRecipient(desiredFeeRecipient)).wait();
    console.log("✓ PositionManager fee recipient updated");
  }
}

async function configureLiquidator(cfg, liquidator, positionManager) {
  const insuranceFund = cfg.liquidator.insuranceFund;
  if ((await liquidator.insuranceFund()).toLowerCase() !== insuranceFund.toLowerCase()) {
    await (await liquidator.setInsuranceFund(insuranceFund)).wait();
    console.log("✓ Liquidator insurance fund updated");
  }

  const liquidationFee = BigInt(cfg.liquidator.liquidationFeeBps);
  if (await liquidator.liquidationFeePercent() !== liquidationFee) {
    await (await liquidator.setLiquidationFee(cfg.liquidator.liquidationFeeBps)).wait();
    console.log("✓ Liquidator fee updated");
  }

  const rewardFee = BigInt(cfg.liquidator.liquidatorRewardBps);
  if (await liquidator.liquidatorRewardPercent() !== rewardFee) {
    await (await liquidator.setLiquidatorReward(cfg.liquidator.liquidatorRewardBps)).wait();
    console.log("✓ Liquidator reward updated");
  }

  const vaultAddress = await liquidator.vault();
  const expectedVault = await positionManager.vault();
  logPostDeploymentCheck("Liquidator vault wiring", vaultAddress.toLowerCase() === expectedVault.toLowerCase(), expectedVault, vaultAddress);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
