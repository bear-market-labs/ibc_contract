// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.18;

enum RewardType {
    LP, // 0
    STAKING, // 1
    PROTOCOL // 2
}

enum ActionType {
    BUY_TOKEN,
    SELL_TOKEN,
    ADD_LIQUIDITY,
    REMOVE_LIQUIDITY
}

enum FeeType {
    INVERSE_TOKEN,
    RESERVE
}
