# Atlas as the Options Settlement Layer
## How Condition Tree Envelopes Redefine What Options Are in Web3
**Internal explainer — February 2026**

---

## Two Distinct Capabilities — Both Valuable

Atlas addresses the options space in two ways that must be kept precise:

**Type 1: Automated conditional execution (no counterparty, no price guarantee)**
You pre-commit to execute a market swap when a condition fires. You sell at whatever spot liquidity offers at that moment, subject to your `minReturn` slippage floor. No counterparty. No premium. No guaranteed floor. For stop-losses, take-profits, and automated portfolio management — where execution certainty matters more than exact price certainty — this is sufficient and dramatically better than anything available today.

**Type 2: Real options with hard price guarantees (counterparty required, but made trustless)**
Two parties commit collateral to the vault before the option is created. The writer's committed collateral is the guarantee — if the option exercises, the buyer receives exactly the strike amount because it is already in the vault. The counterparty cannot default because they have already posted. This is a genuine option with a hard floor, enforced automatically, with no exchange or clearing house.

Atlas does not eliminate the counterparty for Type 2. It makes the counterparty relationship **trustless, automatically enforced, and clearing-house-free.** That is a different and equally important claim.

---

## What an Option Actually Is

Strip away the TradFi machinery and an options contract is:

> The right to buy or sell an asset, at a specific price, under specific conditions, that settles automatically and unconditionally when the condition is met.

That maps onto Atlas primitives precisely:

| Options concept | Atlas primitive | Type |
|---|---|---|
| Strike price | `PriceLeaf` threshold | Both |
| Expiry | `envelope.expiry` | Both |
| Exercise (automatic) | Keeper triggers when condition met | Both |
| Settlement assurance | `minReturn` floor + vault commitment | Type 1 (soft) |
| Hard floor guarantee | Writer's pre-committed collateral in vault | Type 2 (hard) |
| Put (right to sell) | `price < strike → sell` | Both |
| Call (right to buy) | `price > strike → buy` | Both |
| Collar | Two envelopes on split positions | Both |
| Straddle | `OR(price < low, price > high)` condition tree | Both |
| Asian option (averaged) | TWAP leaf condition | Both |
| Barrier option | Conditional capability + envelope | Both |
| Binary / digital | Any condition tree + fixed-output intent | Both |
| Compound option | Chained envelope (child registered on parent trigger) | Both |
| Lookback option | `OnChainStateLeaf` reading an on-chain price tracker | Both |
| Chooser option | `OR` tree with two different `nextEnvelope` paths | Both |
| Quanto option | Cross-asset ratio leaf condition | Both |
| Forward contract | Two-party vault commitment + time leaf | Type 2 |

The vault is the settlement layer. The keeper network is the exercise mechanism. The condition tree is the strike structure. The commitment model makes the strategy private until exercise.

Atlas built general-purpose conditional execution infrastructure and discovered it maps precisely onto the complete options payoff function space — in two complementary modes depending on whether a price guarantee is required.

---

## Type 2: Real Options via Two-Party Vault Commitment

This is Atlas's most important contribution to the options space. Here is the exact mechanism for a hard-guaranteed put option:

**The writer** (yield-seeking, willing to buy ETH at $1,800):
- Deposits 1,800 USDC into the vault. Locked. Irrevocable until expiry.

**The buyer** (wants hard downside protection):
- Deposits 1 ETH into the vault.
- Pays a premium (e.g., 50 USDC) to the writer at commitment time.

**The envelope:**
```
condition (fires):   ETH price < $1,800 at expiry date
  → deliver 1,800 USDC to buyer
  → deliver 1 ETH to writer
  → writer keeps premium

condition (expires): timestamp > expiry AND ETH price ≥ $1,800
  → return 1 ETH to buyer
  → return 1,800 USDC to writer
  → writer keeps premium
```

If ETH drops to $800, the buyer receives exactly $1,800. Not approximately. Not subject to slippage. Exactly $1,800 — because that USDC was committed before the option existed. Gap risk is zero because the collateral was posted at creation. The writer cannot default. There is no clearing house. The vault IS the clearing house.

This produces a genuinely different result from every existing on-chain options protocol:

