// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.18;

import "openzeppelin/token/ERC20/IERC20.sol";

interface IInverseBondingCurveToken is IERC20 {  

    function pause() external;

    function unpause() external;

    function mint(address to, uint256 amount) external;

    function burnFrom(address account, uint256 amount) external;
}
