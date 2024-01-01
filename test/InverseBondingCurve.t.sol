// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import "openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";
import "../src/InverseBondingCurve.sol";
import "../src/InverseBondingCurveToken.sol";
import "../src/InverseBondingCurveProxy.sol";
import "../src/interface/IInverseBondingCurveAdmin.sol";
import "./TestUtil.sol";
import "forge-std/console2.sol";


contract MockAdmin is IInverseBondingCurveAdmin {
    address private _router;
    address private _protocolFeeOwner;
    address private _curveImplementation;
    bool _paused;

    uint256 FEE_PERCENT = 1e15;

    uint256[MAX_ACTION_COUNT] private _lpFeePercent = [LP_FEE_PERCENT, LP_FEE_PERCENT, LP_FEE_PERCENT, LP_FEE_PERCENT];
    uint256[MAX_ACTION_COUNT] private _stakingFeePercent =
        [STAKE_FEE_PERCENT, STAKE_FEE_PERCENT, STAKE_FEE_PERCENT, STAKE_FEE_PERCENT];
    uint256[MAX_ACTION_COUNT] private _protocolFeePercent =
        [PROTOCOL_FEE_PERCENT, PROTOCOL_FEE_PERCENT, PROTOCOL_FEE_PERCENT, PROTOCOL_FEE_PERCENT];

    constructor(address protocolFeeOwner, address routerAddress){
        _protocolFeeOwner = protocolFeeOwner;
        _router = routerAddress;

        updateFeeConfig(ActionType.BUY_TOKEN, FEE_PERCENT, FEE_PERCENT, FEE_PERCENT);
        updateFeeConfig(ActionType.SELL_TOKEN, FEE_PERCENT, FEE_PERCENT, FEE_PERCENT);
        updateFeeConfig(ActionType.ADD_LIQUIDITY, FEE_PERCENT, FEE_PERCENT, FEE_PERCENT);
        updateFeeConfig(ActionType.REMOVE_LIQUIDITY, FEE_PERCENT, FEE_PERCENT, FEE_PERCENT);
    }

    function paused() external view returns (bool){
        return _paused;
    }

    function pause() external {
        _paused = true;
    }

    function unpause() external {
        _paused = false;
    }

    function upgradeCurveTo(address newImplementation) external {
        if (newImplementation == address(0)) revert EmptyAddress();
        _curveImplementation = newImplementation;
    }

    function feeConfig(ActionType actionType) external view returns (uint256 lpFee, uint256 stakingFee, uint256 protocolFee) {
        lpFee = _lpFeePercent[uint256(actionType)];
        stakingFee = _stakingFeePercent[uint256(actionType)];
        protocolFee = _protocolFeePercent[uint256(actionType)];
    }

    function updateFeeConfig(ActionType actionType, uint256 lpFee, uint256 stakingFee, uint256 protocolFee) public {
        if ((lpFee + stakingFee + protocolFee) >= MAX_FEE_PERCENT) revert FeePercentOutOfRange();
        if (uint256(actionType) >= MAX_ACTION_COUNT) revert InvalidInput();

        _lpFeePercent[uint256(actionType)] = lpFee;
        _stakingFeePercent[uint256(actionType)] = stakingFee;
        _protocolFeePercent[uint256(actionType)] = protocolFee;
    }

    function feeOwner() external view returns (address) {
        return _protocolFeeOwner;
    }

    function router() external view returns (address) {
        return _router;
    }

    function weth() external pure returns (address){
        return address(0);
    }

    function curveImplementation() external view returns (address) {
        return _curveImplementation;
    }

    function owner() external pure returns (address){
        return address(0);
    }
}

contract InverseBondingCurveV2 is InverseBondingCurve {
    uint256 _newValue;

    function newValueGet() public view returns (uint256) {
        return _newValue;
    }

    function newValueSet(uint256 value) public {
        _newValue = value;
    }
}

