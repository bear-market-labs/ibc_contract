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
        address proxyContractAddress = vm.parseAddress("0x3818eab6ca8bf427222bfacfa706c514145f4104");
        address ibcTokenContract = vm.parseAddress("0x4a351c6ae3249499cbb50e8fe6566e2615386da8");
        vm.startBroadcast(privateKey);

        InverseBondingCurve curveContract = InverseBondingCurve(proxyContractAddress);

        uint256 supply = 1e18;
        uint256 price = 1e18;
        curveContract.initialize(2e18, supply, price, ibcTokenContract, feeOwner);

        vm.stopBroadcast();
    }
}
