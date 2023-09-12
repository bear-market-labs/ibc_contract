// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.18;

uint256 constant MIN_LIQUIDITY = 1e15; //0.001
uint256 constant MIN_SUPPLY = 1e15; //0.001
uint256 constant ONE_UINT = 1e18;
uint256 constant FEE_PERCENT = 1e15;
uint256 constant MAX_FEE_PERCENT = 1e17;
uint256 constant ALLOWED_INVARIANT_CHANGE = 1e10;

uint8 constant MAX_ACTION_COUNT = 4;
uint8 constant MAX_FEE_TYPE_COUNT = 2;
