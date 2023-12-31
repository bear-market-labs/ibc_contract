// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import "../src/InverseBondingCurveToken.sol";
import "forge-std/console2.sol";

//TODO: add upgradable related test
contract InverseBondingCurveTokenTest is Test {
    InverseBondingCurveToken tokenContract;

    address owner = vm.addr(2);
    address nonOwner = vm.addr(3);

    function setUp() public {
        vm.startPrank(owner);
        tokenContract = new InverseBondingCurveToken("IBC", "IBC");
        vm.stopPrank();
    }

    function testSymbol() public {
        assertEq(tokenContract.symbol(), "IBC");
    }

    function testRevertIfMintFromNonOwner() public {
        vm.startPrank(nonOwner);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        tokenContract.mint(nonOwner, 1);
        vm.stopPrank();
    }

    function testRevertIfBurnFromNonOwner() public {
        vm.startPrank(nonOwner);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        tokenContract.burnFrom(nonOwner, 1);
        vm.stopPrank();
    }

   

    function testRevertIfTransferOwnerFromNonOwner() public {
        vm.startPrank(nonOwner);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        tokenContract.transferOwnership(owner);
        vm.stopPrank();
    }

    function testMint() public {
        vm.startPrank(owner);
        tokenContract.mint(nonOwner, 1);
        assertEq(tokenContract.balanceOf(nonOwner), 1);
        vm.stopPrank();
    }

    function testBurnFrom() public {
        vm.startPrank(owner);
        tokenContract.mint(nonOwner, 1);
        vm.stopPrank();
        vm.startPrank(nonOwner);
        tokenContract.approve(owner, 1);
        vm.stopPrank();
        vm.startPrank(owner);
        tokenContract.burnFrom(nonOwner, 1);
        assertEq(tokenContract.balanceOf(nonOwner), 0);
        vm.stopPrank();
    }

    function testTransferOwner() public {
        vm.startPrank(owner);
        tokenContract.mint(owner, 1);
        tokenContract.transfer(nonOwner, 1);
        assertEq(tokenContract.balanceOf(nonOwner), 1);
        vm.stopPrank();
    }
}
