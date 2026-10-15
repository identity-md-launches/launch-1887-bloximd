// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {BloxIMD} from "src/BloxIMD.sol";

/// @dev Both token calls belong to one transaction, so the second failure must undo the first.
contract BloxBatchSpender {
    function spendTwice(BloxIMD token, address owner, address recipient, uint256 first, uint256 second) external {
        require(token.transferFrom(owner, recipient, first), "first transfer returned false");
        require(token.transferFrom(owner, recipient, second), "second transfer returned false");
    }
}

/// @dev Extends the original suite with boundary approvals, aliasing, retries, and atomic failures.
/// forge-config: default.fuzz.runs = 1000
contract BloxIMDEdgeCasesTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 10 ** 18;
    BloxIMD private token;
    address private alice;
    address private bob;
    address private spender;

    function setUp() public {
        token = new BloxIMD();
        alice = makeAddr("edge alice");
        bob = makeAddr("edge bob");
        spender = makeAddr("edge spender");
    }

    function test_oneMinorUnitCanMoveAndReturnWithoutRounding() public {
        assertTrue(token.transfer(alice, 1));
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.balanceOf(address(this)), SUPPLY - 1);
        vm.prank(alice);
        assertTrue(token.transfer(address(this), 1));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_largestFiniteApprovalDecreasesOnEverySpend() public {
        assertTrue(token.approve(spender, type(uint256).max - 1));
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, 1));
        assertEq(token.allowance(address(this), spender), type(uint256).max - 2);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, SUPPLY - 1));
        assertEq(token.allowance(address(this), spender), type(uint256).max - 1 - SUPPLY);
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_infiniteApprovalCanBeReducedAndRevoked() public {
        assertTrue(token.approve(spender, type(uint256).max));
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, 1));
        assertEq(token.allowance(address(this), spender), type(uint256).max);

        assertTrue(token.approve(spender, 2));
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, 2));
        assertEq(token.allowance(address(this), spender), 0);

        assertTrue(token.approve(spender, type(uint256).max));
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Approval(address(this), spender, 0);
        assertTrue(token.approve(spender, 0));
        _expectAllowanceFailure(address(this), alice, 0, 1);
        assertEq(token.allowance(address(this), spender), 0);
        assertEq(token.balanceOf(alice), 3);
        assertEq(token.balanceOf(address(this)), SUPPLY - 3);
    }

    function test_zeroApprovalToZeroSpenderStillReverts() public {
        assertTrue(token.approve(spender, 7));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 0);
        assertEq(token.allowance(address(this), address(0)), 0);
        assertEq(token.allowance(address(this), spender), 7);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_zeroDelegatedTransfersEmitEventsWithoutConsumingAnyApproval() public {
        uint256[4] memory approvals = [uint256(0), 1, type(uint256).max - 1, type(uint256).max];
        for (uint256 i; i < approvals.length; ++i) {
            vm.prank(alice);
            assertTrue(token.approve(spender, approvals[i]));
            vm.expectEmit(true, true, false, true, address(token));
            emit IERC20.Transfer(alice, bob, 0);
            vm.prank(spender);
            assertTrue(token.transferFrom(alice, bob, 0));
            assertEq(token.allowance(alice, spender), approvals[i]);
            assertEq(token.balanceOf(alice), 0);
            assertEq(token.balanceOf(bob), 0);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_holderNeedsSelfApprovalForTransferFrom() public {
        assertTrue(token.transfer(alice, 1));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        vm.prank(alice);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        token.transferFrom(alice, bob, 1);
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.balanceOf(bob), 0);

        vm.prank(alice);
        assertTrue(token.approve(alice, 1));
        vm.prank(alice);
        assertTrue(token.transferFrom(alice, bob, 1));
        assertEq(token.allowance(alice, alice), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 1);
    }

    function test_delegatedSelfTransferStillChecksBalance() public {
        assertTrue(token.transfer(alice, 1));
        vm.prank(alice);
        assertTrue(token.approve(spender, 2));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1, 2));
        vm.prank(spender);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        token.transferFrom(alice, alice, 2);
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.allowance(alice, spender), 2);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_uint256MaxSpendFailsEvenWithInfiniteApproval() public {
        assertTrue(token.approve(spender, type(uint256).max));
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, type(uint256).max
            )
        );
        vm.prank(spender);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        token.transferFrom(address(this), alice, type(uint256).max);
        assertEq(token.allowance(address(this), spender), type(uint256).max);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_exhaustedAllowanceCannotBeReused() public {
        assertTrue(token.approve(spender, 1));
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, 1));
        _expectAllowanceFailure(address(this), alice, 0, 1);
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.balanceOf(address(this)), SUPPLY - 1);
        assertEq(token.allowance(address(this), spender), 0);
    }

    function test_allowanceCannotBeBorrowedFromAnotherOwner() public {
        assertTrue(token.transfer(alice, 1));
        assertTrue(token.transfer(bob, 1));
        vm.prank(alice);
        assertTrue(token.approve(spender, 1));
        _expectAllowanceFailure(bob, spender, 0, 1);
        assertEq(token.allowance(alice, spender), 1);
        assertEq(token.allowance(bob, spender), 0);
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.balanceOf(bob), 1);
        assertEq(token.balanceOf(spender), 0);
    }

    function test_zeroRecipientFailureCanBeRetriedWithoutApprovingAgain() public {
        assertTrue(token.approve(spender, 1));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        token.transferFrom(address(this), address(0), 1);
        assertEq(token.allowance(address(this), spender), 1);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, 1));
        assertEq(token.allowance(address(this), spender), 0);
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_zeroDelegatedTransferToZeroAddressRevertsWithInfiniteApproval() public {
        assertTrue(token.approve(spender, type(uint256).max));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        token.transferFrom(address(this), address(0), 0);
        assertEq(token.allowance(address(this), spender), type(uint256).max);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_zeroSourceCannotBeUsedToMintThroughTransferFrom() public {
        uint256[3] memory amounts = [uint256(0), 1, type(uint256).max];
        for (uint256 i; i < amounts.length; ++i) {
            vm.prank(spender);
            (bool success,) = address(token).call(abi.encodeCall(token.transferFrom, (address(0), alice, amounts[i])));
            // Either the approval guard or the sender guard may reject this invalid source.
            assertFalse(success, "zero source accepted");
            assertEq(token.balanceOf(alice), 0);
            assertEq(token.balanceOf(address(0)), 0);
            assertEq(token.allowance(address(0), spender), 0);
            assertEq(token.balanceOf(address(this)), SUPPLY);
            assertEq(token.totalSupply(), SUPPLY);
        }
    }

    function test_batchFailureRollsBackEarlierTransferAndAllowanceSpend() public {
        BloxBatchSpender batch = new BloxBatchSpender();
        assertTrue(token.approve(address(batch), 3));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(batch), 1, 2));
        batch.spendTwice(token, address(this), alice, 2, 2);
        assertEq(token.allowance(address(this), address(batch)), 3);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);

        batch.spendTwice(token, address(this), alice, 2, 1);
        assertEq(token.allowance(address(this), address(batch)), 0);
        assertEq(token.balanceOf(alice), 3);
        assertEq(token.balanceOf(address(this)), SUPPLY - 3);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_nonpayableEntryPointsRejectEtherWithoutChangingState() public {
        assertTrue(token.approve(spender, 1));
        bytes[3] memory calls = [
            abi.encodeCall(token.transfer, (alice, 1)),
            abi.encodeCall(token.approve, (alice, type(uint256).max)),
            abi.encodeCall(token.transferFrom, (address(this), alice, 1))
        ];
        for (uint256 i; i < calls.length; ++i) {
            address caller = i == 2 ? spender : address(this);
            vm.deal(caller, 1);
            vm.prank(caller);
            (bool success,) = address(token).call{value: 1}(calls[i]);
            assertFalse(success);
            assertEq(caller.balance, 1);
            assertEq(address(token).balance, 0);
            assertEq(token.balanceOf(address(this)), SUPPLY);
            assertEq(token.balanceOf(alice), 0);
            assertEq(token.allowance(address(this), spender), 1);
            assertEq(token.allowance(address(this), alice), 0);
        }
    }

    function testFuzz_approvalReplacementIsIdempotentAndDoesNotMoveBalances(uint256 first, uint256 replacement) public {
        assertTrue(token.approve(spender, first));
        assertTrue(token.approve(bob, 17));
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Approval(address(this), spender, replacement);
        assertTrue(token.approve(spender, replacement));
        assertTrue(token.approve(spender, replacement));
        assertEq(token.allowance(address(this), spender), replacement);
        assertEq(token.allowance(address(this), bob), 17);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(spender), 0);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_failedDelegatedSpendSucceedsAfterFunding(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY - 1);
        amount = bound(amount, held + 1, SUPPLY);
        assertTrue(token.transfer(alice, held));
        vm.prank(alice);
        assertTrue(token.approve(spender, amount));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, held, amount));
        vm.prank(spender);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        token.transferFrom(alice, bob, amount);
        assertEq(token.allowance(alice, spender), amount);
        assertEq(token.balanceOf(alice), held);
        assertEq(token.balanceOf(bob), 0);

        assertTrue(token.transfer(alice, amount - held));
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, amount));
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_delegatedRoundTripPreservesSupply(uint256 amount, bool infinite) public {
        amount = bound(amount, 1, SUPPLY);
        uint256 approval = infinite ? type(uint256).max : amount;
        assertTrue(token.approve(spender, approval));
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, amount));
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        vm.prank(alice);
        assertTrue(token.approve(spender, approval));
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, address(this), amount));
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(spender), 0);
        assertEq(token.allowance(address(this), spender), infinite ? type(uint256).max : 0);
        assertEq(token.allowance(alice, spender), infinite ? type(uint256).max : 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev Exercise all-equal, owner=spender, owner=recipient, and spender=recipient cases explicitly.
    function testFuzz_delegatedTransfersHandleAliasedAccounts(uint256 amount, uint8 mode, bool infinite) public {
        amount = bound(amount, 1, SUPPLY);
        assertTrue(token.transfer(alice, SUPPLY));
        uint8 variant = mode % 4;
        address caller = variant < 2 ? alice : spender;
        address recipient = bob;
        if (variant == 0 || variant == 2) recipient = alice;
        if (variant == 3) recipient = spender;
        uint256 approval = infinite ? type(uint256).max : amount;
        vm.prank(alice);
        assertTrue(token.approve(caller, approval));
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(alice, recipient, amount);
        vm.prank(caller);
        assertTrue(token.transferFrom(alice, recipient, amount));
        assertEq(token.allowance(alice, caller), infinite ? type(uint256).max : 0);
        assertEq(token.balanceOf(alice), recipient == alice ? SUPPLY : SUPPLY - amount);
        if (recipient != alice) assertEq(token.balanceOf(recipient), amount);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(alice) + token.balanceOf(bob) + token.balanceOf(spender), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function _expectAllowanceFailure(address owner, address recipient, uint256 allowed, uint256 amount) private {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount)
        );
        vm.prank(spender);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        token.transferFrom(owner, recipient, amount);
    }
}
