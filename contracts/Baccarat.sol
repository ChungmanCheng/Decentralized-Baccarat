// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

/**
 * @title  Baccarat
 * @author Decentralized-Baccarat
 * @notice On-chain Punto Banco (Baccarat) powered by Chainlink VRF v2.5.
 *
 * ══════════════════════════════════════════════════════════════════════════
 *  SHOE  (8 decks · 416 cards)
 * ══════════════════════════════════════════════════════════════════════════
 *  Cards are represented as uint8 values 0-51 (position within one deck):
 *    suit  = card / 13    (0=♠  1=♥  2=♦  3=♣)
 *    rank  = card % 13    (0=A  1=2  …  8=9  9=T  10=J  11=Q  12=K)
 *
 *  Baccarat point value:
 *    Ace → 1,  2-9 → face value,  10/J/Q/K → 0
 *
 *  The shoe is shuffled via a LAZY Fisher-Yates algorithm:
 *    • Chainlink VRF supplies one 256-bit seed  (cheap callback, low gas).
 *    • When a card at position i is needed, a pseudo-random index j ∈ [i, 415]
 *      is derived from keccak256(seed, i).  The cards at i and j are swapped
 *      in-place using a sparse mapping, and shoe[j] is returned.
 *    • A per-shoe generation counter isolates each shoe without clearing storage.
 *
 * ══════════════════════════════════════════════════════════════════════════
 *  GAME FLOW
 * ══════════════════════════════════════════════════════════════════════════
 *   IDLE ──requestShoe()──► (VRF pending)
 *        ──fulfillRandomWords()──► IDLE (shoe ready)
 *        ──openBetting()──► BETTING
 *        ──placeBet() × N──► BETTING
 *        ──deal()──► IDLE  (→ reshuffles if cut card reached)
 *
 * ══════════════════════════════════════════════════════════════════════════
 *  PAYOUTS
 * ══════════════════════════════════════════════════════════════════════════
 *   Player wins → 1 : 1    (return = stake × 2)
 *   Banker wins → 0.95 : 1 (return = stake + stake × 19/20)
 *   Tie    wins → 8 : 1    (return = stake × 9)
 *   Tie result  + Player/Banker bet → push (stake returned)
 */
