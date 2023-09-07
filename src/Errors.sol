// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.18;

string constant ERR_POOL_NOT_INITIALIZED = "Can only be called after pool is initialized";

string constant ERR_LIQUIDITY_TOO_SMALL = "Liquidity too small";

string constant ERR_PARAM_ZERO = "Parameter can't be zero";

string constant ERR_PARAM_UPDATE_FAIL = "Parameter update fail because of invalid curve";

string constant ERR_INSUFFICIENT_BALANCE = "Insufficient balance";

string constant ERR_EMPTY_ADDRESS = "Empty address";

string constant ERR_PRICE_OUT_OF_LIMIT = "Price out of limit";

string constant ERR_FEE_PERCENT_OUT_OF_RANGE = "Fee percent should be within[0.0001, 0.5] -> [1e14, 5e17]";

string constant ERR_INVARIANT_CHANGED = "Curve invarint changed out of range";
