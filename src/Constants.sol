// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.18;

uint256 constant MIN_INPUT_AMOUNT = 1e14; // 0.0001
uint256 constant ONE_UINT = 1e18;
uint256 constant LP_FEE_PERCENT = 25e14;
uint256 constant STAKE_FEE_PERCENT = 25e14;
uint256 constant PROTOCOL_FEE_PERCENT = 5e15;
uint256 constant MAX_FEE_PERCENT = 1e17;
uint256 constant ALLOWED_INVARIANT_CHANGE = 1e10;
uint256 constant ALLOWED_INVARIANT_CHANGE_PERCENT = 1e12; //0.000001

uint8 constant MAX_ACTION_COUNT = 4;
uint8 constant MAX_FEE_TYPE_COUNT = 2;
uint8 constant MAX_FEE_STATE_COUNT = 2;
