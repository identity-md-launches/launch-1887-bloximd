// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {BloxIMD} from "../src/BloxIMD.sol";

/// @dev Four tracked holders and a reference ledger exercise arbitrary sequences, including
/// self transfers, infinite approvals, overspending, invalid recipients, and failed transactions.
contract BloxIMDHandler is Test {
    BloxIMD public immutable TOKEN;
    address[4] public actors;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;

    constructor(BloxIMD token_) {
        TOKEN = token_;
        actors[0] = makeAddr("invariant alice");
        actors[1] = makeAddr("invariant bob");
        actors[2] = makeAddr("invariant carol");
        actors[3] = makeAddr("invariant dave");
        expectedBalance[actors[0]] = 1_000_000_000 ether;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 rawAmount, bool exceedBalance) external {
        address from = actors[fromSeed % 4];
        address to = actors[toSeed % 4];
        uint256 held = expectedBalance[from];
        uint256 amount = exceedBalance ? held + 1 : _boundedAmount(rawAmount, held);
        vm.prank(from);
        (bool success, bytes memory returned) = address(TOKEN).call(abi.encodeCall(TOKEN.transfer, (to, amount)));
        assertEq(success, !exceedBalance, "transfer success disagrees with ledger");
        if (success) {
            assertTrue(abi.decode(returned, (bool)));
            expectedBalance[from] -= amount;
            expectedBalance[to] += amount;
        } else {
            assertEq(
                returned, abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, held, amount)
            );
        }
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = actors[ownerSeed % 4];
        address spender = actors[spenderSeed % 4];
        _approve(owner, spender, amount);
    }

    /// @dev Force revocation and the finite/infinite boundary to occur frequently in sequences.
    function approvalBoundary(uint256 ownerSeed, uint256 spenderSeed, uint256 mode) external {
        uint256[5] memory amounts = [uint256(0), 1, 1_000_000_000 ether, type(uint256).max - 1, type(uint256).max];
        _approve(actors[ownerSeed % 4], actors[spenderSeed % 4], amounts[mode % amounts.length]);
    }

    function _approve(address owner, address spender, uint256 amount) private {
        vm.prank(owner);
        assertTrue(TOKEN.approve(spender, amount));
        expectedAllowance[owner][spender] = amount;
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 rawAmount, bool validAmount)
        external
    {
        address owner = actors[ownerSeed % 4];
        address spender = actors[spenderSeed % 4];
        address to = actors[toSeed % 4];
        uint256 held = expectedBalance[owner];
        uint256 allowed = expectedAllowance[owner][spender];
        uint256 limit = held < allowed ? held : allowed;
        uint256 amount = validAmount ? _boundedAmount(rawAmount, limit) : rawAmount;
        bool shouldSucceed = amount <= held && amount <= allowed;

        vm.prank(spender);
        (bool success, bytes memory returned) =
            address(TOKEN).call(abi.encodeCall(TOKEN.transferFrom, (owner, to, amount)));
        assertEq(success, shouldSucceed, "transferFrom success disagrees with ledger");
        if (success) {
            assertTrue(abi.decode(returned, (bool)));
            expectedBalance[owner] -= amount;
            expectedBalance[to] += amount;
            if (allowed != type(uint256).max) {
                expectedAllowance[owner][spender] -= amount;
            }
        } else if (amount > allowed) {
            assertEq(
                returned,
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount)
            );
        } else {
            assertEq(
                returned, abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, held, amount)
            );
        }
    }

    /// @dev Guarantee balance failures after a sufficient approval, including an unlimited one.
    /// The approval is intentional state; the subsequent failed transfer must not consume it.
    function insufficientBalance(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, bool infinite) external {
        address owner = actors[ownerSeed % 4];
        address spender = actors[spenderSeed % 4];
        uint256 held = expectedBalance[owner];
        uint256 amount = held + 1;
        _approve(owner, spender, infinite ? type(uint256).max : amount);
        vm.prank(spender);
        (bool success, bytes memory returned) =
            address(TOKEN).call(abi.encodeCall(TOKEN.transferFrom, (owner, actors[toSeed % 4], amount)));
        assertFalse(success, "balance failure unexpectedly succeeded");
        assertEq(returned, abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, held, amount));
    }

    function invalidSpender(uint256 ownerSeed, uint256 amount) external {
        vm.prank(actors[ownerSeed % 4]);
        (bool success, bytes memory returned) = address(TOKEN).call(abi.encodeCall(TOKEN.approve, (address(0), amount)));
        assertFalse(success, "zero spender accepted");
        assertEq(returned, abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
    }

    function invalidRecipient(uint256 ownerSeed, uint256 spenderSeed, uint256 rawAmount) external {
        address owner = actors[ownerSeed % 4];
        address spender = actors[spenderSeed % 4];
        uint256 amount = _boundedAmount(rawAmount, expectedBalance[owner]);
        _approve(owner, spender, amount);
        vm.prank(spender);
        (bool success, bytes memory returned) =
            address(TOKEN).call(abi.encodeCall(TOKEN.transferFrom, (owner, address(0), amount)));
        assertFalse(success, "zero recipient accepted");
        assertEq(returned, abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
    }

    /// @dev Zero, one minor unit, and the whole spendable amount recur alongside arbitrary amounts.
    function _boundedAmount(uint256 seed, uint256 limit) private pure returns (uint256) {
        if (seed % 4 == 0) return 0;
        if (seed % 4 == 1) return limit == 0 ? 0 : 1;
        if (seed % 4 == 2) return limit;
        return bound(seed, 0, limit);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract BloxIMDInvariantTest is StdInvariant, Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    BloxIMD internal token;
    BloxIMDHandler internal handler;

    function setUp() public {
        token = new BloxIMD();
        handler = new BloxIMDHandler(token);
        assertTrue(token.transfer(handler.actors(0), SUPPLY));

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.transferFrom.selector;
        selectors[3] = handler.invalidRecipient.selector;
        selectors[4] = handler.approvalBoundary.selector;
        selectors[5] = handler.insufficientBalance.selector;
        selectors[6] = handler.invalidSpender.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_supplyAndBalancesMatchReferenceLedger() public view {
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            uint256 actual = token.balanceOf(actor);
            assertEq(actual, handler.expectedBalance(actor));
            sum += actual;
        }
        assertEq(sum, SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
    }

    function invariant_allowancesMatchReferenceLedger() public view {
        for (uint256 i; i < 4; ++i) {
            address owner = handler.actors(i);
            assertEq(token.allowance(owner, address(0)), 0);
            for (uint256 j; j < 4; ++j) {
                address spender = handler.actors(j);
                assertEq(token.allowance(owner, spender), handler.expectedAllowance(owner, spender));
            }
        }
    }

    function invariant_metadataRemainsFixed() public view {
        assertEq(token.name(), "BloxIMD");
        assertEq(token.symbol(), "BLOX");
        assertEq(token.decimals(), 18);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
    }

    /// @dev Deterministically exercise nonzero transfers, revocation, and every new handler.
    /// This guards against an invariant campaign that only performs empty-account no-ops.
    function test_handlerExercisesAllowanceTransitionsAndFailures() public {
        handler.transfer(0, 1, 2, false); // Full supply to actor 1.
        handler.approvalBoundary(1, 2, 4); // Infinite approval.
        handler.transferFrom(1, 2, 3, 1, true); // Spend one minor unit.
        assertEq(token.balanceOf(handler.actors(3)), 1);
        assertEq(token.allowance(handler.actors(1), handler.actors(2)), type(uint256).max);
        handler.approvalBoundary(1, 2, 3); // Largest finite approval.
        handler.transferFrom(1, 2, 3, 1, true);
        assertEq(token.allowance(handler.actors(1), handler.actors(2)), type(uint256).max - 2);
        handler.approvalBoundary(1, 2, 0); // Revoke, then attempt a positive spend.
        handler.transferFrom(1, 2, 3, 1, false);
        handler.insufficientBalance(0, 2, 3, false);
        handler.insufficientBalance(1, 2, 3, true);
        handler.invalidRecipient(1, 2, 1);
        handler.invalidSpender(1, type(uint256).max);
        handler.transfer(3, 3, 2, false); // Full self transfer.
        handler.transfer(3, 0, 0, true); // One over the balance.
        invariant_supplyAndBalancesMatchReferenceLedger();
        invariant_allowancesMatchReferenceLedger();
        invariant_metadataRemainsFixed();
    }
}
