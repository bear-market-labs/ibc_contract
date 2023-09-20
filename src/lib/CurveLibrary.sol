// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.18;

import "./balancer/FixedPoint.sol";
import "../FeeState.sol";
import "../Constants.sol";
import "../Enums.sol";

library CurveLibrary {
    using FixedPoint for uint256;

    function updateLpReward(address user, uint256 userLpBalance, FeeState storage state) public {
        if (userLpBalance > 0) {
            uint256 reward = state.globalFeeIndexes[uint256(RewardType.LP)].sub(state.feeIndexStates[uint256(RewardType.LP)][user]).mulDown(userLpBalance);
            state.pendingRewards[uint256(RewardType.LP)][user] += reward;
            state.feeIndexStates[uint256(RewardType.LP)][user] = state.globalFeeIndexes[uint256(RewardType.LP)];
        } else {
            state.feeIndexStates[uint256(RewardType.LP)][user] = state.globalFeeIndexes[uint256(RewardType.LP)];
        }
    }

    function updateStakingReward(address user, uint256 userStakingBalance,FeeState storage state) public{
        if (userStakingBalance > 0) {
            uint256 reward =
                state.globalFeeIndexes[uint256(RewardType.STAKING)].sub(state.feeIndexStates[uint256(RewardType.STAKING)][user]).mulDown(userStakingBalance);
            state.pendingRewards[uint256(RewardType.STAKING)][user] += reward;
            state.feeIndexStates[uint256(RewardType.STAKING)][user] = state.globalFeeIndexes[uint256(RewardType.STAKING)];
        } else {
            state.pendingRewards[uint256(RewardType.STAKING)][user] = 0;
            state.feeIndexStates[uint256(RewardType.STAKING)][user] = state.globalFeeIndexes[uint256(RewardType.STAKING)];
        }
    }

    function calculatePendingReward(address recipient, FeeState storage state, uint256 userBalance, RewardType rewardType)
        public
        view
        returns (uint256)
    {
        uint256 reward = 0;
        if (rewardType == RewardType.LP) {
            reward += state.pendingRewards[uint256(RewardType.LP)][recipient];
            if (userBalance > 0) {
                reward += state.globalFeeIndexes[uint256(RewardType.LP)].sub(state.feeIndexStates[uint256(RewardType.LP)][recipient]).mulDown(userBalance);
            }
        } else if (rewardType == RewardType.STAKING) {
            reward += state.pendingRewards[uint256(RewardType.STAKING)][recipient];
            if (userBalance > 0) {
                reward += state.globalFeeIndexes[uint256(RewardType.STAKING)].sub(state.feeIndexStates[uint256(RewardType.STAKING)][recipient]).mulDown(
                    userBalance
                );
            }
        }
        return reward;
    }

    function isInvariantChanged(uint256 parameterInvariant, uint256 newInvariant) internal pure returns (bool) {
        uint256 diff =
            newInvariant > parameterInvariant ? newInvariant - parameterInvariant : parameterInvariant - newInvariant;

        return(diff.divDown(parameterInvariant) > ALLOWED_INVARIANT_CHANGE_PERCENT);
        // return (diff > ALLOWED_INVARIANT_CHANGE);
    }
}