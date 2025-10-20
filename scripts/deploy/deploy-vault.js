const hre = require("hardhat");
const config = require("./config");
const { loadDeployments, saveDeployments, verifyProxyImplementation, logPostDeploymentCheck } = require("./utils");

async function main() {
  const network = hre.network.name;
  const networkConfig = config[network];
  if (!networkConfig) {
    throw new Error(`No configuration found for network ${network}.`);
  }

  const deployments = loadDeployments(network);
  if (deployments.vault) {
    console.log(`Vault already deployed at ${deployments.vault}. Skipping.`);
    return;
  }

  const [deployer] = await hre.ethers.getSigners();
  console.log(`Deploying Vault with deployer ${deployer.address} to ${network}...`);

  const feeRecipient = networkConfig.vault.feeRecipient || deployer.address;
  const tradingFeeRate = networkConfig.vault.tradingFeeRate ?? 10;

  const Vault = await hre.ethers.getContractFactory("Vault");
  const vault = await hre.upgrades.deployProxy(
    Vault,
    [deployer.address, feeRecipient, tradingFeeRate],
    { kind: "uups" },
  );
  await vault.waitForDeployment();

  const proxyAddress = await vault.getAddress();
  console.log(`Vault proxy deployed at ${proxyAddress}`);

  const implementationAddress = await verifyProxyImplementation(hre, proxyAddress);

  deployments.vault = proxyAddress;
  deployments.vaultImplementation = implementationAddress;
  deployments.vaultFeeRecipient = feeRecipient;
  deployments.vaultTradingFeeRate = tradingFeeRate;
  saveDeployments(network, deployments);

  const storedFee = await vault.tradingFeeRate();
  logPostDeploymentCheck("Vault trading fee", storedFee === BigInt(tradingFeeRate), tradingFeeRate, storedFee.toString());

  const adminRole = await vault.DEFAULT_ADMIN_ROLE();
  const hasAdminRole = await vault.hasRole(adminRole, deployer.address);
  logPostDeploymentCheck("Vault admin role", hasAdminRole, true, hasAdminRole);

  console.log("Vault deployment complete.");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
