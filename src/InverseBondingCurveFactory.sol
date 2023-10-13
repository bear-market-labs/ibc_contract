// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.18;

import "openzeppelin/access/Ownable.sol";
import "openzeppelin/utils/Create2.sol";

import "openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";

import "./InverseBondingCurve.sol";
import "./interface/IWETH9.sol";

contract InverseBondingCurveFactory is Ownable {
    event Deployed(address cruveContract, address tokenContract, address proxyContract);

    bytes private _tokenContractCode;
    bytes private _proxyContractCode;

    IInverseBondingCurveAdmin private _admin;

    mapping(address => address) private _poolMap;
    address[] public pools;

    constructor(address adminContract, 
        bytes memory tokenContractCode,
        bytes memory proxyContractCode) Ownable() {
            _admin = IInverseBondingCurveAdmin(adminContract);
            _tokenContractCode = tokenContractCode;
            _proxyContractCode = proxyContractCode;
        }

    function createPool(
        uint256 reserve,
        uint256 supply,
        uint256 price,
        address reserveTokenAddress
    ) external payable {
        string memory tokenSymbol = "";
        uint256 leftReserve = msg.value;
        address reserveFromAccount = msg.sender;
        if(reserveTokenAddress == address(0) && msg.value > 0){
            if(msg.value < reserve){
                revert InsufficientBalance();
            }
            // create ETH pool
            reserveTokenAddress = _admin.weth();
            IWETH9(reserveTokenAddress).deposit();
            // IWETH9(reserveTokenAddress).transfer(address(this), reserve);
            IWETH9(reserveTokenAddress).transfer(msg.sender, msg.value - reserve);
            leftReserve = 0;
            tokenSymbol = "ibETH";
            reserveFromAccount = address(this);
        }else{
            tokenSymbol = string(
                abi.encodePacked(
                    "ib",       
                    IERC20Metadata(reserveTokenAddress).symbol()
                )
            );
        } 

        if(_poolMap[reserveTokenAddress] != address(0)){
                revert PoolAlreadyExist();            
        }

        _createPool(reserve, supply, price, tokenSymbol, reserveFromAccount, reserveTokenAddress);   

        if(leftReserve > 0){
            (bool sent,) = msg.sender.call{value: leftReserve}("");
            if (!sent) {
                revert FailToSend(msg.sender);
            }
        }
    }

    function _createPool(
        uint256 reserve,
        uint256 supply,
        uint256 price,
        string memory inverseTokenSymbol,
        address reserveFromAccount,
        address reserveTokenAddress) private {

        bytes32 salt = bytes32(uint256(uint160(msg.sender)) + block.number);
        address _cruveContract = _admin.curveImplementation();

        bytes memory creationCode = abi.encodePacked(_tokenContractCode, abi.encode(address(this), inverseTokenSymbol, inverseTokenSymbol));
        address _tokenContract = Create2.deploy(0, salt, creationCode);

        // Create proxy contract and intialize

        
        creationCode = abi.encodePacked(_proxyContractCode, abi.encode(_cruveContract, ""));
        address _proxyContract = Create2.deploy(0, salt, creationCode);


        IERC20Metadata(reserveTokenAddress).transferFrom(reserveFromAccount, _proxyContract, reserve);

        bytes memory data = abi.encodeWithSignature(
            "initialize(address,address,address,address,uint256,uint256,uint256)", _admin, _admin, _tokenContract, reserveTokenAddress, reserve,supply, price
        );
        // address adminContract, address router, address inverseTokenContractAddress, address reserveTokenAddress, uint256 reserve, uint256 supply, uint256 price
        (bool success,) = _proxyContract.call(data);
        require(success, "Curve contract initialize failed");

        // Change owner to external owner
        (success,) = _tokenContract.call(abi.encodeWithSignature("transferOwnership(address)", _proxyContract));
        require(success, "Token contract owner transfer failed");

        (success,) = _proxyContract.call(abi.encodeWithSignature("transferOwnership(address)", owner()));
        require(success, "Token contract owner transfer failed");

        _poolMap[reserveTokenAddress] = _proxyContract;
        pools.push(_proxyContract);

        emit Deployed(_cruveContract, _tokenContract, _proxyContract);
    }

    function getPool(address reserveToken) public view returns (address){
        if(reserveToken == address(0)){
            // create ETH pool
            reserveToken = _admin.weth();
        }

        return _poolMap[reserveToken];
    }
}