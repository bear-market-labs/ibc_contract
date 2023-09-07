// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.18;

struct CurveParameter {
    uint256 reserve;
    uint256 supply;
    uint256 price;
    int256 parameterK;
    uint256 parameterM;
}
