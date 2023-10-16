// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/Script.sol";
import "../src/InverseBondingCurve.sol";
import "../src/InverseBondingCurveProxy.sol";
import "../src/InverseBondingCurveToken.sol";
import "forge-std/console2.sol";

// contract DeployerScript is Script {
//     function setUp() public {}

//     function run() public {
//         // Put secret in .secret file under contracts folder
//         string memory seedPhrase = vm.readFile(".secret");
//         uint256 privateKey = vm.deriveKey(seedPhrase, 0);
//         vm.startBroadcast(privateKey);
//         // address feeOwner = vm.addr(privateKey);

//         // uint256 virtualReserve = 2e22;
//         // uint256 supply = 1e21;
//         // uint256 price = 1e19;

//         Deployer deployer = new Deployer();

//         // deployer.deploy(
//         //     type(InverseBondingCurve).creationCode,
//         //     type(InverseBondingCurveToken).creationCode,
//         //     type(InverseBondingCurveProxy).creationCode,
//         //     virtualReserve,
//         //     supply,
//         //     price,
//         //     feeOwner
//         // );

//         vm.stopBroadcast();
//     }
// }
