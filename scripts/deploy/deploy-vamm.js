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
  if (deployments.vamm) {
    console.log(`vAMM already deployed at ${deployments.vamm}. Skipping.`);
    return;
  }

  const baseReserve = hre.ethers.parseEther(cfg.vamm.baseReserve.toString());
  const quoteReserve = hre.ethers.parseEther(cfg.vamm.quoteReserve.toString());

  const [deployer] = await hre.ethers.getSigners();
  console.log(`Deploying vAMM from ${deployer.address} to ${network}...`);

  const VAMM = await hre.ethers.getContractFactory("vAMM");
  const vamm = await hre.upgrades.deployProxy(
    VAMM,
    [baseReserve, quoteReserve],
    { kind: "uups" },
  );
  await vamm.waitForDeployment();

  const proxyAddress = await vamm.getAddress();
  console.log(`vAMM proxy deployed at ${proxyAddress}`);

  const implementationAddress = await verifyProxyImplementation(hre, proxyAddress);

  deployments.vamm = proxyAddress;
  deployments.vammImplementation = implementationAddress;
  saveDeployments(network, deployments);

  const storedPrice = await vamm.getMarkPrice();
  logPostDeploymentCheck("vAMM initial price", storedPrice > 0n, "> 0", storedPrice.toString());

  console.log("vAMM deployment complete.");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
