# Decentralized-Baccarat

On-chain Punto Banco (Baccarat) powered by **Chainlink VRF v2.5**. Players bet with ETH; an 8-deck shoe is shuffled once per shoe via a verifiable random seed and dealt using a lazy Fisher-Yates algorithm — no server, no trust required.

---

## Table of Contents

- [How It Works](#how-it-works)
- [Randomness](#randomness)
- [Shoe & Cut Card](#shoe--cut-card)
- [Game Flow](#game-flow)
- [Payouts](#payouts)
- [Deployment](#deployment)
  - [Local (Hardhat)](#local-hardhat)
  - [Sepolia Testnet](#sepolia-testnet)
  - [Anonymous Deployment](#anonymous-deployment)
- [Post-Deploy Steps](#post-deploy-steps)
- [Running Tests](#running-tests)

---

## How It Works

The contract is a fully on-chain Baccarat (Punto Banco) table:

- The **house** (owner) manages the shoe and opens/closes betting rounds.
- **Players** call `placeBet()` with ETH, choosing Player, Banker, or Tie.
- The owner calls `deal()` to resolve the round using standard Baccarat rules.
- Winners are paid out automatically in the same transaction.

---

## Randomness

Randomness is a **hybrid model**:

| Layer | Method | Truly random? |
|---|---|---|
| Shoe seed | **Chainlink VRF v2.5** (256-bit) | ✅ Verifiably random |
| Card draws | `keccak256(seed, position)` | Pseudo-random (deterministic given seed) |

One VRF call covers the entire 8-deck shoe (~60+ rounds), keeping LINK costs minimal. The seed is replaced on every reshuffle — each shoe is fully independent.

---

## Shoe & Cut Card

- **8 decks · 416 cards** per shoe
- **Cut card at position 384** — when `s_shoeIndex >= 384`, the shoe is flagged as spent after the current round; the owner must call `requestShoe()` (a new VRF request) before the next round
- **32 cards remain undealt** when the reshuffle is triggered (standard casino practice)

---

## Game Flow

```
requestShoe()          — owner triggers Chainlink VRF
fulfillRandomWords()   — VRF callback stores new seed, increments generation
openBetting()          — owner opens the betting window
placeBet(betType)      — players send ETH to bet (PLAYER / BANKER / TIE)
deal()                 — owner deals cards, settles bets, pays winners
                         └─ if shoeIndex ≥ 384 → marks shoe as spent
```

---

## Payouts

| Outcome | Payout |
|---|---|
| Player wins | 1 : 1 (stake × 2) |
| Banker wins | 0.95 : 1 (stake + stake × 19/20) |
| Tie wins | 8 : 1 (stake × 9) |
| Tie result + Player/Banker bet | Push (stake returned) |

---

## Deployment

### Prerequisites

```bash
npm install
cp .env.example .env   # fill in your values
npx hardhat compile
```

`.env` variables:

```
ETHEREUM_RPC_URL=https://...
Sepolia_RPC_URL=https://...
PRIVATE_KEY=0x...                   # only for standard deploy
ETHERSCAN_API_KEY=...               # optional, for verification
VRF_SUBSCRIPTION_ID=...             # from https://vrf.chain.link
```

---

### Local (Hardhat)

Deploys a `VRFCoordinatorV2_5Mock`, creates and funds a subscription automatically.

```bash
npx hardhat node
npm run deploy:local
```

---

### Sepolia Testnet

```bash
npm run deploy:sepolia
```

---

### Anonymous Deployment

Deploys the contract **without linking your real wallet address to the deployer**.

#### How it works

```
Your real wallet (OWNER_ADDRESS)
        │
        │  fund from CEX / any unlinked source
        ▼
Throwaway address  ──deploys──►  Baccarat contract
 (random key,                     (on-chain deployer = throwaway)
  in-memory only,
  never saved)
        │
        └──proposes──►  transferOwnership(OWNER_ADDRESS)
                                │
                                ▼
                   YOU call acceptOwnership()
                   (your address appears as owner, not deployer)
```

1. A fresh random private key is generated **in memory only** — never written to disk or any file.
2. The script prints the throwaway address and exact ETH needed (gas estimate + 20% buffer).
3. You fund that address from any source with no on-chain link to you.
4. The script deploys and immediately proposes ownership to your `OWNER_ADDRESS` using Chainlink's 2-step transfer.
5. The throwaway key is discarded when the script exits.
6. You call `acceptOwnership()` from your own wallet — your address only appears as **owner**, not deployer.

#### Required `.env`

```
OWNER_ADDRESS=0xYourRealAddress
DEPLOY_RPC_URL=https://...
VRF_SUBSCRIPTION_ID=12345
```

#### Run

```bash
npm run deploy:anonymous
```

#### Supported networks (auto-detected from `DEPLOY_RPC_URL`)

| Network | Chain ID |
|---|---|
| Ethereum Mainnet | 1 |
| Sepolia | 11155111 |
| Polygon | 137 |
| Optimism | 10 |

---

## Post-Deploy Steps

1. **Add the contract as a VRF consumer**
   Go to [vrf.chain.link](https://vrf.chain.link) → your subscription → Add Consumer.

2. **Fund the house bankroll**
   ```js
   await baccarat.depositHouse({ value: ethers.parseEther("1") })
   ```

3. **Request the first shuffled shoe**
   ```js
   await baccarat.requestShoe()
   // wait for VRF fulfillment (~1-3 blocks)
   await baccarat.openBetting()
   ```

---

## Running Tests

```bash
npm run test:unit
```
