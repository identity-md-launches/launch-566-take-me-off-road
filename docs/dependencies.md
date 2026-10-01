# Offline dependencies

All dependencies are ordinary source files under `lib/`. No submodules, package installation, FFI, network RPC, or filesystem cheatcodes are needed by the tests.

The source bundle is the published [`@uniswap/v4-core` 1.0.2 package](https://registry.npmjs.org/@uniswap/v4-core/1.0.2), retrieved from its registry tarball. Its declared source commit is `59d3ecf53afa9264a16bba0e38f4c5d2231f80bc`.

Tarball SHA-256: `f3db3af55f3d0c52f16abe96e7db12443f243bca1f334962373f95c57611de49`.

| Directory | Contents | Version in bundle | License files |
| --- | --- | --- | --- |
| `lib/v4-core` | Upstream Solidity source, package identity, licenses | 1.0.2 | `licenses/` and source SPDX identifiers |
| `lib/forge-std` | Test library bundled by v4-core | 1.9.3 | `LICENSE-APACHE`, `LICENSE-MIT` |
| `lib/solmate` | Upstream source used by the local PoolManager | 6.2.0 | `LICENSE` and source SPDX identifiers |
| `lib/openzeppelin-contracts` | Upstream contracts referenced by core | 5.0.2 | `LICENSE` |

Upstream artifacts, caches, deployment scripts, repository metadata and package-manager installations are omitted. Dependency source is unmodified. The delivered hook uses internal v4 libraries and interfaces; the token is self-contained. The local test PoolManager is upstream v4-core code, including its separate protocol-fee ownership machinery, which grants no administrative powers over either delivered contract.

The host must provide Foundry and the pinned Solidity 0.8.26 compiler. No compiler binary is part of this repository. Foundry configuration does not enable FFI or filesystem access.
