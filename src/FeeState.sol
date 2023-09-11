// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.18;

struct FeeState {
    uint256 protocolFee;
    uint256 globalLpFeeIndex;
    uint256 globalStakingFeeIndex;
    mapping(address => uint256) userLpFeeIndexState;
    mapping(address => uint256) userLpPendingReward;
    mapping(address => uint256) userStakingFeeIndexState;
    mapping(address => uint256) userStakingPendingReward;
}
