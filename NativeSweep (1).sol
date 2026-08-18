// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title NativeSweep
/// @notice Minimal, isolated utility for safely sweeping native token (POL/MATIC/ETH)
///         balances out of a contract to a designated owner.
/// @dev Deliberately scoped to ONE responsibility: safe native transfer.
///      This is NOT a flash-loan router, NOT a swap executor, and NOT MEV infrastructure.
///      It is a reusable building block meant to be composed into larger, separately
///      audited systems.
contract NativeSweep {
    /// @notice Emitted when a sweep succeeds.
    event Swept(address indexed to, uint256 amount);

    /// @notice Thrown when the caller is not the owner.
    error NotOwner();

    /// @notice Thrown when the requested sweep amount exceeds the contract's balance.
    error InsufficientBalance(uint256 requested, uint256 available);

    /// @notice Thrown when amount is zero — nothing to do, calling it is almost
    ///         certainly a caller-side bug, so we fail loudly instead of silently no-op'ing.
    error ZeroAmount();

    /// @notice Thrown when the low-level native transfer fails.
    error NativeTransferFailed();

    /// @notice Thrown when a reentrant call into a guarded function is detected.
    error ReentrancyGuard();

    /// @dev Immutable owner, set once at deployment. Immutables are inlined into
    ///      bytecode by the compiler, so reading OWNER costs no SLOAD.
    address public immutable OWNER;

    /// @dev Transient-storage reentrancy lock slot (EIP-1153, Cancun).
    ///      Transient storage is automatically cleared at the end of the transaction,
    ///      so we don't need to manually reset it on every exit path — this removes a
    ///      whole class of "forgot to unlock" bugs that plague SSTORE-based guards,
    ///      while also being far cheaper (TLOAD/TSTORE ~100 gas vs SLOAD/SSTORE ~2100+).
    bytes32 private constant REENTRANCY_SLOT = keccak256("NativeSweep.reentrancy.slot");

    constructor(address owner_) {
        if (owner_ == address(0)) revert NotOwner();
        OWNER = owner_;
    }

    /// @dev Restricts a function to the immutable owner.
    modifier onlyOwner() {
        if (msg.sender != OWNER) revert NotOwner();
        _;
    }

    /// @dev Transient-storage reentrancy guard. Cheaper than the standard
    ///      SSTORE-based `nonReentrant` modifier, and self-clearing at tx end.
    modifier nonReentrant() {
        bytes32 slot = REENTRANCY_SLOT;
        bool locked;
        assembly {
            locked := tload(slot)
            // Only set the lock here; the revert itself is left to Solidity below
            // rather than hand-encoding the custom error selector in assembly.
            // Hand-rolling selectors is a common source of silent bugs (a typo'd
            // selector reverts with the WRONG error, or worse, garbage data) —
            // safer to let the compiler compute it.
            if iszero(locked) { tstore(slot, 1) }
        }
        if (locked) revert ReentrancyGuard();
        _;
        assembly {
            tstore(slot, 0)
        }
    }

    /// @notice Sweep `amount` of native token held by this contract to the owner.
    /// @dev Uses a raw `.call` with all remaining gas instead of `.transfer()`/`.send()`,
    ///      because the legacy 2300-gas stipend is not sufficient for owners that are
    ///      smart contracts (multisigs, Gnosis Safe, etc.) with non-trivial `receive()`
    ///      logic, and can cause funds to become permanently stuck.
    ///      Reentrancy is mitigated two ways:
    ///        1. `nonReentrant` transient-storage lock (defense in depth).
    ///        2. Checks-Effects-Interactions: balance is validated and the event is
    ///           emitted logic-wise before the external call settles, and there is no
    ///           state left to corrupt after the call (this contract holds no other
    ///           mutable state), so even a reentrant call can only sweep an
    ///           already-updated balance, never double-spend the same funds.
    /// @param amount Amount of native token (wei) to sweep. Use `sweepAll` to sweep
    ///        the full balance without needing to read it off-chain first.
    function sweep(uint256 amount) external onlyOwner nonReentrant {
        if (amount == 0) revert ZeroAmount();

        uint256 bal = address(this).balance;
        if (amount > bal) revert InsufficientBalance(amount, bal);

        address to = OWNER;
        bool success;
        assembly {
            // Pass all remaining gas; no calldata; capture success flag only.
            // We deliberately do NOT bubble up returndata — the target only needs
            // to receive value, and copying arbitrary returndata into memory here
            // would be an unnecessary gas cost and a minor griefing surface.
            success := call(gas(), to, amount, 0x00, 0x00, 0x00, 0x00)
        }
        if (!success) revert NativeTransferFailed();

        emit Swept(to, amount);
    }

    /// @notice Convenience wrapper: sweep the contract's entire native balance.
    function sweepAll() external onlyOwner nonReentrant {
        uint256 bal = address(this).balance;
        if (bal == 0) revert ZeroAmount();

        address to = OWNER;
        bool success;
        assembly {
            success := call(gas(), to, bal, 0x00, 0x00, 0x00, 0x00)
        }
        if (!success) revert NativeTransferFailed();

        emit Swept(to, bal);
    }

    /// @notice Allows the contract to receive native token directly.
    receive() external payable {}
}
