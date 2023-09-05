// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../src/InverseBondingCurve.sol";

contract InitializeCurve is Script {
    function setUp() public {}

    function run() public {
        // Put secret in .secret file under contracts folder
        string memory seedPhrase = vm.readFile(".secret");
        uint256 privateKey = vm.deriveKey(seedPhrase, 0);
        address feeOwner = vm.addr(privateKey);
        address proxyContractAddress = vm.parseAddress("0x930b218f3e63eE452c13561057a8d5E61367d5b7");
        vm.startBroadcast(privateKey);

        InverseBondingCurve curveContract = InverseBondingCurve(proxyContractAddress);

        uint256 supply = 1e18;
        uint256 price = 1e18;
        curveContract.initialize{value: 2 ether}(supply, price, feeOwner);

        vm.stopBroadcast();
    }
}
