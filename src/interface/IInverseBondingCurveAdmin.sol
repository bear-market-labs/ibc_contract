// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.18;

import "../Enums.sol";

interface IInverseBondingCurveAdmin {
    /**
     * @dev Returns true if the contract is paused, and false otherwise.
     */
    function paused() external view returns (bool);

    function weth() external view returns (address);

    function feeOwner() external view returns (address);

    function curveImplementation() external view returns (address);

    function owner() external view returns(address);
    function router() external view returns (address);

    /**
     * @notice  Query fee configuration
     * @dev     Each fee config array contains configuration for four actions(Buy/Sell/Add liquidity/Remove liquidity)
     * @return  lpFee : The percent of fee reward to LP
     * @return  stakingFee : The percent of fee reward to staker
     * @return  protocolFee : The percent of fee reward to protocol
     */
    function feeConfig(ActionType actionType)
        external
        view
        returns (uint256 lpFee, uint256 stakingFee, uint256 protocolFee);
}
