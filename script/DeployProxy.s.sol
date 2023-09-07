// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/Script.sol";
import "../src/InverseBondingCurveProxy.sol";
import "forge-std/console2.sol";

contract DeploymentProxy is Script {
    function setUp() public {}

    function run() public {
        // Put secret in .secret file under contracts folder
        string memory seedPhrase = vm.readFile(".secret");
        uint256 privateKey = vm.deriveKey(seedPhrase, 0);
        address curveContractAddress = vm.parseAddress("0x7c02b58029beea7c1fcc872803dc9818f57a0e61");
        vm.startBroadcast(privateKey);

        InverseBondingCurveProxy proxyContract = new InverseBondingCurveProxy(curveContractAddress, "");

        console2.log("Bonding curve proxy contract address:", address(proxyContract));

        vm.stopBroadcast();
    }
}
