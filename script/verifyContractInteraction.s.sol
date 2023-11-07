// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/Script.sol";
import "../src/InverseBondingCurve.sol";
import "../src/InverseBondingCurveRouter.sol";
import "../src/InverseBondingCurveToken.sol";
import "forge-std/console2.sol";

contract VerifyContractInteraction is Script {
    function setUp() public {}


    function run() public {
        address routerAddress = vm.envAddress("IBC_ROUTER_CONTRACT_ADDRESS");
        address ibethCurveAddress = vm.envAddress("IBC_IBETH_CURVE_CONTRACT_ADDRESS");
        // string memory seedPhrase = vm.envString("FOUNDRY_TEST_MNEMONIC");
        // uint256 privateKey = vm.deriveKey(seedPhrase, 0);
        uint256 privateKey = vm.parseUint(vm.toString(vm.envBytes32("FOUNDRY_TEST_PRIVATE_KEY")));

        vm.startBroadcast(privateKey);
        address recipient = vm.addr(privateKey);
        console2.log(recipient); 

        InverseBondingCurveRouter routerContract = InverseBondingCurveRouter(payable(routerAddress));
        InverseBondingCurve curveContract = InverseBondingCurve(ibethCurveAddress);
        InverseBondingCurveToken inverseToken = InverseBondingCurveToken(curveContract.inverseTokenAddress());

        
        // Step 1: verify buy token
        // uint256 tokenBalanceBefore = inverseToken.balanceOf(recipient);
        // uint256 buyReserve = 0.01 ether;
        // bytes memory data = abi.encode(recipient, buyReserve, 0, [0, 0], [0, 0]);        
        // console2.log("Previous balance", tokenBalanceBefore); 
        // routerContract.execute{value: buyReserve}(recipient, ibethCurveAddress, true, CommandType.BUY_TOKEN, data);
        // uint256 boughtToken = inverseToken.balanceOf(recipient) - tokenBalanceBefore;     
        // console2.log("Token bought", boughtToken); 

        // Step 2: verify stake token(half balance)
        // uint256 tokenBalanceBefore = inverseToken.balanceOf(recipient);
        // uint256 stakeAmount = tokenBalanceBefore/2;
        // bytes memory data = abi.encode(recipient, stakeAmount);
        // inverseToken.approve(address(routerContract), tokenBalanceBefore);
        // routerContract.execute(recipient, ibethCurveAddress, true, CommandType.STAKE, data);
        // console2.log("stake balance", curveContract.stakingBalanceOf(recipient));

        // Step 3: sell token
        // uint256 tokenBalanceBefore = inverseToken.balanceOf(recipient);
        // console2.log("sell token:", tokenBalanceBefore);
        // bytes memory data = abi.encode(recipient, tokenBalanceBefore, [0, 0], [0, 0]);
        // uint256 reserveBalanceBefore = recipient.balance;
        // routerContract.execute(recipient, ibethCurveAddress, true, CommandType.SELL_TOKEN, data);
        // console2.log("return liquidity:", recipient.balance - reserveBalanceBefore);

        // Step 4: add liquidity
        // uint256 addLiquidity = 0.01 ether;
        // bytes memory data = abi.encode(recipient, addLiquidity, [0, 0]);
        // routerContract.execute{value: addLiquidity}(recipient, ibethCurveAddress, true, CommandType.ADD_LIQUIDITY, data);
        // (uint256 lpPosition, uint256 creditToken) = curveContract.liquidityPositionOf(recipient);
        // console2.log("lp position", lpPosition);
        // console2.log("credit token", creditToken);

        // Step 5: remove liquidity
        // bytes memory data = abi.encode(recipient, inverseToken.balanceOf(recipient), [0, 0]);
        // uint256 reserveBalanceBefore = recipient.balance;
        // routerContract.execute(recipient, ibethCurveAddress, true, CommandType.REMOVE_LIQUIDITY, data);
        // console2.log("remove liquidity returned:", recipient.balance - reserveBalanceBefore);

        // Step 6: unstake
        // uint256 tokenBalanceBefore = inverseToken.balanceOf(recipient);
        // bytes memory data = abi.encode(recipient, curveContract.stakingBalanceOf(recipient));
        // routerContract.execute(recipient, ibethCurveAddress, true, CommandType.UNSTAKE, data);
        // inverseToken.balanceOf(recipient) - tokenBalanceBefore;     
        // console2.log("unstake balance", inverseToken.balanceOf(recipient) - tokenBalanceBefore);
        // console2.log("current stake balance", curveContract.stakingBalanceOf(recipient));

        // Step 7: claim reward
        // bytes memory data = abi.encode(recipient);
        // uint256 tokenBalanceBefore = inverseToken.balanceOf(recipient);
        // uint256 reserveBalanceBefore = recipient.balance;
        // routerContract.execute(recipient, ibethCurveAddress, true, CommandType.CLAIM_REWARD, data);
        // console2.log("claim token reward:", inverseToken.balanceOf(recipient) - tokenBalanceBefore);
        // console2.log("claim ETH reward:", recipient.balance - reserveBalanceBefore);

        vm.stopBroadcast();
    }
}