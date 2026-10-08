# SIMDTEST launch

This project delivers the fixed-supply `SIMDTEST` ERC-20 and its immutable, ownerless Uniswap v4 `SIMDTESTHook`. All imported Solidity dependencies are vendored as ordinary files in `lib/`; their upstream commits and licenses are recorded in `docs/dependencies.json` and the corresponding library directories. No installation, network connection, FFI, or filesystem cheatcode is required to build or run the default tests.

## Build and check

```sh
forge build
forge test
forge fmt --check
python3 script/check_manifest.py
```

`foundry.toml` pins Solidity 0.8.26, Cancun, optimizer enabled with 200 runs, and `bytecode_hash = "none"`. Supply the pinned compiler through the normal Foundry installation. No compiler executable is bundled.

The unit/integration suite deploys the actual vendored v4 PoolManager and uses its swap and liquidity routers. It exercises both currency orderings, exact-input/output buys and sells, every fee-decay block, exact limit boundaries, partial fills, large requests, sweep reentrancy, permission bits, forbidden runtime opcodes, and initialization restrictions. Five fuzz tests run 1,000 cases each. A stateful invariant performs 128 sequences of 64 actions and checks token conservation, fee claims plus treasury receipts, and zero outstanding PoolManager deltas.

Fork tests explicitly skip when no fork is active, without reading environment variables. They use real IMD bytecode and the real mainnet PoolManager. The following run passed all three fork tests at block **26145829**:

```sh
forge test --match-contract MainnetForkTest \
  --fork-url https://ethereum-rpc.publicnode.com \
  --fork-block-number 26145829 -vv
```

An archive-capable mainnet endpoint may be substituted on the command line. Test funding uses Foundry's ERC-20 `deal` to give the test trader IMD; the tests do not replace IMD's code, replace the live PoolManager, fund real accounts, or broadcast transactions. They verify real-token settlement, treasury payout, both trade modes in both directions, decay, and max-buy enforcement. Default offline tests use an explicit IMD stand-in at the specified pair address.

## Token and pool

| Parameter | Value |
| --- | --- |
| Token name / symbol | SIMDTEST / SIMDTEST |
| Supply / decimals | 1,000,000,000 / 18 |
| Supply in minor units | 1000000000000000000000000000 (`1e27`) |
| Chain | Ethereum mainnet, chainId 1 |
| PoolManager constructor argument | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
| IMD paired currency | `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` |
| Static LP fee / tick spacing | 12500 (1.25%) / 60 |
| Treasury | `0x3dd5f73dd1a4e62630fad3909673f130ad429985` |
| Manifest initialPrice | `79228162514264337593543950336`, provenance only |
| Required hook address bits | `(uint160(hook) & 0x3fff) == 0x20c8` |

`SIMDTEST()` has no arguments and mints **all** `1e27` units to its deployer. The token is OpenZeppelin ERC20 with only this constructor; it has no tax, hooks, subsequent minting, owner, pause, burn function, blocklist, or upgrade interface. Transfers have ordinary ERC-20 behavior.

The factory owns distribution responsibilities: seed 90% of supply into the IMD pool, send the swarm's 10% through its Merkle distributor, and route any remainder to `remainderTo`. These contracts neither choose nor execute that allocation. The factory derives the actual opening price from launch economics; the manifest's price must not be treated as a production price recommendation.

## Hook behavior and rounding

Pool opening records `openedBlock` and `openedAt` in the manager-only `beforeInitialize` callback. Only the exact immutable token/IMD pair, this hook, static fee 12500, and spacing 60 can initialize it. Initialization succeeds once. The constructor takes `IPoolManager poolManager_` and the newly deployed `address token_`; both are immutable and must have code. The mainnet manager above is mandatory for deployment, while the argument allows real local PoolManagers in tests.

For elapsed blocks `e = block.number - openedBlock`, the buy fee is `(10-e)*300` basis points for `e < 10`, otherwise zero. Thus opening-block buys pay 30%, the next block pays 27%, block `+9` pays 3%, and block `+10` pays zero. Sells never pay this hook fee. The 1.25% LP fee always remains in force; there is no dynamic flag, LP fee update, or override.

Fees use IMD only and are charged through `beforeSwap` return deltas:

- **Exact input:** the specified IMD budget includes the hook fee. A full fill charges `floor(budget * rate / 10000)` and sends the remainder through the pool.
- **Exact output:** the actual pool IMD input includes the LP fee. The hook adds `floor(poolInput * rate / 10000)` IMD to that input, preserving the specified token output.
- **Partial exact input:** the hook charges `floor(actualPoolInput * rate / (10000-rate))`, so unused budget is not taxed. Integer rounding always floors; tiny fees can be zero.

