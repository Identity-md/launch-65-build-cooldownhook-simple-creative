# CooldownHook

A small Uniswap v4 hook: **each address may swap at most once per pool every N blocks.** N is fixed when the hook
is deployed and must be between 1 and 1000. There is one callback (`beforeSwap`), one storage mapping, no owner,
no admin, no upgrade path, and no dependency on the pool's fee tier.

This repository is source and tests for publication. It contains no token, no deployment script, no launch
manifest and no website.

## The rule

If an address last swapped in pool `P` at block `B`, its next swap in `P` is:

| Block                    | Result                             |
| ------------------------ | ---------------------------------- |
| `B` … `B + N - 1`        | reverts with `SwapCooldownActive`  |
| `B + N` and later        | accepted; the window restarts here |

So `N = 1` means "once per block", and `N = 10` means the 2nd swap can land ten blocks after the 1st. The window
is measured from the most recent *accepted* swap — rejected attempts record nothing and do not extend it.

What does **not** matter: swap direction (`zeroForOne` either way is a swap), swap size, exact-in vs exact-out,
the pool's fee tier, and `hookData`. What **is** kept apart:

- **Pools.** State is keyed `PoolId → address → block`. A swap in pool A never consumes pool B's allowance, even
  for the same address and the same hook instance, and even when A and B are the same token pair at different
  tick spacings.
- **Addresses.** Two distinct `sender`s in the same pool and block are two independent windows.

Liquidity and donations are untouched. The hook declares no liquidity callbacks at all, so LPs can add and —
more importantly — remove liquidity at any time, cooldown or not. Tests prove a full exit while a swapper is
mid-cooldown.

## Whose cooldown is it? (the router assumption)

The `sender` that `PoolManager` passes to `beforeSwap` is **the address that called `PoolManager.swap`** — in
practice the router, or whichever contract took the unlock. It is never the end user's EOA. That address is the
only identity the manager actually attests, so it is the only one this hook uses.

Consequences, all deliberate and all tested:

- **A shared router is one swapper.** If Alice and Bob both swap through the same router contract, Bob is
  rate-limited by Alice's swap. `test_senders_usersOfASharedRouterShareOneCooldown` shows exactly this.
- **A user who wants their own window must be their own `sender`** — swap through a contract they alone control
  (a smart account, a personal unlock-callback contract, a per-user proxy). Any such contract is its own identity.
- **`hookData` is ignored.** An address inside `hookData` is a claim made by the router, not a fact the manager
  vouches for. A router that says "this is really Bob" is still the router, and a router that says nothing
  afterwards is still rate-limited. `test_hookData_isIgnoredForIdentity` covers it.
- **This is a rate limiter, not an anti-Sybil device.** Because any fresh contract is a fresh identity, an actor
  willing to deploy contracts can swap as often as they have contracts. The hook bounds swap frequency *per
  address*; it does not bound it per person. Do not describe it as doing so.

A router that wanted to give each of its users a separate window under this hook would have to be written so
that each user is a distinct `PoolManager.swap` caller — the hook itself will never accept identity from
`hookData` or from anything else the router asserts.

## Security posture

- **Every callback authenticates the caller.** `beforeSwap` reverts `NotPoolManager` unless `msg.sender` is the
  `PoolManager` fixed at construction. The other nine `IHooks` callbacks revert `HookNotImplemented` for every
  caller, manager included; the address does not advertise them so the manager never calls them anyway.
- **Permissions are exactly `beforeSwap`.** `getHookPermissions()` declares it and nothing else; the constructor
  runs `Hooks.validateHookPermissions` and refuses to deploy to an address whose low 14 bits disagree. No
  `*ReturnDelta` flag is set: the hook gates the swap and never reshapes it. It returns `ZERO_DELTA` and a zero
  fee override, so it works identically on static-fee and dynamic-fee pools and never touches an LP fee.