contract InverseBondingCurveTest is Test {
    using FixedPoint for uint256;

    InverseBondingCurve curveContract;
    InverseBondingCurveToken tokenContract;
    // InverseBondingCurveProxy proxyContract;
    InverseBondingCurve curveContractImpl;
    MockAdmin adminContract;
    ReserveToken reserveToken;

    uint256 ALLOWED_ERROR = 1e10;
    uint256 FEE_PERCENT = 1e15;

    address recipient = address(this);

    
    
    uint256 feePercent = 3e15;
    address nonOwner = vm.addr(1);
    address feeOwner = vm.addr(2);
    address otherRecipient = vm.addr(20);
    address router = vm.addr(30);
    address initializer = vm.addr(40);

    address owner = address(this);
    address deadAccount = vm.parseAddress("0x000000000000000000000000000000000000dEaD");

    uint256 LIQUIDITY_2ETH_BEFOR_FEE = 2006018054162487000; // 2e18 / 0.997, to make actual liquidity 2eth

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
        uint256 initialReserve = 2e18;
        vm.warp(1);
        reserveToken = new ReserveToken("WETH", "WETH", 18);

        reserveToken.mint(initializer, initialReserve);
        vm.deal(initializer, 100 ether);

        tokenContract = new InverseBondingCurveToken("ibETH", "ibETH");

        adminContract = new MockAdmin(feeOwner, router);

        curveContractImpl = new InverseBondingCurve();
        adminContract.upgradeCurveTo(address(curveContractImpl));

        curveContract = InverseBondingCurve(address(new InverseBondingCurveProxy(address(adminContract), address(curveContractImpl), "")));
        tokenContract.transferOwnership(address(curveContract));
        vm.startPrank(initializer);
        reserveToken.transfer(address(curveContract), initialReserve);
        curveContract.initialize(address(adminContract), router, address(tokenContract), address(reserveToken), initializer, initialReserve);
        vm.stopPrank();

    }

    function testInverseTokenSymbol() public {
        assertEq(IERC20Metadata(curveContract.inverseTokenAddress()).symbol(), "ibETH");
    }


    function testInitialize() public {
        // uint256 price = curveContract.priceOf(1e18);
        CurveParameter memory param = curveContract.curveParameters();

        assertEqWithError(param.price, 1e18);
        assertEqWithError(tokenContract.balanceOf(initializer), 0);
        (uint256 lpBalance, uint256 ibcCredit) = curveContract.liquidityPositionOf(initializer);
        (uint256 deadLpBalance, uint256 deadIbcCredit) = curveContract.liquidityPositionOf(deadAccount);
        console2.log("lpBalance", lpBalance);
        console2.log("deadLpBalance", deadLpBalance);
        assertEqWithError(deadLpBalance, lpBalance / 1e4);
        assertEqWithError(deadIbcCredit, ibcCredit / 1e4);
        assertEq(param.reserve, 2e18);
        assertEq(param.supply, 1e18);
        assertEq(tokenContract.totalSupply(), 0);
        assertEq(lpBalance + deadLpBalance, 1e18);
        assertEq(ibcCredit + deadIbcCredit, 1e18);
    }

    function testInverseTokenAddress() public {
        assertEq(curveContract.inverseTokenAddress(), address(tokenContract));
    }


    function testAddLiquidity() public {
        uint256[2] memory valueRange = [uint256(0),uint256(0)];
        CurveParameter memory param = curveContract.curveParameters();
        reserveToken.mint(recipient, LIQUIDITY_2ETH_BEFOR_FEE);
        reserveToken.transfer(address(curveContract), LIQUIDITY_2ETH_BEFOR_FEE);
        curveContract.addLiquidity(recipient, LIQUIDITY_2ETH_BEFOR_FEE, valueRange);

        param = curveContract.curveParameters();

        assertEqWithError(param.price, 1e18);

        assertEqWithError(tokenContract.balanceOf(recipient), 0);
        (uint256 lpBalance, uint256 ibcCredit) = curveContract.liquidityPositionOf(recipient);
        assertEqWithError(lpBalance, 1e18);
        assertEqWithError(ibcCredit, 1e18);
    }

    function testRemoveLiquidity() public {
        uint256[2] memory valueRange = [uint256(0),uint256(0)];
        CurveParameter memory param = curveContract.curveParameters();
        assertEqWithError(param.price, 1e18);

        reserveToken.mint(recipient, LIQUIDITY_2ETH_BEFOR_FEE);
        reserveToken.transfer(address(curveContract), LIQUIDITY_2ETH_BEFOR_FEE);
        curveContract.addLiquidity(recipient, LIQUIDITY_2ETH_BEFOR_FEE, valueRange);
        param = curveContract.curveParameters();
        assertEqWithError(param.price, 1e18);
        (uint256 lpBalance, uint256 ibcCredit) = curveContract.liquidityPositionOf(recipient);

        uint256 balanceBefore = reserveToken.balanceOf(otherRecipient);

        curveContract.removeLiquidity(otherRecipient, 0, valueRange);

        uint256 balanceAfter = reserveToken.balanceOf(otherRecipient);

        param = curveContract.curveParameters();
        assertEqWithError(param.price, 1e18);

        assertEqWithError(tokenContract.balanceOf(recipient), 0);
        (lpBalance, ibcCredit) = curveContract.liquidityPositionOf(recipient);
        assertEqWithError(lpBalance, 0);
        assertEqWithError(balanceAfter - balanceBefore, uint256(2e18).mulDown(UINT_ONE.sub(FEE_PERCENT.mulDown(3e18))));
    }

    function testRemoveLiquidityReturnAdditionalToken() public {
        uint256[2] memory valueRange = [uint256(0),uint256(0)];
        CurveParameter memory param = curveContract.curveParameters();
        assertEqWithError(param.price, 1e18);


        reserveToken.mint(recipient, LIQUIDITY_2ETH_BEFOR_FEE);
        reserveToken.transfer(address(curveContract), LIQUIDITY_2ETH_BEFOR_FEE);
        curveContract.buyTokens(recipient, LIQUIDITY_2ETH_BEFOR_FEE, 0, valueRange, valueRange);

        reserveToken.mint(recipient, LIQUIDITY_2ETH_BEFOR_FEE);
        reserveToken.transfer(address(curveContract), LIQUIDITY_2ETH_BEFOR_FEE);
        curveContract.addLiquidity(recipient, LIQUIDITY_2ETH_BEFOR_FEE, valueRange);
        param = curveContract.curveParameters();
        uint256 priceBefore = param.price;

        (uint256 lpBalance, uint256 ibcCredit) = curveContract.liquidityPositionOf(recipient);

        uint256 balanceBefore = reserveToken.balanceOf(otherRecipient);
        uint256 tokenBalanceBefore = tokenContract.balanceOf(recipient);
        tokenContract.transfer(address(curveContract), tokenBalanceBefore);
        curveContract.removeLiquidity(otherRecipient, tokenBalanceBefore, valueRange);

        uint256 balanceAfter = reserveToken.balanceOf(otherRecipient);

        param = curveContract.curveParameters();
        assertEqWithError(priceBefore, param.price);

        assertEqWithError(tokenContract.balanceOf(otherRecipient), tokenBalanceBefore);
        assertEqWithError(tokenContract.balanceOf(recipient), 0);
        (lpBalance, ibcCredit) = curveContract.liquidityPositionOf(recipient);
        assertEqWithError(lpBalance, 0);
        assertEqWithError(balanceAfter - balanceBefore, uint256(2e18).mulDown(UINT_ONE.sub(FEE_PERCENT.mulDown(3e18))));
    }

    function testRemoveLiquidityWithAdditionalBurn() public {
        uint256[2] memory valueRange = [uint256(0),uint256(0)];
        CurveParameter memory param = curveContract.curveParameters();
        assertEqWithError(param.price, 1e18);

        reserveToken.mint(recipient, LIQUIDITY_2ETH_BEFOR_FEE);
        reserveToken.transfer(address(curveContract), LIQUIDITY_2ETH_BEFOR_FEE);
        curveContract.addLiquidity(recipient, LIQUIDITY_2ETH_BEFOR_FEE, valueRange);
        param = curveContract.curveParameters();
        assertEqWithError(param.price, 1e18);

        reserveToken.mint(recipient, LIQUIDITY_2ETH_BEFOR_FEE);
        reserveToken.transfer(address(curveContract), LIQUIDITY_2ETH_BEFOR_FEE);
        curveContract.buyTokens(otherRecipient, LIQUIDITY_2ETH_BEFOR_FEE, 0, valueRange, valueRange);
        (uint256 lpBalance, uint256 ibcCredit) = curveContract.liquidityPositionOf(recipient);

        console2.log("bought token:", tokenContract.balanceOf(otherRecipient));

        uint256 balanceBefore = reserveToken.balanceOf(otherRecipient);
        vm.expectRevert();
        curveContract.removeLiquidity(otherRecipient, 0, valueRange);

        reserveToken.mint(recipient, LIQUIDITY_2ETH_BEFOR_FEE);
        reserveToken.transfer(address(curveContract), LIQUIDITY_2ETH_BEFOR_FEE);
        curveContract.buyTokens(recipient, LIQUIDITY_2ETH_BEFOR_FEE, 0, valueRange, valueRange);
        console2.log("bought token:", tokenContract.balanceOf(recipient));
        vm.expectRevert();
        curveContract.removeLiquidity(otherRecipient, 0, valueRange);

        tokenContract.approve(address(curveContract), 1e19);
        uint256 tokenBalanceBefore = tokenContract.balanceOf(recipient);
        uint256 otherBalanceBefore = tokenContract.balanceOf(otherRecipient);
        tokenContract.transfer(address(curveContract), tokenBalanceBefore);
        curveContract.removeLiquidity(otherRecipient, tokenBalanceBefore, valueRange);

        (lpBalance, ibcCredit) = curveContract.liquidityPositionOf(recipient);

        assertEq(lpBalance, 0);
        assertEq(ibcCredit, 0);

        uint256 balanceAfter = reserveToken.balanceOf(otherRecipient);
        assertGt(balanceAfter, balanceBefore);
        // Rest mint to LP recipient
        assertLt(otherBalanceBefore, tokenContract.balanceOf(otherRecipient));
        assertLt(tokenContract.balanceOf(otherRecipient) - otherBalanceBefore, tokenBalanceBefore);
    }

    function testRemoveLiquidityGetAdditionalMint() public {
        uint256[2] memory valueRange = [uint256(0),uint256(0)];
        CurveParameter memory param = curveContract.curveParameters();
        assertEqWithError(param.price, 1e18);


        reserveToken.mint(recipient, LIQUIDITY_2ETH_BEFOR_FEE);
        reserveToken.transfer(address(curveContract), LIQUIDITY_2ETH_BEFOR_FEE);
        curveContract.buyTokens(otherRecipient, LIQUIDITY_2ETH_BEFOR_FEE, 0, valueRange, valueRange);


        reserveToken.mint(recipient, LIQUIDITY_2ETH_BEFOR_FEE);
        reserveToken.transfer(address(curveContract), LIQUIDITY_2ETH_BEFOR_FEE);
        curveContract.addLiquidity(recipient, LIQUIDITY_2ETH_BEFOR_FEE, valueRange);

        vm.startPrank(otherRecipient);
        uint256 otherBalanceBefore = tokenContract.balanceOf(otherRecipient);
        tokenContract.transfer(address(curveContract), otherBalanceBefore);
        curveContract.sellTokens(otherRecipient, otherBalanceBefore, valueRange, valueRange);
        vm.stopPrank();

        uint256 balanceBefore = reserveToken.balanceOf(otherRecipient);
        uint256 tokenBalanceBefore = tokenContract.balanceOf(otherRecipient);
        vm.recordLogs();
        curveContract.removeLiquidity(otherRecipient, 0,  valueRange);
        Vm.Log[] memory entries = vm.getRecordedLogs();
        // Token mint event Transfer(0, recipient, amount)
        address tokenReceiver = address(uint160(uint256(entries[1].topics[2])));
        uint256 mintedToken = abi.decode(entries[1].data, (uint256));
        assertEq(tokenReceiver, address(curveContract));

        (uint256 lpBalance, uint256 ibcCredit) = curveContract.liquidityPositionOf(recipient);

        assertEq(lpBalance, 0);
        assertEq(ibcCredit, 0);

        uint256 balanceAfter = reserveToken.balanceOf(otherRecipient);
        assertGt(balanceAfter, balanceBefore);
        assertEqWithError(tokenContract.balanceOf(otherRecipient) - tokenBalanceBefore, mintedToken.mulDown(UINT_ONE.sub(FEE_PERCENT.mulDown(3e18))));
    }

    function testBuyTokensExactAmount() public {
        uint256[2] memory valueRange = [uint256(0),uint256(0)];
        uint256 buyLiquidity = 2e18;
        uint256 buyToken = 2e18;
        uint256 balanceBefore = tokenContract.balanceOf(otherRecipient);
        uint256 reserveBalanceBefore = reserveToken.balanceOf(otherRecipient);
        uint256 curveBalanceBefore = reserveToken.balanceOf(address(curveContract));

        reserveToken.mint(recipient, buyLiquidity);
        reserveToken.transfer(address(curveContract), buyLiquidity);
        curveContract.buyTokens(otherRecipient, buyLiquidity, buyToken, valueRange, valueRange);

        uint256 balanceAfter = tokenContract.balanceOf(otherRecipient);

        uint256 balanceChange = balanceAfter - balanceBefore;

        assertEqWithError(balanceChange, 2e18);
        assertGt(reserveToken.balanceOf(otherRecipient), reserveBalanceBefore);
        assertEq(reserveToken.balanceOf(address(curveContract)) - curveBalanceBefore + reserveToken.balanceOf(otherRecipient), buyToken);
    }

    function testSellTokens() public {
        uint256[2] memory valueRange = [uint256(0),uint256(0)];
        uint256 buyLiquidity = 1e18;
        uint256 sellTokenAmount = 1e18;

        reserveToken.mint(recipient, buyLiquidity);
        reserveToken.transfer(address(curveContract), buyLiquidity);
        curveContract.buyTokens(recipient, buyLiquidity, 0, valueRange, valueRange);

        uint256 balanceBefore = tokenContract.balanceOf(recipient);
        uint256 ethBalanceBefore = reserveToken.balanceOf(otherRecipient);

        tokenContract.transfer(address(curveContract), sellTokenAmount);
        curveContract.sellTokens(otherRecipient, sellTokenAmount, valueRange, valueRange);
        uint256 ethBalanceAfter = reserveToken.balanceOf(otherRecipient);
        uint256 balanceAfter = tokenContract.balanceOf(recipient);

        assertEq(balanceBefore - balanceAfter, 1e18);
        uint256 balanceOut = 761250348967084500;

        uint256 ethBalanceChange = ethBalanceAfter - ethBalanceBefore;
        assertEqWithError(ethBalanceChange, balanceOut);
    }

    function testFeeAccumulate() public {
        uint256[2] memory valueRange = [uint256(0),uint256(0)];
        uint256 buyLiquidity = 1e18;
        uint256 sellTokenAmount = 1e18;

        reserveToken.mint(recipient, LIQUIDITY_2ETH_BEFOR_FEE);
        reserveToken.transfer(address(curveContract), LIQUIDITY_2ETH_BEFOR_FEE);
        curveContract.addLiquidity(recipient, LIQUIDITY_2ETH_BEFOR_FEE, valueRange);


        reserveToken.mint(recipient, buyLiquidity);
        reserveToken.transfer(address(curveContract), buyLiquidity);
        curveContract.buyTokens(otherRecipient, buyLiquidity, 0, valueRange, valueRange);


        uint256 feeBalance = tokenContract.balanceOf(address(curveContract));

        uint256 tokenOut = tokenContract.balanceOf(otherRecipient);
        uint256 fee = (tokenOut * feePercent) / (1e18 - feePercent);

        assertEqWithError(feeBalance, fee);
        vm.startPrank(otherRecipient);
        

        tokenContract.transfer(address(curveContract), sellTokenAmount);
        curveContract.sellTokens(otherRecipient, sellTokenAmount, valueRange, valueRange);

        vm.stopPrank();

        feeBalance = tokenContract.balanceOf(address(curveContract));
        fee += 1e18 * feePercent / 1e18;

        assertEqWithError(feeBalance, fee);
        (uint256 lpReward,,,) = curveContract.rewardOf(recipient);

        uint256 balanceBefore = tokenContract.balanceOf(otherRecipient);
        curveContract.claimReward(otherRecipient);
        uint256 balanceAfter = tokenContract.balanceOf(otherRecipient);

        (uint256 lpBalance,) = curveContract.liquidityPositionOf(recipient);
        CurveParameter memory param = curveContract.curveParameters();

        assertEq(balanceAfter - balanceBefore, lpReward);
        assertEqWithError(
            feeBalance.divDown(3e18).mulDown(lpBalance.divDown(param.lpSupply)), balanceAfter - balanceBefore
        );
        assertEqWithError(tokenContract.balanceOf(address(curveContract)), feeBalance - (balanceAfter - balanceBefore));

        vm.startPrank(otherRecipient);
        tokenContract.transfer(address(curveContract), tokenOut - sellTokenAmount);
        curveContract.stake(otherRecipient, tokenOut - sellTokenAmount);
        vm.stopPrank();

        (, uint256 stakingTokenReward,, uint256 stakingReserveReward) = curveContract.rewardOf(otherRecipient);
        uint256 accumulatedReserveFee = (LIQUIDITY_2ETH_BEFOR_FEE - 2e18).divDown(3e18);
        assertEqWithError(feeBalance.divDown(3e18), stakingTokenReward);
        assertEqWithError(stakingReserveReward, accumulatedReserveFee);

        vm.startPrank(otherRecipient);
        balanceBefore = tokenContract.balanceOf(otherRecipient);
        uint256 reserveTokenBefore = reserveToken.balanceOf(otherRecipient);
        curveContract.claimReward(otherRecipient);
        balanceAfter = tokenContract.balanceOf(otherRecipient);
        uint256 reserveTokenAfter = reserveToken.balanceOf(otherRecipient);
        assertEqWithError(balanceAfter - balanceBefore, stakingTokenReward);
        assertEqWithError(reserveTokenAfter - reserveTokenBefore, accumulatedReserveFee);
        vm.stopPrank();
    }

    function testClaimRewardFeePortion() public {
        uint256[2] memory valueRange = [uint256(0),uint256(0)];
        uint256 buyLiquidity = 1e18;

        reserveToken.mint(recipient, LIQUIDITY_2ETH_BEFOR_FEE);
        reserveToken.transfer(address(curveContract), LIQUIDITY_2ETH_BEFOR_FEE);
        curveContract.addLiquidity(recipient, LIQUIDITY_2ETH_BEFOR_FEE, valueRange);


        uint256 feeBalanceBefore = tokenContract.balanceOf(address(curveContract));

        reserveToken.mint(recipient, buyLiquidity);
        reserveToken.transfer(address(curveContract), buyLiquidity);
        curveContract.buyTokens(otherRecipient, buyLiquidity, 0, valueRange, valueRange);

        uint256 feeBalanceAfter = tokenContract.balanceOf(address(curveContract));
        uint256 totalFee = feeBalanceAfter - feeBalanceBefore;

        uint256 balanceBefore = tokenContract.balanceOf(otherRecipient);
        curveContract.claimReward(otherRecipient);
        uint256 balanceAfter = tokenContract.balanceOf(otherRecipient);

        assertEqWithError(totalFee, (balanceAfter - balanceBefore) * 6);
    }

    function testClaimRewardLiquidityChange() public {
        uint256[2] memory valueRange = [uint256(0),uint256(0)];
        address thirdRecipient = vm.addr(3);
        uint256 buyLiquidity = 2e18;
        uint256 sellTokenAmount = 1e18;

        vm.deal(otherRecipient, 1000 ether);
        vm.deal(thirdRecipient, 1000 ether);

        vm.startPrank(otherRecipient);
        reserveToken.mint(otherRecipient, LIQUIDITY_2ETH_BEFOR_FEE);
        reserveToken.transfer(address(curveContract), LIQUIDITY_2ETH_BEFOR_FEE);
        curveContract.addLiquidity(otherRecipient, LIQUIDITY_2ETH_BEFOR_FEE, valueRange);
        vm.stopPrank();

        reserveToken.mint(recipient, buyLiquidity);
        reserveToken.transfer(address(curveContract), buyLiquidity);
        curveContract.buyTokens(otherRecipient, buyLiquidity, 0, valueRange, valueRange);


        vm.startPrank(otherRecipient);
        tokenContract.transfer(thirdRecipient, 1e18);
        vm.stopPrank();

        curveContract.claimReward(recipient);

        vm.startPrank(otherRecipient);
        curveContract.claimReward(otherRecipient);
        vm.stopPrank();

        vm.startPrank(otherRecipient);

        tokenContract.transfer(address(curveContract), sellTokenAmount);
        curveContract.sellTokens(otherRecipient, sellTokenAmount, valueRange, valueRange);
 

        CurveParameter memory param = curveContract.curveParameters();
        (uint256 lpBalance, uint256 ibcCredit) = curveContract.liquidityPositionOf(otherRecipient);
        uint256 firstSellFee = 1e15 * lpBalance / param.lpSupply;

        vm.stopPrank();

        vm.startPrank(thirdRecipient);
        uint256 addLiquidity = reserveToken.balanceOf(address(curveContract));
        reserveToken.mint(thirdRecipient, addLiquidity);
        reserveToken.transfer(address(curveContract), addLiquidity);
        curveContract.addLiquidity(thirdRecipient, addLiquidity, valueRange);


        tokenContract.transfer(address(curveContract), 1e18);
        curveContract.sellTokens(otherRecipient, 1e18, valueRange, valueRange);


        param = curveContract.curveParameters();

        (lpBalance, ibcCredit) = curveContract.liquidityPositionOf(otherRecipient);
        uint256 secondSellFee = 1e15 * lpBalance / param.lpSupply;
        vm.stopPrank();

        vm.startPrank(otherRecipient);
        uint256 balanceBefore = tokenContract.balanceOf(otherRecipient);
        curveContract.claimReward(otherRecipient);
        uint256 balanceAfter = tokenContract.balanceOf(otherRecipient);
        uint256 otherRecipientFee = balanceAfter - balanceBefore;
        vm.stopPrank();

        vm.startPrank(thirdRecipient);
        balanceBefore = tokenContract.balanceOf(thirdRecipient);
        curveContract.claimReward(thirdRecipient);
        balanceAfter = tokenContract.balanceOf(thirdRecipient);
        uint256 thirdRecipientFee = balanceAfter - balanceBefore;
        (lpBalance, ibcCredit) = curveContract.liquidityPositionOf(thirdRecipient);
        uint256 secondSellFeeForthirdRecipient = uint256(1e15).mulDown(lpBalance).divDown(param.lpSupply);
        vm.stopPrank();

        assertEqWithError(firstSellFee + secondSellFee, otherRecipientFee);
        assertEqWithError(secondSellFeeForthirdRecipient, thirdRecipientFee);
    }

    function testClaimRewardStakingChange() public {
        uint256[2] memory valueRange = [uint256(0),uint256(0)];
        address thirdRecipient = vm.addr(3);
        uint256 buyLiquidity = 2e19;
        
        vm.deal(otherRecipient, 1000 ether);
        vm.deal(thirdRecipient, 1000 ether);
        reserveToken.mint(recipient, buyLiquidity);
        reserveToken.transfer(address(curveContract), buyLiquidity);
        curveContract.buyTokens(otherRecipient, buyLiquidity, 0, valueRange, valueRange);


        vm.startPrank(otherRecipient);
        tokenContract.transfer(thirdRecipient, 2e18);
        vm.stopPrank();

        curveContract.claimReward(recipient);
        vm.startPrank(otherRecipient);

        tokenContract.transfer(address(curveContract), 1e18);
        curveContract.stake(otherRecipient, 1e18);
        curveContract.claimReward(otherRecipient);
        vm.stopPrank();

        vm.startPrank(otherRecipient);
        tokenContract.transfer(address(curveContract), 1e18);
        curveContract.sellTokens(otherRecipient, 1e18, valueRange, valueRange);
        vm.stopPrank();

        vm.startPrank(thirdRecipient);

        tokenContract.transfer(address(curveContract), 1e18);
        curveContract.stake(thirdRecipient, 1e18);
        tokenContract.transfer(address(curveContract), 1e18);
        curveContract.sellTokens(otherRecipient, 1e18, valueRange, valueRange);
        vm.stopPrank();

        vm.startPrank(otherRecipient);

        uint256 balanceBefore = tokenContract.balanceOf(otherRecipient);
        curveContract.claimReward(otherRecipient);
        uint256 balanceAfter = tokenContract.balanceOf(otherRecipient);
        uint256 otherRecipientFee = balanceAfter - balanceBefore;

        vm.stopPrank();

        vm.startPrank(thirdRecipient);

        balanceBefore = tokenContract.balanceOf(thirdRecipient);
        curveContract.claimReward(thirdRecipient);
        balanceAfter = tokenContract.balanceOf(thirdRecipient);
        uint256 thirdRecipientFee = balanceAfter - balanceBefore;
        vm.stopPrank();

        assertEq(otherRecipientFee, feePercent / 3 + feePercent / 6);
        assertEq(thirdRecipientFee, feePercent / 6);
    }


    function testStake() public {

        uint256[2] memory valueRange = [uint256(0),uint256(0)];
        uint256 buyLiquidity = 2e18;

        reserveToken.mint(recipient, buyLiquidity);
        reserveToken.transfer(address(curveContract), buyLiquidity);
        curveContract.buyTokens(recipient, buyLiquidity, 0, valueRange, valueRange);


        uint256 stakeAmount = tokenContract.balanceOf(recipient);
        assertEq(curveContract.stakingBalanceOf(recipient), 0);

        tokenContract.transfer(address(curveContract), stakeAmount);
        curveContract.stake(recipient, stakeAmount);

        assertEq(tokenContract.balanceOf(recipient), 0);
        assertEq(curveContract.stakingBalanceOf(recipient), stakeAmount);
        assertEq(curveContract.totalStaked(), stakeAmount);
    }

    function testStakeForOtherRecipient() public {

        uint256[2] memory valueRange = [uint256(0),uint256(0)];
        uint256 buyLiquidity = 2e18;

        reserveToken.mint(recipient, buyLiquidity);
        reserveToken.transfer(address(curveContract), buyLiquidity);
        curveContract.buyTokens(recipient, buyLiquidity, 0, valueRange, valueRange);


        uint256 stakeAmount = tokenContract.balanceOf(recipient);
        assertEq(curveContract.stakingBalanceOf(recipient), 0);

        tokenContract.transfer(address(curveContract), stakeAmount);
        curveContract.stake(otherRecipient, stakeAmount);

        assertEq(tokenContract.balanceOf(recipient), 0);
        assertEq(curveContract.stakingBalanceOf(otherRecipient), stakeAmount);
        assertEq(curveContract.totalStaked(), stakeAmount);
    }

    function testUnstake() public {
        uint256[2] memory valueRange = [uint256(0),uint256(0)];
        uint256 buyLiquidity = 2e18;

        reserveToken.mint(recipient, buyLiquidity);
        reserveToken.transfer(address(curveContract), buyLiquidity);
        curveContract.buyTokens(recipient, buyLiquidity, 0, valueRange, valueRange);


        uint256 stakeAmount = tokenContract.balanceOf(recipient);
        assertEq(curveContract.stakingBalanceOf(recipient), 0);

        tokenContract.transfer(address(curveContract), stakeAmount);
        curveContract.stake(recipient, stakeAmount);
        assertEq(tokenContract.balanceOf(recipient), 0);
        assertEq(curveContract.stakingBalanceOf(recipient), stakeAmount);

        curveContract.unstake(recipient, stakeAmount);
        assertEq(tokenContract.balanceOf(recipient), stakeAmount);
        assertEq(curveContract.stakingBalanceOf(recipient), 0);
    }

    function testUnstakeForOtherRecipient() public {
        uint256[2] memory valueRange = [uint256(0),uint256(0)];
        uint256 buyLiquidity = 2e18;

        reserveToken.mint(recipient, buyLiquidity);
        reserveToken.transfer(address(curveContract), buyLiquidity);
        curveContract.buyTokens(recipient, buyLiquidity, 0, valueRange, valueRange);


        uint256 stakeAmount = tokenContract.balanceOf(recipient);
        assertEq(curveContract.stakingBalanceOf(recipient), 0);

        tokenContract.transfer(address(curveContract), stakeAmount);
        curveContract.stake(recipient, stakeAmount);
        assertEq(tokenContract.balanceOf(recipient), 0);
        assertEq(curveContract.stakingBalanceOf(recipient), stakeAmount);

        curveContract.unstake(otherRecipient, stakeAmount);
        assertEq(tokenContract.balanceOf(otherRecipient), stakeAmount);
        assertEq(curveContract.stakingBalanceOf(recipient), 0);
    }

    function testClaimProtocolFee() public {
        uint256[2] memory valueRange = [uint256(0),uint256(0)];
        uint256 buyLiquidity = 1e18;

        reserveToken.mint(recipient, LIQUIDITY_2ETH_BEFOR_FEE);
        reserveToken.transfer(address(curveContract), LIQUIDITY_2ETH_BEFOR_FEE);
        curveContract.addLiquidity(recipient, LIQUIDITY_2ETH_BEFOR_FEE, valueRange);

        uint256 accumulatedReserveFee = (LIQUIDITY_2ETH_BEFOR_FEE - 2e18).divDown(3e18);

        uint256 balanceBefore = tokenContract.balanceOf(otherRecipient);

        reserveToken.mint(recipient, buyLiquidity);
        reserveToken.transfer(address(curveContract), buyLiquidity);
        curveContract.buyTokens(otherRecipient, buyLiquidity, 0, valueRange, valueRange);

        uint256 balanceAfter = tokenContract.balanceOf(otherRecipient);
        uint256 balanceChange = balanceAfter - balanceBefore;

        uint256 accumulatedTokenFee =
            uint256(balanceChange.divDown(1e18 - FEE_PERCENT.mulDown(3e18)).mulDown(FEE_PERCENT));
        (uint256 inverseTokenReward, uint256 reserveReward) = curveContract.rewardOfProtocol();

        assertEqWithError(inverseTokenReward, accumulatedTokenFee);
        assertEqWithError(reserveReward, accumulatedReserveFee);

        uint256 reserveBalanceBefore = reserveToken.balanceOf(feeOwner);
        uint256 tokenBalanceBefore = tokenContract.balanceOf(feeOwner);
        vm.startPrank(feeOwner);
        curveContract.claimProtocolReward();
        vm.stopPrank();
        uint256 reserveBalanceAfter = reserveToken.balanceOf(feeOwner);
        uint256 tokenBalanceAfter = tokenContract.balanceOf(feeOwner);
        assertEq(reserveBalanceAfter - reserveBalanceBefore, reserveReward);
        assertEq(tokenBalanceAfter - tokenBalanceBefore, inverseTokenReward);
    }

    function testClaimProtocolFeeWithAdditionalToken() public {
        uint256[2] memory valueRange = [uint256(0),uint256(0)];
        uint256 buyLiquidity = 1e18;

        reserveToken.mint(recipient, LIQUIDITY_2ETH_BEFOR_FEE);
        reserveToken.transfer(address(curveContract), LIQUIDITY_2ETH_BEFOR_FEE);
        curveContract.addLiquidity(recipient, LIQUIDITY_2ETH_BEFOR_FEE, valueRange);

        uint256 accumulatedReserveFee = (LIQUIDITY_2ETH_BEFOR_FEE - 2e18).divDown(3e18);

        uint256 balanceBefore = tokenContract.balanceOf(otherRecipient);

        reserveToken.mint(recipient, buyLiquidity);
        reserveToken.transfer(address(curveContract), buyLiquidity);
        curveContract.buyTokens(otherRecipient, buyLiquidity, 0, valueRange, valueRange);

        uint256 balanceAfter = tokenContract.balanceOf(otherRecipient);
        uint256 balanceChange = balanceAfter - balanceBefore;

        uint256 accumulatedTokenFee =
            uint256(balanceChange.divDown(1e18 - FEE_PERCENT.mulDown(3e18)).mulDown(FEE_PERCENT));
        (uint256 inverseTokenReward, uint256 reserveReward) = curveContract.rewardOfProtocol();

        assertEqWithError(inverseTokenReward, accumulatedTokenFee);
        assertEqWithError(reserveReward, accumulatedReserveFee);

        reserveToken.mint(recipient, 1e18);
        reserveToken.transfer(address(curveContract), 1e18);
        vm.startPrank(otherRecipient);
        tokenContract.transfer(address(curveContract), 1e18);
        vm.stopPrank();
        uint256 reserveBalanceBefore = reserveToken.balanceOf(feeOwner);
        uint256 tokenBalanceBefore = tokenContract.balanceOf(feeOwner);
        vm.startPrank(feeOwner);
        curveContract.claimProtocolReward();
        vm.stopPrank();
        uint256 reserveBalanceAfter = reserveToken.balanceOf(feeOwner);
        uint256 tokenBalanceAfter = tokenContract.balanceOf(feeOwner);
        assertEq(reserveBalanceAfter - reserveBalanceBefore, reserveReward + 1e18);
        assertEq(tokenBalanceAfter - tokenBalanceBefore, inverseTokenReward + 1e18);
    }

    function testRewardFirstStaker() public {
        uint256[2] memory valueRange = [uint256(0),uint256(0)];
        uint256 buyLiquidity = 2e18;

        reserveToken.mint(recipient, LIQUIDITY_2ETH_BEFOR_FEE);
        reserveToken.transfer(address(curveContract), LIQUIDITY_2ETH_BEFOR_FEE);
        curveContract.addLiquidity(recipient, LIQUIDITY_2ETH_BEFOR_FEE, valueRange);

        uint256 accumulatedReserveFee = (LIQUIDITY_2ETH_BEFOR_FEE - 2e18).divDown(3e18);


        uint256 balanceBefore = tokenContract.balanceOf(otherRecipient);
        reserveToken.mint(recipient, buyLiquidity);
        reserveToken.transfer(address(curveContract), buyLiquidity);
        curveContract.buyTokens(otherRecipient, buyLiquidity, 0, valueRange, valueRange);


        uint256 balanceAfter = tokenContract.balanceOf(otherRecipient);
        uint256 balanceChange = balanceAfter - balanceBefore;

        uint256 accumulatedTokenFee =
            uint256(balanceChange.divDown(1e18 - FEE_PERCENT.mulDown(3e18)).mulDown(FEE_PERCENT));

        vm.startPrank(otherRecipient);
        tokenContract.transfer(address(curveContract), 1e18);
        curveContract.stake(otherRecipient, 1e18);


        (uint256 inverseTokenForLp, uint256 inverseTokenForStaking, uint256 reserveForLp, uint256 reserveForStaking) =
            curveContract.rewardOf(otherRecipient);

        assertEq(inverseTokenForLp, 0);
        assertEq(reserveForLp, 0);

        assertEqWithError(inverseTokenForStaking, accumulatedTokenFee);
        assertEqWithError(reserveForStaking, accumulatedReserveFee);

        curveContract.unstake(otherRecipient, 1e18);

        tokenContract.transfer(address(curveContract), 1e18);
        curveContract.sellTokens(recipient, 1e18, valueRange, valueRange);

        tokenContract.transfer(address(curveContract), 1e18);
        curveContract.stake(otherRecipient, 1e18);

        uint256 reserveBalanceBefore = reserveToken.balanceOf(otherRecipient);
        uint256 tokenBalanceBefore = tokenContract.balanceOf(otherRecipient);

        curveContract.unstake(recipient, 1e18);

        curveContract.claimReward(otherRecipient);

        uint256 reserveBalanceAfter = reserveToken.balanceOf(otherRecipient);
        uint256 tokenBalanceAfter = tokenContract.balanceOf(otherRecipient);
        assertEq(reserveBalanceAfter - reserveBalanceBefore, reserveForStaking);
        assertEq(tokenBalanceAfter - tokenBalanceBefore, inverseTokenForStaking + feePercent.divDown(3e18));

        (inverseTokenForLp, inverseTokenForStaking, reserveForLp, reserveForStaking) =
            curveContract.rewardOf(recipient);

        assertEq(inverseTokenForStaking, 0);
        assertEq(reserveForStaking, 0);

        vm.stopPrank();
    }

    function testRevertIfPriceOutOfLimitWhenBuyToken() public {
        uint256[2] memory valueRange = [uint256(0),uint256(0)];
        uint256 buyLiquidity = 1e18;

        reserveToken.mint(recipient, buyLiquidity);
        reserveToken.transfer(address(curveContract), buyLiquidity);
        curveContract.buyTokens(recipient, buyLiquidity, 0, valueRange, valueRange);

        CurveParameter memory param = curveContract.curveParameters();


        tokenContract.transfer(address(curveContract), 1e18);
        curveContract.sellTokens(recipient, 1e18, valueRange, valueRange);
        // CurveParameter memory param2 = curveContract.curveParameters();

        //vm.expectRevert(bytes(ERR_PRICE_OUT_OF_LIMIT));
        //vm.expectRevert(abi.encodeWithSelector(PriceOutOfLimit.selector, param2.price, param.price));
        
        // curveContract.buyTokens{value: 1 ether}(recipient, 0, param.price);
        reserveToken.mint(recipient, buyLiquidity);
        reserveToken.transfer(address(curveContract), buyLiquidity);
        valueRange[1] = param.price;
        vm.expectRevert();
        curveContract.buyTokens(recipient, buyLiquidity, 0, valueRange, valueRange);
    }

    function testRevertIfReserveOutOfLimitWhenBuyToken() public {
        uint256[2] memory priceRange = [uint256(0),uint256(0)];
        uint256[2] memory reserveRange = [uint256(0),uint256(0)];
        uint256 buyLiquidity = 1e18;

        reserveToken.mint(recipient, buyLiquidity);
        reserveToken.transfer(address(curveContract), buyLiquidity);
        curveContract.buyTokens(recipient, buyLiquidity, 0, priceRange, reserveRange);

        CurveParameter memory param = curveContract.curveParameters();

        reserveToken.mint(recipient, LIQUIDITY_2ETH_BEFOR_FEE);
        reserveToken.transfer(address(curveContract), LIQUIDITY_2ETH_BEFOR_FEE);
        curveContract.addLiquidity(recipient, LIQUIDITY_2ETH_BEFOR_FEE, priceRange);

        param = curveContract.curveParameters();


        // vm.expectRevert(bytes(ERR_RESERVE_OUT_OF_LIMIT));
        reserveToken.mint(recipient, buyLiquidity);
        reserveToken.transfer(address(curveContract), buyLiquidity);
        reserveRange[1] = 2e18;
        vm.expectRevert();
        curveContract.buyTokens(recipient, buyLiquidity, 0, priceRange, reserveRange);
    }

    function testRevertIfPriceOutOfLimitWhenSellToken() public {
        uint256[2] memory priceRange = [uint256(0),uint256(0)];
        uint256[2] memory reserveRange = [uint256(0),uint256(0)];
        uint256 buyLiquidity = 1e18;

        reserveToken.mint(recipient, buyLiquidity);
        reserveToken.transfer(address(curveContract), buyLiquidity);
        curveContract.buyTokens(recipient, buyLiquidity, 0, priceRange, reserveRange);

        CurveParameter memory param = curveContract.curveParameters();

        reserveToken.mint(recipient, buyLiquidity);
        reserveToken.transfer(address(curveContract), buyLiquidity);
        curveContract.buyTokens(recipient, buyLiquidity, 0, priceRange, reserveRange);

        // vm.expectRevert(bytes(ERR_PRICE_OUT_OF_LIMIT));
        priceRange[0] = param.price;
        tokenContract.transfer(address(curveContract), 1e18);
        vm.expectRevert();
        curveContract.sellTokens(recipient, 1e18, priceRange, reserveRange);        
    }

    function testRevertIfReserveOutOfLimitWhenSellToken() public {
        uint256[2] memory priceRange = [uint256(0),uint256(0)];
        uint256[2] memory reserveRange = [uint256(0),uint256(0)];

        uint256 buyLiquidity = 1e18;

        reserveToken.mint(recipient, LIQUIDITY_2ETH_BEFOR_FEE);
        reserveToken.transfer(address(curveContract), LIQUIDITY_2ETH_BEFOR_FEE);
        curveContract.addLiquidity(recipient, LIQUIDITY_2ETH_BEFOR_FEE, priceRange);


        reserveToken.mint(recipient, buyLiquidity);
        reserveToken.transfer(address(curveContract), buyLiquidity);
        curveContract.buyTokens(recipient, buyLiquidity, 0, priceRange, reserveRange);

        uint256 tokenBalanceBefore = tokenContract.balanceOf(recipient);
        tokenContract.transfer(address(curveContract), tokenBalanceBefore);
        curveContract.removeLiquidity(recipient, tokenBalanceBefore, priceRange);

        console2.log("tokenContract.balanceOf(recipient)", tokenContract.balanceOf(recipient));


        tokenContract.transfer(address(curveContract), 5e17);
        reserveRange[0] = 4e18;
        vm.expectRevert();
        curveContract.sellTokens(recipient, 5e17, priceRange, reserveRange);  

        // tokenContract.approve(address(curveContract), 2e18);
        // //vm.expectRevert(bytes(ERR_RESERVE_OUT_OF_LIMIT));
        // vm.expectRevert();
        // curveContract.sellTokens(recipient, 1e18, 0);
    }

    function testRevertIfPriceOutOfLimitWhenAddLiquidity() public {
        uint256[2] memory priceRange = [uint256(0),uint256(0)];
        uint256[2] memory reserveRange = [uint256(0),uint256(0)];
        uint256 buyLiquidity = 1e18;

        reserveToken.mint(recipient, buyLiquidity);
        reserveToken.transfer(address(curveContract), buyLiquidity);
        curveContract.buyTokens(recipient, buyLiquidity, 0, priceRange, reserveRange);

        // vm.expectRevert(bytes(ERR_PRICE_OUT_OF_LIMIT));

        reserveToken.mint(recipient, LIQUIDITY_2ETH_BEFOR_FEE);
        reserveToken.transfer(address(curveContract), LIQUIDITY_2ETH_BEFOR_FEE);
        priceRange[0] = 1e18;
        vm.expectRevert();
        curveContract.addLiquidity(recipient, LIQUIDITY_2ETH_BEFOR_FEE, priceRange);
    }

    function testRevertIfPriceOutOfLimitWhenRemoveLiquidity() public {
        uint256[2] memory priceRange = [uint256(0),uint256(0)];
        uint256[2] memory reserveRange = [uint256(0),uint256(0)];

        uint256 buyLiquidity = 1e18;

        reserveToken.mint(recipient, LIQUIDITY_2ETH_BEFOR_FEE);
        reserveToken.transfer(address(curveContract), LIQUIDITY_2ETH_BEFOR_FEE);
        curveContract.addLiquidity(recipient, LIQUIDITY_2ETH_BEFOR_FEE, priceRange);


        reserveToken.mint(recipient, buyLiquidity);
        reserveToken.transfer(address(curveContract), buyLiquidity);
        curveContract.buyTokens(recipient, buyLiquidity, 0, priceRange, reserveRange);

        CurveParameter memory param = curveContract.curveParameters();

        tokenContract.transfer(address(curveContract), 1e18);
        curveContract.sellTokens(recipient, 1e18, priceRange, reserveRange); 

        // vm.expectRevert(bytes(ERR_PRICE_OUT_OF_LIMIT));
        priceRange[1] = param.price;
        vm.expectRevert();
        curveContract.removeLiquidity(recipient, 0, priceRange);
    }

    function testFeeRewardForRemovingLPMintToken() public {

        uint256[2] memory priceRange = [uint256(0),uint256(0)];
        uint256[2] memory reserveRange = [uint256(0),uint256(0)];

        CurveParameter memory param = curveContract.curveParameters();
        assertEqWithError(param.price, 1e18);


        reserveToken.mint(recipient, LIQUIDITY_2ETH_BEFOR_FEE);
        reserveToken.transfer(address(curveContract), LIQUIDITY_2ETH_BEFOR_FEE);
        curveContract.buyTokens(otherRecipient, LIQUIDITY_2ETH_BEFOR_FEE, 0, priceRange, reserveRange);

        reserveToken.mint(recipient, LIQUIDITY_2ETH_BEFOR_FEE);
        reserveToken.transfer(address(curveContract), LIQUIDITY_2ETH_BEFOR_FEE);
        curveContract.addLiquidity(recipient, LIQUIDITY_2ETH_BEFOR_FEE, priceRange);

        vm.startPrank(otherRecipient);
        uint256 tokenBalanceBefore = tokenContract.balanceOf(otherRecipient);
        tokenContract.transfer(address(curveContract), tokenBalanceBefore);
        curveContract.sellTokens(recipient, tokenBalanceBefore, priceRange, reserveRange);

        vm.stopPrank();

        (uint256 lpReward,,,) = curveContract.rewardOf(feeOwner);
        (uint256 lpRewardOfRemovalLP,, uint256 lpReserveRewardOfRemovalLP,) = curveContract.rewardOf(recipient);

        tokenBalanceBefore = tokenContract.balanceOf(address(curveContract));
        vm.recordLogs();
        curveContract.removeLiquidity(otherRecipient, 0, priceRange);
        (uint256 lpRewardAfter,,,) = curveContract.rewardOf(feeOwner);
        (uint256 lpRewardOfRemovalLPAfter,, uint256 lpReserveRewardOfRemovalLPAfter,) =
            curveContract.rewardOf(recipient);
        Vm.Log[] memory entries = vm.getRecordedLogs();
        // Fee mint event Transfer(0, curvecontract, amount)
        address mintedReceiver = address(uint160(uint256(entries[1].topics[2])));
        uint256 tokenMinted = abi.decode(entries[1].data, (uint256));
        uint256 fee = tokenMinted.mulDown(FEE_PERCENT.mulDown(3e18));

        assertEq(mintedReceiver, address(curveContract));
        assertEq(lpRewardAfter - lpReward, 0);
        assertEq(lpRewardOfRemovalLP, lpRewardOfRemovalLPAfter);
        assertEq(lpReserveRewardOfRemovalLP, lpReserveRewardOfRemovalLPAfter);


        uint256 tokenBalanceAfter = tokenContract.balanceOf(address(curveContract));
        assertEqWithError(tokenBalanceAfter - tokenBalanceBefore, fee);

        (
            uint256[MAX_FEE_TYPE_COUNT][MAX_FEE_STATE_COUNT] memory totalReward,
            uint256[MAX_FEE_TYPE_COUNT][MAX_FEE_STATE_COUNT] memory totalPendingReward
        ) = curveContract.rewardState();

        assertEqWithError(totalReward[uint256(FeeType.IBC_FROM_LP)][0], fee.divDown(3e18));
        assertEqWithError(totalReward[uint256(FeeType.IBC_FROM_LP)][1], fee.divDown(3e18));
        assertEqWithError(totalReward[uint256(FeeType.IBC_FROM_LP)][2], fee.divDown(3e18));

        assertEqWithError(totalPendingReward[uint256(FeeType.IBC_FROM_LP)][0], fee.divDown(3e18));
        assertEqWithError(totalPendingReward[uint256(FeeType.IBC_FROM_LP)][1], fee.divDown(3e18));
        assertEqWithError(totalPendingReward[uint256(FeeType.IBC_FROM_LP)][2], fee.divDown(3e18));
    }

    function testRewardState() public {

        uint256[2] memory priceRange = [uint256(0),uint256(0)];
        uint256[2] memory reserveRange = [uint256(0),uint256(0)];

        uint256 buyLiquidity = 1e18;

        reserveToken.mint(recipient, LIQUIDITY_2ETH_BEFOR_FEE);
        reserveToken.transfer(address(curveContract), LIQUIDITY_2ETH_BEFOR_FEE);
        curveContract.addLiquidity(recipient, LIQUIDITY_2ETH_BEFOR_FEE, priceRange);

        (
            uint256[MAX_FEE_TYPE_COUNT][MAX_FEE_STATE_COUNT] memory totalReward,
            uint256[MAX_FEE_TYPE_COUNT][MAX_FEE_STATE_COUNT] memory totalPendingReward
        ) = curveContract.rewardState();

        uint256 addLiquidityFee = LIQUIDITY_2ETH_BEFOR_FEE - 2e18;

        assertEq(totalReward[uint256(FeeType.IBC_FROM_TRADE)][0], 0);
        assertEq(totalReward[uint256(FeeType.IBC_FROM_TRADE)][1], 0);
        assertEq(totalReward[uint256(FeeType.IBC_FROM_TRADE)][2], 0);

        assertEq(totalReward[uint256(FeeType.IBC_FROM_LP)][0], 0);
        assertEq(totalReward[uint256(FeeType.IBC_FROM_LP)][1], 0);
        assertEq(totalReward[uint256(FeeType.IBC_FROM_LP)][2], 0);

        assertEq(totalPendingReward[uint256(FeeType.IBC_FROM_TRADE)][0], 0);
        assertEq(totalPendingReward[uint256(FeeType.IBC_FROM_TRADE)][1], 0);
        assertEq(totalPendingReward[uint256(FeeType.IBC_FROM_TRADE)][2], 0);

        assertEq(totalPendingReward[uint256(FeeType.IBC_FROM_LP)][0], 0);
        assertEq(totalPendingReward[uint256(FeeType.IBC_FROM_LP)][1], 0);
        assertEq(totalPendingReward[uint256(FeeType.IBC_FROM_LP)][2], 0);

        assertEqWithError(totalReward[uint256(FeeType.RESERVE)][uint256(RewardType.LP)], addLiquidityFee.divDown(3e18));
        assertEqWithError(
            totalReward[uint256(FeeType.RESERVE)][uint256(RewardType.STAKING)], addLiquidityFee.divDown(3e18)
        );
        assertEqWithError(
            totalReward[uint256(FeeType.RESERVE)][uint256(RewardType.PROTOCOL)], addLiquidityFee.divDown(3e18)
        );

        assertEqWithError(
            totalPendingReward[uint256(FeeType.RESERVE)][uint256(RewardType.LP)], addLiquidityFee.divDown(3e18)
        );
        assertEqWithError(
            totalPendingReward[uint256(FeeType.RESERVE)][uint256(RewardType.STAKING)], addLiquidityFee.divDown(3e18)
        );
        assertEqWithError(
            totalPendingReward[uint256(FeeType.RESERVE)][uint256(RewardType.PROTOCOL)], addLiquidityFee.divDown(3e18)
        );

        uint256 reserveRewardToDead = addLiquidityFee.divDown(3e18)/1e4;
        CurveParameter memory param = curveContract.curveParameters();

        reserveToken.mint(recipient, buyLiquidity);
        reserveToken.transfer(address(curveContract), buyLiquidity);
        curveContract.buyTokens(otherRecipient, buyLiquidity, 0, priceRange, reserveRange);

        uint256 tokenOut = tokenContract.balanceOf(otherRecipient);
        uint256 fee = (tokenOut * feePercent) / (1e18 - feePercent);

        (totalReward, totalPendingReward) = curveContract.rewardState();

        // dead lp amount 1e14
        uint256 ibcRewardToDead = fee.divDown(3e18).mulDown(1e14).divDown(param.lpSupply);

        assertEqWithError(totalReward[uint256(FeeType.IBC_FROM_TRADE)][uint256(RewardType.LP)], fee.divDown(3e18));
        assertEqWithError(totalReward[uint256(FeeType.IBC_FROM_TRADE)][uint256(RewardType.STAKING)], fee.divDown(3e18));
        assertEqWithError(totalReward[uint256(FeeType.IBC_FROM_TRADE)][uint256(RewardType.PROTOCOL)], fee.divDown(3e18));

        assertEqWithError(
            totalPendingReward[uint256(FeeType.IBC_FROM_TRADE)][uint256(RewardType.LP)], fee.divDown(3e18)
        );
        assertEqWithError(
            totalPendingReward[uint256(FeeType.IBC_FROM_TRADE)][uint256(RewardType.STAKING)], fee.divDown(3e18)
        );
        assertEqWithError(
            totalPendingReward[uint256(FeeType.IBC_FROM_TRADE)][uint256(RewardType.PROTOCOL)], fee.divDown(3e18)
        );

        assertEqWithError(totalReward[uint256(FeeType.RESERVE)][uint256(RewardType.LP)], addLiquidityFee.divDown(3e18));
        assertEqWithError(
            totalReward[uint256(FeeType.RESERVE)][uint256(RewardType.STAKING)], addLiquidityFee.divDown(3e18)
        );
        assertEqWithError(
            totalReward[uint256(FeeType.RESERVE)][uint256(RewardType.PROTOCOL)], addLiquidityFee.divDown(3e18)
        );

        assertEqWithError(
            totalPendingReward[uint256(FeeType.RESERVE)][uint256(RewardType.LP)], addLiquidityFee.divDown(3e18)
        );
        assertEqWithError(
            totalPendingReward[uint256(FeeType.RESERVE)][uint256(RewardType.STAKING)], addLiquidityFee.divDown(3e18)
        );
        assertEqWithError(
            totalPendingReward[uint256(FeeType.RESERVE)][uint256(RewardType.PROTOCOL)], addLiquidityFee.divDown(3e18)
        );

        vm.startPrank(otherRecipient);
        tokenContract.transfer(address(curveContract), 1e18);
        curveContract.stake(otherRecipient, 1e18);
        vm.stopPrank();

        reserveToken.mint(recipient, LIQUIDITY_2ETH_BEFOR_FEE);
        reserveToken.transfer(address(curveContract), LIQUIDITY_2ETH_BEFOR_FEE);
        curveContract.addLiquidity(otherRecipient, LIQUIDITY_2ETH_BEFOR_FEE, priceRange);

        (totalReward, totalPendingReward) = curveContract.rewardState();

        reserveRewardToDead += addLiquidityFee.divDown(3e18).mulDown(1e14).divDown(param.lpSupply);

        assertEqWithError(totalReward[uint256(FeeType.IBC_FROM_TRADE)][uint256(RewardType.LP)], fee.divDown(3e18));
        assertEqWithError(totalReward[uint256(FeeType.IBC_FROM_TRADE)][uint256(RewardType.STAKING)], fee.divDown(3e18));
        assertEqWithError(totalReward[uint256(FeeType.IBC_FROM_TRADE)][uint256(RewardType.PROTOCOL)], fee.divDown(3e18));

        assertEqWithError(
            totalPendingReward[uint256(FeeType.IBC_FROM_TRADE)][uint256(RewardType.LP)], fee.divDown(3e18)
        );
        assertEqWithError(
            totalPendingReward[uint256(FeeType.IBC_FROM_TRADE)][uint256(RewardType.STAKING)], fee.divDown(3e18)
        );
        assertEqWithError(
            totalPendingReward[uint256(FeeType.IBC_FROM_TRADE)][uint256(RewardType.PROTOCOL)], fee.divDown(3e18)
        );

        assertEqWithError(
            totalReward[uint256(FeeType.RESERVE)][uint256(RewardType.LP)], addLiquidityFee.divDown(3e18).mulDown(2e18)
        );
        assertEqWithError(
            totalReward[uint256(FeeType.RESERVE)][uint256(RewardType.STAKING)],
            addLiquidityFee.divDown(3e18).mulDown(2e18)
        );
        assertEqWithError(
            totalReward[uint256(FeeType.RESERVE)][uint256(RewardType.PROTOCOL)],
            addLiquidityFee.divDown(3e18).mulDown(2e18)
        );

        assertEqWithError(
            totalPendingReward[uint256(FeeType.RESERVE)][uint256(RewardType.LP)],
            addLiquidityFee.divDown(3e18).mulDown(2e18)
        );
        assertEqWithError(
            totalPendingReward[uint256(FeeType.RESERVE)][uint256(RewardType.STAKING)],
            addLiquidityFee.divDown(3e18).mulDown(2e18)
        );
        assertEqWithError(
            totalPendingReward[uint256(FeeType.RESERVE)][uint256(RewardType.PROTOCOL)],
            addLiquidityFee.divDown(3e18).mulDown(2e18)
        );

        curveContract.claimReward(recipient);

        vm.startPrank(initializer);
        curveContract.claimReward(otherRecipient);
        vm.stopPrank();

        vm.startPrank(otherRecipient);
        curveContract.claimReward(otherRecipient);
        vm.stopPrank();
        vm.startPrank(feeOwner);
        curveContract.claimReward(otherRecipient);
        vm.stopPrank();
        vm.startPrank(feeOwner);
        curveContract.claimProtocolReward();
        vm.stopPrank();
        (totalReward, totalPendingReward) = curveContract.rewardState();

        assertEqWithError(totalReward[uint256(FeeType.IBC_FROM_TRADE)][uint256(RewardType.LP)], fee.divDown(3e18));
        assertEqWithError(totalReward[uint256(FeeType.IBC_FROM_TRADE)][uint256(RewardType.STAKING)], fee.divDown(3e18));
        assertEqWithError(totalReward[uint256(FeeType.IBC_FROM_TRADE)][uint256(RewardType.PROTOCOL)], fee.divDown(3e18));

        assertEqWithError(totalPendingReward[uint256(FeeType.IBC_FROM_TRADE)][uint256(RewardType.LP)], ibcRewardToDead);
        assertEqWithError(totalPendingReward[uint256(FeeType.IBC_FROM_TRADE)][uint256(RewardType.STAKING)], 0);
        assertEqWithError(totalPendingReward[uint256(FeeType.IBC_FROM_TRADE)][uint256(RewardType.PROTOCOL)], 0);

        assertEqWithError(
            totalReward[uint256(FeeType.RESERVE)][uint256(RewardType.LP)], addLiquidityFee.divDown(3e18).mulDown(2e18)
        );
        assertEqWithError(
            totalReward[uint256(FeeType.RESERVE)][uint256(RewardType.STAKING)],
            addLiquidityFee.divDown(3e18).mulDown(2e18)
        );
        assertEqWithError(
            totalReward[uint256(FeeType.RESERVE)][uint256(RewardType.PROTOCOL)],
            addLiquidityFee.divDown(3e18).mulDown(2e18)
        );

        assertEqWithError(totalPendingReward[uint256(FeeType.RESERVE)][uint256(RewardType.LP)], reserveRewardToDead);
        assertEqWithError(totalPendingReward[uint256(FeeType.RESERVE)][uint256(RewardType.STAKING)], 0);
        assertEqWithError(totalPendingReward[uint256(FeeType.RESERVE)][uint256(RewardType.PROTOCOL)], 0);
    }

    function testRewardEMAPerSecond() public {

        uint256 buyLiquidity = 100 ether;
        //vm.roll(block.number() + 1)
        // vm.roll(block.number + 1);
        uint256 blockTimestamp = block.timestamp;
        // console.log(block.timestamp);
        // blockTimestamp += 12;
        // vm.warp(blockTimestamp);
        (uint256 inverseTokenReward, uint256 reserveReward) = curveContract.rewardEMAPerSecond(RewardType.LP);
        assertEq(inverseTokenReward, 0);
        assertEq(reserveReward, 0);
        (inverseTokenReward, reserveReward) = curveContract.rewardEMAPerSecond(RewardType.STAKING);
        assertEq(inverseTokenReward, 0);
        assertEq(reserveReward, 0);

        reserveToken.mint(recipient, LIQUIDITY_2ETH_BEFOR_FEE);
        reserveToken.transfer(address(curveContract), LIQUIDITY_2ETH_BEFOR_FEE);
        {
        uint256[2] memory priceRange = [uint256(0),uint256(0)];
        curveContract.addLiquidity(recipient, LIQUIDITY_2ETH_BEFOR_FEE, priceRange);
        }



        uint256 addLiquidityFee = LIQUIDITY_2ETH_BEFOR_FEE - 2e18;
        uint256 alpha = 138879244274000; // 1 - exp(-1/7200)

        uint256 feeForLpStaking = addLiquidityFee.divDown(12e18).mulDown(alpha).divDown(3e18);
        vm.roll(block.number + 1);
        blockTimestamp += 12;
        vm.warp(blockTimestamp);
        (inverseTokenReward, reserveReward) = curveContract.rewardEMAPerSecond(RewardType.LP);
        assertEq(inverseTokenReward, 0);
        assertEqWithError(reserveReward, feeForLpStaking);

        

        (inverseTokenReward, reserveReward) = curveContract.rewardEMAPerSecond(RewardType.STAKING);
        assertEq(inverseTokenReward, 0);
        assertEqWithError(reserveReward, feeForLpStaking);


        reserveToken.mint(recipient, buyLiquidity);
        reserveToken.transfer(address(curveContract), buyLiquidity);
        {
            uint256[2] memory priceRange = [uint256(0),uint256(0)];
            uint256[2] memory reserveRange = [uint256(0),uint256(0)];
            curveContract.buyTokens(recipient, buyLiquidity, 0, priceRange, reserveRange);
        }
        

        vm.roll(block.number + 1);
        blockTimestamp += 12;
        vm.warp(blockTimestamp);
        uint256 tokenOut = tokenContract.balanceOf(recipient);
        uint256 fee = (tokenOut * feePercent) / (1e18 - feePercent);
        uint256 lpEMA = fee.divDown(12e18).mulDown(alpha).divDown(3e18);

        (inverseTokenReward, reserveReward) = curveContract.rewardEMAPerSecond(RewardType.LP);
        assertEqWithError(inverseTokenReward, lpEMA);
        assertEqWithError(reserveReward, feeForLpStaking);
        (inverseTokenReward, reserveReward) = curveContract.rewardEMAPerSecond(RewardType.STAKING);
        assertEqWithError(inverseTokenReward, lpEMA);

        for (uint256 i = 0; i < 1000; i++) {            
            vm.roll(block.number + 100);
            blockTimestamp += 1000;
            vm.warp(blockTimestamp);
            

            tokenContract.transfer(address(curveContract), 1e18);
            {
            uint256[2] memory priceRange = [uint256(0),uint256(0)];
            uint256[2] memory reserveRange = [uint256(0),uint256(0)];                
            curveContract.sellTokens(recipient, 1e18, priceRange, reserveRange);
            }
            
        }

        // eventually it will be close to average if enough time
        (inverseTokenReward, reserveReward) = curveContract.rewardEMAPerSecond(RewardType.LP);
        assertEqWithError(inverseTokenReward, uint256(1e15).divDown(1000e18));

        (inverseTokenReward, reserveReward) = curveContract.rewardEMAPerSecond(RewardType.STAKING);
        assertEqWithError(inverseTokenReward, uint256(1e15).divDown(1000e18));


        for (uint256 i = 0; i < 1000; i++) {
            vm.roll(block.number + 100);
            blockTimestamp += 1000;
            vm.warp(blockTimestamp);

            tokenContract.transfer(address(curveContract), 1e16);
            {
            uint256[2] memory priceRange = [uint256(0),uint256(0)];
            uint256[2] memory reserveRange = [uint256(0),uint256(0)];
                curveContract.sellTokens(recipient, 1e16, priceRange, reserveRange);
            }
        }

        (inverseTokenReward, reserveReward) = curveContract.rewardEMAPerSecond(RewardType.LP);
        assertEqWithError(inverseTokenReward, uint256(1e11).divDown(1000e18));

        (inverseTokenReward, reserveReward) = curveContract.rewardEMAPerSecond(RewardType.STAKING);
        assertEqWithError(inverseTokenReward, uint256(1e11).divDown(1000e18));

        // confirm proper handling for large time differences between ema updates
        vm.roll(block.number + 100);
        blockTimestamp += 3542401; // 41 days + 1 sec
        vm.warp(blockTimestamp);

        tokenContract.transfer(address(curveContract), 1e16);
        {
        uint256[2] memory priceRange = [uint256(0),uint256(0)];
        uint256[2] memory reserveRange = [uint256(0),uint256(0)];
            curveContract.sellTokens(recipient, 1e16, priceRange, reserveRange);
        }
    }

    function testRevertIfAdminPause() public {

        uint256[2] memory priceRange = [uint256(0),uint256(0)];
        uint256[2] memory reserveRange = [uint256(0),uint256(0)];

        CurveParameter memory param = curveContract.curveParameters();
        assertEqWithError(param.price, 1e18);


        reserveToken.mint(recipient, LIQUIDITY_2ETH_BEFOR_FEE);
        reserveToken.transfer(address(curveContract), LIQUIDITY_2ETH_BEFOR_FEE);
        curveContract.buyTokens(recipient, LIQUIDITY_2ETH_BEFOR_FEE, 0, priceRange, reserveRange);

        reserveToken.mint(recipient, LIQUIDITY_2ETH_BEFOR_FEE);
        reserveToken.transfer(address(curveContract), LIQUIDITY_2ETH_BEFOR_FEE);
        curveContract.addLiquidity(recipient, LIQUIDITY_2ETH_BEFOR_FEE, priceRange);

        adminContract.pause();

        reserveToken.mint(recipient, LIQUIDITY_2ETH_BEFOR_FEE);
        reserveToken.transfer(address(curveContract), LIQUIDITY_2ETH_BEFOR_FEE);
        vm.expectRevert();
        curveContract.buyTokens(recipient, LIQUIDITY_2ETH_BEFOR_FEE, 0, priceRange, reserveRange);

        reserveToken.mint(recipient, LIQUIDITY_2ETH_BEFOR_FEE);
        reserveToken.transfer(address(curveContract), LIQUIDITY_2ETH_BEFOR_FEE);
        vm.expectRevert();
        curveContract.addLiquidity(recipient, LIQUIDITY_2ETH_BEFOR_FEE, priceRange);


        uint256 tokenBalanceBefore = tokenContract.balanceOf(recipient);
        // tokenContract.transfer(address(curveContract), tokenBalanceBefore);
        vm.expectRevert();
        curveContract.sellTokens(recipient, tokenBalanceBefore, priceRange, reserveRange);

        
        vm.expectRevert();
        curveContract.removeLiquidity(otherRecipient, 0, priceRange);

        vm.expectRevert();
        curveContract.claimReward(recipient);

        // Tx executed after unpause
        adminContract.unpause();
        tokenContract.transfer(address(curveContract), tokenBalanceBefore);
        curveContract.sellTokens(recipient, tokenBalanceBefore, priceRange, reserveRange);
        curveContract.removeLiquidity(otherRecipient, 0, priceRange);


        reserveToken.mint(recipient, LIQUIDITY_2ETH_BEFOR_FEE);
        reserveToken.transfer(address(curveContract), LIQUIDITY_2ETH_BEFOR_FEE);
        curveContract.buyTokens(recipient, LIQUIDITY_2ETH_BEFOR_FEE, 0, priceRange, reserveRange);

        reserveToken.mint(recipient, LIQUIDITY_2ETH_BEFOR_FEE);
        reserveToken.transfer(address(curveContract), LIQUIDITY_2ETH_BEFOR_FEE);
        curveContract.addLiquidity(recipient, LIQUIDITY_2ETH_BEFOR_FEE, priceRange);

    }

    function testAdminUpgrade() public {
        InverseBondingCurveV2 contractV2 = new InverseBondingCurveV2();
        (bool success, bytes memory data) = address(curveContract).call(abi.encodeWithSignature("newValueGet()"));
        assertEq(success, false);
        adminContract.upgradeCurveTo(address(contractV2));
        (success, data) = address(curveContract).call(abi.encodeWithSignature("newValueSet(uint256)", 2e18));
        assertEq(success, true);
        (success, data) = address(curveContract).call(abi.encodeWithSignature("newValueGet()"));
        assertEq(success, true);
        assertEq(bytes32(data), bytes32(uint256(2e18)));
    }

    function testTransactionFromRouter() public {

        uint256[2] memory priceRange = [uint256(0),uint256(0)];
        uint256[2] memory reserveRange = [uint256(0),uint256(0)];

        CurveParameter memory param = curveContract.curveParameters();
        assertEqWithError(param.price, 1e18);

        vm.startPrank(router);

        assertEq(tokenContract.balanceOf(router), 0);
        reserveToken.mint(router, LIQUIDITY_2ETH_BEFOR_FEE);
        reserveToken.transfer(address(curveContract), LIQUIDITY_2ETH_BEFOR_FEE);
        curveContract.buyTokens(otherRecipient, LIQUIDITY_2ETH_BEFOR_FEE, 0, priceRange, reserveRange);

        assertGt(tokenContract.balanceOf(router), 0);


        reserveToken.mint(router, LIQUIDITY_2ETH_BEFOR_FEE);
        reserveToken.transfer(address(curveContract), LIQUIDITY_2ETH_BEFOR_FEE);
        curveContract.addLiquidity(otherRecipient, LIQUIDITY_2ETH_BEFOR_FEE, priceRange);

        (uint256 lpBalance, uint256 ibcCredit) = curveContract.liquidityPositionOf(otherRecipient);
        assertGt(lpBalance, 0);
        assertGt(ibcCredit, 0);

        assertEq(reserveToken.balanceOf(router), 0);
        uint256 tokenBalanceBefore = tokenContract.balanceOf(router);
        tokenContract.transfer(address(curveContract), tokenBalanceBefore);
        curveContract.sellTokens(otherRecipient, tokenBalanceBefore, priceRange, reserveRange);
        assertGt(reserveToken.balanceOf(router), 0);
        assertEq(tokenContract.balanceOf(router), 0);

        tokenBalanceBefore = reserveToken.balanceOf(router);        
        curveContract.removeLiquidity(otherRecipient, 0, priceRange);
        assertGt(reserveToken.balanceOf(router), tokenBalanceBefore);
        (lpBalance, ibcCredit) = curveContract.liquidityPositionOf(otherRecipient);
        assertEqWithError(lpBalance, 0);
        assertEqWithError(ibcCredit, 0);
        vm.stopPrank();

    }


    function logParameter(CurveParameter memory param, string memory desc) private pure {
        console2.log(desc);
        console2.log("  reserve:", param.reserve);
        console2.log("  supply:", param.supply);
        console2.log("  price:", param.price);
        console2.log("  parameterInvariant:", param.parameterInvariant);
    }
}
