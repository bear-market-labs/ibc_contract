// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "openzeppelin/access/Ownable.sol";
import "openzeppelin/utils/Create2.sol";

contract Deployer is Ownable {
    event Deployed(address cruveContract, address tokenContract, address proxyContract);

    address private _cruveContract;
    address private _proxyContract;
    address private _tokenContract;

    constructor() Ownable() {}

    function deploy(
        bytes memory curveContractCode,
        bytes memory tokenContractCode,
        bytes memory proxyContractCode,
        uint256 supply,
        uint256 price,
        address protocolFeeOwner
    ) external payable onlyOwner {
        bytes32 salt = bytes32(uint256(uint160(msg.sender)) + block.number);
        _cruveContract = Create2.deploy(0, salt, abi.encodePacked(curveContractCode));

        bytes memory creationCode = abi.encodePacked(tokenContractCode, abi.encode(address(this), "IBC", "IBC"));
        _tokenContract = Create2.deploy(0, salt, creationCode);

        // Create proxy contract and intialize

        creationCode = abi.encodePacked(proxyContractCode, abi.encode(_cruveContract, ""));
        _proxyContract = Create2.deploy(0, salt, creationCode);

        bytes memory data = abi.encodeWithSignature(
            "initialize(uint256,uint256,address,address)", supply, price, _tokenContract, protocolFeeOwner
        );
        (bool success,) = _proxyContract.call{value: msg.value}(data);
        require(success, "Curve contract initialize failed");

        // Change owner to external owner
        (success,) = _tokenContract.call(abi.encodeWithSignature("transferOwnership(address)", _proxyContract));
        require(success, "Token contract owner transfer failed");

        (success,) = _proxyContract.call(abi.encodeWithSignature("transferOwnership(address)", owner()));
        require(success, "Token contract owner transfer failed");

        emit Deployed(_cruveContract, _tokenContract, _proxyContract);
    }

    function getDeployedContracts()
        external
        view
        returns (address cruveContract, address proxyContract, address tokenContract)
    {
        return (_cruveContract, _tokenContract, _proxyContract);
    }
}
