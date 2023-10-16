// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.18;

import "openzeppelin/token/ERC20/IERC20.sol";
import "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import "./Enums.sol";
import "./Errors.sol";
import "./interface/IWETH9.sol";
import "./interface/IInverseBondingCurve.sol";

contract InverseBondingCurveRouter {
    using SafeERC20 for IERC20;

    IWETH9 private _weth;

    constructor(address wethAddress) {
        _weth = IWETH9(wethAddress);
    }

    function execute(address recipient, address pool, bool useNative, CommandType command, bytes memory data) external payable {
        IInverseBondingCurve curveContract = IInverseBondingCurve(pool);
        IERC20 reserveToken = IERC20(curveContract.reserveTokenAddress());
        IERC20 inverseToken = IERC20(curveContract.inverseTokenAddress());
        // Send back ether if not using ETH for input token
        if (msg.value > 0) {
            if (useNative && address(reserveToken) == address(_weth)) {
                _weth.deposit{value: msg.value}();
                _weth.transfer(pool, msg.value);
            } else {
                revert EtherNotAccept();
            }
        }

        uint256 reserveBalanceBefore = reserveToken.balanceOf(address(this));
        uint256 inverseBalanceBefore = inverseToken.balanceOf(address(this));
        _payAndExecute(recipient, pool, useNative, command, reserveToken, inverseToken, data);
        uint256 reserveBalanceAfter = reserveToken.balanceOf(address(this));
        uint256 inverseBalanceAfter = inverseToken.balanceOf(address(this));

        if (reserveBalanceAfter > reserveBalanceBefore) {
            uint256 amountToUser = reserveBalanceAfter - reserveBalanceBefore;
            if (useNative && address(reserveToken) == address(_weth)) {
                _weth.withdraw(amountToUser);
                (bool success,) = recipient.call{value: amountToUser}("");
                if (!success) revert FailToSend(recipient);
            } else {
                reserveToken.safeTransfer(recipient, amountToUser);
            }
        }

        if (inverseBalanceAfter > inverseBalanceBefore) {
            inverseToken.safeTransfer(recipient, inverseBalanceAfter - inverseBalanceBefore);
        }
    }

    function _payAndExecute(
        address recipient,
        address pool,
        bool useNative,
        CommandType command,
        IERC20 reserveToken,
        IERC20 inverseToken,
        bytes memory data
    ) private {
        (uint256 reserveTokenAmount, uint256 inverseTokenAmount, bytes memory poolCallData) = _getInputAndCallData(command, data);

        if (reserveTokenAmount > 0) {
            if (!useNative) {
                reserveToken.safeTransferFrom(recipient, pool, reserveTokenAmount);
            }
        }
        if (inverseTokenAmount > 0) {
            inverseToken.safeTransferFrom(recipient, pool, inverseTokenAmount);
        }

        (bool success,) = pool.call(poolCallData);
        if (!success) revert FailToExecute(pool, data);
    }

    function _getInputAndCallData(CommandType command, bytes memory data)
        private
        view
        returns (uint256 reserveTokenAmount, uint256 inverseTokenAmount, bytes memory poolCallData)
    {
        if (command == CommandType.ADD_LIQUIDITY) {
            (address recipient, uint256 reserveIn, uint256[2] memory priceLimits) =
                abi.decode(data, (address, uint256, uint256[2]));
            reserveTokenAmount = reserveIn;
            poolCallData = abi.encodeWithSignature("addLiquidity(address,uint256,uint256[2])", recipient, reserveIn, priceLimits);
        } else if (command == CommandType.REMOVE_LIQUIDITY) {
            (, uint256 inverseTokenIn, uint256[2] memory priceLimits) = abi.decode(data, (address, uint256, uint256[2]));
            inverseTokenAmount = inverseTokenIn;
            poolCallData =
                abi.encodeWithSignature("removeLiquidity(address,uint256,uint256[2])", msg.sender, inverseTokenIn, priceLimits);
        } else if (command == CommandType.BUY_TOKEN) {
            (, uint256 reserveIn, uint256 exactAmountOut, uint256[2] memory priceLimits, uint256[2] memory reserveLimits) =
                abi.decode(data, (address, uint256, uint256, uint256[2], uint256[2]));
            reserveTokenAmount = reserveIn;
            poolCallData = abi.encodeWithSignature(
                "buyTokens(address,uint256,uint256,uint256[2],uint256[2])",
                msg.sender, reserveIn, exactAmountOut, priceLimits, reserveLimits);
        } else if (command == CommandType.SELL_TOKEN) {
            (, uint256 inverseTokenIn, uint256[2] memory priceLimits, uint256[2] memory reserveLimits) =
                abi.decode(data, (address, uint256, uint256[2], uint256[2]));
            inverseTokenAmount = inverseTokenIn;
            poolCallData = abi.encodeWithSignature(
                "sellTokens(address,uint256,uint256[2],uint256[2])", msg.sender, inverseTokenIn, priceLimits, reserveLimits
            );
        } else if (command == CommandType.CLAIM_REWARD) {
            poolCallData = abi.encodeWithSignature("claimReward(address)", msg.sender);
        } else if (command == CommandType.STAKE) {
            (, uint256 amount) = abi.decode(data, (address, uint256));
            inverseTokenAmount = amount;
            poolCallData = abi.encodeWithSignature("stake(address,uint256)", msg.sender, amount);
        } else if (command == CommandType.UNSTAKE) {
            (, uint256 amount) = abi.decode(data, (address, uint256));
            poolCallData = abi.encodeWithSignature("unstake(address,uint256)", msg.sender, amount);
        } else {
            revert CommandUnsupport();
        }
    }

    receive() external payable {}
}
