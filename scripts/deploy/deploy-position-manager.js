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
  if (deployments.positionManager) {
    console.log(`PositionManager already deployed at ${deployments.positionManager}. Skipping.`);
    return;
  }

  const vault = deployments.vault;
  const oracle = deployments.indexOracle;
  const fundingCalculator = deployments.fundingCalculator;
  const vamm = deployments.vamm;
  if (!vault || !oracle || !fundingCalculator || !vamm) {
    throw new Error("PositionManager deployment requires vault, oracle, fundingCalculator, and vAMM addresses.");
  }

  const [deployer] = await hre.ethers.getSigners();
  const feeRecipient = cfg.vault.feeRecipient || deployer.address;
  console.log(`Deploying PositionManager from ${deployer.address} to ${network}...`);

  const PositionManager = await hre.ethers.getContractFactory("PositionManager");
  const positionManager = await hre.upgrades.deployProxy(
    PositionManager,
    [vault, oracle, fundingCalculator, vamm, feeRecipient, deployer.address],
    { kind: "uups" },
  );
  await positionManager.waitForDeployment();

  const proxyAddress = await positionManager.getAddress();
  console.log(`PositionManager proxy deployed at ${proxyAddress}`);

  const implementationAddress = await verifyProxyImplementation(hre, proxyAddress);

  deployments.positionManager = proxyAddress;
  deployments.positionManagerImplementation = implementationAddress;
  deployments.feeRecipient = feeRecipient;
  saveDeployments(network, deployments);

  const storedVault = await positionManager.vault();
  logPostDeploymentCheck("PositionManager vault wiring", storedVault.toLowerCase() === vault.toLowerCase(), vault, storedVault);

  console.log("PositionManager deployment complete.");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
