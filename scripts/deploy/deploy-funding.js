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
  if (deployments.fundingCalculator) {
    console.log(`FundingRateCalculator already deployed at ${deployments.fundingCalculator}. Skipping.`);
    return;
  }

  const vammAddress = deployments.vamm;
  const oracleAddress = deployments.indexOracle;
  if (!vammAddress || !oracleAddress) {
    throw new Error("Funding calculator deployment requires vAMM and IndexOracle addresses. Deploy them first.");
  }

  const { funding } = cfg;
  const [deployer] = await hre.ethers.getSigners();
  console.log(`Deploying FundingRateCalculator from ${deployer.address} to ${network}...`);

  const FundingRateCalculator = await hre.ethers.getContractFactory("FundingRateCalculator");
  const fundingCalculator = await hre.upgrades.deployProxy(
    FundingRateCalculator,
    [
      vammAddress,
      oracleAddress,
      hre.ethers.ZeroAddress, // PositionManager wired later
      funding.interval,
      funding.coefficient,
      funding.maxRate,
      funding.minRate,
    ],
    { kind: "uups" },
  );
  await fundingCalculator.waitForDeployment();

  const proxyAddress = await fundingCalculator.getAddress();
  console.log(`FundingRateCalculator proxy deployed at ${proxyAddress}`);

  const implementationAddress = await verifyProxyImplementation(hre, proxyAddress);

  deployments.fundingCalculator = proxyAddress;
  deployments.fundingCalculatorImplementation = implementationAddress;
  saveDeployments(network, deployments);

  const storedInterval = await fundingCalculator.fundingInterval();
  logPostDeploymentCheck("Funding interval", storedInterval === BigInt(funding.interval), funding.interval, storedInterval.toString());

  console.log("FundingRateCalculator deployment complete.");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
