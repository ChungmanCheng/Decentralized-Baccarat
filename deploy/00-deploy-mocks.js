// deploy/00-deploy-mocks.js
// Deploys VRFCoordinatorV2_5Mock on local development chains only.

const { network } = require("hardhat");
const { developmentChains } = require("../helper-hardhat-config");

// Mock VRF fee parameters.
// Set to 0 so _chargePayment never drains the test subscription balance.
const BASE_FEE          = "0";                // no flat LINK fee in tests
const GAS_PRICE_LINK    = "0";                // no per-gas LINK fee in tests
const WEI_PER_UNIT_LINK = "4523213842788";    // ~ LINK/ETH price (informational)

module.exports = async ({ getNamedAccounts, deployments }) => {
    const { deploy, log } = deployments;
    const { deployer }    = await getNamedAccounts();

    if (!developmentChains.includes(network.name)) {
        log("⏭  Not a development chain – skipping mock deployment.");
        return;
    }

    log("────────────────────────────────────────────────────────────");
    log("🔧  Development chain detected – deploying VRF mock …");

    const vrfMock = await deploy("VRFCoordinatorV2_5Mock", {
        from:    deployer,
        args:    [BASE_FEE, GAS_PRICE_LINK, WEI_PER_UNIT_LINK],
        log:     true,
        waitConfirmations: 1,
    });

    log(`✅  VRFCoordinatorV2_5Mock deployed at ${vrfMock.address}`);
    log("────────────────────────────────────────────────────────────");
};

module.exports.tags = ["all", "mocks"];
