// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/Script.sol";
import "../src/InverseBondingCurveToken.sol";
import "../src/InverseBondingCurveProxy.sol";
import "forge-std/console2.sol";

contract DeploymentToken is Script {
    function setUp() public {}

    function getBytecode(address _implementation, bytes memory _data) public pure returns (bytes memory) {
        bytes memory bytecode = type(InverseBondingCurveProxy).creationCode;

        return abi.encodePacked(bytecode, abi.encode(_implementation, _data));
    }

    // 2. Compute the address of the contract to be deployed
    // NOTE: _salt is a random number used to create an address
    function getAddress(bytes memory bytecode, bytes32 _salt) public view returns (address) {
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), address(this), uint256(_salt), keccak256(bytecode)));

        // NOTE: cast last 20 bytes of hash to address
        return address(uint160(uint256(hash)));
    }

    function run() public {
        // Put secret in .secret file under contracts folder
        string memory seedPhrase = vm.readFile(".secret");
        uint256 privateKey = vm.deriveKey(seedPhrase, 0);

        vm.startBroadcast(privateKey);
        address curveContractAddress = vm.parseAddress("0x9bb65b12162a51413272d10399282e730822df44");
        bytes memory data = "";
        bytes32 salt = "abc";
        bytes memory byteCode = getBytecode(curveContractAddress, data);

        address preCalculateProxyAddress = getAddress(byteCode, salt);

        // proxy contract
        address proxyContractAddress = vm.parseAddress("0x7a5ec257391817ef241ef8451642cc6b222d4f8c");

        InverseBondingCurveToken tokenContract = new InverseBondingCurveToken(proxyContractAddress, "IBC", "IBC");

        console2.log("Bonding curve token contract address:", address(tokenContract));

        vm.stopBroadcast();
    }
}
