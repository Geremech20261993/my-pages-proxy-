# NativeSweep — Phase-by-Phase Build Log

## Run it locally
```bash
forge init --no-git .          # or: forge install foundry-rs/forge-std
# copy src/ and test/ into place
forge fmt --check              # Phase 3: lint
forge build                    # compile
forge test -vvv                # Phase 4: tests
forge coverage                 # optional: confirm coverage
slither .                      # optional: deeper static analysis
```

## What each phase caught
- **Phase 3 (lint):** naive `.transfer()`/`.send()` grep check false-positived on a
  doc comment that *mentions* those methods — fixed the checker, not the contract.
- **Phase 4 (tests):** wrote a reentrancy attacker + gas-hungry receiver + rejecting
  receiver to exercise every revert path, not just the happy path.
- **Phase 5 (self-check):** found two real bugs before they ever hit a compiler:
  1. Hand-rolled `bytes4` selector for `ReentrancyGuard()` in raw assembly was
     wrong/fragile — replaced with a plain Solidity `revert CustomError()`, keeping
     assembly only for the `tload`/`tstore` gas-sensitive part.
  2. Reentrancy test had a circular-dependency bug (attacker needs the sweep
     contract's address, sweep contract needs the attacker's address as owner) —
     fixed with a test-only `setTarget()` setter, and tightened the assertion to
     check the *specific* revert reason (`ReentrancyGuard.selector`) rather than
     any revert.

## Scope
This is intentionally ONE reusable primitive — safe native-token sweeping with a
transient-storage reentrancy guard — not a flash-loan router, swap executor, or
MEV/bribe system. Compose it into larger systems only after each of those larger
systems has gone through its own audit.
