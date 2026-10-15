# Vendored dependencies

These are ordinary source files, not submodules. No dependency installation or
network access is needed to build or test with the pinned compiler installed.

| Dependency | Pinned release | Source | Included files | License |
| --- | --- | --- | --- | --- |
| OpenZeppelin Contracts | v5.1.0 | https://github.com/OpenZeppelin/openzeppelin-contracts/tree/v5.1.0 | `ERC20`, `IERC20`, `IERC20Metadata`, `Context`, `draft-IERC6093`, and `LICENSE` | MIT |
| Forge Standard Library | v1.9.7 | https://github.com/foundry-rs/forge-std/tree/v1.9.7 | Entire `src/` directory and both license files | MIT or Apache-2.0 |

Source contents are unchanged from those releases. Only the transitive production
imports are included from OpenZeppelin. Forge Standard Library is used only for
tests; it is not part of the token runtime. `SHA256SUMS` records the included
dependency sources and licenses; paths are relative to this directory.
