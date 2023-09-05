// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/InverseBondingCurve.sol";
import "../src/InverseBondingCurveProxy.sol";
import "../src/InverseBondingCurveToken.sol";
import "forge-std/console2.sol";

contract InverseBondingCurveProxyTest is Test {
    InverseBondingCurve public curveContract;

    uint256 ALLOWED_ERROR = 1e8;

    address recipient = address(this);
    address otherRecipient = vm.parseAddress("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266");
    uint256 feePercent = 3e15;

    function setUp() public {
        curveContract = new InverseBondingCurve();  
        InverseBondingCurveProxy proxy = new InverseBondingCurveProxy(address(curveContract), "");
        curveContract = InverseBondingCurve(address(proxy)); 
        curveContract.initialize{value: 2 ether}(1e18, 1e18, otherRecipient, otherRecipient);    
    }

    function testSymbol() public {
        assertEq(curveContract.symbol(), "IBCLP");
    }

    function testInverseTokenSymbol() public {
        InverseBondingCurveToken tokenContract = InverseBondingCurveToken(curveContract.getInverseTokenAddress());

        assertEq(tokenContract.symbol(), "IBC");
    }

}
