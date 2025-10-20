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
  if (deployments.indexOracle) {
    console.log(`IndexOracle already deployed at ${deployments.indexOracle}. Skipping.`);
    return;
  }

  const { chainlink } = cfg;
  const updateInterval = chainlink.updateInterval ?? 3600;
  const maxDeviation = chainlink.maxDeviation ?? 500;

  const [deployer] = await hre.ethers.getSigners();
  console.log(`Deploying IndexOracle from ${deployer.address} to ${network}...`);

  const IndexOracle = await hre.ethers.getContractFactory("IndexOracle");
  const oracle = await hre.upgrades.deployProxy(
    IndexOracle,
    [chainlink.cpiFeed, chainlink.treasuryFeed, updateInterval, maxDeviation],
    { kind: "uups" },
  );
  await oracle.waitForDeployment();

  const proxyAddress = await oracle.getAddress();
  console.log(`IndexOracle proxy deployed at ${proxyAddress}`);

  const implementationAddress = await verifyProxyImplementation(hre, proxyAddress);

  deployments.indexOracle = proxyAddress;
  deployments.indexOracleImplementation = implementationAddress;
  deployments.indexOracleFeeds = {
    cpi: chainlink.cpiFeed,
    treasury: chainlink.treasuryFeed,
  };
  saveDeployments(network, deployments);

  const storedInterval = await oracle.updateInterval();
  logPostDeploymentCheck("Oracle update interval", storedInterval === BigInt(updateInterval), updateInterval, storedInterval.toString());

  console.log("IndexOracle deployment complete.");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
