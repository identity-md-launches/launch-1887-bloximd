// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BloxIMD} from "../src/BloxIMD.sol";

/// @dev Test-only factory. The production deliverable is BloxIMD alone.
contract TokenFactoryFixture {
    function deploy(bytes32 salt) external returns (BloxIMD) {
        return new BloxIMD{salt: salt}();
    }

    function move(BloxIMD token, address recipient, uint256 amount) external {
        require(token.transfer(recipient, amount), "transfer failed");
    }
}

contract BloxIMDLaunchTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    TokenFactoryFixture internal factory;
    BloxIMD internal token;
    address internal distributor;
    address internal pool;
    address internal remainder;
    address internal holder;
    address internal trader;

    function setUp() public {
        factory = new TokenFactoryFixture();
        token = factory.deploy(keccak256("blox launch test"));
        distributor = makeAddr("distributor fixture");
        pool = makeAddr("pool custody fixture");
        remainder = makeAddr("remainder fixture");
        holder = makeAddr("holder");
        trader = makeAddr("trader");
    }

    function test_create2ConstructorMintsEverythingToFactory() public view {
        assertEq(token.balanceOf(address(factory)), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(address(token).balance, 0);
    }

    /// @dev Exercises ERC-20 movements only; the network's protected suite exercises the actual v4 pool.
    function test_launchDistributionClaimsAndTwoWayPoolTransfersAreExact() public {
        uint256 swarmShare = SUPPLY * 1_000 / 10_000;
        uint256 poolShare = SUPPLY * 8_800 / 10_000;
        uint256 remainderShare = SUPPLY - swarmShare - poolShare;

        factory.move(token, distributor, swarmShare);
        factory.move(token, pool, poolShare);
        factory.move(token, remainder, remainderShare);
        assertEq(token.balanceOf(distributor), 100_000_000 ether);
        assertEq(token.balanceOf(pool), 880_000_000 ether);
        assertEq(token.balanceOf(remainder), 20_000_000 ether);
        assertEq(token.balanceOf(address(factory)), 0);

        vm.prank(distributor);
        assertTrue(token.transfer(holder, swarmShare));
        assertEq(token.balanceOf(holder), swarmShare);
        assertEq(token.balanceOf(distributor), 0);

        uint256 tradeAmount = 123 ether;
        vm.prank(pool);
        assertTrue(token.transfer(trader, tradeAmount));
        assertEq(token.balanceOf(trader), tradeAmount);
        assertEq(token.balanceOf(pool), poolShare - tradeAmount);
        vm.prank(trader);
        assertTrue(token.transfer(pool, tradeAmount));
        assertEq(token.balanceOf(pool), poolShare);
        assertEq(token.balanceOf(trader), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_factoryHasNoPrivilegeOverHolderTokens() public {
        factory.move(token, holder, 100 ether);
        vm.prank(address(factory));
        (bool moved,) = address(token).call(abi.encodeCall(token.transferFrom, (holder, address(factory), 1 ether)));
        assertFalse(moved);
        assertEq(token.balanceOf(holder), 100 ether);
        vm.prank(holder);
        assertTrue(token.transfer(trader, 100 ether));
        assertEq(token.balanceOf(trader), 100 ether);
    }

    function test_mintAndAdminSelectorsAreUnavailableToFactoryAndStranger() public {
        factory.move(token, holder, 100 ether);
        bytes[] memory calls = new bytes[](18);
        calls[0] = abi.encodeWithSignature("mint(address,uint256)", trader, SUPPLY);
        calls[1] = abi.encodeWithSignature("mint(uint256)", SUPPLY);
        calls[2] = abi.encodeWithSignature("mint()");
        calls[3] = abi.encodeWithSignature("issue(uint256)", SUPPLY);
        calls[4] = abi.encodeWithSignature("initialize(address)", trader);
        calls[5] = abi.encodeWithSignature("setMinter(address)", trader);
        calls[6] = abi.encodeWithSignature("transferOwnership(address)", trader);
        calls[7] = abi.encodeWithSignature("upgradeTo(address)", trader);
        calls[8] = abi.encodeWithSignature("pause()");
        calls[9] = abi.encodeWithSignature("blacklist(address)", holder);
        calls[10] = abi.encodeWithSignature("freeze(address)", holder);
        calls[11] = abi.encodeWithSignature("setBlacklist(address,bool)", holder, true);
        calls[12] = abi.encodeWithSignature("lock(address)", holder);
        calls[13] = abi.encodeWithSignature("disableTransfers()");
        calls[14] = abi.encodeWithSignature("setTransfersEnabled(bool)", false);
        calls[15] = abi.encodeWithSignature("burnFrom(address,uint256)", holder, 100 ether);
        calls[16] = abi.encodeWithSignature("seize(address)", holder);
        calls[17] = abi.encodeWithSignature("burn(uint256)", 1 ether);

        for (uint256 i; i < calls.length; ++i) {
            vm.prank(address(factory));
            (bool factoryCall,) = address(token).call(calls[i]);
            assertFalse(factoryCall, "factory unexpectedly has administrative access");
            vm.prank(trader);
            (bool strangerCall,) = address(token).call(calls[i]);
            assertFalse(strangerCall, "stranger unexpectedly has administrative access");
            assertEq(token.totalSupply(), SUPPLY);
            assertEq(token.balanceOf(holder), 100 ether);
            assertEq(token.balanceOf(trader), 0);
        }

        vm.prank(holder);
        assertTrue(token.transfer(trader, 100 ether));
        assertEq(token.balanceOf(trader), 100 ether);
    }

    function test_runtimeHasNoForbiddenOpcodesAndFitsDeploymentLimit() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 opcode = uint8(runtime[i]);
            if (opcode >= 0x60 && opcode <= 0x7f) {
                i += opcode - 0x5f;
                continue;
            }
            assertTrue(opcode != 0xf4, "DELEGATECALL");
            assertTrue(opcode != 0xf2, "CALLCODE");
            assertTrue(opcode != 0xff, "SELFDESTRUCT");
        }
    }
}
