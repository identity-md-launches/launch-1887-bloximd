// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
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
        uint256 amount = exceedBalance ? held + 1 : bound(rawAmount, 0, held);
        vm.prank(from);
        (bool success, bytes memory returned) = address(TOKEN).call(abi.encodeCall(TOKEN.transfer, (to, amount)));
        assertEq(success, !exceedBalance, "transfer success disagrees with ledger");
        if (success) {
            assertTrue(abi.decode(returned, (bool)));
            expectedBalance[from] -= amount;
            expectedBalance[to] += amount;
        }
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = actors[ownerSeed % 4];
        address spender = actors[spenderSeed % 4];
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
        uint256 amount = validAmount ? bound(rawAmount, 0, limit) : rawAmount;
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
        }
    }

    function invalidRecipient(uint256 ownerSeed, uint256 spenderSeed, uint256 rawAmount) external {
        address owner = actors[ownerSeed % 4];
        address spender = actors[spenderSeed % 4];
        uint256 amount = bound(rawAmount, 0, expectedBalance[owner]);
        vm.prank(owner);
        assertTrue(TOKEN.approve(spender, amount));
        expectedAllowance[owner][spender] = amount;
        vm.prank(spender);
        (bool success,) = address(TOKEN).call(abi.encodeCall(TOKEN.transferFrom, (owner, address(0), amount)));
        assertFalse(success, "zero recipient accepted");
    }
}

contract BloxIMDInvariantTest is StdInvariant, Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    BloxIMD internal token;
    BloxIMDHandler internal handler;

    function setUp() public {
        token = new BloxIMD();
        handler = new BloxIMDHandler(token);
        assertTrue(token.transfer(handler.actors(0), SUPPLY));

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.transferFrom.selector;
        selectors[3] = handler.invalidRecipient.selector;
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
    }

    function invariant_allowancesMatchReferenceLedger() public view {
        for (uint256 i; i < 4; ++i) {
            for (uint256 j; j < 4; ++j) {
                address owner = handler.actors(i);
                address spender = handler.actors(j);
                assertEq(token.allowance(owner, spender), handler.expectedAllowance(owner, spender));
            }
        }
    }
}
