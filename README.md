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
