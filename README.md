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
