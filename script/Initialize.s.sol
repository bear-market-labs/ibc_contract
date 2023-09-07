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
        address proxyContractAddress = vm.parseAddress("0xfc073209b7936a771f77f63d42019a3a93311869");
        address ibcTokenContract = vm.parseAddress("0xb4e9a5bc64dc07f890367f72941403eed7fadcbb");
        vm.startBroadcast(privateKey);

        InverseBondingCurve curveContract = InverseBondingCurve(proxyContractAddress);

        uint256 supply = 1e18;
        uint256 price = 1e18;
        curveContract.initialize{value: 2 ether}(supply, price, ibcTokenContract, feeOwner);

        vm.stopBroadcast();
    }
}
