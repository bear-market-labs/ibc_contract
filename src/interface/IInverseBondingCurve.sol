// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.13;

interface IInverseBondingCurve {
    function addLiquidity(address recipient, uint256 minPriceLimit) external payable;

    function removeLiquidity(address recipient, uint256 amount, uint256 maxPriceLimit) external;

    function buyTokens(address recipient, uint256 maxPriceLimit) external payable;

    function sellTokens(address recipient, uint256 amount, uint256 minPriceLimit) external;

    function claimReward(address recipient) external;

    function getPrice(uint256 supply) external view returns(uint256); 

    function getInverseTokenAddress() external view returns(address);

    function getCurveParameters() external view returns(int256 parameterK, uint256 parameterM);

    function getReward(address recipient) external view returns(uint256);
}