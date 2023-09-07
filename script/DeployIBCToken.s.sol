// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/Script.sol";
import "../src/InverseBondingCurveToken.sol";
import "forge-std/console2.sol";

contract DeploymentToken is Script {
    function setUp() public {}

    function run() public {
        // Put secret in .secret file under contracts folder
        string memory seedPhrase = vm.readFile(".secret");
        uint256 privateKey = vm.deriveKey(seedPhrase, 0);
        // proxy contract
        address proxyContractAddress = vm.parseAddress("0x3818eab6ca8bf427222bfacfa706c514145f4104");
        vm.startBroadcast(privateKey);

        InverseBondingCurveToken tokenContract = new InverseBondingCurveToken(proxyContractAddress, "IBC", "IBC");

        console2.log("Bonding curve token contract address:", address(tokenContract));

        vm.stopBroadcast();
    }
}
