// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/Script.sol";
import "../src/InverseBondingCurve.sol";
import "../src/InverseBondingCurveAdmin.sol";
import "forge-std/console2.sol";

contract DeployAdminScript is Script {
    function setUp() public {}

    function run() public {
        address wethAddress = vm.parseAddress("0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2");
        address routerAddress = vm.parseAddress("0xf102f0173707c6726543d65fa38025eb72026c37");
        // Put secret in .secret file under contracts folder
        string memory seedPhrase = vm.readFile(".secret");
        uint256 privateKey = vm.deriveKey(seedPhrase, 0);
        vm.startBroadcast(privateKey);
        address feeOwner = vm.addr(privateKey);

        uint256 reserve = 2e18;
        uint256 supply = 1e18;
        uint256 price = 1e18;

        InverseBondingCurveAdmin adminContract = new InverseBondingCurveAdmin(wethAddress, routerAddress, feeOwner, type(InverseBondingCurve).creationCode);

        console.log("Admin contract deployed:", address(adminContract));
        console.log("Admin contract owner:", adminContract.owner());
        console.log("Protocol fee owner:", adminContract.feeOwner());
        console.log("Curve Factory address:", adminContract.factoryAddress());

        vm.stopBroadcast();
    }
}
