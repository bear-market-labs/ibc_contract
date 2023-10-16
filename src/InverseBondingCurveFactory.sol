// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.18;

import "openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";

import "./InverseBondingCurveProxy.sol";
import "./InverseBondingCurveToken.sol";
import "./interface/IWETH9.sol";
import "./Errors.sol";

contract InverseBondingCurveFactory {
    event Deployed(address cruveContract, address tokenContract, address proxyContract);

    IInverseBondingCurveAdmin private _admin;

    mapping(address => address) private _poolMap;
    address[] public pools;

    constructor(address adminContract) {
        _admin = IInverseBondingCurveAdmin(adminContract);
    }

    function createPool(uint256 reserve, address reserveTokenAddress) external payable {
        string memory tokenSymbol = "";
        uint256 leftReserve = msg.value;
        address reserveFromAccount = msg.sender;
        if (reserveTokenAddress == address(0) && msg.value > 0) {
            if (msg.value < reserve) {
                revert InsufficientBalance();
            }
            // Ignore reserve parameter passed in, use all msg.value as reserve
            reserve = msg.value;
            leftReserve = 0;

            // convert eth to weth
            reserveTokenAddress = _admin.weth();
            IWETH9(reserveTokenAddress).deposit{value: msg.value}();
            IWETH9(reserveTokenAddress).approve(address(this), reserve);
            tokenSymbol = "ibETH";
            reserveFromAccount = address(this);
        } else {
            tokenSymbol = string(abi.encodePacked("ib", IERC20Metadata(reserveTokenAddress).symbol()));
        }

        if (_poolMap[reserveTokenAddress] != address(0)) {
            revert PoolAlreadyExist();
        }

        _createPool(reserve, tokenSymbol, reserveFromAccount, reserveTokenAddress);

        if (leftReserve > 0) {
            (bool sent,) = msg.sender.call{value: leftReserve}("");
            if (!sent) {
                revert FailToSend(msg.sender);
            }
        }
    }

    function _createPool(
        uint256 reserve,
        string memory inverseTokenSymbol,
        address reserveFromAccount,
        address reserveTokenAddress
    ) private {
        address _cruveContract = _admin.curveImplementation();

        InverseBondingCurveToken tokenContract =
            new InverseBondingCurveToken(address(this), inverseTokenSymbol, inverseTokenSymbol);

        address proxyContract = address(new InverseBondingCurveProxy(address(_admin), _cruveContract, ""));
        IERC20Metadata(reserveTokenAddress).transferFrom(reserveFromAccount, address(proxyContract), reserve);

        bytes memory data = abi.encodeWithSignature(
            "initialize(address,address,address,address,uint256)",
            _admin,
            _admin.router(),
            tokenContract,
            reserveTokenAddress,
            reserve
        );

        (bool success,) = proxyContract.call(data);
        require(success, "Curve contract initialize failed");

        // Change owner to external owner
        (success,) = address(tokenContract).call(abi.encodeWithSignature("transferOwnership(address)", proxyContract));
        require(success, "Token contract owner transfer failed");

        (success,) = proxyContract.call(abi.encodeWithSignature("transferOwnership(address)", _admin.owner()));
        require(success, "Token contract owner transfer failed");

        _poolMap[reserveTokenAddress] = proxyContract;
        pools.push(proxyContract);

        emit Deployed(_cruveContract, address(tokenContract), proxyContract);
    }

    function getPool(address reserveToken) public view returns (address) {
        if (reserveToken == address(0)) {
            // create ETH pool
            reserveToken = _admin.weth();
        }

        return _poolMap[reserveToken];
    }

    function poolLength() public view returns (uint256) {
        return pools.length;
    }
}
