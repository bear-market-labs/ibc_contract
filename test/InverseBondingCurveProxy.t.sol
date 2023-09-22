// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import "../src/InverseBondingCurve.sol";
import "../src/InverseBondingCurveProxy.sol";
import "../src/InverseBondingCurveToken.sol";
import "forge-std/console2.sol";

contract InverseBondingCurveV2 is InverseBondingCurve {
    uint256 _newValue;

    function newValueGet() public view returns (uint256) {
        return _newValue;
    }

    function newValueSet(uint256 value) public {
        _newValue = value;
    }
}

//TODO: add upgradable related test
contract InverseBondingCurveProxyTest is Test {
    InverseBondingCurve public curveContract;
    InverseBondingCurveToken tokenContract;

    uint256 ALLOWED_ERROR = 1e8;

    address recipient = address(this);
    address otherRecipient = vm.parseAddress("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266");
    uint256 feePercent = 3e15;

    function setUp() public {
        curveContract = new InverseBondingCurve();
        InverseBondingCurveProxy proxy = new InverseBondingCurveProxy(address(curveContract), "");
        tokenContract = new InverseBondingCurveToken(address(proxy), "IBC", "IBC");
        curveContract = InverseBondingCurve(address(proxy));
        curveContract.initialize(2e18, 1e18, 1e18, address(tokenContract), otherRecipient);
    }

    function testSymbol() public {
        console2.log("Symbol", curveContract.symbol());
        assertEq(curveContract.symbol(), "IBCLP");
    }

    function testInverseTokenSymbol() public {
        InverseBondingCurveToken tokenContractAddr = InverseBondingCurveToken(curveContract.inverseTokenAddress());

        assertEq(tokenContract.symbol(), "IBC");
        assertEq(address(tokenContract), address(tokenContractAddr));
    }

    function testRevertIfExternalMint() public {
        address from = vm.addr(2);
        address to = vm.addr(3);
        vm.startPrank(from);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        tokenContract.mint(to, 1);
        vm.stopPrank();
    }

    function testRevertIfExternalBurn() public {
        address from = vm.addr(2);
        address to = vm.addr(3);
        vm.startPrank(from);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        tokenContract.burnFrom(to, 1);
        vm.stopPrank();
    }

    function testRevertReInitialize() public {
        vm.expectRevert(bytes("Initializable: contract is already initialized"));
        curveContract.initialize(2e18, 1e18, 1e18, address(tokenContract), otherRecipient);
    }

    function testRevertSendingEtherToCurve() public {
        (bool sent,) = address(curveContract).call{value: 1 ether}("");

        assertEq(sent, false);
    }

    function testUpgrade() public {
        InverseBondingCurveV2 contractV2 = new InverseBondingCurveV2();
        (bool success, bytes memory data) = address(curveContract).call(abi.encodeWithSignature("newValueGet()"));
        assertEq(success, false);
        curveContract.upgradeTo(address(contractV2));
        (success, data) = address(curveContract).call(abi.encodeWithSignature("newValueSet(uint256)", 2e18));
        assertEq(success, true);
        (success, data) = address(curveContract).call(abi.encodeWithSignature("newValueGet()"));
        assertEq(success, true);
        assertEq(bytes32(data), bytes32(uint256(2e18)));
    }

    function testRevertIfUpgradeNotFromProxy() public {
        address from = vm.addr(2);
        InverseBondingCurveV2 contractV2 = new InverseBondingCurveV2();
        vm.startPrank(from);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        curveContract.upgradeTo(address(contractV2));
        vm.stopPrank();
    }
}
