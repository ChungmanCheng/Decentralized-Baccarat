// deploy/01-deploy-baccarat.js
// Deploys the Baccarat contract and wires it to Chainlink VRF v2.5.
//
// On development chains:
//   • Uses the locally deployed VRFCoordinatorV2_5Mock.
//   • Programmatically creates + funds a VRF subscription and registers
//     the Baccarat contract as a consumer.
//
// On live networks:
//   • Uses the coordinator address and subscription ID from helper-hardhat-config.
//   • Verifies the contract on Etherscan/Polygonscan when ETHERSCAN_API_KEY is set.
//   • You must manually add the deployed Baccarat address as a consumer in the
//     Chainlink VRF UI (https://vrf.chain.link) before calling requestShoe().

const { network, ethers } = require("hardhat");
const {
    networkConfig,
    developmentChains,
    VERIFICATION_BLOCK_CONFIRMATIONS,
} = require("../helper-hardhat-config");
const { verify } = require("../utils/verify");

// Amount of "mock LINK" to fund the test subscription with (18 decimals)
const FUND_AMOUNT = ethers.parseEther("10");

module.exports = async ({ getNamedAccounts, deployments }) => {
    const { deploy, log, get } = deployments;
    const { deployer }         = await getNamedAccounts();
    const chainId              = network.config.chainId;
    const cfg                  = networkConfig[chainId] ?? networkConfig["default"];

    log("════════════════════════════════════════════════════════════");
    log(`🃏  Deploying Baccarat on "${network.name}" (chainId ${chainId})`);

    // ── Resolve VRF coordinator + subscription ───────────────────────────
    let vrfCoordinatorAddress;
    let subscriptionId;
    let keyHash;

    if (developmentChains.includes(network.name)) {
        // ── Local mock path ──────────────────────────────────────────────
        const vrfMock      = await get("VRFCoordinatorV2_5Mock");
        vrfCoordinatorAddress = vrfMock.address;

        const vrfCoordinator  = await ethers.getContractAt(
            "VRFCoordinatorV2_5Mock",
            vrfCoordinatorAddress
        );

        // Create subscription
        const txCreate  = await vrfCoordinator.createSubscription();
        const rcCreate  = await txCreate.wait(1);
        const subCreatedEvent = rcCreate.logs.find(
            (l) => l.fragment?.name === "SubscriptionCreated"
        );
        subscriptionId = subCreatedEvent
            ? subCreatedEvent.args.subId
            : 1n;
        log(`   Subscription created  id=${subscriptionId}`);

        // Fund subscription with mock LINK
        await vrfCoordinator.fundSubscription(subscriptionId, FUND_AMOUNT);
        log(`   Subscription funded   ${ethers.formatEther(FUND_AMOUNT)} mock-LINK`);

        keyHash = cfg.keyHash ?? ethers.ZeroHash;

    } else {
        // ── Live network path ────────────────────────────────────────────
        vrfCoordinatorAddress = cfg.vrfCoordinatorV2_5;
        subscriptionId        = cfg.subscriptionId;
        keyHash               = cfg.keyHash;

        if (!vrfCoordinatorAddress || !subscriptionId || !keyHash) {
            throw new Error(
                `Missing VRF config for network "${network.name}". ` +
                "Check networkConfig in helper-hardhat-config.js."
            );
        }
        log(`   VRF coordinator: ${vrfCoordinatorAddress}`);
        log(`   Subscription ID: ${subscriptionId}`);
    }

    // ── Deploy Baccarat ──────────────────────────────────────────────────
    const waitConfirmations = developmentChains.includes(network.name)
        ? 1
        : VERIFICATION_BLOCK_CONFIRMATIONS;

    const baccarat = await deploy("Baccarat", {
        from:    deployer,
        args:    [vrfCoordinatorAddress, subscriptionId, keyHash],
        log:     true,
        waitConfirmations,
    });

    log(`✅  Baccarat deployed at ${baccarat.address}`);

    // ── Register consumer (dev only) ─────────────────────────────────────
    if (developmentChains.includes(network.name)) {
        const vrfCoordinator = await ethers.getContractAt(
            "VRFCoordinatorV2_5Mock",
            vrfCoordinatorAddress
        );
        await vrfCoordinator.addConsumer(subscriptionId, baccarat.address);
        log(`   Baccarat registered as VRF consumer ✓`);
    } else {
        log("");
        log("⚠️  ACTION REQUIRED on live network:");
        log(`   Go to https://vrf.chain.link and add`);
        log(`   ${baccarat.address}`);
        log(`   as a consumer for subscription ${subscriptionId}`);
    }

    // ── Verify on block explorer (live networks only) ────────────────────
    if (
        !developmentChains.includes(network.name) &&
        process.env.ETHERSCAN_API_KEY
    ) {
        log("   Waiting for block explorer propagation …");
        await verify(baccarat.address, [
            vrfCoordinatorAddress,
            subscriptionId,
            keyHash,
        ]);
    }

    log("════════════════════════════════════════════════════════════");
    log("Next steps:");
    log("  1. Fund the contract with ETH so the house can cover payouts:");
    log(`       await baccarat.depositHouse({ value: ethers.parseEther("1") })`);
    log("  2. Request a shuffled shoe:");
    log("       await baccarat.requestShoe()");
    log("  3. Wait for VRF fulfillment, then open betting:");
    log("       await baccarat.openBetting()");
    log("════════════════════════════════════════════════════════════");
};

module.exports.tags = ["all", "baccarat"];
