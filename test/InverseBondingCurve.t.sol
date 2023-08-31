// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/InverseBondingCurve.sol";

contract CounterTest is Test {
    InverseBondingCurve public curveContract;

    function setUp() public {
        curveContract = new InverseBondingCurve();
    }
}
