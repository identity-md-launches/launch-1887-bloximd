# BloxIMD test coverage

The tests exercise the actual `src/BloxIMD.sol` contract and its vendored ERC-20
implementation. They require no RPC, fork, FFI, new dependencies, or environment
changes from Solidity tests.

| Suite | Coverage |
| --- | --- |
| `BloxIMD.t.sol` | Metadata, constructor mint and event, exact transfers, approvals, failures, and five fuzz properties. |
| `BloxIMDLaunch.t.sol` | Existing CREATE2 deployment, token distribution, absent administrator privileges, and runtime opcode checks. |
| `BloxIMDEdgeCases.t.sol` | Smallest unit, maximum finite and infinite approvals, revocation and exhaustion, owner isolation, account aliasing, zero addresses, failed-call retries, nonpayable calls, transaction rollback, and four fuzz properties. |
| `BloxIMDInvariant.t.sol` | Four actors and seven actions, with balance and allowance reference ledgers checked after random calls. |

Fuzz properties use 1,000 cases each. The invariant campaign uses 256 sequences
of 128 calls. These settings live in inline test annotations, without changing
the project configuration.

The invariant properties are:

- The sum of tracked balances and the reported supply both remain exactly
  `1_000_000_000 * 10**18`, including after failed calls and self transfers.
- Each actor's balance matches the reference ledger; transfers cannot silently
  send value to a different account or introduce a fee.
- Each owner/spender allowance matches the reference ledger. Finite approvals
  decrease only on successful delegated transfers; unlimited approvals remain
  unlimited until replaced or revoked. Failed calls cannot consume allowances.
- Zero-address balances and allowances stay zero, and metadata stays fixed.

The handler deliberately selects zero, one minor unit, full spendable amounts,
overspending, arbitrary approvals, and both sides of the finite/infinite approval
boundary. Expected token reverts are caught and their error data checked;
unexpected handler reverts fail the campaign. A deterministic handler test also
exercises nonzero transfers, replacement, revocation, and rejection paths.

The batch rollback test uses a helper so both token calls occur in one
transaction. Its successful retry checks that the reverted transaction left the
original balance and approval usable.

Run the same seed as the verifier, keeping generated artifacts in scratch:

```sh
forge build --offline --out test/scratch/out --cache-path test/scratch/cache
FOUNDRY_FUZZ_SEED=0x68f6d107c97cc29b622d8b7aebde21b37ea4c15569f14afa938954ce054027bb forge test --offline --out test/scratch/out --cache-path test/scratch/cache
```

The local launch suite tests token movements. The supplied protected owner and
Uniswap v4 tests depend on the network's factory harness and launch manifest,
which are absent from this repository; the verifier runs that integration.
