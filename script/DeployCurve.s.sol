// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/Script.sol";
import "../src/InverseBondingCurve.sol";
import "forge-std/console2.sol";

contract DeploymentCurve is Script {
    function setUp() public {}

    function run() public {
        // Put secret in .secret file under contracts folder
        string memory seedPhrase = vm.readFile(".secret");
        uint256 privateKey = vm.deriveKey(seedPhrase, 0);
        vm.startBroadcast(privateKey);

        InverseBondingCurve curveContract = new InverseBondingCurve();
        console2.log("Bonding curve contract address:", address(curveContract));

        vm.stopBroadcast();
    }
}
