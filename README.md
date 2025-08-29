# Account Weight Providers

This package contains two implementations of [`IAccountWeightProvider`](./src/interfaces/IAccountWeightProvider.sol).  
They provide different semantics for how accounts are deemed *eligible* and how their *weights* are tracked.

---

## Implementations

### 1. AccountWeightProviderUnbounded
- **Graded weights**: any non-negative integer.
- Weights are measured in **basis points** (`getWeightScale() = 10_000`).
- Total weight = sum of all per-account weights (no maximum cap).
- Useful when eligibility is proportional (e.g. multipliers, boosts, variable scoring).

### 2. AccountWeightProviderBinary
- **Binary weights**: either 0 (ineligible) or `getWeightScale()` (eligible).
- Backed by the **Circles v2 Hub** trust graph at: 0xc12C1E50ABB450d6205Ea2C3Fa861b3B834d13e8
- Each offer gets its own lazily-created [`EligibilityOrganization`](./src/AccountWeightProviderBinary.sol#L19),  
which toggles Hub trust for accounts:
- **Trust (eligible):** `HUB.trust(account, type(uint96).max)`
- **Untrust (ineligible):** `HUB.trust(account, 0)`
- Total weight = `totalEligibleAccounts × getWeightScale()`.
- Useful when eligibility is **yes/no only**.

---

## Admin Workflow

1. **Assign weights**  
 `setAccountWeights(offer, accounts, weights)`  
 - Unbounded: directly updates stored weights.  
 - Binary: delegates to the per-offer `EligibilityOrganization` to update Hub trust.

2. **Finalize weights**  
 `finalizeWeights()`  
 - Locks state permanently for that offer.  
 - Emits `WeightsFinalized(offer, accountsCount, totalWeight)`.

---

## Querying

All queries are **scoped to the calling offer** (`msg.sender`).

- `getAccountWeight(account)` → the account’s weight for the calling offer.  
- `getTotalWeight()` → sum of all weights for the calling offer.  
- `getTotalAccounts()` → count of accounts with nonzero weight.  
- `getWeightScale()` → the scale constant (`10_000` = basis points).

---

## Integration Notes

- **Immutable admin**: set once in constructor, cannot be changed.  
- **Idempotent updates**: setting the same weight twice has no effect.  
- **Finalization**: once `finalizeWeights()` is called, further updates revert.  
- **Binary provider** depends on Circles Hub — do not redeploy that contract.  
- **Unbounded provider** is self-contained.

---

## Example Use Cases

- **Unbounded:** reward boosts, loyalty multipliers, variable eligibility scoring.  
- **Binary:** allowlist / denylist, strict membership gating.

---

# ERC20 Token Offer

The `ERC20TokenOffer` contract implements a fixed-window token sale in exchange for CRC (Circles).  
It integrates with a pluggable [`IAccountWeightProvider`](./src/interfaces/IAccountWeightProvider.sol) to gate **per-account limits** and uses the **Circles v2 Hub** for CRC transfers.

---

## Lifecycle

1. **Deployment**  
   - Parameters set: ERC-20 token, price in CRC, base per-account limit, start time, duration.  
   - Registers an organization in the Hub and trusts the provided CRC ids.

2. **Weight assignment**  
   - Admin sets weights via the chosen provider (e.g. Binary or Unbounded).

3. **Deposit**  
   - Admin calls `depositOfferTokens()`.  
   - Pulls in the exact ERC-20 amount required to back all potential claims.  
   - Freezes the weight provider (`finalizeWeights()`).  
   - Offer is now ready.

4. **Claim**  
   - During the active window, eligible accounts spend CRC (via Hub callbacks).  
   - Contract sends them ERC-20 tokens at the fixed price.  
   - Each account is limited to `baseLimit * weight / weightScale`.  
   - First-time claim increments `claimantCount`.

5. **Withdraw leftover**  
   - After the end, admin may call `withdrawUnclaimedOfferTokens()` to recover any unsold ERC-20 balance.

---

## Eligibility & Limits

- **Eligibility** is defined entirely by the configured `ACCOUNT_WEIGHT_PROVIDER`.  
- **Per-account limit**:  limit(account) = BASE_OFFER_LIMIT_IN_CRC * weight(account) / WEIGHT_SCALE

- **Total ERC-20 required**:  amount = (BASE_OFFER_LIMIT_IN_CRC * totalWeight * 10^TOKEN_DECIMALS)
/ (WEIGHT_SCALE * TOKEN_PRICE_IN_CRC)

This ensures the contract can satisfy all claims if everyone spends to their limit.

---

## Key Functions

- `isOfferAvailable()` → true if in window and tokens deposited.  
- `isAccountEligible(account)` → weight > 0.  
- `getAccountOfferLimit(account)` → weighted CRC spend cap.  
- `getAvailableAccountOfferLimit(account)` → remaining CRC cap after usage.  
- `depositOfferTokens()` → pulls required ERC-20 and finalizes weights.  
- `withdrawUnclaimedOfferTokens()` → recovers leftover tokens after end.  

---

## Integration Notes

- **Hub callbacks** (`onERC1155Received`, `onERC1155BatchReceived`) handle CRC payments automatically.  
- If `CREATED_BY_CYCLE == true`, claims can only be initiated by the Cycle owner, with beneficiary encoded in `data`.  
- The contract enforces **idempotent accounting**: multiple calls with same weights or limits are safe.  
- **Finalization**: after deposit, weights are frozen and cannot be changed.

---

## Example Use Cases

- Distribution of a new ERC-20 token to an allowlisted community.  
- Weighted airdrops with per-account caps.  
- Cycle-created offers where eligibility is managed off-chain but enforced via Hub trust.

sequenceDiagram
    autonumber
    participant Admin
    participant WeightProvider as IAccountWeightProvider
    participant Offer as ERC20TokenOffer
    participant Hub as Circles Hub
    participant User

    Admin->>WeightProvider: setAccountWeights(offer, accounts, weights)
    Admin->>Offer: depositOfferTokens()
    Offer->>WeightProvider: getRequiredOfferTokenAmount()
    Offer->>WeightProvider: finalizeWeights()
    Admin->>Offer: ERC20.approve(Offer, amount)
    Offer->>Admin: ERC20.transferFrom(Admin, Offer, amount)

    Note over Offer,Hub: Offer window is now active (time OK + tokens deposited)

    User->>Hub: safeTransferFrom(User → Offer, CRC id(s), value, data?)
    Hub->>Offer: onERC1155Received / onERC1155BatchReceived(...)
    Offer->>WeightProvider: getAccountWeight(user), getTotalAccounts/Weight()
    Offer->>User: ERC20.transfer(user, amount = value * 10^decimals / price)
    Offer->>Hub: safeTransferFrom(Offer → Admin, CRC id(s), value, pass-through data)

    Note over Admin,Offer: After end:
    Admin->>Offer: withdrawUnclaimedOfferTokens()
    Offer->>Admin: ERC20.transfer(Admin, leftover)


flowchart TD
    A[Deploy Offer] --> B[Register org & trust accepted CRC]
    B --> C[Admin sets weights in provider]
    C --> D[Admin calls depositOfferTokens()]
    D --> E[Offer pulls required ERC20<br/>and provider.finalizeWeights()]
    E --> F{Now active? <br/>(time window && tokens deposited)}
    F -- No --> F
    F -- Yes --> G[User sends CRC via Hub]
    G --> H[Offer checks weight/limit]
    H --> I{Within limit?}
    I -- No --> I2[Revert ExceedsOfferLimit]
    I -- Yes --> J[Offer pays ERC20 to user]
    J --> K[Offer forwards CRC to Admin via Hub]
    K --> L{After end?}
    L -- No --> F
    L -- Yes --> M[Admin withdraws leftover ERC20]


stateDiagram-v2
    [*] --> Uninitialized
    Uninitialized --> Funded: depositOfferTokens()
    Funded --> Active: time in [start,end]
    Active --> Ended: time > end
    Ended --> Drained: withdrawUnclaimedOfferTokens()


---

# ERC20 Token Offer Cycle

`ERC20TokenOfferCycle` orchestrates a series of fixed-window ERC-20 offers that sell a token for CRC via the **Circles v2 Hub**.  
All offers in the cycle share a single [`IAccountWeightProvider`](./src/interfaces/IAccountWeightProvider.sol), so eligibility and limits are centrally managed.

---

## What it does

- **Time-based rotation:** Each offer occupies a slot of `OFFER_DURATION` seconds.  
  `currentOfferId()` derives the active offer from `block.timestamp`.
- **Factory-driven:** The cycle uses an `IERC20TokenOfferFactory` to:
  - Create the **shared weight provider** (binary or unbounded).
  - Create per-period `ERC20TokenOffer` instances.
- **Hub integration:** The cycle registers an org in the **Circles Hub** and proxies CRC:
  - **Pre-claim:** CRC sent to the cycle is forwarded to the current offer.
  - **Post-claim:** CRC coming back from the offer is forwarded onward to the admin.
- **Soft lock (optional):** If enabled, a user can’t send CRC to the current offer if their **claimed ERC-20** exceeds their **current wallet balance** (prevents “sell-then-double-spend” patterns).

---

## Lifecycle

1. **Initialize cycle**
   - Constructor creates the **shared weight provider** (binary/unbounded), sets `OFFERS_START`, `OFFER_DURATION`, registers a Hub org, emits `CycleConfiguration`.

2. **Create next offer**
   - Admin calls `createNextOffer(price, baseLimit, acceptedCRC[])`.
   - Deploys the next `ERC20TokenOffer` (id = current + 1).
   - Records `acceptedCRC` for that offer (Hub trust list).

3. **Fund next offer**
   - Admin calls `depositNextOfferTokens()` (after approving the cycle).
   - Cycle pulls ERC-20 from admin, safe-approves the new offer, calls `offer.depositOfferTokens()` (which finalizes weights).

4. **Active period (claims)**
   - Users send CRC via Hub to the cycle.
   - Cycle forwards CRC to the **current** offer (pre-claim path).
   - Offer pays ERC-20 to user and calls back with CRC to the cycle (post-claim path).
   - Cycle forwards CRC to the **admin** and emits `OfferClaimed`.

5. **Withdraw leftovers (past offers)**
   - Admin calls `withdrawUnclaimedOfferTokens(offerId)` to recover unsold ERC-20.

---

## Time model

- `currentOfferId()`:
  - `0` if `now < OFFERS_START`.
  - Otherwise `((now - OFFERS_START) / OFFER_DURATION) + 1`.
- The **next** offer is always `current + 1` in storage.

---

## Key functions

- **Creation & funding**
  - `createNextOffer(tokenPriceInCRC, offerLimitInCRC, acceptedCRC[])`  
    → deploys next offer, records accepted CRC ids.
  - `depositNextOfferTokens()`  
    → transfers ERC-20 from admin, approves and triggers `offer.depositOfferTokens()`.

- **Active offer facade**
  - `isOfferAvailable()` → passthrough to current offer.
  - `isAccountEligible(account)` → passthrough to current offer.
  - `getTotalEligibleAccounts()` / `getClaimantCount()` → passthrough to current offer.
  - `getAccountOfferLimit(account)` / `getAvailableAccountOfferLimit(account)` → passthrough to current offer.

- **Trust sync**
  - `syncOfferTrust()` → sets Hub trust end-time for current offer’s accepted CRC ids.

- **Withdraw**
  - `withdrawUnclaimedOfferTokens(offerId)` → pulls leftover ERC-20 from past offer and forwards to admin.

- **Weight admin**
  - `setNextOfferAccountWeights(accounts[], weights[])`  
    → writes to the **shared provider** under the **next offer’s address**.

---

## Soft lock semantics

- Enabled by `SOFT_LOCK_ENABLED`.
- Before forwarding CRC **to the current offer**, the cycle checks: totalClaimed[user] <= OFFER_TOKEN.balanceOf(user)
- If violated → `SoftLock()` (helps prevent users from claiming tokens and then immediately transferring them away while still attempting more CRC spending).

---

## Data tracked by the cycle

- `offers[offerId]` → offer instance.
- `acceptedCRC[offerId]` → CRC ids trusted by that offer.
- `totalClaimed[user]` → cumulative ERC-20 received by `user` across **all** offers in this cycle (used for soft lock + analytics).

---

## Gotchas & tips

- **Funding guard:** `createNextOffer` reverts if the next offer exists **and** is already funded (`NextOfferTokensAreAlreadyDeposited`).
- **Approve before deposit:** Admin must `approve(cycle, requiredAmount)` before `depositNextOfferTokens()`.
- **Shared provider scope:** When setting weights for the **next** offer, the cycle uses the next offer’s **address** as the scope key in the shared provider.
- **Trust syncing:** `syncOfferTrust()` is a QoL helper; it updates Hub trust end-times to the current offer’s natural end.
- **Readiness check:** `isOfferAvailable()` is true only when the **time window** is active **and** the offer is **funded**.

---

## Typical sequence

1) `createNextOffer(...)`  
2) `setNextOfferAccountWeights(...)` (can be repeated)  
3) `depositNextOfferTokens()` (finalizes weights)  
4) Users claim during the window; cycle routes CRC and records `OfferClaimed`.  
5) After end, `withdrawUnclaimedOfferTokens(offerId)` if needed.  

