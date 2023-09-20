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
            uint256 reward = state.globalLpFeeIndex.sub(state.userLpFeeIndexState[user]).mulDown(userLpBalance);
            state.userLpPendingReward[user] += reward;
            state.userLpFeeIndexState[user] = state.globalLpFeeIndex;
        } else {
            state.userLpFeeIndexState[user] = state.globalLpFeeIndex;
        }
    }

    function updateStakingReward(address user, uint256 userStakingBalance,FeeState storage state) public{
        if (userStakingBalance > 0) {
            uint256 reward =
                state.globalStakingFeeIndex.sub(state.userStakingFeeIndexState[user]).mulDown(userStakingBalance);
            state.userStakingPendingReward[user] += reward;
            state.userStakingFeeIndexState[user] = state.globalStakingFeeIndex;
        } else {
            state.userStakingPendingReward[user] = 0;
            state.userStakingFeeIndexState[user] = state.globalStakingFeeIndex;
        }
    }

    function calculatePendingReward(address recipient, FeeState storage state, uint256 userBalance, RewardType rewardType)
        public
        view
        returns (uint256)
    {
        uint256 reward = 0;
        if (rewardType == RewardType.LP) {
            reward += state.userLpPendingReward[recipient];
            if (userBalance > 0) {
                reward += state.globalLpFeeIndex.sub(state.userLpFeeIndexState[recipient]).mulDown(userBalance);
            }
        } else if (rewardType == RewardType.STAKING) {
            reward += state.userStakingPendingReward[recipient];
            if (userBalance > 0) {
                reward += state.globalStakingFeeIndex.sub(state.userStakingFeeIndexState[recipient]).mulDown(
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