| | Lyra / Opyn / Hegic (pool-based) | Atlas (two-party vault) |
|---|---|---|
| Writer collateral | Pooled — can become undercollateralized | Per-option — always fully collateralized |
| Default risk | Pool insolvency possible under stress | Zero — collateral pre-committed |
| Settlement oracle | Single block read — manipulable | TWAP leaf — manipulation-resistant |
| Supported assets | ETH, BTC only | Any asset with oracle feed |
| Settlement privacy | Fully public at creation | Private until exercise |
| MEV at exercise | Front-runnable | Flashbots Protect + `minReturn` floor |
| Clearing infrastructure | Protocol-managed, trusted | Vault commitment — trustless |

---

## What Atlas Breaks About the Existing Model

### Counterparty default risk — eliminated
In any pool-based options protocol, the LP pool is the counterparty. Under stress — a black swan, a liquidity crisis, a correlated market move — the pool can become undercollateralized. LPs can withdraw. The guarantee degrades to a probabilistic claim on pool solvency.

In Atlas's two-party model, the writer posts the full strike amount before the option is created. That USDC is in the vault. The writer cannot withdraw it. The guarantee is absolute. The question "can the writer pay?" has a trivial answer: yes, because the payment is already there.

### Liquidity-free options on any asset
Every existing options protocol concentrates on ETH and BTC because those are the only assets with enough two-sided LP capital to run a pool. Two parties who agree on a price can create an Atlas option for any asset with an oracle feed — no pool, no liquidity mining, no bootstrapping. The long tail of thousands of tokens becomes addressable immediately.

### No premium pricing infrastructure needed
Black-Scholes and its DeFi variants exist to price the counterparty's risk. In Atlas, the premium is negotiated between the two parties and committed to the vault. There is no protocol that sets the price. The market sets the price between the two parties — bilaterally, off-chain — and the vault enforces the commitment. Atlas does not need a pricing oracle because Atlas is not the counterparty.

### Expiry is optional for Type 1
For automated conditional execution (Type 1), envelopes can have no expiry. A standing stop-loss waits indefinitely. Type 2 options have a defined expiry because both parties need to know when their collateral is released if the option does not exercise.

### Privacy until settlement
The condition tree is committed as a hash. A large institutional protective put does not signal to the market where the protection is struck. Traditional on-chain options reveal every parameter — strike, size, expiry — at creation. Atlas positions are invisible until they fire.

### Liquidity-free options on any asset
Every existing options protocol concentrates on ETH and BTC because those are the only assets with enough two-sided order flow to run a market. Atlas can create synthetic options on any asset with a reliable oracle feed — thousands of tokens. The entire long tail of the market is inaccessible to every current options protocol. It is Atlas's entire addressable market.

### No premium pricing problem
Options pricing (Black-Scholes and variants) exists because the counterparty needs to know what to charge for bearing risk. If there is no counterparty, there is no premium. The user's cost is: the keeper reward (small, fixed, ~$0.50–$2 on Base) plus the opportunity cost of encumbering capital for the option's life. This is dramatically cheaper than any market-quoted premium, especially for out-of-the-money protection.

### Expiry is optional
Traditional options have fixed expiry because the counterparty cannot hold risk forever. Atlas envelopes can have no expiry — a standing `ETH < $1,200 → sell` envelope can wait a year. Or they can have a specific expiry. The user decides. The market does not impose a term structure.

### Privacy until settlement
The condition tree is committed as a hash. No one knows your strike price, strategy, or position size until the envelope executes. A large position in a conventional options protocol immediately reveals to the market where the smart money's protection levels are. Atlas positions are invisible until they fire.

### MEV-resistant execution
When a traditional options position exercises, the execution is visible and front-runnable. Atlas routes through Flashbots Protect bundles with encrypted calldata and enforces a `minReturn` floor. The option executes at fair value.

### Manipulation-resistant exercise
Using TWAP leaf conditions, exercise evaluates against the 30-minute time-weighted average price — not the spot price at a single block. A flash manipulation attack cannot force an early exercise or prevent a correct one. The attack cost scales with the TWAP window multiplied by the required price deviation.

---

## Simple Examples (Any User)

### Stop-loss as a put option
Deposit 1 ETH into the vault. Register an envelope:
```
condition: ETH spot price < $1,800
intent:    sell 1 ETH → USDC
minReturn: 1,790 USDC (0.5% slippage floor)
expiry:    none
```
This is economically identical to buying a put option at $1,800 strike with no expiry. Cost: one keeper reward when it executes (~$1). No premium. No counterparty. Executes automatically whether you are online or not, whether your agent is running or not.

