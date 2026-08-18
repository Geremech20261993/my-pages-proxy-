// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {NativeSweep} from "../src/NativeSweep.sol";

/// @dev Malicious receiver that attempts to reenter `sweep`/`sweepAll` on receipt
///      of native token, to prove the transient-storage guard blocks it.
contract ReentrantAttacker {
    NativeSweep public target;
    bool public attacked;
    bytes public lastRevertReason;

    constructor(NativeSweep _target) {
        target = _target;
    }

    /// @dev Test-only setter to break the circular dependency between the
    ///      attacker (which needs to know the sweep contract's address) and the
    ///      sweep contract (which needs the attacker's address as its owner).
    function setTarget(NativeSweep _target) external {
        target = _target;
    }

    receive() external payable {
        if (!attacked) {
            attacked = true;
            // Attempt reentrant call — must revert due to nonReentrant guard.
            try target.sweepAll() {
                revert("REENTRANCY SUCCEEDED - VULNERABLE");
            } catch (bytes memory reason) {
                // Capture the revert reason so the test can assert it was
                // specifically ReentrancyGuard() and not some unrelated failure.
                lastRevertReason = reason;
            }
        }
    }
}

/// @dev Receiver that deliberately burns more than 2300 gas on receive(),
///      to prove `.call` (not `.transfer()`) is required for this to succeed.
contract ExpensiveReceiver {
    uint256 public counter;

    receive() external payable {
        // Burn gas well beyond the 2300 stipend .transfer()/.send() would allow.
        for (uint256 i = 0; i < 50; i++) {
            counter += i;
        }
    }
}

