# Vendored dependencies

Everything under `lib/` is committed as ordinary files — no git submodules, no package manager, no network
needed to build or test. Each entry records the upstream, the exact commit, and what was copied so the pin can
be audited or refreshed by hand.

| Path            | Upstream                                          | Pin                                                 | Copied                                                                                          |
| --------------- | ------------------------------------------------- | --------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| `lib/v4-core`   | https://github.com/Uniswap/v4-core                | tag `v4.0.0` = `46c6834698c48bc4a463a86d8420f4eb1d7f3b75` | `src/` (see note), `test/utils/{CurrencySettler,Constants,LiquidityAmounts}.sol`, `licenses/`   |
| `lib/forge-std` | https://github.com/foundry-rs/forge-std           | tag `v1.16.2` = `bf647bd6046f2f7da30d0c2bf435e5c76a780c1b` | `src/`, `LICENSE-MIT`, `LICENSE-APACHE`                                                          |
| `lib/solmate`   | https://github.com/transmissions11/solmate        | `4b47a19038b798b4a33d9749d25e570443520647` (v4-core's own pin) | `src/`, `LICENSE`                                                                     |

## Notes

- **v4-core `src/test/ProxyPoolManager.sol` is omitted.** It is a delegatecall proxy used only by v4-core's own
  test suite and is the single file in `src/` that imports OpenZeppelin. Nothing here uses it; dropping it means
  OpenZeppelin does not need to be vendored. Every other file under v4-core's `src/` is byte-for-byte upstream.
- The three files copied from v4-core's `test/utils/` are the ones its `src/test/` routers (`PoolSwapTest`,
  `PoolModifyLiquidityTest`, `PoolDonateTest`, …) import via `../../test/utils/`. They are libraries, not tests.
- solmate is a transitive dependency of v4-core (`Owned` under `ProtocolFees`, `MockERC20` under
  `ActionsRouter`) and is also what this project's `test/mocks/MockERC20.sol` extends.
- Remappings live in `foundry.toml`: `forge-std/`, `v4-core/`, `solmate/`.
- Forge only compiles files under `src/`, `test/` and `script/` plus whatever they import, so the parts of these
  libraries this project does not touch cost nothing at build time.

## Refreshing a pin

Clone the upstream at the new commit, copy the same paths over the existing directory, update the table above,
then run `forge build && forge test && forge fmt --check`. The protected admission checks are `pragma solidity
0.8.26`, so a v4-core bump that raises its own compiler floor past 0.8.26 cannot be taken without revisiting
`foundry.toml`.
