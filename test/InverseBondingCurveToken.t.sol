// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/InverseBondingCurveToken.sol";

contract CounterTest is Test {
    InverseBondingCurveToken public token;

    function setUp() public {
        token = new InverseBondingCurveToken();

    }
}
