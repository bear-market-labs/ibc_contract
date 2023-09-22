// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.18;

import "./Constants.sol";

struct FeeState {
    // uint256 protocolFee;
    uint256 feeForFirstStaker;
    // uint256 globalLpFeeIndex;
    // uint256 globalStakingFeeIndex;
    // mapping(address => uint256) userLpFeeIndexState;
    // mapping(address => uint256) userLpPendingReward;
    // mapping(address => uint256) userStakingFeeIndexState;
    // mapping(address => uint256) userStakingPendingReward;
    mapping(address => uint256)[MAX_FEE_STATE_FOR_USER_COUNT] feeIndexStates;
    mapping(address => uint256)[MAX_FEE_STATE_FOR_USER_COUNT] pendingRewards;
    uint256[MAX_FEE_STATE_COUNT] globalFeeIndexes;
    uint256[MAX_FEE_STATE_COUNT] totalReward;
    uint256[MAX_FEE_STATE_COUNT] totalPendingReward;
    uint256 emaRewardUpdateBlockNumber;
    uint256[MAX_EMA_STATE_COUNT] emaReward;
    uint256[MAX_EMA_STATE_COUNT] previousReward;
}
