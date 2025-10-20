require("dotenv").config();

const REQUIRED_ENV_MESSAGE =
  "Missing required environment variable for Arbitrum Sepolia deployment. Please review scripts/deploy/config.js.";

function getEnv(name, optional = false) {
  const value = process.env[name];
  if (!value && !optional) {
    throw new Error(`${REQUIRED_ENV_MESSAGE} Variable: ${name}`);
  }
  return value;
}

const config = {
  arbitrumSepolia: {
    chainId: 421614,
    collateral: {
      token: getEnv("ARB_SEPOLIA_USDC"),
      decimals: Number(process.env.ARB_SEPOLIA_USDC_DECIMALS || 6),
    },
    vault: {
      tradingFeeRate: Number(process.env.ARB_VAULT_TRADING_FEE_BPS || 10),
      feeRecipient: process.env.ARB_VAULT_FEE_RECIPIENT,
    },
    chainlink: {
      cpiFeed: getEnv("ARB_SEPOLIA_CHAINLINK_CPI_FEED"),
      treasuryFeed: getEnv("ARB_SEPOLIA_CHAINLINK_TREASURY_FEED"),
      updateInterval: Number(process.env.ARB_ORACLE_UPDATE_INTERVAL || 3600),
      maxDeviation: Number(process.env.ARB_ORACLE_MAX_DEVIATION_BPS || 500),
    },
    vamm: {
      baseReserve: process.env.ARB_VAMM_BASE_RESERVE || "1000000", // expressed in ETH with 18 decimals
      quoteReserve: process.env.ARB_VAMM_QUOTE_RESERVE || "2000000000", // expressed with 18 decimals
      maxPriceImpactBps: Number(process.env.ARB_VAMM_MAX_PRICE_IMPACT_BPS || 1500),
    },
    funding: {
      interval: Number(process.env.ARB_FUNDING_INTERVAL || 3600),
      coefficient: process.env.ARB_FUNDING_COEFFICIENT || "1000000000000000000", // 1e18
      maxRate: process.env.ARB_FUNDING_MAX_RATE || "1000000000000000", // 0.001 * 1e18
      minRate: process.env.ARB_FUNDING_MIN_RATE || "1000000000000000",
    },
    liquidator: {
      insuranceFund: getEnv("ARB_INSURANCE_FUND_ADDRESS"),
      liquidationFeeBps: Number(process.env.ARB_LIQUIDATION_FEE_BPS || 500),
      liquidatorRewardBps: Number(process.env.ARB_LIQUIDATOR_REWARD_BPS || 500),
    },
    positionManager: {
      tradingFeeBps: Number(process.env.ARB_POSITION_TRADING_FEE_BPS || 10),
      liquidationFeeBps: Number(process.env.ARB_POSITION_LIQUIDATION_FEE_BPS || 500),
      maxLeverage: process.env.ARB_POSITION_MAX_LEVERAGE || "10000000000000000000", // 10e18 default
      maintenanceMarginBps: Number(process.env.ARB_POSITION_MAINTENANCE_MARGIN_BPS || 500),
      minCollateral: process.env.ARB_POSITION_MIN_COLLATERAL || "10000000", // 10 USDC default
    },
  },
};

module.exports = config;
