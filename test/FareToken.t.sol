// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FareToken} from "../src/FareToken.sol";

contract FareTokenTest is Test {
    FareToken private token;
    address private constant HOLDER = address(0xA11CE);
    address private constant SPENDER = address(0xB0B);

    function setUp() public {
        token = new FareToken();
    }

    function testMetadataAndExactInitialSupply() public view {
        assertEq(token.name(), "Fare for Medallion 447");
        assertEq(token.symbol(), "FARE447");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
        assertEq(token.balanceOf(HOLDER), 0);
    }

    function testTransferIsExactAndSelfTransferPreservesBalance() public {
        assertTrue(token.transfer(HOLDER, 12 ether));
        assertEq(token.balanceOf(HOLDER), 12 ether);
        assertEq(token.balanceOf(address(this)), 1e27 - 12 ether);
        vm.prank(HOLDER);
        assertTrue(token.transfer(HOLDER, 12 ether));
        assertEq(token.balanceOf(HOLDER), 12 ether);
        assertEq(token.totalSupply(), 1e27);
    }

    function testTransferFromConsumesAllowance() public {
        token.approve(SPENDER, 10 ether);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(address(this), HOLDER, 4 ether));
        assertEq(token.allowance(address(this), SPENDER), 6 ether);
        assertEq(token.balanceOf(HOLDER), 4 ether);
    }

    function testBurnAndBurnFromReduceSupply() public {
        token.burn(3 ether);
        token.approve(SPENDER, 5 ether);
        vm.prank(SPENDER);
        token.burnFrom(address(this), 5 ether);
        assertEq(token.totalSupply(), 1e27 - 8 ether);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
        assertEq(token.allowance(address(this), SPENDER), 0);
    }

    function testInfiniteAllowancePersistsForTransfersAndBurns() public {
        token.approve(SPENDER, type(uint256).max);
        vm.startPrank(SPENDER);
        token.transferFrom(address(this), HOLDER, 1 ether);
        token.burnFrom(address(this), 2 ether);
        vm.stopPrank();
        assertEq(token.allowance(address(this), SPENDER), type(uint256).max);
        assertEq(token.totalSupply(), 1e27 - 2 ether);
    }

    function testRejectedOperationsPreserveSupplyBalancesAndAllowance() public {
        vm.expectRevert(FareToken.InvalidReceiver.selector);
        token.transfer(address(0), 1);
        vm.expectRevert(FareToken.InvalidSpender.selector);
        token.approve(address(0), 1);
        vm.expectRevert(FareToken.InsufficientBalance.selector);
        token.transfer(HOLDER, 1e27 + 1);
        vm.expectRevert(FareToken.InsufficientBalance.selector);
        token.burn(1e27 + 1);
        vm.prank(SPENDER);
        vm.expectRevert(FareToken.InsufficientAllowance.selector);
        token.burnFrom(address(this), 1);
        token.approve(SPENDER, type(uint256).max - 1);
        vm.prank(SPENDER);
        vm.expectRevert(FareToken.InsufficientBalance.selector);
        token.transferFrom(address(this), HOLDER, 1e27 + 1);
        assertEq(token.allowance(address(this), SPENDER), type(uint256).max - 1);
        assertEq(token.balanceOf(address(this)), 1e27);
        assertEq(token.totalSupply(), 1e27);
    }

    function testZeroValueOperations() public {
        assertTrue(token.transfer(HOLDER, 0));
        vm.startPrank(HOLDER);
        token.burn(0);
        assertTrue(token.transferFrom(address(this), HOLDER, 0));
        token.burnFrom(address(this), 0);
        vm.stopPrank();
        assertEq(token.totalSupply(), 1e27);
    }

    function testFuzzConservationAcrossTransferAndBurn(uint256 amount, uint256 burned) public {
        amount = bound(amount, 0, 1e27);
        burned = bound(burned, 0, amount);
        token.transfer(HOLDER, amount);
        vm.prank(HOLDER);
        token.burn(burned);
        assertEq(token.balanceOf(address(this)) + token.balanceOf(HOLDER), token.totalSupply());
        assertEq(token.totalSupply(), 1e27 - burned);
    }

    function testNoMintOrAdministrativeSelectors() public {
        bytes4[6] memory selectors = [
            bytes4(keccak256("mint(address,uint256)")),
            bytes4(keccak256("owner()")),
            bytes4(keccak256("pause()")),
            bytes4(keccak256("upgradeTo(address)")),
            bytes4(keccak256("transferOwnership(address)")),
            bytes4(keccak256("initialize(address)"))
        ];
        for (uint256 i; i < selectors.length; ++i) {
            (bool success,) = address(token).call(abi.encodeWithSelector(selectors[i], HOLDER, 1 ether));
            assertFalse(success);
        }
        assertEq(token.totalSupply(), 1e27);
    }

    function testRuntimeContainsNoForbiddenOpcodes() public view {
        bytes memory runtime = address(token).code;
        for (uint256 i; i < runtime.length; ++i) {
            uint8 opcode = uint8(runtime[i]);
            if (opcode >= 0x60 && opcode <= 0x7f) {
                i += opcode - 0x5f;
            } else {
                assertTrue(opcode != 0xf2 && opcode != 0xf4 && opcode != 0xff);
            }
        }
    }
}
