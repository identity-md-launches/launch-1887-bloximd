# BloxIMD (BLOX)

<img src="assets/blox-logo.jpg" alt="Blox profile avatar: a yellow B built from bricks on a blue background" width="200" height="200">

BloxIMD is an immutable ERC-20 token. Its constructor mints **1,000,000,000 BLOX**,
with **18 decimals**, to the immediate deploying caller. For the IdentityMD launch,
that caller is the launch factory. There is no subsequent minting, burning, tax,
pause, blacklist, owner, upgrade mechanism, or application contract.

## Build and test

Run from the repository root with Foundry and Solidity 0.8.26 available:

```sh
forge build
FOUNDRY_FUZZ_SEED=0x68f6d107c97cc29b622d8b7aebde21b37ea4c15569f14afa938954ce054027bb forge test
forge fmt --check
```

The compiler version, optimizer settings, Cancun target, and `bytecode_hash = "none"`
are pinned in [foundry.toml](foundry.toml). All Solidity dependencies are ordinary
files under `lib/`; no downloads, submodules, RPC, environment values, filesystem
permissions, or FFI are needed by the contracts or tests. The test seed above is
the verifier's seed; tests themselves never read or change the environment.

- [src/BloxIMD.sol](src/BloxIMD.sol): the only production contract.
- [test/BloxIMD.t.sol](test/BloxIMD.t.sol): ERC-20 behavior, events, failure rollback,
  zero and maximum values, self transfers, allowances, and five fuzz properties.
- [test/BloxIMDLaunch.t.sol](test/BloxIMDLaunch.t.sol): CREATE2 factory deployment,
  exact launch distribution and claim movements, pool custody transfers in both
  directions, absent administrative powers, and forbidden opcode checks.
- [test/BloxIMDInvariant.t.sol](test/BloxIMDInvariant.t.sol): randomized sequences
  across four holders checked against a separate balance and allowance ledger.
  Invariants run 128 sequences of depth 64; fuzz properties run 512 cases each.

The local pool custody test exercises token transfers, not a live AMM or a swap
price calculation. The provided network checks additionally exercise a real
Uniswap v4 PoolManager using the network's launch harness and resolved manifest.
Those network-owned dependencies and launch configuration are not part of this
repository, so the full protected integration suite is run by the verifier.

## Token behavior and assumptions

The brief specifies ordinary transfers and a single constructor mint. Standard
OpenZeppelin ERC-20 v5.1.0 behavior supplies the transfer and approval rules:

- `name()` is `BloxIMD`; `symbol()` is `BLOX`; `decimals()` is `18`.
- `INITIAL_SUPPLY()` and `totalSupply()` equal
  `1000000000000000000000000000` smallest units (10^27).
- `transfer` and `transferFrom` deliver exactly the requested amount, return
  `true` on success, and emit `Transfer`. Invalid operations revert with ERC-6093
  custom errors; failed operations preserve balances and allowances.
- Zero-amount transfers to a nonzero address and self transfers are supported.
  Transfers to the zero address and approvals to the zero spender revert.
- `approve` replaces the caller's allowance and emits `Approval`. Finite
  allowances decrease on spending; `type(uint256).max` remains unchanged.
  OpenZeppelin v5 does not emit `Approval` when `transferFrom` spends allowance.
- `transferFrom` needs allowance even when a factory or the holder calls it.
  Holders can always call `transfer` directly without allowance.
- There are no external callbacks, signatures, or external contract dependencies.
  The token's constructor requires no initialization call or constructor arguments.

## Deployment parameters

| Parameter | Value |
| --- | --- |
| Target chain | Ethereum, chain ID 1 |
| Solidity artifact | `src/BloxIMD.sol:BloxIMD` |
| Contract identifier | `BloxIMD` |
| Constructor arguments | Empty (`[]`) |
| Constructor transaction value | 0 ETH |
| Supply recipient | Immediate deploying caller (`msg.sender`), the launch factory |
| Decimals | 18 |
| Supply in smallest units | `1000000000000000000000000000` |
| Initialization / owner / linked libraries | None |

The launch system deploys the compiled creation bytecode through its factory.
Deploying through a different caller will mint to that caller; this is intentional
and tested. Do not use a helper that deploys and then abandons its token balance.
Creation bytecode can be inspected locally without submitting any transaction:

```sh
forge inspect src/BloxIMD.sol:BloxIMD bytecode
```

The launch system owns the manifest and pool setup. The supplied launch terms are:
native ETH pairing, fee `12500` (1.25%), tick spacing `60`, and provenance initial
price `79228162514264337593543950336`. The factory derives the actual opening price
from the 10 ETH initial market capitalization
(`initialMarketCapWei = "10000000000000000000"`), supply, and final token address.

The factory distributes the constructor's full balance: 10% to its swarm
distributor, 88% to pool seeding (`poolBps = 8800`), and the remaining 2% to
`0xbdd848d77af9e2a9c8def8fbfa6fd3a36c7dfde7`. These are launch responsibilities;
the token constructor only mints the full supply to its caller. No addresses or
allocations are embedded in the token. No `launch.json` or transactions are
produced by this project.

## Logo

[assets/blox-logo.jpg](assets/blox-logo.jpg) is the unchanged 400 × 400 profile
avatar from [@blox_imd](https://x.com/blox_imd), selected as the token logo. Its
original X image URL, retrieval date, and SHA-256 are recorded in
[assets/provenance.json](assets/provenance.json). The image is vendored so the
delivered logo does not depend on X or an image proxy remaining available.

ERC-20 has no standard logo field. The launch operator should use this local
asset in the token listing and submit or host it for wallet/explorer metadata
after the actual deployment address is known. No address or hosted logo URL has
been fabricated. The code license does not license the account's artwork.

## After launch

There are no owner-settable parameters, keepers, or ongoing contract maintenance.
The network's deployer is responsible for deploying the accepted artifact,
performing the specified distribution and pool setup, publishing verified source,
and checking the resulting address, name, symbol, decimals, total supply, and
allocation events. The requester/operator maintains the public logo and listing
metadata. The deployment address is assigned by that later launch process.

Holders control transfers and allowances. Use bounded approvals for trusted
spenders; revoke an existing allowance before replacing it when avoiding the
standard ERC-20 approval transaction-ordering risk. Tokens sent to this token
contract or another address without a recovery path cannot be rescued by an
administrator. Ordinary ETH transfers to the token revert.

See [SECURITY.md](SECURITY.md) for the security review and validation limits, and
[lib/README.md](lib/README.md) for dependency versions and licenses.
