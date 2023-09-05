// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.13;

import "../CurveParameter.sol";
import "../Enums.sol";

interface IInverseBondingCurve {
    function addLiquidity(address recipient, uint256 minPriceLimit) external payable;

    function removeLiquidity(address recipient, uint256 amount, uint256 maxPriceLimit) external;

    function buyTokens(address recipient, uint256 maxPriceLimit) external payable;

    function sellTokens(address recipient, uint256 amount, uint256 minPriceLimit) external;

    function stake(uint256 amount) external;

    function unstake(uint256 amount) external;

    function claimReward(address recipient, RewardType rewardType) external;

    function getStakingBalance(address holder) external view returns (uint256);

    function getPrice(uint256 supply) external view returns (uint256);

    function getInverseTokenAddress() external view returns (address);

    function getCurveParameters() external view returns (CurveParameter memory parameters);

    function getReward(address recipient, RewardType rewardType) external view returns (uint256);
}
