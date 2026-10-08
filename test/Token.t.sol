// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {SIMDTEST} from "../src/SIMDTEST.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract TokenTest is Test {
    SIMDTEST internal token;

    function setUp() public {
        token = new SIMDTEST();
    }

    function test_supplyMetadataAndPlainTransfers() public {
        assertEq(token.name(), "SIMDTEST");
        assertEq(token.symbol(), "SIMDTEST");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
        address buyer = makeAddr("buyer");
        token.transfer(buyer, 1e26);
        assertEq(token.balanceOf(buyer), 1e26);
        assertEq(token.balanceOf(address(this)), 9e26);
        assertEq(token.totalSupply(), 1e27);
        vm.prank(buyer);
        token.transfer(address(this), 1e26);
        assertEq(token.balanceOf(address(this)), 1e27);
    }

    function test_noMintOrAdministrativeEntryPoints() public {
        string[6] memory methods = [
            "mint(address,uint256)",
            "owner()",
            "pause()",
            "upgradeTo(address)",
            "transferOwnership(address)",
            "initialize(address)"
        ];
        for (uint256 i; i < methods.length; ++i) {
            (bool ok,) = address(token).call(abi.encodeWithSignature(methods[i], address(this), 1 ether));
            assertFalse(ok);
            assertEq(token.totalSupply(), 1e27);
        }
    }

    function test_runtimeHasNoForbiddenOpcodes() public view {
        bytes memory code = address(token).code;
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xff && op != 0xf4 && op != 0xf2);
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_allowanceTransferConservesSupply(uint96 raw) public {
        uint256 amount = bound(raw, 0, 1e27);
        address spender = makeAddr("spender");
        address recipient = makeAddr("recipient");
        token.approve(spender, amount);
        vm.prank(spender);
        token.transferFrom(address(this), recipient, amount);
        assertEq(token.balanceOf(recipient), amount);
        assertEq(token.balanceOf(address(this)), 1e27 - amount);
        assertEq(token.allowance(address(this), spender), 0);
        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1)
        );
        token.transferFrom(address(this), recipient, 1);
    }
}