- **No privileged surface.** No owner, no pause, no setter, no upgrade. `cooldownBlocks` and `poolManager` are
  immutables. Runtime code contains no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT` (checked by the admission
  suite). The hook never holds funds and makes no external calls.
- **No initialize callbacks.** The design needs nothing from the pool — not a dynamic fee, not a particular tick
  spacing — so there is nothing to validate at `afterInitialize`, and a pool binding this hook opens without the
  hook ever running (`test_initialize_doesNotInvolveTheHook`).
- **Gas.** `beforeSwap` is one `SLOAD`, one comparison, one `SSTORE` and one event — well under the 50k target
  for a hot-path callback. Only the first swap per (pool, address) pays a cold slot.
- **Not audited.** Tests passing is not an audit. Anything that routes other people's funds through this hook
  should get an independent adversarial review first.

## Deployment parameters

The hook takes two constructor arguments and requires one property of its address.

| Parameter        | Type           | Constraint                                     | Notes                                                                                                  |
| ---------------- | -------------- | ---------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| `_poolManager`   | `IPoolManager` | non-zero                                       | The canonical `PoolManager` on the target chain. Take it from Uniswap's published deployments, not from a README. Baked in forever. |
| `_cooldownBlocks`| `uint256`      | `1 ≤ N ≤ 1000`                                 | Blocks, not seconds. Translate with the chain's block time: on a 12-second chain `N = 5` is about a minute, `N = 300` about an hour; on a 2-second chain divide accordingly. |
| address          | —              | low 14 bits `== 0x0080` (`HookFlags.COOLDOWN_HOOK`, decimal `128`) | Mined with CREATE2. `test/utils/HookMiner.sol` is the search the tests use; the same loop works in a script. The address depends on the deployer, the salt and the full init code (bytecode **plus** encoded constructor args), so mine after fixing both arguments and deploy from the address you mined for. |

A mis-mined address fails at deployment (`HookAddressNotValid`), not at the first swap. `foundry.toml` sets
`bytecode_hash = "none"` so the init code, and therefore the mined address, does not shift with source path or
metadata differences between machines.

There is no deployment script here on purpose. When one is written, it should do exactly: pick `N`, mine a salt
for flags `0x80`, `CREATE2` the hook, verify `getHookPermissions()`/address agreement on-chain, and stop. Pools
bind the hook via their `PoolKey.hooks`; the hook has no registry and no say in which pools use it.

## Operational responsibilities

Because there are no admin powers there is nothing to operate, but there are a few things to know:

- **Changing N means a new hook and new pools.** A deployed cooldown is permanent. Pool creators who want a
  different window deploy another instance and open pools against it.
- **Pool creators choose to opt in**, by setting `PoolKey.hooks` to this address. Nothing here can attach the hook
  to a pool, detach it, or affect pools that did not choose it.
- **Observability.** Every accepted swap emits `SwapRecorded(poolId, swapper, blockNumber, nextAllowedBlock)`.
  `lastSwapBlock(poolId, swapper)`, `nextAllowedBlock(poolId, swapper)` and `canSwap(poolId, swapper)` are
  public views for integrators to pre-check before spending gas on a swap that would revert.
- **Revert shape.** Integrators will see the hook's `SwapCooldownActive(poolId, swapper, lastSwapBlock,
  nextAllowedBlock)` wrapped in v4-core's ERC-7751 `WrappedError(hook, beforeSwap.selector, reason,
  HookCallFailed())`. The tests assert on the exact wrapped encoding.
- **Front ends must explain the router assumption** to users, or run each user through their own `sender`.
- **Block-zero corner.** A recorded block of `0` is read as "never swapped". Block 0 carries no user transactions
  on any chain this could be deployed to, so this has no practical effect; it is noted for completeness.

## Tests

```
forge build
forge test
forge fmt --check
```

All three run offline; every dependency is vendored under `lib/` (see `lib/VENDOR.md`) and the compiler is
pinned to `solc 0.8.26`, `evm_version = "cancun"`, `ffi = false`, no filesystem permissions.

`test/CooldownHook.t.sol` runs against a real `PoolManager` from vendored v4-core `v4.0.0`: it deploys the hook
via a mined CREATE2 salt exactly as production would, initialises pools, seeds full-range liquidity through
`PoolModifyLiquidityTest`, and swaps through two instances of `PoolSwapTest` (two independent `sender`s).
Coverage, by section:

- **Construction / permissions** — both bounds accepted, 0 and 1001 rejected (plus a fuzz over every out-of-range
  N), zero manager rejected, a non-flagged address rejected by the constructor, permissions and address bits
  agree.
- **Success paths** — first swap trades and records; accepted exactly at `B + N`; accepted long after; the window
  restarts from the latest accepted swap.
- **Failure paths** — same block, opposite direction, `B + N - 1`, every block inside the window, and a fuzz over
  `N ∈ [1, 1000]` × `elapsed ∈ [0, 2N]` with a fresh hook per run. A rejected swap leaves price and balances
  unchanged and records nothing.
- **Isolation** — two pools independent; a swap in one starts nothing in the other; same pair at different tick
  spacings independent; two routers independent; two EOAs behind one router share a window; `hookData` cannot
  change identity.
- **LP and donate** — add/remove during an active cooldown; full liquidity exit with tokens returned; donate
  unaffected.
- **Pool shapes** — a `DYNAMIC_FEE_FLAG` pool works and its fee is not overridden; initialize never calls the hook.
- **Authentication** — every `IHooks` callback refuses non-manager callers; undeclared callbacks refuse the
  manager too; the manager itself is accepted and the cooldown then applies.

A quick mutation check was run while writing these (off-by-one in the boundary comparison; removed manager
authentication; state not keyed by pool). Each mutation fails multiple tests.

### Admission suite

The contributor-network admission checks (`Hook.protected.t.sol`, `Token.protected.t.sol`) are external to this
repository and are run against the attested creation code. They expect `src/HookFlags.sol` and
`test/mocks/MockERC20.sol`, both provided here, and read three environment variables:

| Variable                  | Value for this hook                                                          |
| ------------------------- | ---------------------------------------------------------------------------- |
| `IMD_HOOK_CREATION_CODE`  | `type(CooldownHook).creationCode ++ abi.encode(poolManager, cooldownBlocks)` |
| `IMD_HOOK_FLAGS`          | `128` (`0x80`, `beforeSwap` only)                                            |
| `IMD_POOL_MANAGER`        | the `poolManager` address encoded above                                      |

There is no token, so the token half of that suite skips. Both halves were exercised locally during development
and pass; they are not committed because they cannot run without the variables above.

## Layout

```
src/CooldownHook.sol        the hook
src/HookFlags.sol           the 14 permission bits + flagsOf/matches, mirrored from v4-core's Hooks.sol
test/CooldownHook.t.sol     the suite described above
test/utils/HookMiner.sol    CREATE2 salt search for a flagged address
test/mocks/MockERC20.sol    18-decimal ERC-20 minting to deployer (solmate ERC20)
lib/                        vendored v4-core v4.0.0, forge-std v1.16.2, solmate — see lib/VENDOR.md
foundry.toml                pinned solc 0.8.26 / cancun, ffi off, no fs permissions
```

## License

MIT for the code in `src/` and `test/`. Vendored libraries keep their own licenses under `lib/*/`
(v4-core: BUSL-1.1 for `PoolManager` and MIT for libraries/interfaces/types — see `lib/v4-core/licenses/`).
