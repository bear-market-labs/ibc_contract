// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import "../src/InverseBondingCurve.sol";
import "../src/InverseBondingCurveToken.sol";
import "../src/InverseBondingCurveProxy.sol";
import "forge-std/console2.sol";

contract InverseBondingCurveTest is Test {
    using FixedPoint for uint256;

    InverseBondingCurve curveContract;
    InverseBondingCurveToken tokenContract;
    InverseBondingCurveProxy proxyContract;
    InverseBondingCurve curveContractImpl;

    uint256 ALLOWED_ERROR = 1e10;
    uint256 FEE_PERCENT = 1e15;

    address recipient = address(this);
    address otherRecipient = vm.parseAddress("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266");
    uint256 feePercent = 3e15;
    address nonOwner = vm.addr(1);
    address owner = address(this);

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
        curveContractImpl = new InverseBondingCurve();
        tokenContract = new InverseBondingCurveToken(address(this), "IBC", "IBC");

        proxyContract = new InverseBondingCurveProxy(address(curveContractImpl), "");
        tokenContract = new InverseBondingCurveToken(address(proxyContract), "IBC", "IBC");
        curveContract = InverseBondingCurve(address(proxyContract));
        curveContract.initialize(2e18, 1e18, 1e18, address(tokenContract), otherRecipient);
        curveContract.updateFeeConfig(ActionType.ADD_LIQUIDITY, FEE_PERCENT, FEE_PERCENT, FEE_PERCENT);
        curveContract.updateFeeConfig(ActionType.REMOVE_LIQUIDITY, FEE_PERCENT, FEE_PERCENT, FEE_PERCENT);
        curveContract.updateFeeConfig(ActionType.BUY_TOKEN, FEE_PERCENT, FEE_PERCENT, FEE_PERCENT);
        curveContract.updateFeeConfig(ActionType.SELL_TOKEN, FEE_PERCENT, FEE_PERCENT, FEE_PERCENT);
    }

    // function testSymbol() public {
    //     assertEq(curveContract.symbol(), "IBCLP");
    // }

    function testInverseTokenSymbol() public {
        assertEq(tokenContract.symbol(), "IBC");
    }

    // function testLPTokenSymbol() public {
    //     assertEq(curveContract.symbol(), "IBCLP");
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

    function testRevertIfFeeOverLimit() public {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(FeePercentOutOfRange.selector));
        curveContract.updateFeeConfig(ActionType.REMOVE_LIQUIDITY, 2e16, 4e16, 4e16);
        vm.stopPrank();
    }

    function testRevertIfUpdateFeeFromNonOwner() public {
        vm.startPrank(nonOwner);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        curveContract.updateFeeConfig(ActionType.REMOVE_LIQUIDITY, 2e15, 3e15, 4e15);
        vm.stopPrank();
    }

    function testRevertIfPauseFromNonOwner() public {
        vm.startPrank(nonOwner);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        curveContract.pause();
        vm.stopPrank();
    }

    function testRevertIfUnpauseFromNonOwner() public {
        vm.startPrank(owner);
        curveContract.pause();
        vm.stopPrank();
        vm.startPrank(nonOwner);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        curveContract.unpause();
        vm.stopPrank();
    }

    function testRevertIfChangeOwnerFromNonOwner() public {
        vm.startPrank(nonOwner);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        curveContract.transferOwnership(owner);
        vm.stopPrank();
    }

    function testRevertIfChangeFeeOwnerFromNonOwner() public {
        vm.startPrank(nonOwner);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        curveContract.updateFeeOwner(owner);
        vm.stopPrank();
    }

    function testRevertIfChangeFeeOwnerToZero() public {
        vm.startPrank(owner);
        vm.expectRevert();
        curveContract.updateFeeOwner(address(0));
        vm.stopPrank();
    }

    function testUpdateFeeOwner() public {
        vm.startPrank(owner);
        assertEq(curveContract.feeOwner(), address(otherRecipient));
        curveContract.updateFeeOwner(nonOwner);
        assertEq(curveContract.feeOwner(), nonOwner);
        // vm.expectRevert(bytes(ERR_ONLY_OWNER_ALLOWED));
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector));
        curveContract.claimProtocolReward();
        vm.stopPrank();

        vm.startPrank(nonOwner);
        curveContract.claimProtocolReward();
        vm.stopPrank();
    }

    function testPause() public {
        curveContract.addLiquidity{value: 1 ether}(recipient, 1e18);
        curveContract.buyTokens{value: 1 ether}(recipient, 1e18);
        vm.startPrank(owner);
        assertEq(curveContract.paused(), false);
        assertEq(tokenContract.paused(), false);
        curveContract.pause();
        assertEq(curveContract.paused(), true);
        assertEq(tokenContract.paused(), true);

        vm.stopPrank();
        // vm.expectRevert(bytes("Pausable: paused"));
        // curveContract.transfer(otherRecipient, 1e18);
        vm.expectRevert(bytes("Pausable: paused"));
        tokenContract.transfer(otherRecipient, 1e18);
    }

    function testInitialize() public {
        // uint256 price = curveContract.priceOf(1e18);
        CurveParameter memory param = curveContract.curveParameters();

        assertEqWithError(param.price, 1e18);
        assertEqWithError(tokenContract.balanceOf(recipient), 0);
        (uint256 lpBalance, uint256 ibcCredit) = curveContract.liquidityPositionOf(recipient);
        assertEqWithError(lpBalance, 0);
        assertEqWithError(ibcCredit, 0);
        assertEqWithError(param.virtualReserve, param.reserve);
        assertEqWithError(param.virtualSupply, param.supply);
    }

    function testInverseTokenAddress() public {
        assertEq(curveContract.inverseTokenAddress(), address(tokenContract));
    }

    function testFeeOwner() public {
        assertEq(curveContract.feeOwner(), address(otherRecipient));
    }

    // function testPriceOf() public {
    //     assertEqWithError(curveContract.priceOf(1e20), 1e17);
    // }

    function testGetImplementation() public {
        assertEq(curveContract.getImplementation(), address(curveContractImpl));
    }

    function testAddLiquidity() public {
        CurveParameter memory param = curveContract.curveParameters();
        curveContract.addLiquidity{value: LIQUIDITY_2ETH_BEFOR_FEE}(recipient, 1e18);

        param = curveContract.curveParameters();

        assertEqWithError(param.price, 1e18);

        assertEqWithError(tokenContract.balanceOf(recipient), 0);
        (uint256 lpBalance, uint256 ibcCredit) = curveContract.liquidityPositionOf(recipient);
        assertEqWithError(lpBalance, 1e18);
        assertEqWithError(ibcCredit, 1e18);
    }

    function testRemoveLiquidity() public {
        CurveParameter memory param = curveContract.curveParameters();
        assertEqWithError(param.price, 1e18);

        curveContract.addLiquidity{value: LIQUIDITY_2ETH_BEFOR_FEE}(recipient, 1e18);
        param = curveContract.curveParameters();
        assertEqWithError(param.price, 1e18);
        (uint256 lpBalance, uint256 ibcCredit) = curveContract.liquidityPositionOf(recipient);

        uint256 balanceBefore = otherRecipient.balance;

        curveContract.removeLiquidity(otherRecipient, 1e18 + ALLOWED_ERROR);

        uint256 balanceAfter = otherRecipient.balance;

        param = curveContract.curveParameters();
        assertEqWithError(param.price, 1e18);

        assertEqWithError(tokenContract.balanceOf(recipient), 0);
        (lpBalance, ibcCredit) = curveContract.liquidityPositionOf(recipient);
        assertEqWithError(lpBalance, 0);
        assertEqWithError(balanceAfter - balanceBefore, uint256(2e18).mulDown(ONE_UINT.sub(FEE_PERCENT.mulDown(3e18))));
    }

    function testRemoveLiquidityWithAdditionalBurn() public {
        CurveParameter memory param = curveContract.curveParameters();
        assertEqWithError(param.price, 1e18);

        curveContract.addLiquidity{value: LIQUIDITY_2ETH_BEFOR_FEE}(recipient, 1e18);
        param = curveContract.curveParameters();
        assertEqWithError(param.price, 1e18);

        curveContract.buyTokens{value: LIQUIDITY_2ETH_BEFOR_FEE}(otherRecipient, 1e18);
        (uint256 lpBalance, uint256 ibcCredit) = curveContract.liquidityPositionOf(recipient);

        uint256 balanceBefore = otherRecipient.balance;
        vm.expectRevert();
        curveContract.removeLiquidity(otherRecipient, 1e18 + ALLOWED_ERROR);

        curveContract.buyTokens{value: LIQUIDITY_2ETH_BEFOR_FEE}(recipient, 1e18);
        vm.expectRevert();
        curveContract.removeLiquidity(otherRecipient, 1e18 + ALLOWED_ERROR);

        tokenContract.approve(address(curveContract), 1e19);
        uint256 tokenBalanceBefore = tokenContract.balanceOf(recipient);
        curveContract.removeLiquidity(otherRecipient, 1e18 + ALLOWED_ERROR);

        (lpBalance, ibcCredit) = curveContract.liquidityPositionOf(recipient);

        assertEq(lpBalance, 0);
        assertEq(ibcCredit, 0);

        uint256 balanceAfter = otherRecipient.balance;
        assertGt(balanceAfter, balanceBefore);
        assertLt(tokenContract.balanceOf(recipient), tokenBalanceBefore);
    }

    function testRemoveLiquidityGetAdditionalMint() public {
        CurveParameter memory param = curveContract.curveParameters();
        assertEqWithError(param.price, 1e18);

        curveContract.buyTokens{value: LIQUIDITY_2ETH_BEFOR_FEE}(otherRecipient, 1e18);

        curveContract.addLiquidity{value: LIQUIDITY_2ETH_BEFOR_FEE}(recipient, 1e17);

        vm.startPrank(otherRecipient);
        tokenContract.approve(address(curveContract), 1e19);
        curveContract.sellTokens(otherRecipient, tokenContract.balanceOf(otherRecipient), 1e17);
        vm.stopPrank();

        uint256 balanceBefore = otherRecipient.balance;
        uint256 tokenBalanceBefore = tokenContract.balanceOf(otherRecipient);
        curveContract.removeLiquidity(otherRecipient, 1e18 + ALLOWED_ERROR);

        (uint256 lpBalance, uint256 ibcCredit) = curveContract.liquidityPositionOf(recipient);

        assertEq(lpBalance, 0);
        assertEq(ibcCredit, 0);

        uint256 balanceAfter = otherRecipient.balance;
        assertGt(balanceAfter, balanceBefore);
        assertGt(tokenContract.balanceOf(otherRecipient), tokenBalanceBefore);
    }

    function testBuyTokens() public {
        uint256 balanceBefore = tokenContract.balanceOf(otherRecipient);
        curveContract.buyTokens{value: 1 ether}(otherRecipient, 1e18);

        uint256 balanceAfter = tokenContract.balanceOf(otherRecipient);

        uint256 balanceChange = balanceAfter - balanceBefore;

        assertEqWithError(balanceChange, 124625e13);
    }

    function testSellTokens() public {
        curveContract.buyTokens{value: 1 ether}(recipient, 1e18);

        uint256 balanceBefore = tokenContract.balanceOf(recipient);
        uint256 ethBalanceBefore = otherRecipient.balance;

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

        // CurveParameter memory param = curveContract.curveParameters();

        curveContract.buyTokens{value: 1 ether}(otherRecipient, 1e18);

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

        uint256 balanceBefore = tokenContract.balanceOf(otherRecipient);
        curveContract.claimReward(otherRecipient);
        uint256 balanceAfter = tokenContract.balanceOf(otherRecipient);

        assertEq(balanceAfter - balanceBefore, lpReward);
        assertEqWithError(feeBalance, (balanceAfter - balanceBefore) * 3);
        assertEqWithError(tokenContract.balanceOf(address(curveContract)), feeBalance - (balanceAfter - balanceBefore));
    }

    function testClaimRewardFeePortion() public {
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

        vm.deal(otherRecipient, 1000 ether);
        vm.deal(thirdRecipient, 1000 ether);

        vm.startPrank(otherRecipient);
        curveContract.addLiquidity{value: LIQUIDITY_2ETH_BEFOR_FEE}(otherRecipient, 0);
        vm.stopPrank();

        curveContract.buyTokens{value: 2 ether}(otherRecipient, 1e18);

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

        CurveParameter memory param = curveContract.curveParameters();
        (uint256 lpBalance, uint256 ibcCredit) = curveContract.liquidityPositionOf(otherRecipient);
        uint256 firstSellFee = 1e15 * lpBalance / param.lpSupply;
        vm.stopPrank();

        vm.startPrank(thirdRecipient);
        curveContract.addLiquidity{value: address(curveContract).balance}(thirdRecipient, 0);
        tokenContract.approve(address(curveContract), 1e18);
        curveContract.sellTokens(otherRecipient, 1e18, 0);

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
        uint256 secondSellFeeForthirdRecipient = 1e15 * lpBalance / param.lpSupply;
        vm.stopPrank();

        assertEqWithError(firstSellFee + secondSellFee, otherRecipientFee);
        assertEqWithError(secondSellFeeForthirdRecipient, thirdRecipientFee);
    }

    function testClaimRewardStakingChange() public {
        address thirdRecipient = vm.addr(2);
        // curveContract.initialize{value: 2 ether}(1e18, 1e18, address(tokenContract), otherRecipient);

        vm.deal(otherRecipient, 1000 ether);
        vm.deal(thirdRecipient, 1000 ether);

        curveContract.buyTokens{value: 20 ether}(otherRecipient, 1e18);

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
    }

    // function testLpTransfers() public {
    //     curveContract.addLiquidity{value: LIQUIDITY_2ETH_BEFOR_FEE}(recipient, 0);

    //     (uint256 reward,,,) = curveContract.rewardOf(recipient);
    //     assertEq(reward, 0);

    //     //perform mints to generate lp fees
    //     curveContract.buyTokens{value: 2 ether}(otherRecipient, 1e18);

    //     //transfer from recipient to otherRecipient
    //     //confirm sender/recipient's reward state
    //     vm.startPrank(recipient);
    //     curveContract.transfer(otherRecipient, curveContract.balanceOf(recipient));
    //     vm.stopPrank();

    //     (uint256 senderLpReward,,,) = curveContract.rewardOf(recipient);
    //     (uint256 recipientLpReward,,,) = curveContract.rewardOf(otherRecipient);
    //     assertEqWithError(senderLpReward, 12187500000000000 / 3);
    //     assert(recipientLpReward == 0);

    //     //perform more mints to generate lp fees
    //     curveContract.buyTokens{value: 1 ether}(recipient, 1e18);

    //     //transferfrom otherRecipient to recipient
    //     //confirm sender/recipient's reward state
    //     vm.startPrank(otherRecipient);
    //     curveContract.approve(recipient, 10e18);
    //     vm.stopPrank();

    //     vm.startPrank(recipient);
    //     curveContract.transferFrom(otherRecipient, recipient, 2e18);
    //     vm.stopPrank();

    //     (uint256 senderLpReward2,,,) = curveContract.rewardOf(otherRecipient);
    //     (uint256 recipientLpReward2,,,) = curveContract.rewardOf(recipient);
    //     assertEqWithError(senderLpReward, recipientLpReward2);
    //     assertEqWithError(senderLpReward2, 12949218750000000 / 3);
    // }

    function testStake() public {
        curveContract.buyTokens{value: 2 ether}(recipient, 1e18);

        uint256 stakeAmount = tokenContract.balanceOf(recipient);
        assertEq(curveContract.stakingBalanceOf(recipient), 0);
        tokenContract.approve(address(curveContract), stakeAmount);
        curveContract.stake(stakeAmount);
        assertEq(tokenContract.balanceOf(recipient), 0);
        assertEq(curveContract.stakingBalanceOf(recipient), stakeAmount);
        assertEq(curveContract.totalStaked(), stakeAmount);
    }

    function testUnstake() public {
        curveContract.buyTokens{value: 2 ether}(recipient, 1e18);

        uint256 stakeAmount = tokenContract.balanceOf(recipient);
        assertEq(curveContract.stakingBalanceOf(recipient), 0);
        tokenContract.approve(address(curveContract), stakeAmount);
        curveContract.stake(stakeAmount);
        assertEq(tokenContract.balanceOf(recipient), 0);
        assertEq(curveContract.stakingBalanceOf(recipient), stakeAmount);
        curveContract.unstake(stakeAmount);
        assertEq(tokenContract.balanceOf(recipient), stakeAmount);
        assertEq(curveContract.stakingBalanceOf(recipient), 0);
    }

    function testClaimProtocolFee() public {
        curveContract.addLiquidity{value: LIQUIDITY_2ETH_BEFOR_FEE}(recipient, 1e18);

        uint256 accumulatedReserveFee = (LIQUIDITY_2ETH_BEFOR_FEE - 2e18).mulDown(2e18).divDown(3e18);

        uint256 balanceBefore = tokenContract.balanceOf(otherRecipient);
        curveContract.buyTokens{value: 1 ether}(otherRecipient, 1e18);

        uint256 balanceAfter = tokenContract.balanceOf(otherRecipient);
        uint256 balanceChange = balanceAfter - balanceBefore;

        uint256 accumulatedTokenFee =
            uint256(balanceChange.divDown(1e18 - FEE_PERCENT.mulDown(3e18)).mulDown(FEE_PERCENT));
        (uint256 inverseTokenReward, uint256 reserveReward) = curveContract.rewardOfProtocol();

        assertEqWithError(inverseTokenReward, accumulatedTokenFee);
        assertEqWithError(reserveReward, accumulatedReserveFee);

        uint256 reserveBalanceBefore = otherRecipient.balance;
        uint256 tokenBalanceBefore = tokenContract.balanceOf(otherRecipient);
        vm.startPrank(otherRecipient);
        curveContract.claimProtocolReward();
        vm.stopPrank();
        uint256 reserveBalanceAfter = otherRecipient.balance;
        uint256 tokenBalanceAfter = tokenContract.balanceOf(otherRecipient);
        assertEq(reserveBalanceAfter - reserveBalanceBefore, reserveReward);
        assertEq(tokenBalanceAfter - tokenBalanceBefore, inverseTokenReward);
    }

    function testRewardFirstStaker() public {
        curveContract.addLiquidity{value: LIQUIDITY_2ETH_BEFOR_FEE}(recipient, 1e18);

        uint256 accumulatedReserveFee = (LIQUIDITY_2ETH_BEFOR_FEE - 2e18).mulDown(1e18).divDown(3e18);

        uint256 balanceBefore = tokenContract.balanceOf(otherRecipient);
        curveContract.buyTokens{value: 1 ether}(otherRecipient, 1e18);

        uint256 balanceAfter = tokenContract.balanceOf(otherRecipient);
        uint256 balanceChange = balanceAfter - balanceBefore;

        uint256 accumulatedTokenFee =
            uint256(balanceChange.divDown(1e18 - FEE_PERCENT.mulDown(3e18)).mulDown(FEE_PERCENT));

        vm.startPrank(otherRecipient);
        tokenContract.approve(address(curveContract), 1e18);
        curveContract.stake(1e18);

        (uint256 inverseTokenForLp, uint256 inverseTokenForStaking, uint256 reserveForLp, uint256 reserveForStaking) =
            curveContract.rewardOf(otherRecipient);

        assertEq(inverseTokenForLp, 0);
        assertEq(reserveForLp, 0);

        assertEqWithError(inverseTokenForStaking, accumulatedTokenFee);
        assertEqWithError(reserveForStaking, accumulatedReserveFee);

        uint256 reserveBalanceBefore = otherRecipient.balance;
        uint256 tokenBalanceBefore = tokenContract.balanceOf(otherRecipient);

        curveContract.claimReward(otherRecipient);

        uint256 reserveBalanceAfter = otherRecipient.balance;
        uint256 tokenBalanceAfter = tokenContract.balanceOf(otherRecipient);
        assertEq(reserveBalanceAfter - reserveBalanceBefore, reserveForStaking);
        assertEq(tokenBalanceAfter - tokenBalanceBefore, inverseTokenForStaking);

        vm.stopPrank();
    }

    function testRevertIfPriceOutOfLimitWhenBuyToken() public {
        curveContract.buyTokens{value: 1 ether}(recipient, 1e18);
        CurveParameter memory param = curveContract.curveParameters();

        tokenContract.approve(address(curveContract), 2e18);
        curveContract.sellTokens(recipient, 1e18, 0);
        // CurveParameter memory param2 = curveContract.curveParameters();

        //vm.expectRevert(bytes(ERR_PRICE_OUT_OF_LIMIT));
        //vm.expectRevert(abi.encodeWithSelector(PriceOutOfLimit.selector, param2.price, param.price));
        vm.expectRevert();
        curveContract.buyTokens{value: 1 ether}(recipient, param.price);
    }

    // function testRevertIfReserveOutOfLimitWhenBuyToken() public {
    //     curveContract.buyTokens{value: 1 ether}(recipient, 1e18);
    //     CurveParameter memory param = curveContract.curveParameters();

    //     // tokenContract.approve(address(curveContract), 2e18);
    //     // curveContract.sellTokens(recipient, 1e18, 0, 0);

    //     curveContract.addLiquidity{value: LIQUIDITY_2ETH_BEFOR_FEE}(recipient, param.price);
    //     param = curveContract.curveParameters();

    //     // vm.expectRevert(bytes(ERR_RESERVE_OUT_OF_LIMIT));
    //     vm.expectRevert();
    //     curveContract.buyTokens{value: 1 ether}(recipient, param.price + ALLOWED_ERROR);
    // }

    function testRevertIfPriceOutOfLimitWhenSellToken() public {
        curveContract.buyTokens{value: 1 ether}(recipient, 1e18);
        CurveParameter memory param = curveContract.curveParameters();

        curveContract.buyTokens{value: 1 ether}(recipient, 1e18);
        tokenContract.approve(address(curveContract), 2e18);
        // vm.expectRevert(bytes(ERR_PRICE_OUT_OF_LIMIT));
        vm.expectRevert();
        curveContract.sellTokens(recipient, 1e18, param.price);
    }

    // function testRevertIfReserveOutOfLimitWhenSellToken() public {
    //     curveContract.addLiquidity{value: LIQUIDITY_2ETH_BEFOR_FEE}(recipient, 1e18);

    //     curveContract.buyTokens{value: 1 ether}(recipient, 1e18);
    //     CurveParameter memory param = curveContract.curveParameters();

    //     curveContract.removeLiquidity(recipient, param.price);

    //     tokenContract.approve(address(curveContract), 2e18);
    //     //vm.expectRevert(bytes(ERR_RESERVE_OUT_OF_LIMIT));
    //     vm.expectRevert();
    //     curveContract.sellTokens(recipient, 1e18, 0);
    // }

    function testRevertIfPriceOutOfLimitWhenAddLiquidity() public {
        curveContract.buyTokens{value: 1 ether}(recipient, 1e18);
        // CurveParameter memory param = curveContract.curveParameters();

        // vm.expectRevert(bytes(ERR_PRICE_OUT_OF_LIMIT));
        vm.expectRevert();
        curveContract.addLiquidity{value: LIQUIDITY_2ETH_BEFOR_FEE}(recipient, 1e18);
    }

    function testRevertIfPriceOutOfLimitWhenRemoveLiquidity() public {
        curveContract.addLiquidity{value: LIQUIDITY_2ETH_BEFOR_FEE}(recipient, 1e18);

        curveContract.buyTokens{value: 1 ether}(recipient, 1e18);
        CurveParameter memory param = curveContract.curveParameters();

        tokenContract.approve(address(curveContract), 2e18);
        curveContract.sellTokens(recipient, 1e18, 0);

        // vm.expectRevert(bytes(ERR_PRICE_OUT_OF_LIMIT));
        vm.expectRevert();
        curveContract.removeLiquidity(recipient, param.price);
    }

    function testRewardState() public {
        curveContract.addLiquidity{value: LIQUIDITY_2ETH_BEFOR_FEE}(recipient, 1e18);
        (
            uint256[MAX_FEE_STATE_COUNT] memory inverseTokenTotalReward,
            uint256[MAX_FEE_STATE_COUNT] memory inverseTokenPendingReward,
            uint256[MAX_FEE_STATE_COUNT] memory reserveTotalReward,
            uint256[MAX_FEE_STATE_COUNT] memory reservePendingReward
        ) = curveContract.rewardState();

        assertEq(inverseTokenTotalReward[0], 0);
        assertEq(inverseTokenTotalReward[1], 0);
        assertEq(inverseTokenTotalReward[2], 0);

        assertEq(inverseTokenPendingReward[0], 0);
        assertEq(inverseTokenPendingReward[1], 0);
        assertEq(inverseTokenPendingReward[2], 0);

        uint256 addLiquidityFee = LIQUIDITY_2ETH_BEFOR_FEE - 2e18;

        assertEq(reserveTotalReward[0], 0);
        assertEqWithError(reserveTotalReward[1], addLiquidityFee.divDown(3e18));
        assertEqWithError(reserveTotalReward[2], addLiquidityFee.divDown(3e18).mulDown(2e18));

        assertEq(reservePendingReward[0], 0);
        assertEqWithError(reservePendingReward[1], addLiquidityFee.divDown(3e18));
        assertEqWithError(reservePendingReward[2], addLiquidityFee.divDown(3e18).mulDown(2e18));

        curveContract.buyTokens{value: 1 ether}(otherRecipient, 1e18);

        uint256 tokenOut = tokenContract.balanceOf(otherRecipient);
        uint256 fee = (tokenOut * feePercent) / (1e18 - feePercent);

        (inverseTokenTotalReward, inverseTokenPendingReward, reserveTotalReward, reservePendingReward) =
            curveContract.rewardState();

        assertEqWithError(inverseTokenTotalReward[0], fee.divDown(3e18));
        assertEqWithError(inverseTokenTotalReward[1], fee.divDown(3e18));
        assertEqWithError(inverseTokenTotalReward[2], fee.divDown(3e18));

        assertEqWithError(inverseTokenPendingReward[0], fee.divDown(3e18));
        assertEqWithError(inverseTokenPendingReward[1], fee.divDown(3e18));
        assertEqWithError(inverseTokenPendingReward[2], fee.divDown(3e18));

        assertEqWithError(reserveTotalReward[0], 0);
        assertEqWithError(reserveTotalReward[1], addLiquidityFee.divDown(3e18));
        assertEqWithError(reserveTotalReward[2], addLiquidityFee.divDown(3e18).mulDown(2e18));

        assertEqWithError(reservePendingReward[0], 0);
        assertEqWithError(reservePendingReward[1], addLiquidityFee.divDown(3e18));
        assertEqWithError(reservePendingReward[2], addLiquidityFee.divDown(3e18).mulDown(2e18));

        vm.startPrank(otherRecipient);
        tokenContract.approve(address(curveContract), 1e18);
        curveContract.stake(1e18);
        vm.stopPrank();

        curveContract.addLiquidity{value: LIQUIDITY_2ETH_BEFOR_FEE}(otherRecipient, 0);

        (inverseTokenTotalReward, inverseTokenPendingReward, reserveTotalReward, reservePendingReward) =
            curveContract.rewardState();

        assertEqWithError(inverseTokenTotalReward[0], fee.divDown(3e18));
        assertEqWithError(inverseTokenTotalReward[1], fee.divDown(3e18));
        assertEqWithError(inverseTokenTotalReward[2], fee.divDown(3e18));

        assertEqWithError(inverseTokenPendingReward[0], fee.divDown(3e18));
        assertEqWithError(inverseTokenPendingReward[1], fee.divDown(3e18));
        assertEqWithError(inverseTokenPendingReward[2], fee.divDown(3e18));

        assertEqWithError(reserveTotalReward[0], addLiquidityFee.divDown(3e18));
        assertEqWithError(reserveTotalReward[1], addLiquidityFee.divDown(3e18).mulDown(2e18));
        assertEqWithError(reserveTotalReward[2], addLiquidityFee.divDown(3e18).mulDown(3e18));

        assertEqWithError(reservePendingReward[0], addLiquidityFee.divDown(3e18));
        assertEqWithError(reservePendingReward[1], addLiquidityFee.divDown(3e18).mulDown(2e18));
        assertEqWithError(reservePendingReward[2], addLiquidityFee.divDown(3e18).mulDown(3e18));

        curveContract.claimReward(recipient);
        vm.startPrank(otherRecipient);
        curveContract.claimReward(otherRecipient);
        curveContract.claimProtocolReward();
        vm.stopPrank();
        (inverseTokenTotalReward, inverseTokenPendingReward, reserveTotalReward, reservePendingReward) =
            curveContract.rewardState();

        assertEqWithError(inverseTokenTotalReward[0], fee.divDown(3e18));
        assertEqWithError(inverseTokenTotalReward[1], fee.divDown(3e18));
        assertEqWithError(inverseTokenTotalReward[2], fee.divDown(3e18));

        assertEqWithError(inverseTokenPendingReward[0], 0);
        assertEqWithError(inverseTokenPendingReward[1], 0);
        assertEqWithError(inverseTokenPendingReward[2], 0);

        assertEqWithError(reserveTotalReward[0], addLiquidityFee.divDown(3e18));
        assertEqWithError(reserveTotalReward[1], addLiquidityFee.divDown(3e18).mulDown(2e18));
        assertEqWithError(reserveTotalReward[2], addLiquidityFee.divDown(3e18).mulDown(3e18));

        assertEqWithError(reservePendingReward[0], 0);
        assertEqWithError(reservePendingReward[1], 0);
        assertEqWithError(reservePendingReward[2], 0);
    }

    function testBlockRewardEMA() public {
        //vm.roll(block.number() + 1)
        vm.roll(block.number + 1);
        (uint256 inverseTokenReward, uint256 reserveReward) = curveContract.blockRewardEMA(RewardType.LP);
        assertEq(inverseTokenReward, 0);
        assertEq(reserveReward, 0);
        (inverseTokenReward, reserveReward) = curveContract.blockRewardEMA(RewardType.STAKING);
        assertEq(inverseTokenReward, 0);
        assertEq(reserveReward, 0);
        curveContract.addLiquidity{value: LIQUIDITY_2ETH_BEFOR_FEE}(recipient, 1e18);
        uint256 addLiquidityFee = LIQUIDITY_2ETH_BEFOR_FEE - 2e18;
        uint256 alpha = 138879244274000; // 1 - exp(-1/7200)

        uint256 stakingEMA = addLiquidityFee.mulDown(alpha).divDown(3e18);
        vm.roll(block.number + 1);
        (inverseTokenReward, reserveReward) = curveContract.blockRewardEMA(RewardType.LP);
        assertEq(inverseTokenReward, 0);
        assertEq(reserveReward, 0);

        (inverseTokenReward, reserveReward) = curveContract.blockRewardEMA(RewardType.STAKING);
        assertEq(inverseTokenReward, 0);
        assertEqWithError(reserveReward, stakingEMA);

        curveContract.buyTokens{value: 100 ether}(recipient, 1e19);

        vm.roll(block.number + 1);
        uint256 tokenOut = tokenContract.balanceOf(recipient);
        uint256 fee = (tokenOut * feePercent) / (1e18 - feePercent);
        uint256 lpEMA = fee.mulDown(alpha).divDown(3e18);

        (inverseTokenReward, reserveReward) = curveContract.blockRewardEMA(RewardType.LP);
        assertEqWithError(inverseTokenReward, lpEMA);
        assertEq(reserveReward, 0);
        (inverseTokenReward, reserveReward) = curveContract.blockRewardEMA(RewardType.STAKING);
        assertEqWithError(inverseTokenReward, lpEMA);

        tokenContract.approve(address(curveContract), 1e30);
        for (uint256 i = 0; i < 1000; i++) {
            vm.roll(block.number + 100);
            curveContract.sellTokens(recipient, 1e18, 0);
        }

        // eventually it will be close to average if enough time
        (inverseTokenReward, reserveReward) = curveContract.blockRewardEMA(RewardType.LP);
        assertEqWithError(inverseTokenReward, 1e13);

        (inverseTokenReward, reserveReward) = curveContract.blockRewardEMA(RewardType.STAKING);
        assertEqWithError(inverseTokenReward, 1e13);

        for (uint256 i = 0; i < 1000; i++) {
            vm.roll(block.number + 100);
            curveContract.sellTokens(recipient, 1e16, 0);
        }

        (inverseTokenReward, reserveReward) = curveContract.blockRewardEMA(RewardType.LP);
        assertEqWithError(inverseTokenReward, 1e11);

        (inverseTokenReward, reserveReward) = curveContract.blockRewardEMA(RewardType.STAKING);
        assertEqWithError(inverseTokenReward, 1e11);
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
