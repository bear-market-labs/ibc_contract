// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.18;

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

    function stakingBalanceOf(address holder) external view returns (uint256);

    function priceOf(uint256 supply) external view returns (uint256);

    function inverseTokenAddress() external view returns (address);

    function curveParameters() external view returns (CurveParameter memory parameters);

    function feeConfig() external view returns (uint256 lpFee, uint256 stakingFee, uint256 protocolFee);

    function rewardOf(address recipient, RewardType rewardType) external view returns (uint256);
}
