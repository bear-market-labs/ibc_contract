// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.18;

import "./lib/balancer/FixedPoint.sol";
import "./lib/balancer/LogExpMath.sol";
import "./FeeState.sol";
import "./Constants.sol";
import "./Enums.sol";

/**
 * @author  .
 * @title   .
 * @dev     .
 * @notice  .
 */
library CurveLibrary {
    using FixedPoint for uint256;

    /**
     * @notice  Update fee reward of account
     * @dev
     * @param   account : Account address
     * @param   userBalance : Current account balance
     * @param   feeState : Fee state storage
     * @param   rewardType : Reward for LP or staking
     */
    function updateReward(
        address account,
        uint256 userBalance,
        FeeState[MAX_FEE_TYPE_COUNT] storage feeState,
        RewardType rewardType
    ) public {
        _updateReward(account, userBalance, feeState[uint256(FeeType.RESERVE)], rewardType);
        _updateReward(account, userBalance, feeState[uint256(FeeType.IBC_FROM_TRADE)], rewardType);
        _updateReward(account, userBalance, feeState[uint256(FeeType.IBC_FROM_LP)], rewardType);
    }

    /**
     * @notice  Calculate pending reward
     * @dev
     * @param   recipient : Account address
     * @param   feeState : Fee state storage
     * @param   lpBalance : LP token balance
     * @param   stakingBalance : Staking balance
     * @return  inverseTokenForLp : IBC token reward for account as LP
     * @return  inverseTokenForStaking : IBC token reward for account as Staker
     * @return  reserveForLp : Reserve reward for account as LP
     * @return  reserveForStaking : Reserve reward for account as Staker
     */
    function calcPendingReward(
        address recipient,
        FeeState[MAX_FEE_TYPE_COUNT] storage feeState,
        uint256 lpBalance,
        uint256 stakingBalance
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
            _calcPendingReward(recipient, feeState[uint256(FeeType.IBC_FROM_TRADE)], lpBalance, RewardType.LP) +
            _calcPendingReward(recipient, feeState[uint256(FeeType.IBC_FROM_LP)], lpBalance, RewardType.LP);
        inverseTokenForStaking =
            _calcPendingReward(recipient, feeState[uint256(FeeType.IBC_FROM_TRADE)], stakingBalance, RewardType.STAKING) +
            _calcPendingReward(recipient, feeState[uint256(FeeType.IBC_FROM_LP)], stakingBalance, RewardType.STAKING);
        reserveForLp = _calcPendingReward(recipient, feeState[uint256(FeeType.RESERVE)], lpBalance, RewardType.LP);
        reserveForStaking =
            _calcPendingReward(recipient, feeState[uint256(FeeType.RESERVE)], stakingBalance, RewardType.STAKING);
    }

    /**
     * @notice  Check whether value change
     * @dev     Based on change percent
     * @param   value : Current value
     * @param   newValue : New value
     * @param   allowedChangePercent : Allowed change percent
     * @return  bool : Is value changed
     */
    function isValueChanged(uint256 value, uint256 newValue, uint256 allowedChangePercent) public pure returns (bool) {
        uint256 diff = newValue > value ? newValue - value : value - newValue;

        return (diff.divDown(value) > allowedChangePercent);
    }

    /**
     * @notice  Initialize reward EMA calculation
     * @dev
     * @param   feeState : Fee state storage
     */
    function initializeRewardEMA(FeeState[MAX_FEE_TYPE_COUNT] storage feeState) public {
        feeState[uint256(FeeType.IBC_FROM_TRADE)].emaRewardUpdateBlockNumber = block.number;
        feeState[uint256(FeeType.RESERVE)].emaRewardUpdateBlockNumber = block.number;
    }

    /**
     * @notice  Update reward EMA
     * @dev     Only get updated for next fee event
     * @param   feeState : Fee state storage
     */
    function updateRewardEMA(FeeState storage feeState) public {
        if (block.number != feeState.emaRewardUpdateBlockNumber) {
            uint256 alpha = _calcParameterAlpha(feeState);
            uint256 lpRewardEMA = _calcEMA(feeState, RewardType.LP, alpha);
            uint256 stakingRewardEMA = _calcEMA(feeState, RewardType.STAKING, alpha);

            feeState.previousReward[uint256(RewardType.LP)] = feeState.totalReward[uint256(RewardType.LP)];
            feeState.previousReward[uint256(RewardType.STAKING)] = feeState.totalReward[uint256(RewardType.STAKING)];
            feeState.emaReward[uint256(RewardType.LP)] = lpRewardEMA;
            feeState.emaReward[uint256(RewardType.STAKING)] = stakingRewardEMA;
            feeState.emaRewardUpdateBlockNumber = block.number;
        }
    }

    /**
     * @notice  Calculate reward EMA
     * @dev
     * @param   feeState : Fee state storage
     * @param   rewardType : LP or Staking
     * @return  inverseTokenReward : EMA IBC token reward per block
     * @return  reserveReward : EMA reserve reward per block
     */
    function calcBlockRewardEMA(FeeState[MAX_FEE_TYPE_COUNT] storage feeState, RewardType rewardType)
        public
        view
        returns (uint256 inverseTokenReward, uint256 reserveReward)
    {
        uint256 alpha = _calcParameterAlpha(feeState[uint256(FeeType.IBC_FROM_TRADE)]);
        inverseTokenReward = _calcEMA(feeState[uint256(FeeType.IBC_FROM_TRADE)], rewardType, alpha);

        alpha = _calcParameterAlpha(feeState[uint256(FeeType.RESERVE)]);
        reserveReward = _calcEMA(feeState[uint256(FeeType.RESERVE)], rewardType, alpha);

        // Parameter alpha is same with reserve reward 
        inverseTokenReward += _calcEMA(feeState[uint256(FeeType.IBC_FROM_LP)], rewardType, alpha);
    }

    /**
     * @notice  Update reward state
     * @dev
     * @param   account : Account address
     * @param   userBalance : Account balance of LP/Staking
     * @param   state : Fee state storage
     * @param   rewardType : LP or Staking
     */
    function _updateReward(address account, uint256 userBalance, FeeState storage state, RewardType rewardType)
        private
    {
        if (userBalance > 0) {
            uint256 reward = (
                state.globalFeeIndexes[uint256(rewardType)] - state.feeIndexStates[uint256(rewardType)][account]
            ).mulDown(userBalance);
            state.pendingRewards[uint256(rewardType)][account] += reward;
            state.feeIndexStates[uint256(rewardType)][account] = state.globalFeeIndexes[uint256(rewardType)];
        } else {
            state.feeIndexStates[uint256(rewardType)][account] = state.globalFeeIndexes[uint256(rewardType)];
        }
    }

    /**
     * @notice  Calculate pending reward
     * @dev
     * @param   account : Account address
     * @param   state : Fee state storage
     * @param   userBalance : LP/Staking balance
     * @param   rewardType : LP or Staking
     * @return  uint256 : Pending reward
     */
    function _calcPendingReward(address account, FeeState storage state, uint256 userBalance, RewardType rewardType)
        private
        view
        returns (uint256)
    {
        uint256 reward = state.pendingRewards[uint256(rewardType)][account];
        if (userBalance > 0) {
            reward += (state.globalFeeIndexes[uint256(rewardType)] - state.feeIndexStates[uint256(rewardType)][account])
                .mulDown(userBalance);
        }
        return reward;
    }

    /**
     * @notice  Calculate alpha parameter for EMA calculation
     * @dev
     * @param   feeState : Fee state storage
     * @return  alpha : Parameter alpha
     */
    function _calcParameterAlpha(FeeState storage feeState) private view returns (uint256 alpha) {
        int256 exponent = int256((block.number - feeState.emaRewardUpdateBlockNumber).divDown(DAILY_BLOCK_COUNT));
        alpha = exponent >= LogExpMath.MAX_NATURAL_EXPONENT ? 0 : ONE_UINT - uint256(LogExpMath.exp(-exponent));
    }

    /**
     * @notice  Calculate reward EMA
     * @dev
     * @param   feeState : Fee state storage
     * @param   rewardType : LP or Staking
     * @param   alpha : Parameter alpha
     * @return  rewardEMA : Reward EMA
     */
    function _calcEMA(FeeState storage feeState, RewardType rewardType, uint256 alpha)
        private
        view
        returns (uint256 rewardEMA)
    {
        if (block.number > feeState.emaRewardUpdateBlockNumber) {
            uint256 pastBlockCount = block.number - feeState.emaRewardUpdateBlockNumber;
            uint256 previousEMA = feeState.emaReward[uint256(rewardType)];
            uint256 rewardSinceLastUpdatePerBlock = (
                feeState.totalReward[uint256(rewardType)] - feeState.previousReward[uint256(rewardType)]
            ).divDown(pastBlockCount * 1e18);

            if (rewardSinceLastUpdatePerBlock >= previousEMA) {
                rewardEMA = previousEMA + (alpha.mulDown(rewardSinceLastUpdatePerBlock - previousEMA));
            } else {
                rewardEMA = previousEMA - (alpha.mulDown(previousEMA - rewardSinceLastUpdatePerBlock));
            }
        } else {
            rewardEMA = feeState.emaReward[uint256(rewardType)];
        }
    }
}
