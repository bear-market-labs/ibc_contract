// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../src/InverseBondingCurve.sol";

contract UpgradeContract is Script {
    function setUp() public {}

    function run() public {
        // Put secret in .secret file under contracts folder
        string memory seedPhrase = vm.readFile(".secret");
        uint256 privateKey = vm.deriveKey(seedPhrase, 0);
        address payable proxyContractAddress = payable(vm.parseAddress("0x930b218f3e63eE452c13561057a8d5E61367d5b7"));
        address newCurveContractAddress = vm.parseAddress("0x88d1af96098a928ee278f162c1a84f339652f95b");
        vm.startBroadcast(privateKey);

        InverseBondingCurve curveContract = InverseBondingCurve(proxyContractAddress);

        curveContract.upgradeTo(newCurveContractAddress);

        vm.stopBroadcast();
    }
}
