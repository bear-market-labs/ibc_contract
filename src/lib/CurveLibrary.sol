// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.18;

import "./balancer/FixedPoint.sol";
import "./balancer/LogExpMath.sol";
import "../FeeState.sol";
import "../Constants.sol";
import "../Enums.sol";

library CurveLibrary {
    using FixedPoint for uint256;

    function _updateReward(address user, uint256 userBalance, FeeState storage state, RewardType rewardType) private {
        if (userBalance > 0) {
            uint256 reward = state.globalFeeIndexes[uint256(rewardType)].sub(
                state.feeIndexStates[uint256(rewardType)][user]
            ).mulDown(userBalance);
            state.pendingRewards[uint256(rewardType)][user] += reward;
            state.feeIndexStates[uint256(rewardType)][user] = state.globalFeeIndexes[uint256(rewardType)];
        } else {
            state.feeIndexStates[uint256(rewardType)][user] = state.globalFeeIndexes[uint256(rewardType)];
        }
    }

    function updateReward(
        address user,
        uint256 userBalance,
        FeeState[MAX_FEE_TYPE_COUNT] storage feeState,
        RewardType rewardType
    ) public {
        _updateReward(user, userBalance, feeState[uint256(FeeType.RESERVE)], rewardType);
        _updateReward(user, userBalance, feeState[uint256(FeeType.INVERSE_TOKEN)], rewardType);
    }

    function _calculatePendingReward(
        address recipient,
        FeeState storage state,
        uint256 userBalance,
        RewardType rewardType
    ) private view returns (uint256) {
        uint256 reward = state.pendingRewards[uint256(rewardType)][recipient];
        if (userBalance > 0) {
            reward += state.globalFeeIndexes[uint256(rewardType)].sub(
                state.feeIndexStates[uint256(rewardType)][recipient]
            ).mulDown(userBalance);
        }
        return reward;
    }

    function calculatePendingReward(
        address recipient,
        FeeState[MAX_FEE_TYPE_COUNT] storage feeState,
        uint256 userLpBalance,
        uint256 userStakingBalance
    )
        public
        view
        returns (
            uint256 inverseTokenForLp,
            uint256 inverseTokenForStaking,
            uint256 reserveForLp,
            uint256 reserveForStaking
        )
    {
        inverseTokenForLp =
            _calculatePendingReward(recipient, feeState[uint256(FeeType.INVERSE_TOKEN)], userLpBalance, RewardType.LP);
        inverseTokenForStaking = _calculatePendingReward(
            recipient, feeState[uint256(FeeType.INVERSE_TOKEN)], userStakingBalance, RewardType.STAKING
        );
        reserveForLp =
            _calculatePendingReward(recipient, feeState[uint256(FeeType.RESERVE)], userLpBalance, RewardType.LP);
        reserveForStaking = _calculatePendingReward(
            recipient, feeState[uint256(FeeType.RESERVE)], userStakingBalance, RewardType.STAKING
        );
    }

    function isInvariantChanged(uint256 parameterInvariant, uint256 newInvariant) public pure returns (bool) {
        uint256 diff =
            newInvariant > parameterInvariant ? newInvariant - parameterInvariant : parameterInvariant - newInvariant;

        return (diff.divDown(parameterInvariant) > ALLOWED_INVARIANT_CHANGE_PERCENT);
        // return (diff > ALLOWED_INVARIANT_CHANGE);
    }

    function initializeRewardEMA(FeeState[MAX_FEE_TYPE_COUNT] storage feeState) public {
        feeState[uint256(FeeType.INVERSE_TOKEN)].emaRewardUpdateBlockNumber = block.number;
        feeState[uint256(FeeType.RESERVE)].emaRewardUpdateBlockNumber = block.number;
    }

    function updateRewardEMA(FeeState storage feeState) public {
        if (block.number != feeState.emaRewardUpdateBlockNumber) {
            uint256 alpha = _calculateParameterAlpha(feeState);
            uint256 lpRewardEMA = _calculateEMA(feeState, RewardType.LP, alpha);
            uint256 stakingRewardEMA = _calculateEMA(feeState, RewardType.STAKING, alpha);

            feeState.previousReward[uint256(RewardType.LP)] = feeState.totalReward[uint256(RewardType.LP)];
            feeState.previousReward[uint256(RewardType.STAKING)] = feeState.totalReward[uint256(RewardType.STAKING)];
            feeState.emaReward[uint256(RewardType.LP)] = lpRewardEMA;
            feeState.emaReward[uint256(RewardType.STAKING)] = stakingRewardEMA;
            feeState.emaRewardUpdateBlockNumber = block.number;
        }
    }

    function _calculateParameterAlpha(FeeState storage feeState) private view returns (uint256 alpha) {
        int256 exponent = int256((block.number - feeState.emaRewardUpdateBlockNumber).divDown(DAILY_BLOCK_COUNT));
        alpha = exponent >= LogExpMath.MAX_NATURAL_EXPONENT ? 0 : ONE_UINT.sub(uint256(LogExpMath.exp(-exponent)));
    }

    function _calculateEMA(FeeState storage feeState, RewardType rewardType, uint256 alpha)
        private
        view
        returns (uint256 rewardEMA)
    {
        if (block.number == feeState.emaRewardUpdateBlockNumber) {
            return feeState.emaReward[uint256(rewardType)];
        }
        uint256 pastBlockCount = block.number - feeState.emaRewardUpdateBlockNumber;
        uint256 previousEMA = feeState.emaReward[uint256(rewardType)];
        uint256 rewardSinceLastUpdatePerBlock = feeState.totalReward[uint256(rewardType)].sub(
            feeState.previousReward[uint256(rewardType)]
        ).divDown(pastBlockCount * 1e18);

        if (rewardSinceLastUpdatePerBlock >= previousEMA) {
            rewardEMA = previousEMA.add(alpha.mulDown(rewardSinceLastUpdatePerBlock.sub(previousEMA)));
        } else {
            rewardEMA = previousEMA.sub(alpha.mulDown(previousEMA.sub(rewardSinceLastUpdatePerBlock)));
        }
    }

    function calculateBlockRewardEMA(FeeState[MAX_FEE_TYPE_COUNT] storage feeState, RewardType rewardType)
        public
        view
        returns (uint256 inverseTokenReward, uint256 reserveReward)
    {
        uint256 alpha = _calculateParameterAlpha(feeState[uint256(FeeType.INVERSE_TOKEN)]);
        inverseTokenReward = _calculateEMA(feeState[uint256(FeeType.INVERSE_TOKEN)], rewardType, alpha);

        alpha = _calculateParameterAlpha(feeState[uint256(FeeType.RESERVE)]);
        reserveReward = _calculateEMA(feeState[uint256(FeeType.RESERVE)], rewardType, alpha);
    }
}
