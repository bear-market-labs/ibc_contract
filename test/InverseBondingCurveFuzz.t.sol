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

        curveContract.buyTokens{value: buyReserve}(recipient, 1e19);
    }

    function testFuzz(uint256 additionalReserve, uint256 buyReserve) private {
        uint256 reserve = 2e22; // 2000
        uint256 supply = 1e21; //
        uint256 price = 1e19;

        additionalReserve = bound(additionalReserve, 0.001 ether, 1e4 ether);
        buyReserve = bound(buyReserve, 0.01 ether, 1e4 ether);
        vm.assume(supply < reserve.divDown(price));

        curveContract.initialize(reserve, supply, price, address(tokenContract), otherRecipient);

        curveContract.addLiquidity{value: additionalReserve}(recipient, 0);

        tokenContract.approve(address(curveContract), tokenContract.balanceOf(recipient));
        curveContract.buyTokens{value: buyReserve}(recipient, 1e20);
        curveContract.removeLiquidity(recipient, 1e19);

        // tokenContract.approve(address(curveContract), tokenContract.balanceOf(recipient));
        curveContract.sellTokens(recipient, tokenContract.balanceOf(recipient), 0);
    }

    function testSpecific() private {
        uint256 reserve = 2e22; // 2000
        uint256 supply = 1e21; //
        uint256 price = 1e19;

        // uint256 additionalReserve = 638085905206215834182;
        // uint256 buyReserve = 190767065193740254156;

        uint256 additionalReserve = 1e21;
        uint256 buyReserve = 1e21;

        vm.assume(supply < reserve.divDown(price));

        curveContract.initialize(reserve, supply, price, address(tokenContract), otherRecipient);
        CurveParameter memory param = curveContract.curveParameters();
        logParameter(param, "after initialize");

        curveContract.addLiquidity{value: additionalReserve}(recipient, 0);
        // CurveParameter memory param = curveContract.curveParameters();
        param = curveContract.curveParameters();
        logParameter(param, "after add liquidity");

        curveContract.buyTokens{value: buyReserve}(recipient, 1e20);
        param = curveContract.curveParameters();
        logParameter(param, "after buy token");

        uint256 newInvariant = param.reserve.divDown((param.supply).powDown(param.parameterUtilization));
        console2.log("newInvariant:", newInvariant);

        uint256 _parameterUtilization = param.price.mulDown(param.supply).divDown(param.reserve);

        // require(_parameterUtilization < ONE_UINT, ERR_UTILIZATION_INVALID);
        uint256 _parameterInvariant = param.reserve.divDown(param.supply.powDown(_parameterUtilization));

        console2.log("new calc _parameterUtilization:", _parameterUtilization);
        console2.log("new calc _parameterInvariant:", _parameterInvariant);

        tokenContract.approve(address(curveContract), tokenContract.balanceOf(recipient));
        curveContract.removeLiquidity(recipient, 1e19);
        param = curveContract.curveParameters();
        logParameter(param, "after remove liquidity");

       
        curveContract.sellTokens(recipient, tokenContract.balanceOf(recipient), 0);
        param = curveContract.curveParameters();
        logParameter(param, "after sell token");
    }

    function logParameter(CurveParameter memory param, string memory desc) private pure {
        console2.log(desc);
        console2.log("  reserve:", param.reserve);
        console2.log("  supply:", param.supply);
        console2.log("  virtualReserve:", param.virtualReserve);
        console2.log("  virtualSupply:", param.virtualSupply);
        console2.log("  price:", param.price);
        console2.log("  parameterInvariant:", param.parameterInvariant);
        console2.log("  parameterUtilization:", param.parameterUtilization);
    }
}
