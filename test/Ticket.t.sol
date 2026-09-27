// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Ticket} from "../src/Ticket.sol";

contract TicketTest is Test {
    Ticket token;
    address deployer = makeAddr("factory");

    function setUp() public {
        vm.prank(deployer);
        token = new Ticket();
    }

    function test_metadata() public view {
        assertEq(token.name(), "Ticket");
        assertEq(token.symbol(), "TIKT");
        assertEq(token.decimals(), 18);
    }

    function test_fixedSupplyMintedOnceToDeployer() public view {
        assertEq(token.totalSupply(), 1_000_000_000e18);
        assertEq(token.TOTAL_SUPPLY(), 1_000_000_000e18);
        assertEq(token.balanceOf(deployer), 1_000_000_000e18);
    }

    function test_noMintOrAdminEntryPoints() public {
        string[6] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "owner()",
            "transferOwnership(address)",
            "pause()"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            vm.prank(deployer);
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], deployer, uint256(1)));
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.totalSupply(), 1_000_000_000e18);
    }

    function test_transferMovesExactly() public {
        vm.prank(deployer);
        assertTrue(token.transfer(address(0xCAFE), 1e18));
        assertEq(token.balanceOf(address(0xCAFE)), 1e18);
        assertEq(token.balanceOf(deployer), 1_000_000_000e18 - 1e18);
        assertEq(token.totalSupply(), 1_000_000_000e18);
    }

    function test_transferBeyondBalanceReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(0xCAFE), 0, 1));
        vm.prank(address(0xCAFE));
        token.transfer(deployer, 1);
    }

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != deployer);
        amount = bound(amount, 0, token.totalSupply());
        vm.prank(deployer);
        token.transfer(to, amount);
        assertEq(token.balanceOf(to) + token.balanceOf(deployer), token.totalSupply());
    }
}