---

### Take-profit as a call
Deposit 1 ETH. Register:
```
condition: ETH spot price > $2,800
intent:    sell 1 ETH → USDC
```
Synthetic covered call. If ETH reaches $2,800, the vault converts automatically. You don't need to watch the market.

---

### Collar (bounded exposure)
Split 2 ETH into two vault commitments. Register:
```
Envelope 1:  condition: ETH < $1,600 → sell 1 ETH (downside protection)
Envelope 2:  condition: ETH > $2,800 → sell 1 ETH (capped upside)
```
Your exposure is bounded between $1,600 and $2,800. This is the textbook collar structure, executable in 2 signatures with no broker, no margin account, and no counterparty.

---

### Straddle (profit from big moves in either direction)
Split position into two. Register two envelopes:
```
Envelope 1:  condition: ETH < $1,600 → sell
Envelope 2:  condition: ETH > $2,800 → sell
```
You don't know which way ETH will move but you know it will move. The straddle fires on a large move in either direction. No options market needed — just two envelopes and two price leaves.

---

### DCA call ladder (cost-averaged accumulation)
Five envelopes, each buying equal USDC → ETH at successively lower levels:
```
Envelope 1:  ETH < $2,400 → buy $1,000 USDC worth of ETH
Envelope 2:  ETH < $2,200 → buy $1,000 USDC worth of ETH
Envelope 3:  ETH < $2,000 → buy $1,000 USDC worth of ETH
Envelope 4:  ETH < $1,800 → buy $1,000 USDC worth of ETH
Envelope 5:  ETH < $1,600 → buy $1,000 USDC worth of ETH
```
This is a cost-averaging call ladder. It executes automatically, captures lower prices without panic buying, and requires zero monitoring. The worst case: ETH never drops and none fire. The best case: ETH drops through all levels and you accumulate at each.

---

## Advanced Examples (Structured Products, Institutional)

### Reverse convertible note
Deposit $10,000 USDC. Deploy to Aave (earning 5% yield). Simultaneously register:
```
condition: ETH < $1,600 at expiry date (December 31, 2026)
intent:    convert all USDC to ETH at market rate
```
During the quiet period, you earn Aave yield. At expiry, if ETH is below $1,600, the position converts to ETH. If ETH stays above $1,600, the USDC stays put and you keep all yield. This is a reverse convertible note — a structured product that traditionally requires an investment bank to construct. Atlas does it with two primitives: a vault position and a conditional envelope.

---

### Principal-protected structured note
Deposit $10,000 USDC.
- Deploy $9,500 to Aave at 5% APY.
- Use the remaining $500 as premium budget for upside exposure.
- Register five call envelopes at ETH strike levels $2,500, $3,000, $3,500, $4,000, $5,000 using $100 each as keeper reserve.

Worst case: ETH goes to zero. You get $9,500 back from Aave (≈ $10,000 including yield). Principal protected. Best case: ETH goes to $5,000 and all five calls fire — you've captured gains at each level. The Aave yield effectively funds the protection cost. No financial intermediary required.

---

### Asian option (manipulation-resistant, TWAP exercise)
Register a protective sell envelope but with a TWAP price leaf instead of spot:
```
condition: 30-minute TWAP of ETH < $1,800
intent:    sell ETH → USDC
```
The option only exercises if ETH has *averaged* below $1,800 for 30 minutes — not if it briefly touched $1,800 on a flash manipulation attack. Settlement is based on the average realized price, not a single moment. This is the Asian option structure and it is essentially impossible to implement on existing on-chain options platforms. Atlas supports it natively as a leaf type.

---

### Barrier option (macro-regime-gated protection)
Create a protective put that only *exists* in a specific macro regime:
```
Conditional capability: only active when BTC dominance > 60%
Envelope within that capability: ETH/BTC ratio < 0.04 → sell ETH
```
The put option is invisible and inert until BTC dominance crosses 60%. Once the macro condition holds, the capability activates and the envelope is live. If the macro condition reverses, the capability deactivates. You have created a protection instrument that is regime-sensitive — it activates in the market conditions where you want protection, and goes dormant otherwise.

