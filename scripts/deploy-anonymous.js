// scripts/deploy-anonymous.js
//
// Anonymous deployment via one-time burner wallet.
//
// ══════════════════════════════════════════════════════════════════════
//  HOW IT WORKS
// ══════════════════════════════════════════════════════════════════════
//  1. A fresh random private key is generated IN MEMORY — never written
//     to disk, env, or config.
//  2. The script prints the throwaway address and the exact ETH needed.
//  3. You fund that address from any source (CEX withdrawal, friend, etc.)
//     — no link between your real wallet and the deployer address.
//  4. The script deploys Baccarat.  On-chain deployer = throwaway address.
//  5. Immediately proposes ownership to OWNER_ADDRESS (Chainlink uses
//     2-step transfer: propose → accept).
//  6. Script exits.  The throwaway private key is gone forever.
//  7. YOU call acceptOwnership() from your own wallet to claim.
//     Only at that point is your address associated with the contract —
//     as the owner, not the deployer.
//
// ══════════════════════════════════════════════════════════════════════
//  REQUIRED .env
// ══════════════════════════════════════════════════════════════════════
//  OWNER_ADDRESS     = 0xYourRealAddress   (will receive ownership)
//  DEPLOY_RPC_URL    = https://...         (Sepolia or Mainnet RPC)
//  VRF_SUBSCRIPTION_ID = <your sub id>     (from vrf.chain.link)
//
// ══════════════════════════════════════════════════════════════════════
//  USAGE
// ══════════════════════════════════════════════════════════════════════
//  npx hardhat run scripts/deploy-anonymous.js
//  or: npm run deploy:anonymous
//
// ══════════════════════════════════════════════════════════════════════

require("dotenv").config();
const { ethers } = require("ethers");
const fs = require("fs");
const path = require("path");

// ── Config ─────────────────────────────────────────────────────────────
const OWNER_ADDRESS     = process.env.OWNER_ADDRESS;
const DEPLOY_RPC_URL    = process.env.DEPLOY_RPC_URL;
const SUB_ID            = process.env.VRF_SUBSCRIPTION_ID;

// ── VRF config per chainId (mirrors helper-hardhat-config.js) ──────────
const VRF_CONFIG = {
    11155111: {   // Sepolia
        vrfCoordinator: "0x9DdfaCa8183c41ad55329BdeeD9F6A8d53168B1b",
        keyHash:        "0x787d74caea10b2b357790d5b5247c2f63d1d91572a9846f780606e4d953677ae",
    },
    1: {          // Ethereum Mainnet
        vrfCoordinator: "0xD7f86b4b8Cae7D942340FF628F82735b7a20893a",
        keyHash:        "0x8077df514608a09f83e4e8d300645594e5d7234665448ba83f51a50f842bd3d9",
    },
    137: {        // Polygon
        vrfCoordinator: "0xec0Ed46f36576541C75739E915ADbCe9a17d8Ca",
        keyHash:        "0x0d6d65be3ea7b16b0b5dd8d7ec2b858e7d4e0568c59432b6d04be6fd447dee16",
    },
    10: {         // Optimism
        vrfCoordinator: "0x02101dfB77FDE026414827Fdc604ddAF224F0921",
        keyHash:        "0x9a35d8ddb2c2de9407f90ef50b7f53f6a5ed3e1c1ceaecd52c48fbcdf73fce3e",
    },
};

// ── Helpers ────────────────────────────────────────────────────────────
function hr() { console.log("═".repeat(62)); }

async function waitForBalance(provider, address, minWei, pollMs = 8000) {
    console.log(`\n⏳  Waiting for funds at: ${address}`);
    console.log(`    Required: ${ethers.formatEther(minWei)} ETH`);
    console.log("    (polling every 8 s — Ctrl-C to abort)\n");

    for (;;) {
        const bal = await provider.getBalance(address);
        process.stdout.write(`\r    Balance: ${ethers.formatEther(bal)} ETH   `);
        if (bal >= minWei) {
            console.log("\n\n✅  Sufficient funds received.");
            return bal;
        }
        await new Promise((r) => setTimeout(r, pollMs));
    }
}

