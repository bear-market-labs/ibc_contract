// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../src/InverseBondingCurve.sol";

contract InitializeScript is Script {
    function setUp() public {}

    function run() public {
        // Put secret in .secret file under contracts folder
        string memory seedPhrase = vm.readFile(".secret");
        uint256 privateKey = vm.deriveKey(seedPhrase, 0);
        address contractAddress = vm.parseAddress("0x88d1af96098a928ee278f162c1a84f339652f95b");
        vm.startBroadcast(privateKey);

        InverseBondingCurve curveContract = InverseBondingCurve(contractAddress);

        uint256 supply = 1e18;
        uint256 price = 1e18;
        curveContract.initialize{value: 2 ether}(supply, price);

        vm.stopBroadcast();
    }
}
