# Tidewell contracts

Smart contracts of [Tidewell](https://tidewellfi.app): automated Uniswap liquidity management on Robinhood Chain (chain id 4663).

This repository holds the on-chain code, its tests and the deployed addresses. The website, the keeper and the vote server are not part of it.

## Contracts (`contracts/src`)

| Contract | What it does |
| --- | --- |
| `TidewellFactory` | Creates a vault per user and keeps the list of reviewed hooks. |
| `TidewellVaultV3` / `TidewellVaultV4` | A user's own vault for Uniswap v3 and v4 positions (shared logic in `TidewellVaultBase`). |
| `TidewellShapedVaultV3` / `TidewellShapedVaultV4` | The same with shaped liquidity (several bands, see `libraries/Shapes*.sol`). |
| `TidewellSwapper` | Swaps used by the vaults. |
| `ReferralRegistry` | Referral links. |
| `RevenueRouter` | Receives protocol revenue and splits it. |
| `TheWell` | TIDE staking: fee discount and a steady ETH reward stream for stakers. |
| `BuybackBurner` | Buys TIDE and burns it. |
| `Reserve` | Holds ETH for one purpose (safety fund, boosted-pools reserve, expansion reserve). Payments out only through the 48-hour timelock, with a reason. |
| `BoostDistributor` | Boosted pools: pays ETH rewards to liquidity providers of the pools that won the vote, in rounds. |

Admin rights sit behind a 48-hour timelock, owned by a Safe multisig.

## Deployed addresses

See [`deployments/mainnet.json`](deployments/mainnet.json), [`deployments/mainnet-shapes.json`](deployments/mainnet-shapes.json) and [`deployments/mainnet-boost.json`](deployments/mainnet-boost.json).

Verify the code yourself: compare the source here with the verified source on the block explorer of Robinhood Chain.

## Build and test

You need [Foundry](https://book.getfoundry.sh/).

```
cd contracts
./install-deps.sh      # downloads the libraries at pinned versions
forge build
forge test --no-match-path "test/fork/*"
```

Tests in `contracts/test/fork/` run against a copy of Robinhood Chain mainnet and need a node:

```
forge test --match-path "test/fork/*" --fork-url <RPC_URL>
```

GitHub runs all tests on every push (`.github/workflows/contracts.yml`).

## Status

Audits: none published yet. The contracts are live, so read the code and use them at your own risk.

## Security

See [SECURITY.md](SECURITY.md).

## License

MIT, see [LICENSE](LICENSE). Third-party parts: see [NOTICE.md](NOTICE.md).
