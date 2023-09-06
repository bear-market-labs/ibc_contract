// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/InverseBondingCurve.sol";
import "../src/InverseBondingCurveToken.sol";
import "../src/InverseBondingCurveProxy.sol";
import "forge-std/console2.sol";

contract InverseBondingCurveTest is Test {
    InverseBondingCurve curveContract;
    InverseBondingCurveToken tokenContract;

    uint256 ALLOWED_ERROR = 1e8;

    address recipient = address(this);
    address otherRecipient = vm.parseAddress("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266");
    uint256 feePercent = 3e15;

    function setUp() public {
        curveContract = new InverseBondingCurve();
        tokenContract = new InverseBondingCurveToken(address(this), "IBC", "IBC");

        curveContract = new InverseBondingCurve();
        InverseBondingCurveProxy proxy = new InverseBondingCurveProxy(address(curveContract), "");
        tokenContract = new InverseBondingCurveToken(address(proxy), "IBC", "IBC");
        curveContract = InverseBondingCurve(address(proxy));
        curveContract.initialize{value: 2 ether}(1e18, 1e18, address(tokenContract), otherRecipient);
    }

    function testSymbol() public {
        assertEq(curveContract.symbol(), "IBCLP");
    }

    // function testInverseTokenSymbol() public {
    //     InverseBondingCurveToken tokenContract = InverseBondingCurveToken(curveContract.getInverseTokenAddress());

    //     assertEq(tokenContract.symbol(), "IBC");
    // }

    function testSetupFeePercent() public {
        (uint256 lpFee, uint256 stakingFee, uint256 protocolFee) = curveContract.getFeeConfig();
        assertEq(lpFee, 1e15);
        assertEq(stakingFee, 1e15);
        assertEq(protocolFee, 1e15);

        curveContract.updateFeeConfig(2e15, 3e15, 4e15);

        (lpFee, stakingFee, protocolFee) = curveContract.getFeeConfig();

        assertEq(lpFee, 2e15);
        assertEq(stakingFee, 3e15);
        assertEq(protocolFee, 4e15);
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

        uint256 price = curveContract.getPrice(1e18);
        CurveParameter memory param = curveContract.getCurveParameters();
        assert(param.parameterM > 1e18 - ALLOWED_ERROR && param.parameterM < 1e18 + ALLOWED_ERROR);

        assertEq(price, 1e18);
        assertEq(tokenContract.balanceOf(recipient), 1e18);
        assertEq(curveContract.balanceOf(recipient), 2e18);

        assertEq(param.parameterK, 5e17);
    }

    function testAddLiquidity() public {
        // curveContract.initialize{value: 2 ether}(1e18, 1e18, address(tokenContract), otherRecipient);

        curveContract.addLiquidity{value: 2 ether}(recipient, 1e18);

        uint256 price = curveContract.getPrice(1e18);
        CurveParameter memory param = curveContract.getCurveParameters();
        assert(param.parameterM > 1e18 - ALLOWED_ERROR && param.parameterM < 1e18 + ALLOWED_ERROR);
        assert(param.parameterK > 75e16 - int256(ALLOWED_ERROR) && param.parameterK < 75e16 + int256(ALLOWED_ERROR));
        assertEq(price, 1e18);

        assertEq(tokenContract.balanceOf(recipient), 1e18);
        assertEq(curveContract.balanceOf(recipient), 6e18);
    }

    function testRemoveLiquidity() public {
        // curveContract.initialize{value: 2 ether}(1e18, 1e18, address(tokenContract), otherRecipient);
        curveContract.addLiquidity{value: 2 ether}(recipient, 1e18);

        uint256 balanceBefore = otherRecipient.balance;

        // vm.startPrank(recipient);
        // vm.deal(recipient, 1000 ether);

        curveContract.removeLiquidity(otherRecipient, 4e18, 1e18);

        uint256 balanceAfter = otherRecipient.balance;

        uint256 price = curveContract.getPrice(1e18);
        CurveParameter memory param = curveContract.getCurveParameters();
        assert(param.parameterM > 1e18 - ALLOWED_ERROR && param.parameterM < 1e18 + ALLOWED_ERROR);
        assert(param.parameterK > 5e17 - int256(ALLOWED_ERROR) && param.parameterK < 5e17 + int256(ALLOWED_ERROR));
        assertEq(price, 1e18);

        assertEq(tokenContract.balanceOf(recipient), 1e18);
        assertEq(curveContract.balanceOf(recipient), 2e18);
        assertEq(balanceAfter - balanceBefore, 2e18);
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

        assert(balanceChange > 124625e13 - ALLOWED_ERROR && balanceChange < 124625e13 + ALLOWED_ERROR);
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
        assert(ethBalanceChange > balanceOut - ALLOWED_ERROR && ethBalanceChange < balanceOut + ALLOWED_ERROR);
    }

    function testFeeAccumulate() public {
        // curveContract.initialize{value: 2 ether}(1e18, 1e18, address(tokenContract), otherRecipient);

        // curveContract.addLiquidity{value: 2 ether}(recipient, 1e18);

        curveContract.buyTokens{value: 1 ether}(otherRecipient, 1e18);

        uint256 feeBalance = tokenContract.balanceOf(address(curveContract));

        uint256 tokenOut = 124625e13;
        uint256 fee = (tokenOut * feePercent) / (1e18 - feePercent);

        assert(feeBalance >= fee - ALLOWED_ERROR && feeBalance <= fee + ALLOWED_ERROR);

        tokenContract.approve(address(curveContract), 1e18);
        curveContract.sellTokens(otherRecipient, 1e18, 1e17);

        feeBalance = tokenContract.balanceOf(address(curveContract));
        fee += 1e18 * feePercent / 1e18;

        assert(feeBalance >= fee - ALLOWED_ERROR && feeBalance <= fee + ALLOWED_ERROR);

        uint256 balanceBefore = tokenContract.balanceOf(otherRecipient);
        curveContract.claimReward(otherRecipient, RewardType.LP);
        uint256 balanceAfter = tokenContract.balanceOf(otherRecipient);

        assertLe(feeBalance - (balanceAfter - balanceBefore) * 3, ALLOWED_ERROR);
        assertEq(tokenContract.balanceOf(address(curveContract)), feeBalance - (balanceAfter - balanceBefore));
    }

    function testClaimRewardFeePortion() public {
        // curveContract.initialize{value: 2 ether}(1e18, 1e18, address(tokenContract), otherRecipient);

        curveContract.addLiquidity{value: 2 ether}(otherRecipient, 1e18);
        curveContract.buyTokens{value: 1 ether}(otherRecipient, 1e18);

        uint256 feeBalance = tokenContract.balanceOf(address(curveContract));
        uint256 balanceBefore = tokenContract.balanceOf(otherRecipient);

        curveContract.claimReward(otherRecipient, RewardType.LP);
        uint256 balanceAfter = tokenContract.balanceOf(otherRecipient);

        assertLe(feeBalance * 1/ 9 - (balanceAfter - balanceBefore), ALLOWED_ERROR);
        assertLe(tokenContract.balanceOf(address(curveContract)) - feeBalance * 8 / 9, ALLOWED_ERROR);
    }

    function testClaimRewardLiquidityChange() public {
        address thirdRecipient = vm.addr(2);
        // curveContract.initialize{value: 1 ether}(1e18, 1e18, address(tokenContract), otherRecipient);

        vm.deal(otherRecipient, 1000 ether);
        vm.deal(thirdRecipient, 1000 ether);

        vm.startPrank(otherRecipient);
        curveContract.addLiquidity{value: 2 ether}(otherRecipient, 0);
        vm.stopPrank();

        console2.log("lp balance:", curveContract.balanceOf(address(this)));
        console2.log("lp balance:", curveContract.balanceOf(address(otherRecipient)));

        console2.log("total fee balance before buy:", tokenContract.balanceOf(address(curveContract)));

        curveContract.buyTokens{value: 2 ether}(otherRecipient, 1e18);
        console2.log("self claimable:", curveContract.getReward(address(this), RewardType.LP));
        console2.log("otherRecipient claimable:", curveContract.getReward(address(otherRecipient), RewardType.LP));

        vm.startPrank(otherRecipient);
        tokenContract.transfer(thirdRecipient, 1e18);
        vm.stopPrank();

        console2.log("total fee balance:", tokenContract.balanceOf(address(curveContract)));
        curveContract.claimReward(recipient, RewardType.LP);

        console2.log("total fee balance after claim:", tokenContract.balanceOf(address(curveContract)));
        vm.startPrank(otherRecipient);
        curveContract.claimReward(otherRecipient, RewardType.LP);
        vm.stopPrank();

        console2.log("total fee balance after claim:", tokenContract.balanceOf(address(curveContract)));


        vm.startPrank(otherRecipient);

        
        tokenContract.approve(address(curveContract), 1e18);
        curveContract.sellTokens(otherRecipient, 1e18, 0);

        uint256 firstSellFee = 1e15 * curveContract.balanceOf(otherRecipient)  / curveContract.totalSupply();
        console2.log("firstSellFee:",firstSellFee);
        vm.stopPrank();

        console2.log("total fee balance after sell:", tokenContract.balanceOf(address(curveContract)));

        vm.startPrank(thirdRecipient);
        curveContract.addLiquidity{value: address(curveContract).balance}(thirdRecipient, 0);
        tokenContract.approve(address(curveContract), 1e18);
        curveContract.sellTokens(otherRecipient, 1e18, 0);

        uint256 secondSellFee = 1e15 * curveContract.balanceOf(otherRecipient) / curveContract.totalSupply();
        console2.log("secondSellFee:",firstSellFee);
        vm.stopPrank();
        console2.log("total fee balance after 2nd sell:", tokenContract.balanceOf(address(curveContract)));

        vm.startPrank(otherRecipient);
        uint256 balanceBefore = tokenContract.balanceOf(otherRecipient);
        curveContract.claimReward(otherRecipient, RewardType.LP);
        uint256 balanceAfter = tokenContract.balanceOf(otherRecipient);
        uint256 otherRecipientFee = balanceAfter - balanceBefore;
        vm.stopPrank();

        vm.startPrank(thirdRecipient);
        balanceBefore = tokenContract.balanceOf(thirdRecipient);
        curveContract.claimReward(thirdRecipient, RewardType.LP);
        balanceAfter = tokenContract.balanceOf(thirdRecipient);
        uint256 thirdRecipientFee = balanceAfter - balanceBefore;
        uint256 secondSellFeeForthirdRecipient = 1e15 * curveContract.balanceOf(thirdRecipient) / curveContract.totalSupply();
        vm.stopPrank();

        assert(firstSellFee + secondSellFee - otherRecipientFee < ALLOWED_ERROR );
        assert(secondSellFeeForthirdRecipient - thirdRecipientFee < ALLOWED_ERROR );

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

        curveContract.claimReward(recipient, RewardType.LP);
        vm.startPrank(otherRecipient);
        tokenContract.approve(address(curveContract), 1e18);
        curveContract.stake(1e18);
        curveContract.claimReward(otherRecipient, RewardType.LP);
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
        curveContract.claimReward(otherRecipient, RewardType.STAKING);
        uint256 balanceAfter = tokenContract.balanceOf(otherRecipient);
        uint256 otherRecipientFee = balanceAfter - balanceBefore;
        vm.stopPrank();

        vm.startPrank(thirdRecipient);
        balanceBefore = tokenContract.balanceOf(thirdRecipient);
        curveContract.claimReward(thirdRecipient, RewardType.STAKING);
        balanceAfter = tokenContract.balanceOf(thirdRecipient);
        uint256 thirdRecipientFee = balanceAfter - balanceBefore;
        vm.stopPrank();

        assertEq(otherRecipientFee, feePercent / 3 + feePercent / 6);
        assertEq(thirdRecipientFee, feePercent / 6);

        console2.log("otherRecipientFee", otherRecipientFee);
        console2.log("thirdRecipientFee", thirdRecipientFee);
    }

    function testLpTransfers() public {
        assertEq(curveContract.balanceOf(recipient), 2e18);
        assertEq(curveContract.getReward(recipient, RewardType.LP), 0);

        //perform mints to generate lp fees
        curveContract.buyTokens{value: 1 ether}(otherRecipient, 1e18);

        //transfer from recipient to otherRecipient
        //confirm sender/recipient's reward state
        vm.startPrank(recipient);
        curveContract.transfer(otherRecipient, 2e18);
        vm.stopPrank();

        uint256 senderLpReward = curveContract.getReward(recipient, RewardType.LP);
        uint256 recipientLpReward = curveContract.getReward(otherRecipient, RewardType.LP);
        assertEq(senderLpReward, 1250000000000044);
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

        uint256 senderLpReward2 = curveContract.getReward(otherRecipient, RewardType.LP);
        uint256 recipientLpReward2 = curveContract.getReward(recipient, RewardType.LP);
        assert(senderLpReward == recipientLpReward2);
        assertEq(senderLpReward2, 1750000000000034);
    }
}
