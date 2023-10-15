// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.18;

import "openzeppelin/access/Ownable.sol";
import "openzeppelin/security/Pausable.sol";

import "./Constants.sol";
import "./Enums.sol";

import "./InverseBondingCurveFactory.sol";

contract InverseBondingCurveAdmin is Ownable, Pausable {
    address private _weth;

    address private _router;
    address private _factory;
    address private _curveImplementation;
    address private _protocolFeeOwner;

    uint256[MAX_ACTION_COUNT] private _lpFeePercent = [LP_FEE_PERCENT, LP_FEE_PERCENT, LP_FEE_PERCENT, LP_FEE_PERCENT];
    uint256[MAX_ACTION_COUNT] private _stakingFeePercent =
        [STAKE_FEE_PERCENT, STAKE_FEE_PERCENT, STAKE_FEE_PERCENT, STAKE_FEE_PERCENT];
    uint256[MAX_ACTION_COUNT] private _protocolFeePercent =
        [PROTOCOL_FEE_PERCENT, PROTOCOL_FEE_PERCENT, PROTOCOL_FEE_PERCENT, PROTOCOL_FEE_PERCENT];

    /**
     * @notice  Emitted when protocol fee owner changed
     * @dev
     * @param   feeOwner : New fee owner of protocol fee
     */
    event FeeOwnerChanged(address feeOwner);

    /**
     * @notice  Emmitted when fee configuration changed
     * @dev
     * @param   actionType : The action type of the changed fee configuration. (Buy/Sell/Add liquidity/Remove liquidity)
     * @param   lpFee : Fee reward percent for LP
     * @param   stakingFee : Fee reward percent for Staker
     * @param   protocolFee : Fee reward percent for Protocol
     */
    event FeeConfigChanged(ActionType actionType, uint256 lpFee, uint256 stakingFee, uint256 protocolFee);

    constructor(
        address wethAddress,
        address routerAddress,
        address protocolFeeOwner,
        bytes memory curveContractCode
    ) Ownable() {
        _weth = wethAddress;
        _router = routerAddress;
        _protocolFeeOwner = protocolFeeOwner;

        bytes32 salt = bytes32(uint256(uint160(msg.sender)) + block.number);

        _curveImplementation = Create2.deploy(0, salt, abi.encodePacked(curveContractCode));

        // _intialFeeConfig();
        _createFactory();
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

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
        returns (uint256 lpFee, uint256 stakingFee, uint256 protocolFee)
    {
        lpFee = _lpFeePercent[uint256(actionType)];
        stakingFee = _stakingFeePercent[uint256(actionType)];
        protocolFee = _protocolFeePercent[uint256(actionType)];
    }

    //     /**
    //  * @notice  Initialize default fee percent
    //  * @dev
    //  */
    // function _intialFeeConfig() private {
    //     for (uint8 i = 0; i < MAX_ACTION_COUNT; i++) {
    //         _lpFeePercent[i] = LP_FEE_PERCENT;
    //         _stakingFeePercent[i] = STAKE_FEE_PERCENT;
    //         _protocolFeePercent[i] = PROTOCOL_FEE_PERCENT;
    //     }
    // }

    /**
     * @notice  Update fee config
     * @dev
     * @param   actionType : Fee configuration for : Buy/Sell/Add liquidity/Remove liquidity)
     * @param   lpFee : The percent of fee reward to LP
     * @param   stakingFee : The percent of fee reward to staker
     * @param   protocolFee : The percent of fee reward to protocol
     */
    function updateFeeConfig(ActionType actionType, uint256 lpFee, uint256 stakingFee, uint256 protocolFee)
        external
        onlyOwner
    {
        if ((lpFee + stakingFee + protocolFee) >= MAX_FEE_PERCENT) revert FeePercentOutOfRange();
        if (uint256(actionType) >= MAX_ACTION_COUNT) revert InvalidInput();

        _lpFeePercent[uint256(actionType)] = lpFee;
        _stakingFeePercent[uint256(actionType)] = stakingFee;
        _protocolFeePercent[uint256(actionType)] = protocolFee;

        emit FeeConfigChanged(actionType, lpFee, stakingFee, protocolFee);
    }

    /**
     * @notice  Update protocol fee owner
     * @dev
     * @param   protocolFeeOwner : The new owner of protocol fee
     */
    function updateFeeOwner(address protocolFeeOwner) public onlyOwner {
        if (protocolFeeOwner == address(0)) revert EmptyAddress();

        _protocolFeeOwner = protocolFeeOwner;

        emit FeeOwnerChanged(protocolFeeOwner);
    }

    function updateRouter(address routerAddress) public onlyOwner {
        if (routerAddress == address(0)) revert EmptyAddress();

        _router = routerAddress;
    }

    function upgradeCurveTo(address newImplementation) external onlyOwner {
        _curveImplementation = newImplementation;
    }

    function _createFactory() private {
        _factory = address(new InverseBondingCurveFactory(address(this)));
    }

    function factoryAddress() external view returns (address) {
        return _factory;
    }

    /**
     * @notice  Query protocol fee owner
     * @dev
     * @return  address : protocol fee owner
     */
    function feeOwner() external view returns (address) {
        return _protocolFeeOwner;
    }

    function weth() external view returns (address) {
        return _weth;
    }

    function router() external view returns (address) {
        return _router;
    }

    function curveImplementation() external view returns (address) {
        return _curveImplementation;
    }
}
