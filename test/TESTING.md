# SIMDTEST test additions

The existing tests and dependencies are retained. All additions and edits are under `test/`;
no contracts, configuration, scripts, or dependencies were changed or installed.

## Coverage

`Adversarial.t.sol` adds eight checks for each currency ordering, using directly CREATE2-mined
hooks and the vendored, unmodified PoolManager:

- Differential fuzzing compares a taxed buy with one equivalent underlying swap after fee expiry.
  Price, tick, liquidity, LP fee growth, protocol fees, delivered tokens, and net input must agree.
  This checks that internal quotes cannot persist accounting changes. Both request modes,
  full and partial fills, all ten active fee rates, and nonzero protocol fees are exercised.
- Rejected oversized buys must preserve balances, prior claims, price, LP fees, and protocol fees.
  A subsequent compliant buy must still succeed.
- A propagated quote failure must preserve funds and permit a subsequent valid swap.
- Expiry of the timestamp limit must not disable a still-active block-based fee.
- Sells exceeding the buy cap remain executable in both request modes during the active windows.
- A failed claim payout preserves claims and permits further collection and a later sweep.
- A failed donation payout rolls back the claim redemption that happened earlier in the sweep.
- Failed initialization must leave the clocks unset, allowing a later valid opening.

The two new fuzz properties run 1,000 cases each for both currency orderings (4,000 cases).
Sweep failure injection uses a local ERC-20 replacement that preserves mock storage and returns
false for a selected sender. It is a fault-injection test, not a claim about real IMD behavior.

`Invariant.t.sol` now independently calculates expected fees from payer balance changes and the
specified block schedule. Its handler mixes exact-input/output buys and sells, direct donations,
donations of backed ERC-6909 claims, rejected oversized buys, sweeps, and clock advances through
both expiry boundaries. Each run starts with nonzero fees, both donation forms, and a rejected buy.
No handler action mints or uses `deal` to create funds. The invariants check conservation of both
currencies, fees plus donations, claim backing, fixed supply, immutable opening clocks, static LP
fees, and zero unsettled manager deltas. Each currency ordering runs 256 sequences of 64 calls,
with unexpected reverts treated as failures.

`MainnetFork.t.sol` adds actual-delivery partial-fill checks, mixed donation/claim sweeps by an
unrelated caller, and rollback checks against real IMD balances and PoolManager state. All five
fork scenarios run in both currency orderings. The existing scenarios cover the fee decay, exact
buy cap and expiry, and exact-input/output buys and sells. Fork setup preserves the deployed IMD
and PoolManager code, verifies chainId 1 and IMD metadata, and uses `deal` only for test funding.

The retained suites cover permission bits, callback authentication, absence of common admin
entry points, forbidden opcodes, reentrant sweep attempts, one-sided pools without manager IMD,
empty pools, huge specified requests, and token supply/transfer rules.

## Reproduction and recorded results

From the repository root, keep all generated output in disposable scratch space:

```sh
mkdir -p test/scratch
forge build --out test/scratch/out --cache-path test/scratch/cache
forge test --out test/scratch/out --cache-path test/scratch/cache
```

Recorded result: build succeeds; 61 tests pass, zero fail, and two fork suites skip when there is
no active fork. Both invariant suites complete 16,384 randomized calls without unexpected reverts.
The compiler emits existing source lint warnings; they are not suppressed.

The real mainnet run was also completed successfully at block **26146133**:

```sh
forge test --out test/scratch/out --cache-path test/scratch/cache \
  --match-contract '^MainnetFork' \
  --fork-url https://ethereum-rpc.publicnode.com \
  --fork-block-number 26146133 --no-storage-caching
```

Recorded result: 10 tests pass, zero fail, zero skip. Future reproduction at this block requires
an endpoint retaining that historical state. The default offline suite has no RPC requirement,
FFI, environment mutation, downloaded dependencies, or runtime dependency on scratch files.

No reproducible implementation defect was found in these cases. This scoped review does not
attest the external launch factory's supply distribution or future changes to external contracts.
