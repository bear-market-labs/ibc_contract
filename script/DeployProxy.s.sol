// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../src/InverseBondingCurveProxy.sol";

contract DeploymentProxy is Script {
    function setUp() public {}

    function run() public {
        // Put secret in .secret file under contracts folder
        string memory seedPhrase = vm.readFile(".secret");
        uint256 privateKey = vm.deriveKey(seedPhrase, 0);
        address curveContractAddress = vm.parseAddress("0xdc57724ea354ec925baffca0ccf8a1248a8e5cf1");
        vm.startBroadcast(privateKey);

        InverseBondingCurveProxy proxyContract = new InverseBondingCurveProxy(curveContractAddress, "");

        // uint256 supply = 1e18;
        // uint256 price = 1e18;
        // curveContract.initialize{value: 2 ether}(supply, price);

        vm.stopBroadcast();
    }
}
