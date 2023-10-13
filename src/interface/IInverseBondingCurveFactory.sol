// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.18;

interface IInverseBondingCurveFactory {
    function protocolFeeOwner() external returns (address);
}