Barrier options of this type are not offered by any on-chain options protocol because they require conditioning the option's existence on an unrelated oracle feed.

---

### Quanto option (cross-asset denomination)
A standard option has a strike denominated in USD. A quanto option has a strike denominated in a different asset. Example:
```
condition: ETH/BTC ratio < 0.04
intent:    sell ETH → BTC
```
The strike is not a USD price — it is an ETH/BTC ratio. The settlement asset is BTC, not USDC. This is a quanto put on ETH denominated in BTC. It profits when ETH underperforms BTC specifically, not just when ETH falls in USD terms. A cross-asset ratio leaf condition makes this a single-line configuration. No existing DeFi options platform supports this.

---

### Ladder option (capture profits at multiple levels)
Five envelopes, each selling 20% of the position at successively higher ETH levels:
```
Envelope 1:  ETH > $2,600 → sell 20% of ETH
Envelope 2:  ETH > $2,800 → sell 20%
Envelope 3:  ETH > $3,000 → sell 20%
Envelope 4:  ETH > $3,200 → sell 20%
Envelope 5:  ETH > $3,400 → sell 20%
```
The position ladders out automatically as price rises. You capture profits at each level without watching the market, without market orders, and without the slippage of selling the full position at once. The ladder option is a well-known structured product — here it is five envelopes and five minutes to set up.

---

### Compound option (option to create an option)
An envelope that, when triggered, creates another envelope:
```
Envelope A:
  condition: ETH drops 15% (from current price)
  intent:    no swap — just register Envelope B
  next:      Envelope B (pre-committed hash)

Envelope B (created when A fires):
  condition: ETH < (A's trigger price - 10%)
  intent:    sell all ETH → USDC
```
When ETH drops 15%, Stage A fires and creates Stage B — a protective put set at 10% below the new (lower) price level. The protection dynamically adjusts to the new market level. A compound option — the right to acquire an option — expressed as two chained envelopes.

---

### Chooser option (decide put or call based on where market is)
```
condition: timestamp > 30 days from now
intent:    if ETH > entry_price → register call envelope
           if ETH < entry_price → register put envelope
```
At expiry of the chooser period, the user (or keeper) evaluates which direction has more value and commits to the appropriate leg. Because the next envelope is condition-dependent, the protocol supports this natively through conditional `nextEnvelope` selection. You defer the put/call decision until you have more information.

---

### Cliquet option (ratcheting protection that resets monthly)
A recursive chain of time-leaf envelopes, each resetting the strike to the current price:
```
Month 1 envelope:
  condition: ETH < (current_price × 0.9)
  intent:    sell ETH → USDC
  next:      Month 2 envelope

Month 2 envelope (registered when Month 1 either fires or expires):
  strike:    current price at Month 2 start
  condition: ETH < (new_price × 0.9)
  ...
```
Every month you get a fresh 10% downside protection floor, reset from wherever the market currently is. Gains from the previous month are locked in. Losses are bounded at 10% per month. A cliquet (ratchet option) typically costs significant premium from an investment bank. Here it is a self-sustaining strategy graph running on keeper incentives.

---

### Accumulator (condition-dependent purchase rate)
Two parallel envelopes reading the same time trigger but with different price conditions:
```
Envelope A (active when ETH > $2,200):
  condition: every 7 days AND ETH > $2,200
  intent:    buy $500 of ETH with USDC

Envelope B (active when ETH < $2,200):
  condition: every 7 days AND ETH < $2,200
  intent:    buy $1,000 of ETH with USDC (double up below threshold)
```
You accumulate at a standard rate when ETH is above your threshold and double up when it drops below. The accumulator structure is a well-known retail wealth management product — here it runs perpetually without any intermediary, without fee drag, and without minimum investment requirements.

---

## The Market Opportunity Reframe

The on-chain options market had approximately $2B in open interest in 2025. It is concentrated almost entirely on ETH and BTC. It requires deep liquidity on both sides and protocol-specific infrastructure for each options type. Bootstrapping a new asset requires months of liquidity incentives.

The Atlas addressable market for options-equivalent behavior is:

- Every user who has ever set a stop-loss (they are buying a put without knowing it)
- Every user who has ever set a take-profit (synthetic covered call)
- Every user who wants to automate entries at lower prices (DCA ladder)
- Every protocol treasury that needs downside protection
- Every institution that requires structured risk management but finds on-chain options too expensive or insufficiently liquid
- Every asset with an oracle feed — thousands of tokens — that will never have a dedicated options market

