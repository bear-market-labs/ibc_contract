// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import "../src/InverseBondingCurve.sol";
import "../src/InverseBondingCurveProxy.sol";
import "../src/InverseBondingCurveToken.sol";
import "../src/InverseBondingCurveFactory.sol";
import "../src/InverseBondingCurveAdmin.sol";
import "../src/InverseBondingCurveRouter.sol";
import "../src/interface/IInverseBondingCurve.sol";
import "forge-std/console2.sol";

import "./TestUtil.sol";

//TODO: add upgradable related test
contract InverseBondingCurveAdminTest is Test {
    InverseBondingCurveAdmin _adminContract;
    WethToken _weth;

    address owner = address(this);
    address feeOwner = vm.addr(3);
    address router = vm.addr(4);
    address nonOwner = vm.addr(5);

    function setUp() public {
        _weth = new WethToken();
        _adminContract = new InverseBondingCurveAdmin(address(_weth), router, feeOwner);
    }


    function testConstructor() public {
        assertEq(_adminContract.weth(), address(_weth));
        assertEq(_adminContract.router(), router);
        assertEq(_adminContract.feeOwner(), feeOwner);
        assertEq(_adminContract.owner(), owner);
        assert(_adminContract.factoryAddress() != address(0));
        assert(_adminContract.curveImplementation() != address(0));
    }

    function testSetupFeePercent() public {
        (
            uint256 lpFee,
            uint256 stakingFee,
            uint256 protocolFee
        ) = _adminContract.feeConfig(ActionType.REMOVE_LIQUIDITY);
        assertEq(lpFee, LP_FEE_PERCENT);
        assertEq(stakingFee, STAKE_FEE_PERCENT);
        assertEq(protocolFee, PROTOCOL_FEE_PERCENT);

        _adminContract.updateFeeConfig(ActionType.REMOVE_LIQUIDITY, 2e15, 3e15, 4e15);

        (lpFee, stakingFee, protocolFee) = _adminContract.feeConfig(ActionType.REMOVE_LIQUIDITY);

        assertEq(lpFee, 2e15);
        assertEq(stakingFee, 3e15);
        assertEq(protocolFee, 4e15);
    }

    function testRevertIfFeeOverLimit() public {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(FeePercentOutOfRange.selector));
        _adminContract.updateFeeConfig(ActionType.REMOVE_LIQUIDITY, 2e16, 4e16, 4e16);
        vm.stopPrank();
    }

    function testRevertUpdateFromNonOwner() public {
        vm.startPrank(nonOwner);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        _adminContract.updateFeeOwner(nonOwner);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        _adminContract.updateRouter(nonOwner);   
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        _adminContract.upgradeCurveTo(nonOwner);                
        vm.stopPrank();
    }

    function testRevertIfUpdateFeeFromNonOwner() public {
        vm.startPrank(nonOwner);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        _adminContract.updateFeeConfig(ActionType.REMOVE_LIQUIDITY, 2e15, 3e15, 4e15);
        vm.stopPrank();
    }

    function testRevertIfPauseFromNonOwner() public {
        vm.startPrank(nonOwner);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        _adminContract.pause();
        vm.stopPrank();
    }

    function testRevertIfUnpauseFromNonOwner() public {
        vm.startPrank(owner);
        _adminContract.pause();
        vm.stopPrank();
        vm.startPrank(nonOwner);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        _adminContract.unpause();
        vm.stopPrank();
    }

    function testRevertIfChangeOwnerFromNonOwner() public {
        vm.startPrank(nonOwner);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        _adminContract.transferOwnership(owner);
        vm.stopPrank();
    }

    function testRevertIfChangeFeeOwnerFromNonOwner() public {
        vm.startPrank(nonOwner);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        _adminContract.updateFeeOwner(owner);
        vm.stopPrank();
    }

    function testRevertIfChangeFeeOwnerToZero() public {
        vm.startPrank(owner);
        vm.expectRevert();
        _adminContract.updateFeeOwner(address(0));
        vm.stopPrank();
    }


    function testRevertIfChangeRouterToZero() public {
        vm.startPrank(owner);
        vm.expectRevert();
        _adminContract.updateRouter(address(0));
        vm.stopPrank();
    }

    function testRevertIfUpgradeCurveToZero() public {
        vm.startPrank(owner);
        vm.expectRevert();
        _adminContract.upgradeCurveTo(address(0));
        vm.stopPrank();
    }

    function testUpdateFeeOwner() public {
        vm.startPrank(owner);
        assertEq(_adminContract.feeOwner(), feeOwner);
        _adminContract.updateFeeOwner(nonOwner);
        assertEq(_adminContract.feeOwner(), nonOwner);
        vm.stopPrank();
    }

    function testUpdateRouter() public {
        vm.startPrank(owner);
        _adminContract.updateRouter(nonOwner);
        assertEq(_adminContract.router(), nonOwner);
        vm.stopPrank();
    }

    function testUpdateCurve() public {
        vm.startPrank(owner);
        _adminContract.upgradeCurveTo(nonOwner);
        assertEq(_adminContract.curveImplementation(), nonOwner);
        vm.stopPrank();
    }


    function testUpdateOwner() public {
        vm.startPrank(owner);
        _adminContract.transferOwnership(nonOwner);
        assertEq(_adminContract.owner(), owner);

        vm.stopPrank();

        vm.startPrank(nonOwner);
        vm.expectRevert();
        _adminContract.pause();
        _adminContract.acceptOwnership();
        assertEq(_adminContract.owner(), nonOwner);
        _adminContract.pause();
        vm.stopPrank();
    }

    function testPause() public {
        vm.startPrank(owner);
        assertEq(_adminContract.paused(), false);
        _adminContract.pause();
        assertEq(_adminContract.paused(), true);

        vm.stopPrank();
        // vm.expectRevert(bytes("Pausable: paused"));
        // _adminContract.transfer(otherRecipient, 1e18);



        vm.startPrank(owner);

        _adminContract.unpause();
        assertEq(_adminContract.paused(), false);

        vm.stopPrank();
    }    

}
