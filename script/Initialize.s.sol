// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/Script.sol";
import "../src/InverseBondingCurve.sol";

contract InitializeCurve is Script {
    function setUp() public {}

    function run() public {
        // Put secret in .secret file under contracts folder
        string memory seedPhrase = vm.readFile(".secret");
        uint256 privateKey = vm.deriveKey(seedPhrase, 0);
        address feeOwner = vm.addr(privateKey);
        address proxyContractAddress = vm.parseAddress("0x7a5ec257391817ef241ef8451642cc6b222d4f8c");
        address ibcTokenContract = vm.parseAddress("0x90e75f390332356426b60fb440df23f860f6a113");
        vm.startBroadcast(privateKey);

        InverseBondingCurve curveContract = InverseBondingCurve(proxyContractAddress);

        uint256 supply = 1e18;
        uint256 price = 1e18;
        curveContract.initialize(2e18, supply, price, ibcTokenContract, feeOwner);

        vm.stopBroadcast();
    }
}