This is not the options market. This is the DeFi user base.

The critical distinction: **existing options protocols require liquidity to function. Atlas requires only an oracle.** As oracle coverage expands (Chainlink, Pyth, Uniswap V3 TWAPs), Atlas's options surface expands automatically — zero bootstrapping, zero incentive programs, zero liquidity mining.

---

## The Competitive Frame

| | Lyra / Dopex / Opyn | Atlas |
|---|---|---|
| Counterparty required | Yes — liquidity pool or market maker | No — open spot liquidity at exercise |
| Premium paid upfront | Yes — market-priced | No — keeper reward only (~$1) |
| Supported assets | ETH, BTC, a handful of majors | Any asset with an oracle feed |
| Options types | Standard vanilla + a few exotics | Any structure expressible as a condition tree |
| Exercise | Keeper or protocol function | Any keeper, permissionless |
| Privacy | Fully public at creation | Strategy private until exercise |
| MEV protection | None or limited | Flashbots Protect + `minReturn` floor |
| Manipulation resistance | Spot oracle (single block) | TWAP leaf option available |
| Liveness requirement | None | None (envelopes persist) |
| Composability | Protocol-specific | Composes with any Atlas primitive |

---

## Summary: Two Products, One Protocol

| | Type 1: Automated conditional execution | Type 2: Two-party vault option |
|---|---|---|
| Price guarantee | No — executes at market | Yes — writer's collateral is the guarantee |
| Counterparty needed | No | Yes — but trustless and pre-collateralized |
| Premium | No — keeper reward only | Yes — negotiated bilaterally |
| Supported assets | Any oracle feed | Any oracle feed |
| Expiry | Optional | Required (releases collateral) |
| Privacy | Private until exercise | Private until exercise |
| MEV protection | Flashbots Protect | Flashbots Protect |
| Manipulation resistance | TWAP leaf available | TWAP leaf available |
| Clearing infrastructure | None needed | Vault commitment replaces clearing house |
| Best for | Retail automation, stop-losses, portfolio management | Hard hedges, institutional risk management, structured products |

---

## The Competitive Frame (Updated)

| | Lyra / Dopex / Opyn (pool-based) | Atlas Type 1 | Atlas Type 2 |
|---|---|---|---|
| Counterparty | Pool — can become undercollateralized | None | Pre-collateralized writer, cannot default |
| Premium | Market-priced, paid upfront | None | Bilateral negotiation |
| Supported assets | ETH, BTC only | Any oracle feed | Any oracle feed |
| Options types | Standard vanilla | Any condition tree structure | Any condition tree structure |
| Price guarantee | Probabilistic (pool solvency) | None — market execution | Hard — collateral pre-committed |
| Privacy | Fully public at creation | Private until exercise | Private until exercise |
| MEV at exercise | Front-runnable | Flashbots Protect | Flashbots Protect |
| Manipulation resistance | Single block oracle | TWAP leaf available | TWAP leaf available |
| Clearing house | Protocol-managed | None needed | Vault commitment |

---

## The Correct Claim

Atlas does not eliminate the counterparty for options that carry a hard price guarantee. A price guarantee requires committed collateral, and committed collateral requires a counterparty.

What Atlas does:
- **For execution certainty without price guarantee:** eliminates the counterparty entirely. Any asset, any condition, no premium, no pool.
- **For hard price guarantees:** makes the counterparty relationship trustless, pre-collateralized, automatically settled, and clearing-house-free. The counterparty cannot default because their collateral is in the vault before the option exists.

Together, these two capabilities cover the complete options use case space — from retail stop-losses to institutional structured products — on any asset with an oracle feed, with settlement guaranteed by code rather than by institutional trust.

The implications extend well beyond options. The same two-party vault commitment mechanism that produces trustless options also produces trustless forward contracts, trustless interest rate swaps, trustless credit default protection, and trustless employment contracts. Options are the first obvious reframe. See DERIVATIVES.md for the full picture.

---

*This document is a companion to EXTENSIONS.md §Extension 1, CAPABILITIES.md §3.1, and DERIVATIVES.md. The technical specification for TWAP leaf, N-block confirmation, and conditional capability structures is in EXTENSIONS_SPEC.md.*
