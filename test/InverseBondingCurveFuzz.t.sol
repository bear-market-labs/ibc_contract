// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import "../src/InverseBondingCurve.sol";
import "../src/InverseBondingCurveToken.sol";
import "../src/InverseBondingCurveRouter.sol";
import "../src/InverseBondingCurveFactory.sol";

import "../src/InverseBondingCurveAdmin.sol";
import "./TestUtil.sol";
import "forge-std/console2.sol";


contract InverseBondingCurveFuzzTest is Test {
    using FixedPoint for uint256;

    InverseBondingCurveFactory _factoryContract;
    InverseBondingCurveAdmin _adminContract;
    InverseBondingCurveRouter _router;
    WethToken _weth;

    uint256 ALLOWED_ERROR = 1e10;

    address recipient = address(this);
    address otherRecipient = vm.parseAddress("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266");
    uint256 feePercent = 3e15;
    address nonOwner = vm.addr(1);
    address feeOwner = vm.addr(2);
    address owner = address(this);
    address initializer = vm.addr(40);

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
        _weth = new WethToken();
        _router = new InverseBondingCurveRouter(address(_weth));
        _adminContract =
            new InverseBondingCurveAdmin(address(_weth), address(_router), feeOwner, type(InverseBondingCurve).creationCode);

        _factoryContract = InverseBondingCurveFactory(_adminContract.factoryAddress());        
    }


    function testETHCurveFuzz(uint256 initialReserve, uint256 additionalReserve, uint256 buyReserve) public {

        initialReserve = bound(additionalReserve, 0.01 ether, 1e4 ether);
        additionalReserve = bound(additionalReserve, 0.01 ether, 1e4 ether);
        buyReserve = bound(buyReserve, 0.1 ether, 1e4 ether);

        vm.deal(initializer, initialReserve * 2);
        vm.startPrank(initializer);
        _factoryContract.createCurve{value: initialReserve}(initialReserve, address(0), initializer);
        vm.stopPrank();

        console2.log("after createCurve");

        address curveContractAddress = _factoryContract.getCurve(address(0));
        InverseBondingCurve curveContract = InverseBondingCurve(curveContractAddress);
        InverseBondingCurveToken inverseToken = InverseBondingCurveToken(curveContract.inverseTokenAddress());
        CurveParameter memory initialParam = curveContract.curveParameters();
        logParameter(initialParam, "after initialization");

        // Add liquidity
        bytes memory data = abi.encode(recipient, additionalReserve, [0, 0]);
        _router.execute{value: additionalReserve}(recipient, curveContractAddress, true, CommandType.ADD_LIQUIDITY, data);


        //Buy token
        data = abi.encode(recipient, buyReserve, 0, [0, 0], [0, 0]);
        _router.execute{value: buyReserve}(recipient, curveContractAddress, true, CommandType.BUY_TOKEN, data);

        // Remove liquidity
        data = abi.encode(recipient, inverseToken.balanceOf(recipient), [0, 0]);
        inverseToken.approve(address(_router), inverseToken.balanceOf(recipient));
        _router.execute(recipient, curveContractAddress, true, CommandType.REMOVE_LIQUIDITY, data);
        console2.log("after remove");

        // Sell token
        data = abi.encode(recipient, inverseToken.balanceOf(recipient), [0, 0], [0, 0]);
        inverseToken.approve(address(_router), inverseToken.balanceOf(recipient));
        _router.execute(recipient, curveContractAddress, true, CommandType.SELL_TOKEN, data);

        CurveParameter memory param = curveContract.curveParameters();

        // assertEqWithError(param.lpSupply, initialParam.lpSupply);
        // assertEqWithError(param.reserve, reserve);
        // assertEqWithError(param.supply, supply);
        // assertEqWithError(param.price, price);

        // vm.startPrank(initializer);
        // data = abi.encode(initializer, inverseToken.balanceOf(recipient), [0, 0]);
        // inverseToken.approve(address(_router), inverseToken.balanceOf(recipient));
        // _router.execute(initializer, curveContractAddress, true, CommandType.REMOVE_LIQUIDITY, data);        
        // vm.stopPrank();


        data = abi.encode(recipient);
        _router.execute(recipient, curveContractAddress, true, CommandType.CLAIM_REWARD, data);

        vm.startPrank(initializer);
        data = abi.encode(initializer);
        _router.execute(initializer, curveContractAddress, true, CommandType.CLAIM_REWARD, data);
        vm.stopPrank();

        vm.startPrank(feeOwner);
        curveContract.claimProtocolReward();
        vm.stopPrank();

        param = curveContract.curveParameters();


        assertEqWithError(param.lpSupply, 1e18);
        // assertEqWithError(param.reserve, 0);
        // assertEqWithError(param.supply, 0);
        // assertEqWithError(param.price, 0);
    }

    function testERC20CurveFuzz(uint256 initialReserve, uint256 additionalReserve, uint256 buyReserve) public {
        
        initialReserve = bound(additionalReserve, 1e7, 1e15);
        additionalReserve = bound(additionalReserve, 1e5, 1e15);
        buyReserve = bound(buyReserve, 1e5, 1e10);

        ReserveToken reserveToken = new ReserveToken("USDC", "USDC", 6);
        reserveToken.mint(address(this), initialReserve);
        vm.deal(initializer, 10 ether);
        reserveToken.mint(initializer, initialReserve);

        vm.startPrank(initializer); 
        reserveToken.approve(address(_factoryContract), initialReserve);       
        _factoryContract.createCurve(initialReserve, address(reserveToken), initializer);
        vm.stopPrank();

        address curveContractAddress = _factoryContract.getCurve(address(reserveToken));
        InverseBondingCurve curveContract = InverseBondingCurve(curveContractAddress);
        InverseBondingCurveToken inverseToken = InverseBondingCurveToken(curveContract.inverseTokenAddress());
        CurveParameter memory initialParam = curveContract.curveParameters();
        logParameter(initialParam, "after initialization");

        // Add liquidity
        reserveToken.mint(recipient, additionalReserve);
        reserveToken.approve(address(_router), additionalReserve);
        bytes memory data = abi.encode(recipient, additionalReserve, [0, 0]); 
        _router.execute(recipient, curveContractAddress, false, CommandType.ADD_LIQUIDITY, data);

        // Remove liquidity
        data = abi.encode(recipient, inverseToken.balanceOf(recipient), [0, 0]);
        inverseToken.approve(address(_router), inverseToken.balanceOf(recipient));
        _router.execute(recipient, curveContractAddress, false, CommandType.REMOVE_LIQUIDITY, data);

        //Buy token
        reserveToken.mint(recipient, buyReserve);
        reserveToken.approve(address(_router), buyReserve);
        data = abi.encode(recipient, buyReserve, 0, [0, 0], [0, 0]);
        _router.execute(recipient, curveContractAddress, false, CommandType.BUY_TOKEN, data);



        // Sell token
        data = abi.encode(recipient, inverseToken.balanceOf(recipient), [0, 0], [0, 0]);
        inverseToken.approve(address(_router), inverseToken.balanceOf(recipient));
        _router.execute(recipient, curveContractAddress, false, CommandType.SELL_TOKEN, data);

        CurveParameter memory param = curveContract.curveParameters();

        // assertEqWithError(param.lpSupply, initialParam.lpSupply);
        // assertEqWithError(param.reserve, reserve);
        // assertEqWithError(param.supply, supply);
        // assertEqWithError(param.price, price);

        // vm.startPrank(initializer);
        // data = abi.encode(initializer, inverseToken.balanceOf(recipient), [0, 0]);
        // inverseToken.approve(address(_router), inverseToken.balanceOf(recipient));
        // _router.execute(initializer, curveContractAddress, true, CommandType.REMOVE_LIQUIDITY, data);        
        // vm.stopPrank();


        data = abi.encode(recipient);
        _router.execute(recipient, curveContractAddress, false, CommandType.CLAIM_REWARD, data);

        vm.startPrank(initializer);
        data = abi.encode(initializer);
        _router.execute(initializer, curveContractAddress, false, CommandType.CLAIM_REWARD, data);
        vm.stopPrank();

        vm.startPrank(feeOwner);
        curveContract.claimProtocolReward();
        vm.stopPrank();

        param = curveContract.curveParameters();


        assertEqWithError(param.lpSupply, 1e18);
        // assertEqWithError(param.reserve, 0);
        // assertEqWithError(param.supply, 0);
        // assertEqWithError(param.price, 0);
    }    



    function testERC20CurveFuzzSpecific(uint256 initialReserve, uint256 additionalReserve, uint256 buyReserve) public {

        ReserveToken reserveToken = new ReserveToken("USDC", "USDC", 6);

       

        initialReserve = 10000000000;
        additionalReserve = 10000000000;
        buyReserve = 9999999997;

        reserveToken.mint(address(this), initialReserve);

        vm.deal(initializer, 10 ether);
        reserveToken.mint(initializer, initialReserve);
        
        vm.startPrank(initializer); 
        reserveToken.approve(address(_factoryContract), initialReserve);       
        _factoryContract.createCurve(initialReserve, address(reserveToken), initializer);
        vm.stopPrank();

        console2.log("after createCurve");

        address curveContractAddress = _factoryContract.getCurve(address(reserveToken));
        InverseBondingCurve curveContract = InverseBondingCurve(curveContractAddress);
        InverseBondingCurveToken inverseToken = InverseBondingCurveToken(curveContract.inverseTokenAddress());
        CurveParameter memory initialParam = curveContract.curveParameters();
        logParameter(initialParam, "after initialization");

        // Add liquidity
        reserveToken.mint(recipient, additionalReserve);
        reserveToken.approve(address(_router), additionalReserve);
        bytes memory data = abi.encode(recipient, additionalReserve, [0, 0]); 
        _router.execute(recipient, curveContractAddress, false, CommandType.ADD_LIQUIDITY, data);
        console2.log("after add liquidity");

        //Buy token
        console2.log("reserveToken.totalSupply", reserveToken.totalSupply());
        console2.log("buyReserve", buyReserve);
        reserveToken.mint(recipient, buyReserve);
        console2.log("after mint");
        reserveToken.approve(address(_router), buyReserve);
        data = abi.encode(recipient, buyReserve, 0, [0, 0], [0, 0]);
        _router.execute(recipient, curveContractAddress, false, CommandType.BUY_TOKEN, data);

        // Remove liquidity
        data = abi.encode(recipient, inverseToken.balanceOf(recipient), [0, 0]);
        inverseToken.approve(address(_router), inverseToken.balanceOf(recipient));
        _router.execute(recipient, curveContractAddress, false, CommandType.REMOVE_LIQUIDITY, data);
        console2.log("after remove");

        // Sell token
        data = abi.encode(recipient, inverseToken.balanceOf(recipient), [0, 0], [0, 0]);
        inverseToken.approve(address(_router), inverseToken.balanceOf(recipient));
        _router.execute(recipient, curveContractAddress, false, CommandType.SELL_TOKEN, data);

        CurveParameter memory param = curveContract.curveParameters();

        // assertEqWithError(param.lpSupply, initialParam.lpSupply);
        // assertEqWithError(param.reserve, reserve);
        // assertEqWithError(param.supply, supply);
        // assertEqWithError(param.price, price);

        // vm.startPrank(initializer);
        // data = abi.encode(initializer, inverseToken.balanceOf(recipient), [0, 0]);
        // inverseToken.approve(address(_router), inverseToken.balanceOf(recipient));
        // _router.execute(initializer, curveContractAddress, true, CommandType.REMOVE_LIQUIDITY, data);        
        // vm.stopPrank();


        data = abi.encode(recipient);
        _router.execute(recipient, curveContractAddress, false, CommandType.CLAIM_REWARD, data);

        vm.startPrank(initializer);
        data = abi.encode(initializer);
        _router.execute(initializer, curveContractAddress, false, CommandType.CLAIM_REWARD, data);
        vm.stopPrank();

        vm.startPrank(feeOwner);
        curveContract.claimProtocolReward();
        vm.stopPrank();

        param = curveContract.curveParameters();


        // assertEqWithError(param.lpSupply, 0);
        // assertEqWithError(param.reserve, 0);
        // assertEqWithError(param.supply, 0);
        // assertEqWithError(param.price, 0);
    }



    // function testSpecific() public {
    //     uint256 reserve = 2e22; // 2000
    //     uint256 supply = 1e21; //
    //     uint256 price = 1e19;

    //     // uint256 additionalReserve = 638085905206215834182;
    //     // uint256 buyReserve = 190767065193740254156;

    //     uint256 additionalReserve = 9999999000000000000005;
    //     uint256 buyReserve = 10000000000000000;

    //     vm.assume(supply < reserve.divDown(price));

    //     curveContract.initialize{value: reserve}(supply, price, address(tokenContract), otherRecipient);
    //     CurveParameter memory param = curveContract.curveParameters();
    //     logParameter(param, "after initialize");

    //     curveContract.addLiquidity{value: additionalReserve}(recipient, 0);
    //     // CurveParameter memory param = curveContract.curveParameters();
    //     param = curveContract.curveParameters();
    //     logParameter(param, "after add liquidity");

    //     curveContract.buyTokens{value: buyReserve}(recipient, 0, 1e20);
    //     param = curveContract.curveParameters();
    //     logParameter(param, "after buy token");

    //     uint256 newInvariant = param.reserve.divDown((param.supply).powDown(param.parameterUtilization));
    //     console2.log("newInvariant:", newInvariant);

    //     uint256 _parameterUtilization = param.price.mulDown(param.supply).divDown(param.reserve);

    //     // require(_parameterUtilization < UINT_ONE, ERR_UTILIZATION_INVALID);
    //     uint256 _parameterInvariant = param.reserve.divDown(param.supply.powDown(_parameterUtilization));

    //     console2.log("new calc _parameterUtilization:", _parameterUtilization);
    //     console2.log("new calc _parameterInvariant:", _parameterInvariant);

    //     tokenContract.approve(address(curveContract), tokenContract.balanceOf(recipient));
    //     curveContract.removeLiquidity(recipient, 1e19);
    //     param = curveContract.curveParameters();
    //     logParameter(param, "after remove liquidity");

    //     _parameterUtilization = param.price.mulDown(param.supply).divDown(param.reserve);
    //     _parameterInvariant = param.reserve.divDown(param.supply.powDown(_parameterUtilization));

    //     console2.log("new calc _parameterUtilization:", _parameterUtilization);
    //     console2.log("new calc _parameterInvariant:", _parameterInvariant);

    //     console2.log("sell amount:", tokenContract.balanceOf(recipient));

    //     curveContract.sellTokens(recipient, tokenContract.balanceOf(recipient), 0);
    //     param = curveContract.curveParameters();
    //     logParameter(param, "after sell token");
    // }

    function logParameter(CurveParameter memory param, string memory desc) private pure {
        console2.log(desc);
        console2.log("  reserve:", param.reserve);
        console2.log("  supply:", param.supply);
        console2.log("  price:", param.price);
        console2.log("  parameterInvariant:", param.parameterInvariant);
    }
}
