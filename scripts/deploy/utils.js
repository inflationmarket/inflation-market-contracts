const fs = require("fs");
const path = require("path");

const deploymentsDir = path.join(__dirname, "..", "..", "deployments");

function ensureDeploymentsDir() {
  if (!fs.existsSync(deploymentsDir)) {
    fs.mkdirSync(deploymentsDir, { recursive: true });
  }
}

function getDeploymentFile(network) {
  ensureDeploymentsDir();
  return path.join(deploymentsDir, `${network}.json`);
}

function loadDeployments(network) {
  const file = getDeploymentFile(network);
  if (!fs.existsSync(file)) {
    return {};
  }
  try {
    return JSON.parse(fs.readFileSync(file, "utf-8"));
  } catch (error) {
    throw new Error(`Unable to parse deployment file for network ${network}: ${error.message}`);
  }
}

function saveDeployments(network, deployments) {
  const file = getDeploymentFile(network);
  fs.writeFileSync(file, JSON.stringify(deployments, null, 2) + "\n");
}

async function verifyContract(hre, address, constructorArguments = []) {
  const network = hre.network.name;
  if (network === "hardhat" || network === "localhost") {
    return;
  }

  try {
    await hre.run("verify:verify", {
      address,
      constructorArguments,
    });
    console.log(`✓ Verified contract at ${address}`);
  } catch (error) {
    const message = error.message || error.toString();
    if (message.includes("Already Verified")) {
      console.log(`ℹ Contract at ${address} already verified`);
    } else {
      console.warn(`⚠ Verification skipped for ${address}: ${message}`);
    }
  }
}

async function verifyProxyImplementation(hre, proxyAddress) {
  const implementation = await hre.upgrades.erc1967.getImplementationAddress(proxyAddress);
  await verifyContract(hre, implementation);
  return implementation;
}

function logPostDeploymentCheck(name, assertion, expected, actual) {
  if (!assertion) {
    console.warn(`⚠ ${name} post-deployment check failed. Expected ${expected}, got ${actual}`);
  } else {
    console.log(`✓ ${name} post-deployment check passed`);
  }
}

module.exports = {
  loadDeployments,
  saveDeployments,
  verifyContract,
  verifyProxyImplementation,
  logPostDeploymentCheck,
};