// ── Main ───────────────────────────────────────────────────────────────
async function main() {
    // ── Validate env ────────────────────────────────────────────────────
    if (!OWNER_ADDRESS || !ethers.isAddress(OWNER_ADDRESS)) {
        throw new Error("Set OWNER_ADDRESS=0xYourAddress in .env");
    }
    if (!DEPLOY_RPC_URL) {
        throw new Error("Set DEPLOY_RPC_URL=https://... in .env");
    }
    if (!SUB_ID || SUB_ID === "0") {
        throw new Error("Set VRF_SUBSCRIPTION_ID in .env (from vrf.chain.link)");
    }

    const provider = new ethers.JsonRpcProvider(DEPLOY_RPC_URL);
    const { chainId } = await provider.getNetwork();
    const chainIdNum = Number(chainId);

    const vrfCfg = VRF_CONFIG[chainIdNum];
    if (!vrfCfg) {
        throw new Error(`No VRF config found for chainId ${chainIdNum}. Add it to VRF_CONFIG.`);
    }

    hr();
    console.log(`🕵️   Anonymous deployment`);
    console.log(`    Chain ID  : ${chainIdNum}`);
    console.log(`    Owner     : ${OWNER_ADDRESS}  (will receive ownership)`);
    hr();

    // ── Generate throwaway wallet ────────────────────────────────────────
    const burner = ethers.Wallet.createRandom().connect(provider);
    console.log(`\n🔥  Throwaway deployer : ${burner.address}`);
    console.log("    (private key lives only in this process — never saved)");

    // ── Load compiled artifact ───────────────────────────────────────────
    const artifactPath = path.join(
        __dirname, "../artifacts/contracts/Baccarat.sol/Baccarat.json"
    );
    if (!fs.existsSync(artifactPath)) {
        throw new Error(`Artifact not found — run: npx hardhat compile`);
    }
    const artifact = JSON.parse(fs.readFileSync(artifactPath, "utf8"));

    // ── Estimate deployment gas ──────────────────────────────────────────
    const factory       = new ethers.ContractFactory(artifact.abi, artifact.bytecode, burner);
    const deployTx      = await factory.getDeployTransaction(
        vrfCfg.vrfCoordinator, BigInt(SUB_ID), vrfCfg.keyHash
    );
    const feeData       = await provider.getFeeData();
    const gasPrice      = feeData.maxFeePerGas ?? feeData.gasPrice;
    const estimatedGas  = await provider.estimateGas({ ...deployTx, from: burner.address })
                          .catch(() => 3_000_000n);            // fallback if estimation fails
    const transferGas   = 100_000n;                            // buffer for transferOwnership tx
    const totalGas      = estimatedGas + transferGas;
    const requiredWei   = (totalGas * gasPrice * 120n) / 100n; // +20% safety buffer

    console.log(`\n📊  Gas estimate : ${totalGas.toLocaleString()} units`);
    console.log(`    Gas price    : ${ethers.formatUnits(gasPrice, "gwei")} gwei`);
    console.log(`    ETH needed   : ${ethers.formatEther(requiredWei)} ETH  (+20% buffer)`);

    // ── Wait for funding ─────────────────────────────────────────────────
    await waitForBalance(provider, burner.address, requiredWei);

    // ── Deploy ───────────────────────────────────────────────────────────
    console.log("\n🃏  Deploying Baccarat …");
    const contract = await factory.deploy(
        vrfCfg.vrfCoordinator, BigInt(SUB_ID), vrfCfg.keyHash
    );
    console.log(`    Deploy TX : ${contract.deploymentTransaction().hash}`);
    console.log("    Waiting for confirmation …");
    await contract.waitForDeployment();
    const contractAddress = await contract.getAddress();
    console.log(`\n✅  Baccarat deployed at : ${contractAddress}`);

    // ── Propose ownership transfer ───────────────────────────────────────
    // Chainlink ConfirmedOwner uses 2-step: transferOwnership (propose) +
    // acceptOwnership (claim).  After this call, the throwaway address is
    // a lame-duck owner — it cannot accept its own pending proposal.
    console.log(`\n🔑  Proposing ownership to ${OWNER_ADDRESS} …`);
    const baccarat = new ethers.Contract(contractAddress, artifact.abi, burner);
    const txOwner  = await baccarat.transferOwnership(OWNER_ADDRESS);
    console.log(`    Transfer TX : ${txOwner.hash}`);
    await txOwner.wait();
    console.log("    Ownership transfer proposed ✓");

    // ── Done — key discarded ─────────────────────────────────────────────
    hr();
    console.log("🎉  Deployment complete!  The throwaway key is now gone.\n");
    console.log("  📋  Contract address   : " + contractAddress);
    console.log("  👤  Proposed owner     : " + OWNER_ADDRESS);
    console.log("  🔗  Deployer address   : " + burner.address + "  (throwaway, unlinked to you)");
    console.log("");
    console.log("  ─── Next steps ──────────────────────────────────────────────");
    console.log("");
    console.log("  1. Accept ownership from YOUR wallet:");
    console.log("     Call acceptOwnership() on the contract via Etherscan or:");
    console.log(`     const baccarat = await ethers.getContractAt("Baccarat", "${contractAddress}")`);
    console.log(`     await baccarat.acceptOwnership()   // from OWNER_ADDRESS wallet`);
    console.log("");
    console.log("  2. Add contract as VRF consumer:");
    console.log("     https://vrf.chain.link");
    console.log(`     Contract : ${contractAddress}`);
    console.log(`     Sub ID   : ${SUB_ID}`);
    console.log("");
    console.log("  3. Fund the house bankroll and request first shoe.");
    hr();
}

main().catch((err) => {
    console.error("\n❌  Failed:", err.message);
    process.exitCode = 1;
});
