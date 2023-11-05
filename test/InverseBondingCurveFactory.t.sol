// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import "../src/InverseBondingCurve.sol";
import "../src/InverseBondingCurveProxy.sol";
import "../src/InverseBondingCurveToken.sol";
import "../src/InverseBondingCurveFactory.sol";
import "../src/InverseBondingCurveAdmin.sol";
import "forge-std/console2.sol";

import "./TestUtil.sol";

//TODO: add upgradable related test
contract InverseBondingCurveFactoryTest is Test {
    InverseBondingCurveFactory _factoryContract;
    InverseBondingCurveAdmin _adminContract;
    WethToken _weth;

    address recipient = address(this);
    address owner = address(this);
    address feeOwner = vm.addr(3);

    function setUp() public {
        _weth = new WethToken();
        _adminContract = new InverseBondingCurveAdmin(address(_weth), owner, feeOwner);

        _factoryContract = InverseBondingCurveFactory(_adminContract.factoryAddress());
    }

    function testCreateETHPool() public {
        uint256 initialReserve = 2e18;
        uint256 creatorBalanceBefore = address(this).balance;
        _factoryContract.createCurve{value: initialReserve}(initialReserve, address(0), recipient);

        assertEq(creatorBalanceBefore - address(this).balance, initialReserve);

        address poolAddress = _factoryContract.getCurve(address(0));

        assert(poolAddress != address(0));
        assertEq(_factoryContract.allCurvesLength(), 1);
        assertEq(_factoryContract.curves(0), poolAddress);
        assertEq(_factoryContract.getCurve(address(_weth)), poolAddress);

        assertEq(InverseBondingCurve(poolAddress).reserveTokenAddress(), address(_weth));
        assertEq(_weth.balanceOf(poolAddress), initialReserve);

        InverseBondingCurveToken tokenContract = InverseBondingCurveToken(InverseBondingCurve(poolAddress).inverseTokenAddress());
        assertEq(tokenContract.symbol(), "ibETH");

        CurveParameter memory param = InverseBondingCurve(poolAddress).curveParameters();
        assertEq(param.reserve, initialReserve);
        assertEq(param.supply, 1e18);
        assertEq(param.price, 1e18);
        assertEq(param.lpSupply, 1e18);
    }

    function testRevertIfDuplicatePool() public {
        uint256 initialReserve = 2e18;
        _factoryContract.createCurve{value: initialReserve}(initialReserve, address(0), recipient);

        address poolAddress = _factoryContract.getCurve(address(0));

        assertEq(_factoryContract.allCurvesLength(), 1);
        assertEq(_factoryContract.curves(0), poolAddress);
        assertEq(_factoryContract.getCurve(address(_weth)), poolAddress);

        vm.expectRevert();
        _factoryContract.createCurve{value: initialReserve}(initialReserve, address(0), recipient);

        ReserveToken reserveToken = new ReserveToken("USDC", "USDC", 6);

        reserveToken.mint(address(this), initialReserve * 2);
        reserveToken.approve(address(_factoryContract), initialReserve * 2);
        _factoryContract.createCurve(initialReserve, address(reserveToken), recipient);
        assertEq(_factoryContract.allCurvesLength(), 2);

        vm.expectRevert();
        _factoryContract.createCurve(initialReserve, address(reserveToken), recipient);
    }

    function testCreateERC20Pool() public {
        uint256 initialReserve = 2e7;

        ReserveToken reserveToken = new ReserveToken("USDC", "USDC", 6);

        reserveToken.mint(address(this), initialReserve);
        reserveToken.approve(address(_factoryContract), initialReserve);

        uint256 creatorBalanceBefore = reserveToken.balanceOf(address(this));
        _factoryContract.createCurve(initialReserve, address(reserveToken), recipient);

        assertEq(creatorBalanceBefore - reserveToken.balanceOf(address(this)), initialReserve);

        address poolAddress = _factoryContract.getCurve(address(reserveToken));

        assert(poolAddress != address(0));
        assertEq(_factoryContract.allCurvesLength(), 1);
        assertEq(_factoryContract.curves(0), poolAddress);

        assertEq(InverseBondingCurve(poolAddress).reserveTokenAddress(), address(reserveToken));
        assertEq(reserveToken.balanceOf(poolAddress), initialReserve);

        InverseBondingCurveToken tokenContract = InverseBondingCurveToken(InverseBondingCurve(poolAddress).inverseTokenAddress());
        assertEq(tokenContract.symbol(), "ibUSDC");

        CurveParameter memory param = InverseBondingCurve(poolAddress).curveParameters();
        assertEq(param.reserve, 2e19);
        assertEq(param.supply, 1e20);
        assertEq(param.price, 1e17);
        assertEq(param.lpSupply, 1e18);
    }

    function testMultiplecurves() public {
        uint256 initialReserve = 2e18;
        _factoryContract.createCurve{value: initialReserve}(initialReserve, address(0), recipient);

        address poolAddress = _factoryContract.getCurve(address(0));

        assertEq(_factoryContract.allCurvesLength(), 1);
        assertEq(_factoryContract.curves(0), poolAddress);
        assertEq(_factoryContract.getCurve(address(_weth)), poolAddress);

        ReserveToken reserveToken = new ReserveToken("USDC", "USDC", 6);

        reserveToken.mint(address(this), initialReserve * 2);
        reserveToken.approve(address(_factoryContract), initialReserve * 2);
        _factoryContract.createCurve(initialReserve, address(reserveToken), feeOwner);

        assertEq(_factoryContract.allCurvesLength(), 2);

        poolAddress = _factoryContract.getCurve(address(reserveToken));
        assertEq(_factoryContract.curves(1), poolAddress);

        (uint256 lpAmount, ) = InverseBondingCurve(poolAddress).liquidityPositionOf(feeOwner);
        assertEq(lpAmount, 1e18 - 1e14);
    }
}