contract NativeSweepTest is Test {
    NativeSweep sweep_;
    address owner = makeAddr("owner");
    address stranger = makeAddr("stranger");

    function setUp() public {
        sweep_ = new NativeSweep(owner);
    }

    // ---------------------------------------------------------------
    // Happy path
    // ---------------------------------------------------------------

    function test_sweep_transfersExactAmountToOwner() public {
        vm.deal(address(sweep_), 10 ether);
        uint256 ownerBalBefore = owner.balance;

        vm.prank(owner);
        sweep_.sweep(4 ether);

        assertEq(owner.balance, ownerBalBefore + 4 ether);
        assertEq(address(sweep_).balance, 6 ether);
    }

    function test_sweepAll_transfersEntireBalance() public {
        vm.deal(address(sweep_), 7.5 ether);

        vm.prank(owner);
        sweep_.sweepAll();

        assertEq(owner.balance, 7.5 ether);
        assertEq(address(sweep_).balance, 0);
    }

    function test_sweep_emitsSweptEvent() public {
        vm.deal(address(sweep_), 1 ether);
        vm.expectEmit(true, false, false, true);
        emit NativeSweep.Swept(owner, 1 ether);

        vm.prank(owner);
        sweep_.sweep(1 ether);
    }

    // ---------------------------------------------------------------
    // Access control
    // ---------------------------------------------------------------

    function test_sweep_revertsForNonOwner() public {
        vm.deal(address(sweep_), 1 ether);
        vm.prank(stranger);
        vm.expectRevert(NativeSweep.NotOwner.selector);
        sweep_.sweep(1 ether);
    }

    function test_sweepAll_revertsForNonOwner() public {
        vm.deal(address(sweep_), 1 ether);
        vm.prank(stranger);
        vm.expectRevert(NativeSweep.NotOwner.selector);
        sweep_.sweepAll();
    }

    function test_constructor_revertsOnZeroAddressOwner() public {
        vm.expectRevert(NativeSweep.NotOwner.selector);
        new NativeSweep(address(0));
    }

    // ---------------------------------------------------------------
    // Edge cases / input validation
    // ---------------------------------------------------------------

    function test_sweep_revertsOnZeroAmount() public {
        vm.deal(address(sweep_), 1 ether);
        vm.prank(owner);
        vm.expectRevert(NativeSweep.ZeroAmount.selector);
        sweep_.sweep(0);
    }

    function test_sweepAll_revertsWhenBalanceIsZero() public {
        vm.prank(owner);
        vm.expectRevert(NativeSweep.ZeroAmount.selector);
        sweep_.sweepAll();
    }

    function test_sweep_revertsWhenAmountExceedsBalance() public {
        vm.deal(address(sweep_), 1 ether);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(NativeSweep.InsufficientBalance.selector, 2 ether, 1 ether)
        );
        sweep_.sweep(2 ether);
    }

    function testFuzz_sweep_neverExceedsAvailableBalance(uint256 funded, uint256 requested) public {
        funded = bound(funded, 0, 1000 ether);
        vm.deal(address(sweep_), funded);

        vm.prank(owner);
        if (requested == 0) {
            vm.expectRevert(NativeSweep.ZeroAmount.selector);
            sweep_.sweep(requested);
        } else if (requested > funded) {
            vm.expectRevert(
                abi.encodeWithSelector(NativeSweep.InsufficientBalance.selector, requested, funded)
            );
            sweep_.sweep(requested);
        } else {
            uint256 before = owner.balance;
            sweep_.sweep(requested);
            assertEq(owner.balance, before + requested);
        }
    }

    // ---------------------------------------------------------------
    // Reentrancy
    // ---------------------------------------------------------------

    function test_sweepAll_blocksReentrancy() public {
        // Deploy a fresh NativeSweep instance owned by the attacker, so that
        // when it sweeps funds to itself, its receive() hook fires and attempts
        // the reentrant call.
        ReentrantAttacker attacker = new ReentrantAttacker(NativeSweep(payable(address(0))));
        NativeSweep sweepWithAttackerOwner = new NativeSweep(address(attacker));
        attacker.setTarget(sweepWithAttackerOwner);

        vm.deal(address(sweepWithAttackerOwner), 5 ether);

        vm.prank(address(attacker));
        sweepWithAttackerOwner.sweepAll();

        // The outer sweepAll must succeed and the attacker's nested attempt
        // (from within `receive()`) must have been blocked specifically by the
        // reentrancy guard — not by some unrelated revert (e.g. running out of gas).
        assertTrue(attacker.attacked());
        assertEq(address(attacker).balance, 5 ether);
        assertEq(address(sweepWithAttackerOwner).balance, 0);
        assertEq(
            bytes4(attacker.lastRevertReason()),
            NativeSweep.ReentrancyGuard.selector,
            "reentrant call did not fail with ReentrancyGuard()"
        );
    }

    // ---------------------------------------------------------------
    // Gas-stipend behavior: proves .call is necessary, not .transfer()
    // ---------------------------------------------------------------

    function test_sweep_succeedsForGasHungryReceiver() public {
        ExpensiveReceiver receiver = new ExpensiveReceiver();
        NativeSweep sweepToExpensive = new NativeSweep(address(receiver));
        vm.deal(address(sweepToExpensive), 1 ether);

        // This would revert with .transfer()/.send() due to the 2300 gas stipend;
        // with raw .call it must succeed.
        vm.prank(address(receiver));
        sweepToExpensive.sweep(1 ether);

        assertEq(address(receiver).balance, 1 ether);
    }

    function test_sweep_revertsWhenReceiverRejectsNative() public {
        RejectingReceiver rejecter = new RejectingReceiver();
        NativeSweep sweepToRejecter = new NativeSweep(address(rejecter));
        vm.deal(address(sweepToRejecter), 1 ether);

        vm.prank(address(rejecter));
        vm.expectRevert(NativeSweep.NativeTransferFailed.selector);
        sweepToRejecter.sweep(1 ether);
    }
}

/// @dev Receiver with no payable receive/fallback — forces the low-level call to fail.
contract RejectingReceiver {
    // Intentionally no receive() or payable fallback().
}
