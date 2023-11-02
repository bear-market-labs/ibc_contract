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
contract InverseBondingCurveRouterTest is Test {
    InverseBondingCurveFactory _factoryContract;
    InverseBondingCurveAdmin _adminContract;
    InverseBondingCurveRouter _router;
    WethToken _weth;

    address owner = address(this);
    address feeOwner = vm.addr(3);

    address recipient = vm.addr(4);

    uint256 ALLOWED_ERROR = 1e10;

    uint256 LIQUIDITY_2ETH_BEFOR_FEE = 2020202020202020202; // 2e18 / 0.99, to make actual liquidity 2eth
    uint256 LIQUIDITY_20USDC_BEFOR_FEE = 20202020;

    function assertEqWithError(uint256 a, uint256 b) internal {
        uint256 diff = a > b ? a - b : b - a;
        if (diff > ALLOWED_ERROR) {
            emit log("Error: a == b not satisfied [decimal int]");
            emit log_named_decimal_uint("      Left", a, 18);
            emit log_named_decimal_uint("     Right", b, 18);
            fail();
        }
    }

    function setUp() public {
        _weth = new WethToken();
        _router = new InverseBondingCurveRouter(address(_weth));
        _adminContract =
            new InverseBondingCurveAdmin(address(_weth), address(_router), feeOwner, type(InverseBondingCurve).creationCode);

        _factoryContract = InverseBondingCurveFactory(_adminContract.factoryAddress());
    }

    function testRevertIfDepositToRouter() public {
        vm.expectRevert();
        payable(address(_router)).transfer(1 ether);
    }

    function testInteractionWithETHPool() public {
        uint256 initialReserve = 2e18;
        uint256 buyReserve = 2e18;
        uint256 creatorBalanceBefore = address(this).balance;
        _factoryContract.createCurve{value: initialReserve}(initialReserve, address(0), address(this));

        assertEq(creatorBalanceBefore - address(this).balance, initialReserve);

        address poolAddress = _factoryContract.getCurve(address(0));
        IInverseBondingCurve curveContract = IInverseBondingCurve(poolAddress);
        InverseBondingCurveToken inverseToken = InverseBondingCurveToken(curveContract.inverseTokenAddress());

        vm.deal(recipient, 1000 ether);
        vm.startPrank(recipient);
        console2.log("recipient", recipient);

        // Add liquidity
        bytes memory data = abi.encode(recipient, LIQUIDITY_2ETH_BEFOR_FEE, [0, 0]);

        _router.execute{value: LIQUIDITY_2ETH_BEFOR_FEE}(recipient, poolAddress, true, CommandType.ADD_LIQUIDITY, data);

        (uint256 lpPosition, uint256 creditToken) = curveContract.liquidityPositionOf(recipient);
        assertEq(lpPosition, 1e18);
        assertEq(creditToken, 1e18);
        console2.log("add liquidity", lpPosition);

        // Buy token
        data = abi.encode(recipient, buyReserve, 0, [0, 0], [0, 0]);
        uint256 tokenBalanceBefore = inverseToken.balanceOf(recipient);
        _router.execute{value: buyReserve}(recipient, poolAddress, true, CommandType.BUY_TOKEN, data);
        uint256 boughtToken = inverseToken.balanceOf(recipient) - tokenBalanceBefore;
        assertGt(boughtToken, 0);
        console2.log("boughtToken", boughtToken);

        // Stake token
        tokenBalanceBefore = inverseToken.balanceOf(recipient);
        data = abi.encode(recipient, tokenBalanceBefore);

        inverseToken.approve(address(_router), tokenBalanceBefore);
        _router.execute(recipient, poolAddress, true, CommandType.STAKE, data);
        assertEq(inverseToken.balanceOf(recipient), 0);
        console2.log("stake success");

        // Unstake token
        data = abi.encode(recipient, tokenBalanceBefore);
        _router.execute(recipient, poolAddress, true, CommandType.UNSTAKE, data);
        assertEq(inverseToken.balanceOf(recipient), tokenBalanceBefore);
        console2.log("unstake success");

        // Sell token
        data = abi.encode(recipient, boughtToken / 2, [0, 0], [0, 0]);
        uint256 reserveBalanceBefore = recipient.balance;
        inverseToken.approve(address(_router), boughtToken);
        _router.execute(recipient, poolAddress, true, CommandType.SELL_TOKEN, data);
        assertGt(recipient.balance, reserveBalanceBefore);
        console2.log("sell liquidity:", recipient.balance - reserveBalanceBefore);

        // Remove liquidity
        data = abi.encode(recipient, inverseToken.balanceOf(recipient), [0, 0]);
        reserveBalanceBefore = recipient.balance;
        _router.execute(recipient, poolAddress, true, CommandType.REMOVE_LIQUIDITY, data);
        assertGt(recipient.balance, reserveBalanceBefore);
        console2.log("remove liquidity:", recipient.balance - reserveBalanceBefore);

        // Claim reward
        data = abi.encode(recipient);
        tokenBalanceBefore = inverseToken.balanceOf(recipient);
        _router.execute(recipient, poolAddress, true, CommandType.CLAIM_REWARD, data);
        assertGt(inverseToken.balanceOf(recipient), tokenBalanceBefore);
        console2.log("claim reward:", inverseToken.balanceOf(recipient) - tokenBalanceBefore);

        vm.stopPrank();
    }

    function testInteractionWithERC20Pool() public {
        uint256 initialReserve = 2e7;
        uint256 buyReserve = 2e7;
        ReserveToken reserveToken = new ReserveToken("USDC", "USDC", 6);

        reserveToken.mint(address(this), initialReserve);
        reserveToken.approve(address(_factoryContract), initialReserve);

        _factoryContract.createCurve(initialReserve, address(reserveToken), address(this));

        address poolAddress = _factoryContract.getCurve(address(reserveToken));
        IInverseBondingCurve curveContract = IInverseBondingCurve(poolAddress);
        InverseBondingCurveToken inverseToken = InverseBondingCurveToken(curveContract.inverseTokenAddress());

        reserveToken.mint(recipient, 1e8);
        vm.startPrank(recipient);
        // Add liquidity
        bytes memory data = abi.encode(recipient, LIQUIDITY_20USDC_BEFOR_FEE, [0, 0]);
        reserveToken.approve(address(_router), LIQUIDITY_20USDC_BEFOR_FEE);
        _router.execute(recipient, poolAddress, false, CommandType.ADD_LIQUIDITY, data);

        (uint256 lpPosition, uint256 creditToken) = curveContract.liquidityPositionOf(recipient);
        assertEqWithError(lpPosition, 1e18);
        assertEqWithError(creditToken / 1e12, 1e8);
        assertEqWithError(reserveToken.balanceOf(address(poolAddress)), LIQUIDITY_20USDC_BEFOR_FEE + initialReserve);
        console2.log("add liquidity", lpPosition);

        // Buy token
        data = abi.encode(recipient, buyReserve, 0, [0, 0], [0, 0]);
        uint256 tokenBalanceBefore = inverseToken.balanceOf(recipient);
        reserveToken.approve(address(_router), buyReserve);
        _router.execute(recipient, poolAddress, false, CommandType.BUY_TOKEN, data);
        uint256 boughtToken = inverseToken.balanceOf(recipient) - tokenBalanceBefore;
        assertGt(boughtToken, 0);
        console2.log("boughtToken", boughtToken);

        // Stake token
        tokenBalanceBefore = inverseToken.balanceOf(recipient);
        data = abi.encode(recipient, tokenBalanceBefore);

        inverseToken.approve(address(_router), tokenBalanceBefore);
        _router.execute(recipient, poolAddress, false, CommandType.STAKE, data);
        assertEq(inverseToken.balanceOf(recipient), 0);
        console2.log("stake success");

        // Unstake token
        data = abi.encode(recipient, tokenBalanceBefore);
        _router.execute(recipient, poolAddress, false, CommandType.UNSTAKE, data);
        assertEq(inverseToken.balanceOf(recipient), tokenBalanceBefore);
        console2.log("unstake success");

        // Sell token
        data = abi.encode(recipient, boughtToken / 2, [0, 0], [0, 0]);
        uint256 reserveBalanceBefore = reserveToken.balanceOf(recipient);
        inverseToken.approve(address(_router), boughtToken);
        _router.execute(recipient, poolAddress, false, CommandType.SELL_TOKEN, data);
        assertGt(reserveToken.balanceOf(recipient), reserveBalanceBefore);
        console2.log("sell liquidity:", reserveToken.balanceOf(recipient) - reserveBalanceBefore);

        // Remove liquidity
        data = abi.encode(recipient, inverseToken.balanceOf(recipient), [0, 0]);
        reserveBalanceBefore = reserveToken.balanceOf(recipient);
        _router.execute(recipient, poolAddress, false, CommandType.REMOVE_LIQUIDITY, data);
        assertGt(reserveToken.balanceOf(recipient), reserveBalanceBefore);
        console2.log("remove liquidity:", reserveToken.balanceOf(recipient) - reserveBalanceBefore);

        // Claim reward
        data = abi.encode(recipient);
        tokenBalanceBefore = inverseToken.balanceOf(recipient);
        _router.execute(recipient, poolAddress, false, CommandType.CLAIM_REWARD, data);
        assertGt(inverseToken.balanceOf(recipient), tokenBalanceBefore);
        console2.log("claim reward:", inverseToken.balanceOf(recipient) - tokenBalanceBefore);

        vm.stopPrank();
    }
}
