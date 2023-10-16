// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.18;

import "openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";

import "./InverseBondingCurveProxy.sol";
import "./InverseBondingCurveToken.sol";
import "./interface/IWETH9.sol";
import "./Errors.sol";

contract InverseBondingCurveFactory {
    event CurveCreated(address curveContract, address tokenContract, address proxyContract, uint256 iniitalReserve);

    IInverseBondingCurveAdmin private _admin;

    mapping(address => address) private _curveMap;
    address[] public curves;

    constructor(address adminContract) {
        _admin = IInverseBondingCurveAdmin(adminContract);
    }

    /**
     * @notice  Deploys IBC proxy contract, and the relevant ibAsset token contract for the specified reserve asset.
     * @dev
     * @param   initialReserves : Amount of initial reserves to supply to curve
     * @param   reserveTokenAddress : Contract address of the reserve asset token contract
     */
    function createCurve(uint256 initialReserves, address reserveTokenAddress) external payable {
        string memory tokenSymbol = "";
        uint256 leftReserve = msg.value;
        address reserveFromAccount = msg.sender;
        if (reserveTokenAddress == address(0) && msg.value > 0) {
            if (msg.value < initialReserves) {
                revert InsufficientBalance();
            }
            // Ignore reserve parameter passed in, use all msg.value as reserve
            initialReserves = msg.value;
            leftReserve = 0;

            // convert eth to weth
            reserveTokenAddress = _admin.weth();
            IWETH9(reserveTokenAddress).deposit{value: msg.value}();
            IWETH9(reserveTokenAddress).approve(address(this), initialReserves);
            tokenSymbol = "ibETH";
            reserveFromAccount = address(this);
        } else {
            tokenSymbol = string(abi.encodePacked("ib", IERC20Metadata(reserveTokenAddress).symbol()));
        }

        if (_curveMap[reserveTokenAddress] != address(0)) {
            revert PoolAlreadyExist();
        }

        _createCurve(initialReserves, tokenSymbol, reserveFromAccount, reserveTokenAddress);

        if (leftReserve > 0) {
            (bool sent,) = msg.sender.call{value: leftReserve}("");
            if (!sent) revert FailToSend(msg.sender);
        }
    }

    /**
     * @notice  Deploys IBC proxy contract, and the relevant ibAsset token contract for the specified reserve asset.
     * @dev
     * @param   initialReserves : Amount of initial reserves to supply to curve
     * @param   inverseTokenSymbol : IBC token symbol
     * @param   reserveFromAccount : The account to transfer reserve token from
     * @param   reserveTokenAddress : Contract address of the reserve asset token contract
     */
    function _createCurve(
        uint256 initialReserves,
        string memory inverseTokenSymbol,
        address reserveFromAccount,
        address reserveTokenAddress
    ) private {
        address _cruveContract = _admin.curveImplementation();

        InverseBondingCurveToken tokenContract =
            new InverseBondingCurveToken(address(this), inverseTokenSymbol, inverseTokenSymbol);

        address proxyContract = address(new InverseBondingCurveProxy(address(_admin), _cruveContract, ""));
        _curveMap[reserveTokenAddress] = proxyContract;
        curves.push(proxyContract);
        emit CurveCreated(_cruveContract, address(tokenContract), proxyContract, initialReserves);

        // Initialize Curve contract
        IERC20Metadata(reserveTokenAddress).transferFrom(reserveFromAccount, address(proxyContract), initialReserves);
        bytes memory data = abi.encodeWithSignature( "initialize(address,address,address,address,uint256)",
            _admin, _admin.router(), tokenContract, reserveTokenAddress, initialReserves);

        (bool success,) = proxyContract.call(data);
        require(success, "Curve contract initialize failed");

        // Change owner to external owner
        (success,) = address(tokenContract).call(abi.encodeWithSignature("transferOwnership(address)", proxyContract));
        require(success, "Token contract owner transfer failed");
    }

    /**
     * @notice  Query the IBC implementation of specific reverse token
     * @dev     .
     * @param   reserveToken : Reserve token of curve
     * @return  address : Contract address of the specified reserve asset's IBC implemenation
     */
    function getCurve(address reserveToken) public view returns (address) {
        return _curveMap[reserveToken == address(0)? _admin.weth() : reserveToken];
    }

    /**
     * @notice  Query total curves count
     * @dev
     * @return  uint256 : Total number of IBC curves created by Factory
     */
    function allCurvesLength() public view returns (uint256) {
        return curves.length;
    }
}