sequenceDiagram
    autonumber
    participant Admin
    participant Factory as IERC20TokenOfferFactory
    participant Provider as IAccountWeightProvider
    participant Cycle as ERC20TokenOfferCycle
    participant Offer as ERC20TokenOffer
    participant Hub as Circles Hub
    participant User

    %% Init
    Admin->>Factory: (constructor) deploy Cycle
    Factory-->>Cycle: createAccountWeightProvider(...)
    Cycle-->>Hub: registerOrganization(orgName)

    %% Prepare next period
    Admin->>Cycle: createNextOffer(price, baseLimit, acceptedCRC[])
    Cycle->>Factory: createERC20TokenOffer(...)
    Factory-->>Cycle: Offer address
    Cycle-->>Admin: NextOfferCreated(...)

    Admin->>Cycle: setNextOfferAccountWeights(accounts, weights)
    Cycle->>Provider: setAccountWeights(nextOffer, accounts, weights)

    %% Funding next offer (finalizes weights inside Offer)
    Admin->>Cycle: depositNextOfferTokens()
    Cycle->>Admin: ERC20.transferFrom(ADMIN, Cycle, required)
    Cycle->>Offer: ERC20.approve(required)
    Cycle->>Offer: depositOfferTokens()
    Offer->>Provider: finalizeWeights()
    Cycle-->>Admin: NextOfferTokensDeposited(...)

    %% Claim during active window
    User->>Hub: safeTransferFrom(User → Cycle, CRC id(s), value, data?)
    Hub->>Cycle: onERC1155Received/Batch(...)
    Cycle->>Offer: forward CRC (pre-claim)
    Offer->>Provider: getAccountWeight(user), getTotalWeight()
    Offer-->>User: ERC20.transfer(user, amount)
    Offer->>Hub: safeTransferFrom(Offer → Cycle, CRC id(s), value, data(account, amount))
    Hub->>Cycle: onERC1155Received/Batch(... post-claim)
    Cycle-->>Admin: forward CRC to ADMIN
    Cycle-->>Cycle: totalClaimed[account] += amount

    %% After period end
    Admin->>Cycle: withdrawUnclaimedOfferTokens(offerId)
    Cycle->>Offer: withdrawUnclaimedOfferTokens()
    Offer-->>Cycle: leftover ERC20
    Cycle-->>Admin: ERC20.transfer(leftover)

flowchart TD
    A[Deploy Cycle] --> B[Factory creates shared Provider]
    B --> C[Register org in Hub]
    C --> D[Admin createNextOffer()]
    D --> E[Admin setNextOfferAccountWeights()]
    E --> F[Admin depositNextOfferTokens()]
    F --> G{Window active?}
    G -- No --> G
    G -- Yes --> H[User sends CRC → Cycle]
    H --> I[Cycle forwards CRC → current Offer]
    I --> J[Offer checks weights & limits]
    J --> K{Within limit?}
    K -- No --> K1[Revert ExceedsOfferLimit]
    K -- Yes --> L[Offer pays ERC20 to user]
    L --> M[Offer returns CRC → Cycle]
    M --> N[Cycle forwards CRC → Admin<br/>and updates totalClaimed]
    N --> O{Period ended?}
    O -- No --> G
    O -- Yes --> P[Admin withdrawUnclaimedOfferTokens(offerId)]

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Deploy

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```