The exact-input budget and exact-output pool-input bases differ intentionally: exact input supplies a total spending budget, while exact output supplies desired token output. Routers must include the applicable fee in their quotes and user slippage checks.

To determine an exact-output fee **before** the real swap, `beforeSwap` makes a self-only quote call. That call invokes the same pool swap with the same price limit, then unconditionally reverts with its IMD delta. Core skips recursive callbacks when the hook itself calls `swap`. All quoted changes, including events, protocol fees and transient deltas, roll back. The real swap subsequently executes once. Exact-input quotes also protect partial fills and avoid narrowing enormous specified requests into `int128`. No fee is exchanged for another currency, and no persistent quote swap or price oracle is used. This costs an extra simulated pool traversal during the ten-block fee window. Expired-fee swaps and sells do not quote.

The constructor validates these four permissions: `beforeInitialize`, `beforeSwap`, `afterSwap`, `beforeSwapReturnDelta`. All other permissions are false; in particular, `afterSwapReturnDelta` is unnecessary because the exact-output IMD fee is the unspecified component of the before-swap delta.

`afterSwap` checks the **positive launched-token BalanceDelta**, not the requested size. Until `openedAt + 3600`, delivered tokens greater than `1e25` (10,000,000 tokens, exactly 1%) revert with `MaxBuyExceeded`. Exactly `1e25` succeeds. At the exact expiry timestamp the limit is inactive. Sells have negative token deltas and are unrestricted. There is no wallet limit, so multiple compliant swaps and trades in other pools are possible. `limitActive()` is false before initialization; `maxBuy()` always returns `1e25`.

Large specified requests with small realized fills remain executable. The fee arithmetic supports `int256.min` exact-input budgets. An exact-output request whose specified amount plus its fee exceeds `int256.max` raises `UnrepresentableFee`. Core still enforces its own valid-price, liquidity, balance-delta and settlement domain. PoolManager wraps hook failures in its standard `WrappedError`, retaining the inner custom-error selector.

## Collection and operations

For each nonzero fee, the hook mints itself an IMD-denominated PoolManager ERC-6909 claim. Minting creates the corresponding negative hook delta; the returned positive fee delta cancels it and adds the fee to the router's obligation. This accrues fees to the hook without an early IMD transfer or a dependency on the manager's pre-swap token balance. A regression test starts with zero IMD and zero ETH in a one-sided pool's manager.

`accruedFees()` reports these claims. Anyone can call `sweep()` in a normal, separate transaction. It unlocks PoolManager, burns the claims, and takes the same amount of IMD directly to the immutable treasury. Any IMD donated directly to the hook is also transferred to that treasury. Claims burn before withdrawal, and a reentrancy guard protects sweep. A repeated empty sweep is harmless. No ETH or launched tokens are collected or converted; there are no approvals or arbitrary recipient inputs in the hook.

The treasury or any keeper must pay gas to invoke sweep; there is no scheduled transaction or caller bounty. A sweep attempted during another open manager unlock cannot open a nested unlock and should be retried separately. If IMD refuses a treasury transfer, sweep reverts atomically and retains the claims; the fee-collection callback itself does not make that transfer. Unrelated tokens accidentally sent to the hook have no rescue function.

## Deploying the launch

1. Deploy `SIMDTEST` from the launch factory. Confirm its entire supply belongs to that factory.
2. Encode the hook constructor in order: the mainnet `IPoolManager`, then the just-created token. The manifest resolves these as `"$poolManager"` and `"$token"`; no launch-token address is guessed in advance.
3. Mine a CREATE2 salt for the **actual factory that executes CREATE2**, using `type(SIMDTESTHook).creationCode` plus the two ABI-encoded constructor arguments. `script/HookAddressMiner.s.sol` provides `run(create2Deployer, launchToken, start, attempts)` as a read-only planner returning predicted address, salt and creation bytes. It has no wallet configuration or broadcast behavior. Its public function is tested directly.
4. Deploy `SIMDTESTHook` itself at the mined address and initialize its sorted-currency pool **atomically in the same launch transaction**. Atomicity prevents an outsider from opening the pool at an unwanted price or starting the timers first. The initialization permission prevents a pool at the predicted hook address from opening before hook code exists. There is no proxy, wrapper, or factory privilege in the hook.
5. Seed the position, execute the factory's allocation, attest the constructor arguments and deployed bytes, and verify the source. Re-run the fork rehearsal against current mainnet state before release.

The deployer must use chainId 1 and the stated mainnet manager, correct CREATE2 executor and token, intended economic opening price, and atomic deployment/initialization. There are no after-launch setters or administrative keys. The present assignment makes no live deployment.

The adversarial review, arithmetic arguments, tested attacks, and remaining review responsibilities are in [docs/SECURITY.md](docs/SECURITY.md). The local manifest checker checks the required shapes and this project's invariants; the contributor network's full manifest validator remains authoritative.
