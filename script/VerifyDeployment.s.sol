// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/Script.sol";
import "../src/InverseBondingCurve.sol";
import "../src/InverseBondingCurveProxy.sol";
import "../src/InverseBondingCurveToken.sol";
import "../src/Deployer.sol";
import "forge-std/console2.sol";

contract VerifyDeployment is Script {
    function setUp() public {}


    function run() public {
        // Put secret in .secret file under contracts folder
        string memory seedPhrase = vm.readFile(".secret");
        uint256 privateKey = vm.deriveKey(seedPhrase, 0);
        vm.startBroadcast(privateKey);
        address feeOwner = vm.addr(privateKey);
        
        uint256 virtualReserve = 2e18;
        uint256 supply = 1e18;

        Deployer deployer = Deployer(vm.parseAddress("0x1d460d731bd5a0ff2ca07309daeb8641a7b175a1"));

        (address curveContractAddress, address tokenContractAddress, address proxyContractAddress) = deployer.getDeployedContracts();

        console2.log("Inverse bonding curve implementation contract address:", curveContractAddress);
        console2.log("Inverse bonding curve token contract address:", tokenContractAddress);
        console2.log("Inverse bonding curve proxy contract address:", proxyContractAddress);

        InverseBondingCurve curveContract = InverseBondingCurve(proxyContractAddress);
        InverseBondingCurveToken tokenContract = InverseBondingCurveToken(tokenContractAddress);

        CurveParameter memory param = curveContract.curveParameters();
        require(curveContract.owner() == vm.addr(privateKey), "Curve contract owner incorrect");
        require(tokenContract.owner() == proxyContractAddress, "Token contract owner incorrect");
        require(curveContract.getImplementation() == curveContractAddress, "Curve implementation incorrect");

        require(param.virtualReserve == virtualReserve, "Reserve Parameter incorrect");
        require(param.virtualSupply == supply, "Supply Parameter incorrect");
        require(param.virtualSupply == supply, "Supply Parameter incorrect");

        vm.stopBroadcast();
    }
}