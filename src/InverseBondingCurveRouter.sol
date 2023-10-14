// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.18;

import "./Enums.sol";
import "./Errors.sol";
import "./interface/IWETH9.sol";

contract InverseBondingCurveRouter {
    IWETH9 private _weth;

    constructor(address wethAddress) {
        _weth = IWETH9(wethAddress);
    }

    function execute(address recipient, address pool, bool useNative, CommandType command, bytes memory data)
        external
        payable
    {
        uint256 balanceBeforeAction = 0;
        uint256 nativeEthToUser = msg.value;
        if (useNative && msg.value > 0) {
            _weth.deposit();
            _weth.transfer(pool, msg.value);

            balanceBeforeAction = _weth.balanceOf(recipient);
        }
        bytes memory poolCallData = _getCallDate(command, data);
        (bool success,) = pool.call(poolCallData);
        if (!success) {
            revert FailToExecute(pool, data);
        }

        if (useNative) {
            nativeEthToUser = _weth.balanceOf(recipient) - balanceBeforeAction;
            _weth.withdraw(nativeEthToUser);
        }

        if (!useNative) {
            (bool sent,) = msg.sender.call{value: msg.value}("");
            if (!sent) {
                revert FailToSend(msg.sender);
            }
        }
    }

    function _getCallDate(CommandType command, bytes memory data) private view returns (bytes memory poolCallData) {
        if (command == CommandType.ADD_LIQUIDITY) {
            (, uint256 reserveIn, uint256 minPriceLimit) = abi.decode(data, (address, uint256, uint256));
            poolCallData =
                abi.encodeWithSignature("addLiquidity(address,uint256,uint256)", msg.sender, reserveIn, minPriceLimit);
        } else if (command == CommandType.REMOVE_LIQUIDITY) {
            (, uint256 inverseTokenIn, uint256 maxPriceLimit) = abi.decode(data, (address, uint256, uint256));
            poolCallData = abi.encodeWithSignature(
                "removeLiquidity(address,uint256,uint256)", msg.sender, inverseTokenIn, maxPriceLimit
            );
        } else if (command == CommandType.BUY_TOKEN) {
            (, uint256 reserveIn, uint256 exactAmountOut, uint256 maxPriceLimit) =
                abi.decode(data, (address, uint256, uint256, uint256));
            poolCallData = abi.encodeWithSignature(
                "buyTokens(address,uint256,uint256,uint256)", msg.sender, reserveIn, exactAmountOut, maxPriceLimit
            );
        } else if (command == CommandType.SELL_TOKEN) {
            (, uint256 inverseTokenIn, uint256 minPriceLimit) = abi.decode(data, (address, uint256, uint256));
            poolCallData = abi.encodeWithSignature(
                "sellTokens(address,uint256,uint256)", msg.sender, inverseTokenIn, minPriceLimit
            );
        } else if (command == CommandType.CLAIM_REWARD) {
            poolCallData = abi.encodeWithSignature("claimReward(address)", msg.sender);
        } else if (command == CommandType.STAKE) {
            (, uint256 amount) = abi.decode(data, (address, uint256));
            poolCallData = abi.encodeWithSignature("stake(address,uint256) ", msg.sender, amount);            
        } else if (command == CommandType.UNSTAKE) {
            (, uint256 amount) = abi.decode(data, (address, uint256));
            poolCallData = abi.encodeWithSignature("ustake(address,uint256) ", msg.sender, amount); 
        }else {
            revert CommandUnsupport();
        }
    }
}
