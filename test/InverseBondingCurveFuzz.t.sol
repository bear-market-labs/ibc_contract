// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import "../src/InverseBondingCurve.sol";
import "../src/InverseBondingCurveToken.sol";
import "../src/InverseBondingCurveProxy.sol";
import "forge-std/console2.sol";

//TODO: add pause/unpause test
//TODO: add fuzzy test for major interactions
//TODO: add selfdestruct attack test
contract InverseBondingCurveFuzzTest is Test {
    using FixedPoint for uint256;

    InverseBondingCurve curveContract;
    InverseBondingCurveToken tokenContract;
    InverseBondingCurveProxy proxyContract;
    InverseBondingCurve curveContractImpl;

    uint256 ALLOWED_ERROR = 1e10;

    address recipient = address(this);
    address otherRecipient = vm.parseAddress("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266");
    uint256 feePercent = 3e15;
    address nonOwner = vm.addr(1);
    address owner = address(this);

    function assertEqWithError(uint256 a, uint256 b) internal {
        uint256 diff = a > b ? a - b : b - a;
        if (diff > ALLOWED_ERROR) {
            emit log("Error: a == b not satisfied [decimal int]");
            emit log_named_decimal_uint("      Left", a, 18);
            emit log_named_decimal_uint("     Right", b, 18);
            fail();
        }
    }

    receive() external payable {}

    function setUp() public {
        curveContractImpl = new InverseBondingCurve();
        tokenContract = new InverseBondingCurveToken(address(this), "IBC", "IBC");

        proxyContract = new InverseBondingCurveProxy(address(curveContractImpl), "");
        tokenContract = new InverseBondingCurveToken(address(proxyContract), "IBC", "IBC");
        curveContract = InverseBondingCurve(address(proxyContract));

        //curveContract.initialize(2e18, 1e18, 1e18, address(tokenContract), otherRecipient);
    }

    function testFuzz(uint256 reserve, uint256 supply, uint256 price, uint256 additionalReserve, uint256 buyReserve)
        private
    {
        reserve = bound(reserve, 1 ether, 2e8 ether);
        supply = bound(supply, 0.5 ether, reserve);
        price = bound(price, 0.5 ether, reserve.divDown(supply));

        additionalReserve = bound(additionalReserve, 0.001 ether, 2e8 ether);
        buyReserve = bound(buyReserve, 0.001 ether, 2e8 ether);
        vm.assume(supply < reserve.divDown(price));

        curveContract.initialize(reserve, supply, price, address(tokenContract), otherRecipient);

        curveContract.addLiquidity{value: additionalReserve}(recipient, 0);

        curveContract.buyTokens{value: buyReserve}(recipient, 1e19, 1e19);
    }

    function testFuzz(uint256 additionalReserve, uint256 buyReserve) private {
        uint256 reserve = 1e21; // 1000
        uint256 supply = 5e24; //
        uint256 price = 1e14;
        // 0.0001 ETH

        additionalReserve = bound(additionalReserve, 0.001 ether, 1e4 ether);
        buyReserve = bound(buyReserve, 0.001 ether, 1e4 ether);
        vm.assume(supply < reserve.divDown(price));

        curveContract.initialize(reserve, supply, price, address(tokenContract), otherRecipient);

        curveContract.addLiquidity{value: additionalReserve}(recipient, 0);

        curveContract.buyTokens{value: buyReserve}(recipient, 1e19, 1e19);
        curveContract.removeLiquidity(recipient, curveContract.balanceOf(recipient), 1e19);

        tokenContract.approve(address(curveContract), tokenContract.balanceOf(recipient));
        curveContract.sellTokens(recipient, tokenContract.balanceOf(recipient), 0, 0);
    }

    function testSepecific() private {
        uint256 reserve = 1e18;
        uint256 supply = 5e17;
        uint256 price = 5e17;

        uint256 additionalReserve = 301962792471728260;
        uint256 buyReserve = 115501070904373826890698371;

        vm.assume(supply < reserve.divDown(price));

        curveContract.initialize(reserve, supply, price, address(tokenContract), otherRecipient);

        curveContract.addLiquidity{value: additionalReserve}(recipient, 0);

        curveContract.buyTokens{value: buyReserve}(recipient, 1e19, 1e20);
    }
}
