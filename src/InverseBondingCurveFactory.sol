// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.18;

import "openzeppelin/access/Ownable.sol";
import "openzeppelin/utils/Create2.sol";

import "openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";

import "./InverseBondingCurve.sol";

contract InverseBondingCurveFactory is Ownable {
    event Deployed(address cruveContract, address tokenContract, address proxyContract);

    bytes private _curveContractCode;    
    bytes private _tokenContractCode;
    bytes private _proxyContractCode;

    mapping(address => address) private _poolMap;
    address[] public pools;

    constructor(bytes memory curveContractCode,
        bytes memory tokenContractCode,
        bytes memory proxyContractCode) Ownable() {
            _curveContractCode = curveContractCode;
            _tokenContractCode = tokenContractCode;
            _proxyContractCode = proxyContractCode;
        }

    function createPool(
        uint256 reserve,
        uint256 supply,
        uint256 price,
        address reserveTokenAddress,
        address protocolFeeOwner
    ) external payable {
        if(reserveTokenAddress == address(0) && msg.value > 0){
            // create ETH pool

        }else{

        }
        bytes32 salt = bytes32(uint256(uint160(msg.sender)) + block.number);

        address _cruveContract = Create2.deploy(0, salt, abi.encodePacked(_curveContractCode));

        IERC20Metadata reserveToken = IERC20Metadata(reserveTokenAddress);

        string memory tokenSymbol = string(
            abi.encodePacked(
                "ib",       
                IERC20Metadata(reserveTokenAddress).symbol()
            )
        );
        bytes memory creationCode = abi.encodePacked(_tokenContractCode, abi.encode(address(this), tokenSymbol, tokenSymbol));
        address _tokenContract = Create2.deploy(0, salt, creationCode);

        // Create proxy contract and intialize

        
        creationCode = abi.encodePacked(_proxyContractCode, abi.encode(_cruveContract, ""));
        address _proxyContract = Create2.deploy(0, salt, creationCode);


        IERC20Metadata(reserveTokenAddress).transferFrom(msg.sender, _proxyContract, reserve);

        bytes memory data = abi.encodeWithSignature(
            "initialize(uint256,uint256,uint256,address,address,address)", reserve,supply, price, _tokenContract, reserveTokenAddress, protocolFeeOwner
        );
        (bool success,) = _proxyContract.call(data);
        require(success, "Curve contract initialize failed");

        // Change owner to external owner
        (success,) = _tokenContract.call(abi.encodeWithSignature("transferOwnership(address)", _proxyContract));
        require(success, "Token contract owner transfer failed");

        (success,) = _proxyContract.call(abi.encodeWithSignature("transferOwnership(address)", owner()));
        require(success, "Token contract owner transfer failed");

        emit Deployed(_cruveContract, _tokenContract, _proxyContract);
    }
}
