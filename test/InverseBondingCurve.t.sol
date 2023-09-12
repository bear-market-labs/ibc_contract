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
contract InverseBondingCurveTest is Test {
    using FixedPoint for uint256;

    InverseBondingCurve curveContract;
    InverseBondingCurveToken tokenContract;

    uint256 ALLOWED_ERROR = 1e10;

    address recipient = address(this);
    address otherRecipient = vm.parseAddress("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266");
    uint256 feePercent = 3e15;

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
        curveContract = new InverseBondingCurve();
        tokenContract = new InverseBondingCurveToken(address(this), "IBC", "IBC");

        curveContract = new InverseBondingCurve();
        InverseBondingCurveProxy proxy = new InverseBondingCurveProxy(address(curveContract), "");
        tokenContract = new InverseBondingCurveToken(address(proxy), "IBC", "IBC");
        curveContract = InverseBondingCurve(address(proxy));
        curveContract.initialize(2e18, 1e18, 1e18, address(tokenContract), otherRecipient);
    }

    function testSymbol() public {
        assertEq(curveContract.symbol(), "IBCLP");
    }

    // function testInverseTokenSymbol() public {
    //     InverseBondingCurveToken tokenContract = InverseBondingCurveToken(curveContract.inverseTokenAddress());

    //     assertEq(tokenContract.symbol(), "IBC");
    // }

    function testSetupFeePercent() public {
        (
            uint256[MAX_ACTION_COUNT] memory lpFee,
            uint256[MAX_ACTION_COUNT] memory stakingFee,
            uint256[MAX_ACTION_COUNT] memory protocolFee
        ) = curveContract.feeConfig();
        assertEq(lpFee[uint256(ActionType.REMOVE_LIQUIDITY)], 1e15);
        assertEq(stakingFee[uint256(ActionType.REMOVE_LIQUIDITY)], 1e15);
        assertEq(protocolFee[uint256(ActionType.REMOVE_LIQUIDITY)], 1e15);

        curveContract.updateFeeConfig(ActionType.REMOVE_LIQUIDITY, 2e15, 3e15, 4e15);

        (lpFee, stakingFee, protocolFee) = curveContract.feeConfig();

        assertEq(lpFee[uint256(ActionType.REMOVE_LIQUIDITY)], 2e15);
        assertEq(stakingFee[uint256(ActionType.REMOVE_LIQUIDITY)], 3e15);
        assertEq(protocolFee[uint256(ActionType.REMOVE_LIQUIDITY)], 4e15);
    }

    // function testRevertIfNotInitialized() public {
    //     vm.expectRevert(bytes(ERR_POOL_NOT_INITIALIZED));
    //     curveContract.addLiquidity(address(this), 1e18);

    //     vm.expectRevert(bytes(ERR_POOL_NOT_INITIALIZED));
    //     curveContract.removeLiquidity(address(this), 1e18, 1e18);

    //     vm.expectRevert(bytes(ERR_POOL_NOT_INITIALIZED));
    //     curveContract.claimReward(address(this), RewardType.LP);

    //     vm.expectRevert(bytes(ERR_POOL_NOT_INITIALIZED));
    //     curveContract.buyTokens(address(this), 1e18);

    //     vm.expectRevert(bytes(ERR_POOL_NOT_INITIALIZED));
    //     curveContract.sellTokens(address(this), 1e18, 1e18);
    // }

    function testInitialize() public {
        // curveContract.initialize{value: 2 ether}(1e18, 1e18, address(tokenContract), otherRecipient);

        uint256 price = curveContract.priceOf(1e18);
        console2.log(price);
        CurveParameter memory param = curveContract.curveParameters();
        console2.log(param.price);
        // assert(param.parameterM > 1e18 - ALLOWED_ERROR && param.parameterM < 1e18 + ALLOWED_ERROR);

        assertEqWithError(price, 1e18);
        assertEqWithError(tokenContract.balanceOf(recipient), 0);
        assertEqWithError(curveContract.balanceOf(recipient), 0);
        assertEqWithError(param.virtualReserve, param.reserve);
        assertEqWithError(param.virtualSupply, param.supply);

        // assertEqWithError(param.parameterK, 5e17);
    }

    function testAddLiquidity() public {
        // curveContract.initialize{value: 2 ether}(1e18, 1e18, address(tokenContract), otherRecipient);
        CurveParameter memory param = curveContract.curveParameters();
        console2.log("curve param u:", param.parameterUtilization);
        console2.log("curve param i:", param.parameterInvariant);
        console2.log("curve param supply:", param.supply);
        console2.log("LP supply:", curveContract.totalSupply());

        curveContract.addLiquidity{value: LIQUIDITY_2ETH_BEFOR_FEE}(recipient, 1e18);

        param = curveContract.curveParameters();
        console2.log("curve param u:", param.parameterUtilization);
        console2.log("curve param i:", param.parameterInvariant);
        console2.log("curve param supply:", param.supply);
        console2.log("LP supply:", curveContract.totalSupply());

        uint256 price = curveContract.priceOf(1e18);

        // assert(param.parameterM > 1e18 - ALLOWED_ERROR && param.parameterM < 1e18 + ALLOWED_ERROR);
        // assert(param.parameterK > 75e16 - int256(ALLOWED_ERROR) && param.parameterK < 75e16 + int256(ALLOWED_ERROR));

        assertEqWithError(price, 1e18);
        console2.log(price);
        console2.log(curveContract.totalSupply());

        assertEqWithError(tokenContract.balanceOf(recipient), 0);
        assertEqWithError(curveContract.balanceOf(recipient), 4e18);
    }

    function testRemoveLiquidity() public {
        // curveContract.initialize{value: 2 ether}(1e18, 1e18, address(tokenContract), otherRecipient);
        curveContract.addLiquidity{value: LIQUIDITY_2ETH_BEFOR_FEE}(recipient, 1e18);

        uint256 balanceBefore = otherRecipient.balance;

        // vm.startPrank(recipient);
        // vm.deal(recipient, 1000 ether);

        uint256 lpAmount = curveContract.balanceOf(recipient);
        console2.log(curveContract.totalSupply());
        console2.log(lpAmount);

        curveContract.removeLiquidity(otherRecipient, lpAmount, 1e18 + ALLOWED_ERROR);

        uint256 balanceAfter = otherRecipient.balance;

        uint256 price = curveContract.priceOf(1e18);
        CurveParameter memory param = curveContract.curveParameters();
        console2.log(price);
        assertEqWithError(price, 1e18);

        assertEqWithError(tokenContract.balanceOf(recipient), 0);
        assertEqWithError(curveContract.balanceOf(recipient), 0);
        assertEqWithError(balanceAfter - balanceBefore, uint256(2e18).mulDown(ONE_UINT.sub(FEE_PERCENT.mulDown(3e18))));
    }

    function testBuyTokens() public {
        // curveContract.initialize{value: 2 ether}(1e18, 1e18, address(tokenContract), otherRecipient);

        // curveContract.addLiquidity{value: 2 ether}(recipient, 1e18);
        uint256 balanceBefore = tokenContract.balanceOf(otherRecipient);
        curveContract.buyTokens{value: 1 ether}(otherRecipient, 1e18);

        uint256 balanceAfter = tokenContract.balanceOf(otherRecipient);

        uint256 balanceChange = balanceAfter - balanceBefore;

        console2.log("balanceBefore", balanceBefore);
        console2.log("balanceAfter ", balanceAfter);

        assertEqWithError(balanceChange, 124625e13);
    }

    function testSellTokens() public {
        // curveContract.initialize{value: 2 ether}(1e18, 1e18, address(tokenContract), otherRecipient);

        // curveContract.addLiquidity{value: 2 ether}(recipient, 1e18);

        curveContract.buyTokens{value: 1 ether}(recipient, 1e18);

        uint256 balanceBefore = tokenContract.balanceOf(recipient);
        uint256 ethBalanceBefore = otherRecipient.balance;

        // vm.startPrank(otherRecipient);
        // vm.deal(otherRecipient, 1000 ether);
        tokenContract.approve(address(curveContract), 1e18);
        curveContract.sellTokens(otherRecipient, 1e18, 1e17);
        uint256 ethBalanceAfter = otherRecipient.balance;
        uint256 balanceAfter = tokenContract.balanceOf(recipient);

        assertEq(balanceBefore - balanceAfter, 1e18);
        uint256 balanceOut = 761250348967084500;

        uint256 ethBalanceChange = ethBalanceAfter - ethBalanceBefore;
        assertEqWithError(ethBalanceChange, balanceOut);
    }

    function testFeeAccumulate() public {
        curveContract.addLiquidity{value: LIQUIDITY_2ETH_BEFOR_FEE}(recipient, 1e18);
        // curveContract.initialize{value: 2 ether}(1e18, 1e18, address(tokenContract), otherRecipient);

        // curveContract.addLiquidity{value: 2 ether}(recipient, 1e18);

        curveContract.buyTokens{value: 1 ether}(otherRecipient, 1e18);
        console2.log(tokenContract.balanceOf(otherRecipient));

        uint256 feeBalance = tokenContract.balanceOf(address(curveContract));

        uint256 tokenOut = tokenContract.balanceOf(otherRecipient);
        uint256 fee = (tokenOut * feePercent) / (1e18 - feePercent);

        
        assertEqWithError(feeBalance, fee);
        vm.startPrank(otherRecipient);
        tokenContract.approve(address(curveContract), 1e18);
        curveContract.sellTokens(otherRecipient, 1e18, 1e17);
        vm.stopPrank();

        feeBalance = tokenContract.balanceOf(address(curveContract));
        fee += 1e18 * feePercent / 1e18;

        assertEqWithError(feeBalance, fee);
        (uint256 lpReward,,,) = curveContract.rewardOf(recipient);
        console2.log("reward:", lpReward);
        uint256 balanceBefore = tokenContract.balanceOf(otherRecipient);
        curveContract.claimReward(otherRecipient);
        uint256 balanceAfter = tokenContract.balanceOf(otherRecipient);

        console2.log("balanceBefore",balanceBefore);
        console2.log("balanceAfter",balanceAfter);
        console2.log("feeBalance",feeBalance);
        console2.log("balance of curve",tokenContract.balanceOf(address(curveContract)));

        assertEqWithError(feeBalance, (balanceAfter - balanceBefore)*3);
        assertEqWithError(tokenContract.balanceOf(address(curveContract)), feeBalance - (balanceAfter - balanceBefore));
    }

    function testClaimRewardFeePortion() public {
        // curveContract.initialize{value: 2 ether}(1e18, 1e18, address(tokenContract), otherRecipient);
        curveContract.addLiquidity{value: LIQUIDITY_2ETH_BEFOR_FEE}(recipient, 1e18);
        curveContract.addLiquidity{value: LIQUIDITY_2ETH_BEFOR_FEE}(otherRecipient, 1e18);
        

        uint256 feeBalanceBefore = tokenContract.balanceOf(address(curveContract));

        curveContract.buyTokens{value: 1 ether}(otherRecipient, 1e18);
        uint256 feeBalanceAfter = tokenContract.balanceOf(address(curveContract));
        uint256 totalFee = feeBalanceAfter - feeBalanceBefore;

        uint256 balanceBefore = tokenContract.balanceOf(otherRecipient);

        curveContract.claimReward(otherRecipient);
        uint256 balanceAfter = tokenContract.balanceOf(otherRecipient);

        assertEqWithError(totalFee, (balanceAfter - balanceBefore) * 6);
    }

    function testClaimRewardLiquidityChange() public {
        address thirdRecipient = vm.addr(2);
        // curveContract.initialize{value: 1 ether}(1e18, 1e18, address(tokenContract), otherRecipient);

        vm.deal(otherRecipient, 1000 ether);
        vm.deal(thirdRecipient, 1000 ether);

        vm.startPrank(otherRecipient);
        curveContract.addLiquidity{value: LIQUIDITY_2ETH_BEFOR_FEE}(otherRecipient, 0);
        vm.stopPrank();

        console2.log("lp balance:", curveContract.balanceOf(address(this)));
        console2.log("lp balance:", curveContract.balanceOf(address(otherRecipient)));

        console2.log("total fee balance before buy:", tokenContract.balanceOf(address(curveContract)));

        curveContract.buyTokens{value: 2 ether}(otherRecipient, 1e18);

        vm.startPrank(otherRecipient);
        tokenContract.transfer(thirdRecipient, 1e18);
        vm.stopPrank();

        console2.log("total fee balance:", tokenContract.balanceOf(address(curveContract)));
        curveContract.claimReward(recipient);

        console2.log("total fee balance after claim:", tokenContract.balanceOf(address(curveContract)));
        vm.startPrank(otherRecipient);
        curveContract.claimReward(otherRecipient);
        vm.stopPrank();

        console2.log("total fee balance after claim:", tokenContract.balanceOf(address(curveContract)));

        vm.startPrank(otherRecipient);

        tokenContract.approve(address(curveContract), 1e18);
        curveContract.sellTokens(otherRecipient, 1e18, 0);

        uint256 firstSellFee = 1e15 * curveContract.balanceOf(otherRecipient) / curveContract.totalSupply();
        console2.log("firstSellFee:", firstSellFee);
        vm.stopPrank();

        console2.log("total fee balance after sell:", tokenContract.balanceOf(address(curveContract)));

        vm.startPrank(thirdRecipient);
        curveContract.addLiquidity{value: address(curveContract).balance}(thirdRecipient, 0);
        tokenContract.approve(address(curveContract), 1e18);
        curveContract.sellTokens(otherRecipient, 1e18, 0);

        uint256 secondSellFee = 1e15 * curveContract.balanceOf(otherRecipient) / curveContract.totalSupply();
        console2.log("secondSellFee:", firstSellFee);
        vm.stopPrank();
        console2.log("total fee balance after 2nd sell:", tokenContract.balanceOf(address(curveContract)));

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
        uint256 secondSellFeeForthirdRecipient =
            1e15 * curveContract.balanceOf(thirdRecipient) / curveContract.totalSupply();
        vm.stopPrank();

        assert(firstSellFee + secondSellFee - otherRecipientFee < ALLOWED_ERROR);
        assert(secondSellFeeForthirdRecipient - thirdRecipientFee < ALLOWED_ERROR);

        console2.log("otherRecipientFee", otherRecipientFee);
        console2.log("thirdRecipientFee", thirdRecipientFee);
    }

    function testClaimRewardStakingChange() public {
        address thirdRecipient = vm.addr(2);
        // curveContract.initialize{value: 2 ether}(1e18, 1e18, address(tokenContract), otherRecipient);

        vm.deal(otherRecipient, 1000 ether);
        vm.deal(thirdRecipient, 1000 ether);

        curveContract.buyTokens{value: 20 ether}(otherRecipient, 1e18);
        console2.log("token balance:", tokenContract.balanceOf(address(this)));
        console2.log("token balance otherRecipient:", tokenContract.balanceOf(address(otherRecipient)));

        vm.startPrank(otherRecipient);
        tokenContract.transfer(thirdRecipient, 2e18);
        vm.stopPrank();

        curveContract.claimReward(recipient);
        vm.startPrank(otherRecipient);
        tokenContract.approve(address(curveContract), 1e18);
        curveContract.stake(1e18);
        curveContract.claimReward(otherRecipient);
        vm.stopPrank();

        vm.startPrank(otherRecipient);
        tokenContract.approve(address(curveContract), 1e18);
        curveContract.sellTokens(otherRecipient, 1e18, 0);
        vm.stopPrank();

        vm.startPrank(thirdRecipient);
        tokenContract.approve(address(curveContract), 1e18);
        curveContract.stake(1e18);
        console2.log("token balance thirdRecipient after stake:", tokenContract.balanceOf(address(thirdRecipient)));
        tokenContract.approve(address(curveContract), 1e18);
        curveContract.sellTokens(otherRecipient, 1e18, 0);
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

        console2.log("otherRecipientFee", otherRecipientFee);
        console2.log("thirdRecipientFee", thirdRecipientFee);
    }

    function testLpTransfers() public {
        // assertEq(curveContract.balanceOf(recipient), 2e18);

        // vm.deal(otherRecipient, 1000 ether);
        // vm.deal(thirdRecipient, 1000 ether);

        // vm.startPrank(otherRecipient);
        curveContract.addLiquidity{value: LIQUIDITY_2ETH_BEFOR_FEE}(recipient, 0);
        // vm.stopPrank();

        (uint256 reward,,,) = curveContract.rewardOf(recipient);
        assertEq(reward, 0);


        //perform mints to generate lp fees
        curveContract.buyTokens{value: 2 ether}(otherRecipient, 1e18);

        //transfer from recipient to otherRecipient
        //confirm sender/recipient's reward state
        vm.startPrank(recipient);
        curveContract.transfer(otherRecipient, curveContract.balanceOf(recipient));
        vm.stopPrank();

        (uint256 senderLpReward,,,) = curveContract.rewardOf(recipient);
        (uint256 recipientLpReward,,,) = curveContract.rewardOf(otherRecipient);
        // uint256 senderLpReward = curveContract.rewardOf(recipient)[0];
        // uint256 recipientLpReward = curveContract.rewardOf(otherRecipient)[0];
        assertEqWithError(senderLpReward, 12187500000000000/3);
        assert(recipientLpReward == 0);

        //perform more mints to generate lp fees
        curveContract.buyTokens{value: 1 ether}(recipient, 1e18);

        //transferfrom otherRecipient to recipient
        //confirm sender/recipient's reward state
        vm.startPrank(otherRecipient);
        curveContract.approve(recipient, 10e18);
        vm.stopPrank();

        vm.startPrank(recipient);
        curveContract.transferFrom(otherRecipient, recipient, 2e18);
        vm.stopPrank();

        // uint256 senderLpReward2 = curveContract.rewardOf(otherRecipient);
        // uint256 recipientLpReward2 = curveContract.rewardOf(otherRecipient);

        (uint256 senderLpReward2,,,) = curveContract.rewardOf(otherRecipient);
        (uint256 recipientLpReward2,,,) = curveContract.rewardOf(recipient);
        assertEqWithError(senderLpReward, recipientLpReward2);
        assertEqWithError(senderLpReward2, 12949218750000000/3);
    }
}
