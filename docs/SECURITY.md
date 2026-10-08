# Adversarial review

Scope: `SIMDTEST`, `SIMDTESTHook`, the CREATE2 planner, manifest, and their integration with the pinned v4 core. This is a local source review supported by executable attacks and fuzz/invariant tests. It is not an independent external audit or formal verification. No unresolved concrete exploit was found in the reviewed deployment model.

## Caller and initialization boundaries

Every enabled callback and the unlock callback require the immutable PoolManager. The simulated swap entry point requires `msg.sender == address(this)`; untrusted routers cannot call it to bypass fees or the buy limit. There is no general call forwarding, fallback, manager approval, arbitrary recipient, or token-minting entry point. Tests directly attack every callback, the quote function, and common administration selectors.

The hook accepts exactly one token/IMD pool at fee 12500 and spacing 60. Initialization records both clocks once. Alternative tokens, dynamic fees, wrong spacing, repeat initialization, and predeployment initialization are denied. Before-swap pool keys need no separate mapping: every other pool using this hook necessarily fails its initialization callback. Factory deployment and initialization must be atomic; no fixed factory address or unknown owner has been invented.

## Return deltas and quote rollback

Core's self-call suppression applies because `quoteSwap` calls PoolManager from the hook address. The quote then unconditionally reverts. EVM reversion restores pool price/ticks/liquidity, accrued protocol fees, events, hook accounting and transient balances to the call-entry snapshot. No physical transfer or claim mint occurs in the quote. Only a 36-byte `QuoteResult(int128)` error is decoded; other errors are propagated. A successful quote call is impossible by construction.

For exact input, a positive specified fee reduces the negative spending budget without changing swap direction. The fee is at most 30% of a filled gross budget. For a partial fill, the preliminary net budget reaches the user's price limit with input `U` smaller than the net budget; using `floor(U*r/(10000-r))` as the fee leaves at least as much pool budget and the same price bound, so the final pool input remains `U`. The exact-output fee is a positive unspecified (IMD) delta; the output-token delta is unmodified. The hook never returns the user's entire input as a fabricated swap result. Expired-fee swaps and sells return zero deltas.

Each claim mint debits the hook by exactly `F` IMD, and its return delta credits the hook by exactly `F`. Core subtracts that return delta from the caller's pool delta. At sweep, burning the claim credits `F` and taking IMD debits `F`. The invariant suite checks zero manager deltas and `outstandingClaims + treasuryReceipts == feesAccrued` after randomized trades, time changes and sweeps. Other invariants conserve total token and IMD balances.

## Arithmetic and accepted amounts

Fees are rounded down. Exact-input gross fee computation uses quotient plus remainder: `floor(B/10000)*r + floor((B%10000)*r/10000)`. This equals `floor(B*r/10000)` without overflowing multiplication even at the magnitude of `int256.min`.

The only unchecked operation negates a negative signed input and reinterprets it as unsigned, including the intentional two's-complement representation of `abs(int256.min)`. During quoting `r >= 300`, so subtracting its gross fee leaves `netBudget <= int256.max`.

A quoted IMD debit comes from a real signed `int128` BalanceDelta, hence its magnitude is at most `2^127`. Exact-output fees are at most 30% of this. Partial exact-input fees are at most `3000/7000` of this. Full-input fee casts are likewise bounded because a full fill implies that the net budget fits that same actual delta. Thus the fee's cast into signed `int128` is safe. Actual core inputs plus fees remain subject to v4's own balance-delta representability; the launch's finite real supply is far below those bounds. Huge requested amounts are not cast to `int128` and are fuzzed against narrow price limits for both directions and modes.

Boundary tests include `int256.min` exact input, very large partially filled exact output, and `int256.max` output producing the explicitly permitted `UnrepresentableFee`. `MaxBuyExceeded` uses actual positive delivered tokens, never negates `int128.min`, and allows equality. Both clocks use elapsed values, with exact block +10 and second +3600 boundaries tested. Timestamps/blocks are consensus clocks, not randomness or price oracles.

## Reentrancy and token behavior

The swap callbacks call only the fixed manager and the hook's own reverted quote. Manager claim minting has no receiver callback. No ERC-20 transfer happens in the fee callback. The quote cannot expose lasting partial state or reenter untrusted tokens.

Sweep has an OpenZeppelin reentrancy guard; the manager claims burn before taking IMD. A malicious replacement IMD in the local attack harness attempts recursive sweep during claim payout and during donation-only transfer; both attacks fail without blocking the outer payout. SafeERC20 checks donated-token transfer results. Manager `take` checks its own transfer result. IMD's real transfer behavior was exercised in the fork suite. Only the specified 18-decimal IMD and the standard deployed launch token are supported; arbitrary rebasing/taxed pairs are not accepted.

There is no owner, role, pause, fee setter, upgradability or token mint function. Runtime opcode tests step over PUSH immediates and reject SELFDESTRUCT, DELEGATECALL and CALLCODE in both deployed launch contracts. The creation code and deployed hook code satisfy EIP-3860 and EIP-170.

## Evidence and limitations

- Unit tests run against a real locally deployed v4 PoolManager, mined hook addresses, and both currency orderings.
- Fuzzing covers ordinary swaps, huge partially filled requests, and standard token allowance transfers, at 1,000 runs each.
- Stateful accounting checks run 128 sequences of 64 actions, with `fail_on_revert = true`.
- Mainnet fork block 26145829 passed real IMD settlement and treasury redemption, all four trade modes, fee decay and max-buy enforcement.
- The empty-liquidity regression collects zero phantom fees. A one-sided pool starting with no manager IMD or ETH successfully accrues and sweeps fees.
- Forge build lint ran. Its timestamp notice is the specified timer design. Cast and division notices were assessed using the bounds above. Code-length checks reject zero constructor addresses. Event/reentrancy notices concern fixed-manager calls or guarded sweep; executable reentrancy regressions pass. Unlock return bytes are intentionally unused because the callback returns no application data.

Quoting executes an extra pool traversal during taxed buys and increases gas, particularly across many initialized ticks. Routers must quote the complete hook behavior, retain their minimum-output/maximum-input checks, and budget gas accordingly. This hook does not prevent splitting buys, alternate pools, MEV ordering, or transfers acquired outside the launch pool.

The release operator remains responsible for an independent audit, current-state fork rehearsal, atomic factory integration, source verification, and monitoring. Slither, Mythril and formal verification were not run. Pinned fork success does not attest future changes to external IMD behavior or external factory allocation code.
