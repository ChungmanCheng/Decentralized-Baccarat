
const { ethers } = require("hardhat");

// ─────────────────────────────────────────────────────────────────────────────
//  Chainlink VRF v2.5 — per-network configuration
//
//  vrfCoordinatorV2_5  Official coordinator address for the network.
//  keyHash             Gas-lane key hash.  Choose the lane whose max gas price
//                      matches your needs (lower gwei = cheaper, slower).
//  subscriptionId      Your funded subscription ID from https://vrf.chain.link
//                      Set via process.env.VRF_SUBSCRIPTION_ID or hardcode here.
//
//  Reference: https://docs.chain.link/vrf/v2-5/supported-networks
// ─────────────────────────────────────────────────────────────────────────────

const networkConfig = {

    default: {
        name: "hardhat",
        // keyHash is unused on the local mock; ZeroHash is fine
        keyHash: ethers.ZeroHash,
    },

    31337: {
        name: "localhost",
        keyHash: ethers.ZeroHash,
    },

    // ── Ethereum Sepolia (testnet) ───────────────────────────────────────
    11155111: {
        name: "Sepolia",
        vrfCoordinatorV2_5: "0x9DdfaCa8183c41ad55329BdeeD9F6A8d53168B1b",
        // 150 gwei lane
        keyHash: "0x787d74caea10b2b357790d5b5247c2f63d1d91572a9846f780606e4d953677ae",
        subscriptionId: process.env.VRF_SUBSCRIPTION_ID ?? "0",
    },

    // ── Ethereum Mainnet ─────────────────────────────────────────────────
    1: {
        name: "ethereum",
        vrfCoordinatorV2_5: "0xD7f86b4b8Cae7D942340FF628F82735b7a20893a",
        // 200 gwei lane
        keyHash: "0x8077df514608a09f83e4e8d300645594e5d7234665448ba83f51a50f842bd3d9",
        subscriptionId: process.env.VRF_SUBSCRIPTION_ID ?? "0",
    },

    // ── Polygon Mainnet ──────────────────────────────────────────────────
    137: {
        name: "polygon",
        vrfCoordinatorV2_5: "0xec0Ed46f36576541C75739E915ADbCe9a17d8Ca",
        // 500 gwei lane
        keyHash: "0x0d6d65be3ea7b16b0b5dd8d7ec2b858e7d4e0568c59432b6d04be6fd447dee16",
        subscriptionId: process.env.VRF_SUBSCRIPTION_ID ?? "0",
    },

    // ── OP Mainnet ───────────────────────────────────────────────────────
    10: {
        name: "optimism",
        vrfCoordinatorV2_5: "0x02101dfB77FDE026414827Fdc604ddAF224F0921",
        // 200 gwei lane
        keyHash: "0x9a35d8ddb2c2de9407f90ef50b7f53f6a5ed3e1c1ceaecd52c48fbcdf73fce3e",
        subscriptionId: process.env.VRF_SUBSCRIPTION_ID ?? "0",
    },
}

const developmentChains = ["hardhat", "localhost"];
const VERIFICATION_BLOCK_CONFIRMATIONS = 6;

module.exports = {
    networkConfig,
    developmentChains,
    VERIFICATION_BLOCK_CONFIRMATIONS,
};