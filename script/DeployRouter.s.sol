// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/Script.sol";
import "../src/InverseBondingCurveRouter.sol";
import "forge-std/console2.sol";

contract DeployRouterScript is Script {
    
    function setUp() public {}

    function run() public {
        address wethAddress = vm.parseAddress("0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2");
        // Put secret in .secret file under contracts folder
        string memory seedPhrase = vm.readFile(".secret");
        uint256 privateKey = vm.deriveKey(seedPhrase, 0);
        vm.startBroadcast(privateKey);
        address feeOwner = vm.addr(privateKey);

        address router = address(new InverseBondingCurveRouter(wethAddress));

        console2.log("Router deployed:", router);

        vm.stopBroadcast();
    }
}