contract Baccarat is VRFConsumerBaseV2Plus {
    /* ══════════════════════════════════════════════════════════════════════
       VRF CONFIGURATION
    ══════════════════════════════════════════════════════════════════════ */

    uint256 public s_subscriptionId;
    bytes32 public s_keyHash;

    /// @dev Lazy shuffle only stores a seed → callback needs minimal gas.
    uint32  public constant CALLBACK_GAS_LIMIT   = 100_000;
    uint16  public constant REQUEST_CONFIRMATIONS = 3;
    uint32  public constant NUM_WORDS             = 1;

    /* ══════════════════════════════════════════════════════════════════════
       SHOE CONSTANTS
    ══════════════════════════════════════════════════════════════════════ */

    uint8   public constant NUM_DECKS      = 8;
    uint8   public constant CARDS_PER_DECK = 52;
    uint16  public constant TOTAL_CARDS    = 416;  // 8 × 52
    /// @dev  When shoeIndex reaches CUT_CARD_POS the owner must request
    ///       a new shoe before the next round (≈ last 32 cards undealt).
    uint16  public constant CUT_CARD_POS   = 384;

    /* ══════════════════════════════════════════════════════════════════════
       SHOE STORAGE  – lazy Fisher-Yates
    ══════════════════════════════════════════════════════════════════════ */

    /**
     * @dev  Sparse swap-map for the lazy Fisher-Yates shuffle.
     *       Key   = (generation << 16) | position
     *       Value = stored card + 1   (0 means "not yet swapped" → use pos % 52)
     *
     *       Using a generation prefix means we NEVER need to clear old entries:
     *       a new shoe simply increments `s_generation` and old keys become
     *       permanently unreachable.
     */
    mapping(uint256 => uint8) private s_shoeMap;

    uint256 public s_shoeSeed;      // VRF random seed for the current shoe
    uint16  public s_shoeIndex;     // index of the next card to deal  (0-415)
    uint128 public s_generation;    // incremented on every reshuffle
    bool    public s_shoeReady;     // true after VRF fulfillment

    /* ══════════════════════════════════════════════════════════════════════
       GAME STATE
    ══════════════════════════════════════════════════════════════════════ */

    enum RoundState { IDLE, BETTING, DEALING }
    enum BetType    { PLAYER, BANKER, TIE }
    enum Outcome    { PLAYER_WIN, BANKER_WIN, TIE }

    struct Bet {
        address bettor;
        uint256 amount;
        BetType betType;
    }

    struct RoundInfo {
        uint8[3] playerCards;   // up to 3 cards (index 2 unused when count < 3)
        uint8[3] bankerCards;
        uint8    playerCount;   // 2 or 3
        uint8    bankerCount;   // 2 or 3
        uint8    playerTotal;   // 0-9
        uint8    bankerTotal;   // 0-9
        Outcome  outcome;
        bool     settled;
    }

    RoundState public s_roundState;
    RoundInfo  public s_lastRound;
    Bet[]      public s_bets;

    uint256    public s_pendingVrfRequestId;   // non-zero while VRF is in flight

    /* ══════════════════════════════════════════════════════════════════════
       BET LIMITS
    ══════════════════════════════════════════════════════════════════════ */

    uint256 public constant MIN_BET = 0.001 ether;
    uint256 public constant MAX_BET = 10 ether;

    /* ══════════════════════════════════════════════════════════════════════
       EVENTS
    ══════════════════════════════════════════════════════════════════════ */

    event ShoeRequested(uint256 indexed requestId);
    event ShoeShuffled(uint256 indexed requestId, uint128 generation, uint256 seed);
    event BettingOpened(uint128 generation, uint16 shoeIndex);
    event BetPlaced(address indexed bettor, uint256 amount, BetType betType);
    event RoundSettled(
        uint8   p0, uint8 p1, uint8 p2,
        uint8   b0, uint8 b1, uint8 b2,
        uint8   playerTotal,
        uint8   bankerTotal,
        Outcome outcome
    );
    event Payout(address indexed bettor, uint256 amount);
    event Deposit(address indexed depositor, uint256 amount);
    event Withdrawal(address indexed to, uint256 amount);

    /* ══════════════════════════════════════════════════════════════════════
       ERRORS
    ══════════════════════════════════════════════════════════════════════ */

    error NotIdle();
    error NotBetting();
    error ShoeNotReady();
    error VrfRequestPending();
    error BetTooSmall(uint256 sent, uint256 minimum);
    error BetTooLarge(uint256 sent, uint256 maximum);
    error InsufficientBalance(uint256 available, uint256 required);
    error TransferFailed();

    /* ══════════════════════════════════════════════════════════════════════
       CONSTRUCTOR
    ══════════════════════════════════════════════════════════════════════ */

    /**
     * @param vrfCoordinator  Chainlink VRF Coordinator address.
     * @param subscriptionId  Funded VRF v2.5 subscription ID.
     * @param keyHash         Gas-lane key hash (controls max gas price per VRF request).
     */
    constructor(
        address vrfCoordinator,
        uint256 subscriptionId,
        bytes32 keyHash
    ) VRFConsumerBaseV2Plus(vrfCoordinator) {
        s_subscriptionId = subscriptionId;
        s_keyHash        = keyHash;
    }

    /* ══════════════════════════════════════════════════════════════════════
       HOUSE MANAGEMENT
    ══════════════════════════════════════════════════════════════════════ */

    /// @notice Deposit ETH so the house can cover winner payouts.
    function depositHouse() external payable onlyOwner {
        emit Deposit(msg.sender, msg.value);
    }

    /**
     * @notice Withdraw ETH from the contract.
     * @dev    Only callable when IDLE (no active round) to protect player funds.
     */
    function withdrawHouse(uint256 amount) external onlyOwner {
        if (s_roundState != RoundState.IDLE) revert NotIdle();
        if (amount > address(this).balance)
            revert InsufficientBalance(address(this).balance, amount);
        _safeTransfer(payable(owner()), amount);
        emit Withdrawal(owner(), amount);
    }

    /* ══════════════════════════════════════════════════════════════════════
       VRF – REQUEST & FULFILL
    ══════════════════════════════════════════════════════════════════════ */

    /**
     * @notice  Ask Chainlink VRF for a new random seed to shuffle the shoe.
     * @dev     Requires IDLE state and no pending VRF request.
     *          Subscribe + fund at https://vrf.chain.link and add this
     *          contract as a consumer before calling.
     */
    function requestShoe() external onlyOwner {
        if (s_roundState != RoundState.IDLE) revert NotIdle();
        if (s_pendingVrfRequestId != 0)      revert VrfRequestPending();

        uint256 requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash:              s_keyHash,
                subId:                s_subscriptionId,
                requestConfirmations: REQUEST_CONFIRMATIONS,
                callbackGasLimit:     CALLBACK_GAS_LIMIT,
                numWords:             NUM_WORDS,
                extraArgs:            VRFV2PlusClient._argsToBytes(
                                          VRFV2PlusClient.ExtraArgsV1({nativePayment: false})
                                      )
            })
        );

        s_pendingVrfRequestId = requestId;
        s_shoeReady           = false;
        emit ShoeRequested(requestId);
    }

    /**
     * @notice  Chainlink VRF callback – stores the random seed and arms the shoe.
     * @dev     The actual Fisher-Yates permutation is LAZY: no upfront storage
     *          writes beyond this seed.  Gas cost: ~50 k  (3 SSTOREs + events).
     *
     *          Shuffle correctness:
     *          At draw step i, we pick j = i + keccak256(seed, i) % (416 - i).
     *          This is the Knuth online variant of Fisher-Yates, producing a
     *          uniformly random permutation of all 416 cards.
     */
    function fulfillRandomWords(
        uint256 requestId,
        uint256[] calldata randomWords
    ) internal override {
        s_pendingVrfRequestId = 0;
        s_shoeSeed            = randomWords[0];
        s_shoeIndex           = 0;
        s_generation++;           // invalidates all previous shoe-map entries
        s_shoeReady           = true;
        emit ShoeShuffled(requestId, s_generation, randomWords[0]);
    }

    /**
     * @notice  Emergency escape: clear a stuck pending VRF request ID.
     * @dev     Use only if the VRF callback permanently failed (e.g., ran out
     *          of subscription LINK).  A new requestShoe() will be needed.
     */
    function clearPendingRequest() external onlyOwner {
        s_pendingVrfRequestId = 0;
    }

    /* ══════════════════════════════════════════════════════════════════════
       ROUND LIFECYCLE
    ══════════════════════════════════════════════════════════════════════ */

    /**
     * @notice  Open the betting window for a new round.
     * @dev     Clears previous bets and round result; requires IDLE + shoe ready.
     */
    function openBetting() external onlyOwner {
        if (s_roundState != RoundState.IDLE) revert NotIdle();
        if (!s_shoeReady)                     revert ShoeNotReady();

        delete s_bets;
        delete s_lastRound;
        s_roundState = RoundState.BETTING;
        emit BettingOpened(s_generation, s_shoeIndex);
    }

    /**
     * @notice  Place a bet on the current round outcome.
     * @param   betType  0 = PLAYER  1 = BANKER  2 = TIE
     */
    function placeBet(BetType betType) external payable {
        if (s_roundState != RoundState.BETTING) revert NotBetting();
        if (msg.value < MIN_BET)                revert BetTooSmall(msg.value, MIN_BET);
        if (msg.value > MAX_BET)                revert BetTooLarge(msg.value, MAX_BET);

        s_bets.push(Bet({bettor: msg.sender, amount: msg.value, betType: betType}));
        emit BetPlaced(msg.sender, msg.value, betType);
    }

    /**
     * @notice  Close betting, deal cards according to standard Baccarat rules,
     *          settle all bets, and pay winners.
     *
     * Dealing order:  Player₁ → Banker₁ → Player₂ → Banker₂
     *                 [Player₃ if needed]  [Banker₃ if needed]
     *
     * Natural rule:   If either side totals 8 or 9 after two cards → stand.
     * Player rule:    Draw if two-card total ≤ 5; stand on 6-7.
     * Banker rule:    See _bankerDraws() for full rule table.
     */
    function deal() external onlyOwner {
        if (s_roundState != RoundState.BETTING) revert NotBetting();
        s_roundState = RoundState.DEALING;

        // ── Initial four cards  P B P B ──────────────────────────────────
        uint8 p0 = _drawCard();
        uint8 b0 = _drawCard();
        uint8 p1 = _drawCard();
        uint8 b1 = _drawCard();

        uint8 pTotal = (_cardValue(p0) + _cardValue(p1)) % 10;
        uint8 bTotal = (_cardValue(b0) + _cardValue(b1)) % 10;

        uint8 p2;
        uint8 b2;
        uint8 playerCount = 2;
        uint8 bankerCount = 2;

        // ── Third card rules (skipped on a Natural) ───────────────────────
        if (pTotal < 8 && bTotal < 8) {
            bool playerDrew = false;

            if (pTotal <= 5) {
                p2          = _drawCard();
                pTotal      = (pTotal + _cardValue(p2)) % 10;
                playerCount = 3;
                playerDrew  = true;
            }

            if (_bankerDraws(bTotal, playerDrew, p2)) {
                b2          = _drawCard();
                bTotal      = (bTotal + _cardValue(b2)) % 10;
                bankerCount = 3;
            }
        }

        // ── Store result ──────────────────────────────────────────────────
        s_lastRound.playerCards[0] = p0;
        s_lastRound.playerCards[1] = p1;
        s_lastRound.playerCards[2] = p2;
        s_lastRound.bankerCards[0] = b0;
        s_lastRound.bankerCards[1] = b1;
        s_lastRound.bankerCards[2] = b2;
        s_lastRound.playerCount    = playerCount;
        s_lastRound.bankerCount    = bankerCount;
        s_lastRound.playerTotal    = pTotal;
        s_lastRound.bankerTotal    = bTotal;

        Outcome outcome;
        if      (pTotal > bTotal) outcome = Outcome.PLAYER_WIN;
        else if (bTotal > pTotal) outcome = Outcome.BANKER_WIN;
        else                       outcome = Outcome.TIE;

        s_lastRound.outcome = outcome;
        s_lastRound.settled = true;

        emit RoundSettled(p0, p1, p2, b0, b1, b2, pTotal, bTotal, outcome);

        // ── Pay winners ───────────────────────────────────────────────────
        _settleBets(outcome);

        // ── Cut card check ────────────────────────────────────────────────
        if (s_shoeIndex >= CUT_CARD_POS) {
            s_shoeReady = false;   // owner must call requestShoe() before next round
        }

        s_roundState = RoundState.IDLE;
    }

    /* ══════════════════════════════════════════════════════════════════════
       INTERNAL – LAZY FISHER-YATES CARD DRAWING
    ══════════════════════════════════════════════════════════════════════ */

    /**
     * @dev  Online (lazy) Fisher-Yates step for position i:
     *         1. Derive j = i + keccak256(seed ‖ i) % (TOTAL_CARDS − i)
     *         2. Swap shoe[i] ↔ shoe[j]  using sparse storage map
     *         3. Return shoe[j]   (the card now placed at position i)
     *
     *       Default card at any unvisited position p  =  p % CARDS_PER_DECK.
     *       The generation prefix in the map key makes clearing unnecessary.
     */
    function _drawCard() private returns (uint8 card) {
        uint16 i         = s_shoeIndex;
        uint16 remaining = TOTAL_CARDS - i;

        uint256 rand = uint256(keccak256(abi.encodePacked(s_shoeSeed, i)));
        uint16  j    = i + uint16(rand % remaining);

        card          = _shoeGet(j);
        uint8 cardAtI = _shoeGet(i);

        // Write cardAtI into slot j (position i is now permanently consumed)
        if (i != j) _shoeSet(j, cardAtI);

        s_shoeIndex = i + 1;
    }

    function _shoeGet(uint16 pos) private view returns (uint8) {
        uint8 v = s_shoeMap[_shoeKey(pos)];
        // 0 → position never swapped → default card value
        return v == 0 ? uint8(pos % CARDS_PER_DECK) : v - 1;
    }

    function _shoeSet(uint16 pos, uint8 card) private {
        // Store card+1 so that 0 remains the "unset" sentinel
        s_shoeMap[_shoeKey(pos)] = card + 1;
    }

    /// @dev  Pack generation and position into a single mapping key.
    function _shoeKey(uint16 pos) private view returns (uint256) {
        return (uint256(s_generation) << 16) | pos;
    }

    /* ══════════════════════════════════════════════════════════════════════
       INTERNAL – BACCARAT RULES
    ══════════════════════════════════════════════════════════════════════ */

    /**
     * @notice  Baccarat point value of a card (0–51).
     *          rank = card % 13:
     *            0 (Ace)  → 1
     *            1..8     → 2..9
     *            9..12    → 0  (Ten, Jack, Queen, King)
     */
    function _cardValue(uint8 card) internal pure returns (uint8) {
        uint8 rank = card % 13;
        if (rank == 0)  return 1;          // Ace
        if (rank <= 8)  return rank + 1;   // 2–9
        return 0;                          // 10, J, Q, K
    }

    /**
     * @notice  Standard Punto Banco banker third-card rule.
     *
     *  ┌──────────────┬─────────────────────────────────────────────────────┐
     *  │ Banker total │ Draws when …                                        │
     *  ├──────────────┼─────────────────────────────────────────────────────┤
     *  │  0 – 2       │ Always                                              │
     *  │  3           │ Player 3rd card ≠ 8  (or player didn't draw)        │
     *  │  4           │ Player 3rd card ∈ {2,3,4,5,6,7}                    │
     *  │  5           │ Player 3rd card ∈ {4,5,6,7}                        │
     *  │  6           │ Player 3rd card ∈ {6,7}  (only if player drew)     │
     *  │  7           │ Never                                               │
     *  └──────────────┴─────────────────────────────────────────────────────┘
     *  If player did NOT draw, banker draws on 0–5 (standard mini-baccarat rule).
     *
     * @param bTotal       Banker two-card total (0-9).
     * @param playerDrew   Whether the player took a third card.
     * @param playerThird  Player's third card (used only when playerDrew = true).
     */
    function _bankerDraws(
        uint8 bTotal,
        bool  playerDrew,
        uint8 playerThird
    ) internal pure returns (bool) {
        if (bTotal >= 7) return false;
        if (bTotal <= 2) return true;

        if (!playerDrew) {
            // Player stood (total 6-7) → banker draws on 3-5, stands on 6
            return bTotal <= 5;
        }

        uint8 p3 = _cardValue(playerThird);   // Baccarat point of player's 3rd card

        if (bTotal == 3) return p3 != 8;
        if (bTotal == 4) return p3 >= 2 && p3 <= 7;
        if (bTotal == 5) return p3 >= 4 && p3 <= 7;
        /* bTotal == 6 */ return p3 == 6 || p3 == 7;
    }

    /* ══════════════════════════════════════════════════════════════════════
       INTERNAL – BET SETTLEMENT
    ══════════════════════════════════════════════════════════════════════ */

    function _settleBets(Outcome outcome) private {
        uint256 len = s_bets.length;

        // ── Solvency check ────────────────────────────────────────────────
        uint256 totalPayout;
        for (uint256 i = 0; i < len; i++) {
            totalPayout += _calcPayout(s_bets[i], outcome);
        }
        if (address(this).balance < totalPayout)
            revert InsufficientBalance(address(this).balance, totalPayout);

        // ── Transfer winnings ─────────────────────────────────────────────
        for (uint256 i = 0; i < len; i++) {
            uint256 payout = _calcPayout(s_bets[i], outcome);
            if (payout > 0) {
                _safeTransfer(payable(s_bets[i].bettor), payout);
                emit Payout(s_bets[i].bettor, payout);
            }
            // Losing bets stay in the contract and become house profit.
        }
    }

    /**
     * @dev  Compute payout for a single bet.
     *
     *       Player bet wins  → stake × 2         (1:1)
     *       Banker bet wins  → stake + stake×19/20 (0.95:1, 5% commission)
     *       Tie    bet wins  → stake × 9          (8:1)
     *       Player/Banker on Tie → push (stake returned)
     *       Losing bet       → 0
     */
    function _calcPayout(Bet memory b, Outcome outcome) private pure returns (uint256) {
        if (outcome == Outcome.TIE) {
            if (b.betType == BetType.TIE) return b.amount * 9;   // 8:1 + stake back
            return b.amount;                                       // push on P/B bets
        }
        if (outcome == Outcome.PLAYER_WIN && b.betType == BetType.PLAYER) {
            return b.amount * 2;                                   // 1:1 + stake back
        }
        if (outcome == Outcome.BANKER_WIN && b.betType == BetType.BANKER) {
            return b.amount + (b.amount * 19) / 20;               // 0.95:1 + stake back
        }
        return 0; // losing bet
    }

    function _safeTransfer(address payable to, uint256 amount) private {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    /* ══════════════════════════════════════════════════════════════════════
       VIEW / PURE HELPERS
    ══════════════════════════════════════════════════════════════════════ */

    /// @notice Number of bets in the current round.
    function getBetCount() external view returns (uint256) {
        return s_bets.length;
    }

    /// @notice Retrieve a bet by index (bettor, amount, betType).
    function getBet(uint256 index) external view returns (address, uint256, BetType) {
        Bet memory b = s_bets[index];
        return (b.bettor, b.amount, b.betType);
    }

    /// @notice Player and banker cards from the last settled round.
    function getLastRound()
        external
        view
        returns (
            uint8[3] memory playerCards,
            uint8[3] memory bankerCards,
            uint8 playerCount,
            uint8 bankerCount,
            uint8 playerTotal,
            uint8 bankerTotal,
            Outcome outcome,
            bool settled
        )
    {
        RoundInfo memory r = s_lastRound;
        return (
            r.playerCards,
            r.bankerCards,
            r.playerCount,
            r.bankerCount,
            r.playerTotal,
            r.bankerTotal,
            r.outcome,
            r.settled
        );
    }

    /// @notice Cards remaining in the current shoe before cut-card.
    function remainingCards() external view returns (uint16) {
        return TOTAL_CARDS - s_shoeIndex;
    }

    /// @notice Contract's total ETH balance (house funds + pending player bets).
    function contractBalance() external view returns (uint256) {
        return address(this).balance;
    }

    /**
     * @notice  Human-readable description of a card (0-51).
     * @return  suit      0=♠  1=♥  2=♦  3=♣
     * @return  rank      0=Ace  1-8=2-9  9=10  10=J  11=Q  12=K
     * @return  rankStr   "A", "2"…"10", "J", "Q", "K"
     * @return  suitStr   "Spades", "Hearts", "Diamonds", "Clubs"
     * @return  points    Baccarat point value (0-9)
     */
    function cardInfo(uint8 card)
        external
        pure
        returns (
            uint8  suit,
            uint8  rank,
            string memory rankStr,
            string memory suitStr,
            uint8  points
        )
    {
        suit   = card / 13;
        rank   = card % 13;
        points = _cardValue(card);

        string[13] memory rankNames =
            ["A","2","3","4","5","6","7","8","9","10","J","Q","K"];
        string[4]  memory suitNames =
            ["Spades","Hearts","Diamonds","Clubs"];

        rankStr = rankNames[rank];
        suitStr = suitNames[suit];
    }

    /* ══════════════════════════════════════════════════════════════════════
       RECEIVE
    ══════════════════════════════════════════════════════════════════════ */

    /// @notice Accepts direct ETH transfers as house deposits.
    receive() external payable {
        emit Deposit(msg.sender, msg.value);
    }
}
