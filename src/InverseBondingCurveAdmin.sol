// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.18;

import "openzeppelin/access/Ownable.sol";
import "openzeppelin/security/Pausable.sol";
contract InverseBondingCurveAdmin is Ownable, Pausable{
    constructor() Ownable() {}

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function getFeeConfig() external onlyOwner {

    }

    function updateFeeConfig() external onlyOwner {

    }

    function upgrade() external onlyOwner {

    }
}