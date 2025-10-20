const hre = require("hardhat");
const config = require("./config");
const { loadDeployments, saveDeployments, verifyProxyImplementation, logPostDeploymentCheck } = require("./utils");

async function main() {
  const network = hre.network.name;
  const cfg = config[network];
  if (!cfg) {
    throw new Error(`No deployment config defined for ${network}.`);
  }

  const deployments = loadDeployments(network);
  if (deployments.liquidator) {
    console.log(`Liquidator already deployed at ${deployments.liquidator}. Skipping.`);
    return;
  }

  const positionManager = deployments.positionManager;
  const vault = deployments.vault;
  const oracle = deployments.indexOracle;
  if (!positionManager || !vault || !oracle) {
    throw new Error("Liquidator deployment requires position manager, vault, and oracle addresses. Deploy them first.");
  }

  const { liquidator } = cfg;
  const insuranceFund = liquidator.insuranceFund;
  const liquidationFee = liquidator.liquidationFeeBps;
  const rewardFee = liquidator.liquidatorRewardBps;

  if (!insuranceFund) {
    throw new Error("Insurance fund address must be configured via ARB_INSURANCE_FUND_ADDRESS env var.");
  }

  const [deployer] = await hre.ethers.getSigners();
  console.log(`Deploying Liquidator from ${deployer.address} to ${network}...`);

  const Liquidator = await hre.ethers.getContractFactory("Liquidator");
  const liquidatorProxy = await hre.upgrades.deployProxy(
    Liquidator,
    [
      positionManager,
      vault,
      oracle,
      insuranceFund,
      liquidationFee,
      rewardFee,
    ],
    { kind: "uups" },
  );
  await liquidatorProxy.waitForDeployment();

  const proxyAddress = await liquidatorProxy.getAddress();
  console.log(`Liquidator proxy deployed at ${proxyAddress}`);

  const implementationAddress = await verifyProxyImplementation(hre, proxyAddress);

  deployments.liquidator = proxyAddress;
  deployments.liquidatorImplementation = implementationAddress;
  saveDeployments(network, deployments);

  const storedInsurance = await liquidatorProxy.insuranceFund();
  logPostDeploymentCheck(
    "Liquidator insurance fund",
    storedInsurance.toLowerCase() === insuranceFund.toLowerCase(),
    insuranceFund,
    storedInsurance,
  );

  console.log("Liquidator deployment complete.");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
