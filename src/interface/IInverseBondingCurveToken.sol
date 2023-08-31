// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.13;

interface IInverseBondingCurveToken {
    function addLiquidity() external payable;

    function removeLiquidity(uint256 lpTokenAmount) external;

    function buyToken() external payable;

    function sellToken(uint256 amount) external;
}