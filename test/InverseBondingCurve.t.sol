// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/InverseBondingCurve.sol";
import "../src/InverseBondingCurveToken.sol";
import "forge-std/console2.sol";

contract InverseBondingCurveTest is Test {
    InverseBondingCurve public curveContract;

    uint256 ALLOWED_ERROR = 1e8;

    address recipient = address(this);
    address otherRecipient = vm.parseAddress("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266");
    uint256 feePercent = 1e15;

    function setUp() public {
        curveContract = new InverseBondingCurve();
    }

    function testSymbol() public {
        assertEq(curveContract.symbol(), "IBCLP");
    }

    function testInverseTokenSymbol() public {
        InverseBondingCurveToken tokenContract = InverseBondingCurveToken(curveContract.getInverseTokenAddress());

        assertEq(tokenContract.symbol(), "IBC");
    }

    function testSetupFeePercent() public {
        assertEq(curveContract.getFeePercent(), 1e15);

        curveContract.setupFeePercent(2e15);

        assertEq(curveContract.getFeePercent(), 2e15);
    }

    function testRevertIfNotInitialized() public {
        vm.expectRevert(bytes(ERR_POOL_NOT_INITIALIZED));        
        curveContract.addLiquidity(address(this), 1e18);

        vm.expectRevert(bytes(ERR_POOL_NOT_INITIALIZED));        
        curveContract.removeLiquidity(address(this), 1e18, 1e18);

        vm.expectRevert(bytes(ERR_POOL_NOT_INITIALIZED));        
        curveContract.claimReward(address(this));

        vm.expectRevert(bytes(ERR_POOL_NOT_INITIALIZED));        
        curveContract.buyTokens(address(this), 1e18);

        vm.expectRevert(bytes(ERR_POOL_NOT_INITIALIZED));        
        curveContract.sellTokens(address(this), 1e18, 1e18);
    }

    function testInitialize() public {

        InverseBondingCurveToken tokenContract = InverseBondingCurveToken(curveContract.getInverseTokenAddress());
        curveContract.initialize{value: 2 ether}(1e18, 1e18);

        uint256 price = curveContract.getPrice(1e18);
        (int256 k, uint256 m) = curveContract.getCurveParameters();
        assert(m > 1e18 - ALLOWED_ERROR && m < 1e18 + ALLOWED_ERROR);

        assertEq(price, 1e18);
        assertEq(tokenContract.balanceOf(recipient), 1e18);
        assertEq(curveContract.balanceOf(recipient), 2e18);
        
        assertEq(k, 5e17);
    }

    function testAddLiquidity() public {

        InverseBondingCurveToken tokenContract = InverseBondingCurveToken(curveContract.getInverseTokenAddress());
        curveContract.initialize{value: 2 ether}(1e18, 1e18);

        curveContract.addLiquidity{value: 2 ether}(recipient, 1e18);

        uint256 price = curveContract.getPrice(1e18);
        (int256 k, uint256 m) = curveContract.getCurveParameters();
        assert(m > 1e18 - ALLOWED_ERROR && m < 1e18 + ALLOWED_ERROR);        
        assert(k > 75e16 - int256(ALLOWED_ERROR) && k < 75e16 + int256(ALLOWED_ERROR));
        assertEq(price, 1e18);

        assertEq(tokenContract.balanceOf(recipient), 1e18);
        assertEq(curveContract.balanceOf(recipient), 4e18);
    }

    function testRemoveLiquidity() public {

        InverseBondingCurveToken tokenContract = InverseBondingCurveToken(curveContract.getInverseTokenAddress());
        curveContract.initialize{value: 2 ether}(1e18, 1e18);
        curveContract.addLiquidity{value: 2 ether}(recipient, 1e18);

        uint256 balanceBefore = otherRecipient.balance;

        // vm.startPrank(recipient);
        // vm.deal(recipient, 1000 ether);

        curveContract.removeLiquidity(otherRecipient, 2e18, 1e18);

        uint256 balanceAfter = otherRecipient.balance;

        uint256 price = curveContract.getPrice(1e18);
        (int256 k, uint256 m) = curveContract.getCurveParameters();
        assert(m > 1e18 - ALLOWED_ERROR && m < 1e18 + ALLOWED_ERROR);        
        assert(k > 5e17 - int256(ALLOWED_ERROR) && k < 5e17 + int256(ALLOWED_ERROR));
        assertEq(price, 1e18);

        assertEq(tokenContract.balanceOf(recipient), 1e18);
        assertEq(curveContract.balanceOf(recipient), 2e18);
        assertEq(balanceAfter - balanceBefore, 2e18);
    }

    function testBuyTokens() public {

        InverseBondingCurveToken tokenContract = InverseBondingCurveToken(curveContract.getInverseTokenAddress());
        curveContract.initialize{value: 2 ether}(1e18, 1e18);

        // curveContract.addLiquidity{value: 2 ether}(recipient, 1e18);

        uint256 balanceBefore = tokenContract.balanceOf(otherRecipient);
        curveContract.buyTokens{value: 1 ether} (otherRecipient, 1e18);

        uint256 balanceAfter = tokenContract.balanceOf(otherRecipient);

        uint256 balanceChange = balanceAfter - balanceBefore;

        assert(balanceChange > 124875e13 - ALLOWED_ERROR && balanceChange < 124875e13 + ALLOWED_ERROR);
    }

    function testSellTokens() public {

        InverseBondingCurveToken tokenContract = InverseBondingCurveToken(curveContract.getInverseTokenAddress());
        curveContract.initialize{value: 2 ether}(1e18, 1e18);

        // curveContract.addLiquidity{value: 2 ether}(recipient, 1e18);

        
        curveContract.buyTokens{value: 1 ether} (recipient, 1e18);

        uint256 balanceBefore = tokenContract.balanceOf(recipient);
        uint256 ethBalanceBefore = otherRecipient.balance;

        // vm.startPrank(otherRecipient);
        // vm.deal(otherRecipient, 1000 ether);
        tokenContract.approve(address(curveContract), 1e18);
        curveContract.sellTokens(otherRecipient, 1e18, 1e17);
        uint256 ethBalanceAfter = otherRecipient.balance;
        uint256 balanceAfter = tokenContract.balanceOf(recipient);

        assertEq(balanceBefore - balanceAfter, 1e18);
        uint256 balanceOut = 763037774123130200;
        uint256 ethBalanceChange = ethBalanceAfter - ethBalanceBefore;
        assert(ethBalanceChange > balanceOut - ALLOWED_ERROR && ethBalanceChange < balanceOut + ALLOWED_ERROR);
    }



    function testFeeAccumulate() public {

        InverseBondingCurveToken tokenContract = InverseBondingCurveToken(curveContract.getInverseTokenAddress());
        curveContract.initialize{value: 2 ether}(1e18, 1e18);

        // curveContract.addLiquidity{value: 2 ether}(recipient, 1e18);

        
        curveContract.buyTokens{value: 1 ether} (otherRecipient, 1e18);

        uint256 feeBalance = tokenContract.balanceOf(address(curveContract));

        uint256 tokenOut = 124875e13;
        uint256 fee = (tokenOut * feePercent)/(1e18 - feePercent);

        assert(feeBalance >= fee - ALLOWED_ERROR && feeBalance <= fee + ALLOWED_ERROR);

        tokenContract.approve(address(curveContract), 1e18);
        curveContract.sellTokens(otherRecipient, 1e18, 1e17);

        feeBalance = tokenContract.balanceOf(address(curveContract));
        fee += 1e18 * feePercent / 1e18;

        assert(feeBalance >= fee - ALLOWED_ERROR && feeBalance <= fee + ALLOWED_ERROR);

        uint256 balanceBefore = tokenContract.balanceOf(otherRecipient);
        curveContract.claimReward(otherRecipient);
        uint256 balanceAfter = tokenContract.balanceOf(otherRecipient);

        assertLe(feeBalance - (balanceAfter - balanceBefore), ALLOWED_ERROR);
        assertEq(tokenContract.balanceOf(address(curveContract)), feeBalance - (balanceAfter - balanceBefore));

    }

    function testClaimRewardFeePortion() public {

        InverseBondingCurveToken tokenContract = InverseBondingCurveToken(curveContract.getInverseTokenAddress());
        curveContract.initialize{value: 2 ether}(1e18, 1e18);

        curveContract.addLiquidity{value: 2 ether}(otherRecipient, 1e18);

        
        curveContract.buyTokens{value: 1 ether} (otherRecipient, 1e18);

        uint256 feeBalance = tokenContract.balanceOf(address(curveContract));


        uint256 balanceBefore = tokenContract.balanceOf(otherRecipient);
        curveContract.claimReward(otherRecipient);
        uint256 balanceAfter = tokenContract.balanceOf(otherRecipient);

        console2.log("feebalance   ", feeBalance);
        console2.log("balanceBefore", balanceBefore);
        console2.log("balanceAfter ", balanceAfter);

        assertLe(feeBalance/2 - (balanceAfter - balanceBefore), ALLOWED_ERROR);
        assertLe(tokenContract.balanceOf(address(curveContract)) - feeBalance/2, ALLOWED_ERROR);     

    }

    function testClaimRewardLiquidityChange() public {
        address thirdRecipient = vm.addr(2);
        InverseBondingCurveToken tokenContract = InverseBondingCurveToken(curveContract.getInverseTokenAddress());
        curveContract.initialize{value: 1 ether}(1e18, 1e18);


        vm.deal(otherRecipient, 1000 ether);
        vm.deal(thirdRecipient, 1000 ether);

        vm.startPrank(otherRecipient);
        curveContract.addLiquidity{value: 1 ether}(otherRecipient, 0);
        vm.stopPrank();

        curveContract.buyTokens{value: 2 ether} (otherRecipient, 1e18);

        vm.startPrank(otherRecipient);
        tokenContract.transfer(thirdRecipient, 1e18);
        vm.stopPrank();


        curveContract.claimReward(recipient);
        vm.startPrank(otherRecipient);
        curveContract.claimReward(otherRecipient);
        vm.stopPrank();


        vm.startPrank(otherRecipient);
        tokenContract.approve(address(curveContract), 1e18);
        curveContract.sellTokens(otherRecipient, 1e18, 0);
        vm.stopPrank();



        vm.startPrank(thirdRecipient);
        curveContract.addLiquidity{value: address(curveContract).balance}(thirdRecipient, 0);
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

        assertEq(otherRecipientFee, feePercent/2 + feePercent/4);
        assertEq(thirdRecipientFee, feePercent/2);

        console2.log("otherRecipientFee", otherRecipientFee);
        console2.log("thirdRecipientFee", thirdRecipientFee);


    }    
}
