// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import "../src/deploy/Deployer.sol";
import "../src/InverseBondingCurve.sol";
import "../src/InverseBondingCurveProxy.sol";
import "../src/InverseBondingCurveToken.sol";
import "forge-std/console2.sol";

//TODO: add upgradable related test
// contract DeployerTest is Test {
//     Deployer deployerContract;

//     address owner = address(this);
//     address feeOwner = vm.addr(3);

//     function setUp() public {
//         deployerContract = new Deployer();
//     }

//     function testDeploy() public {
//         uint256 reserve = 2e18;
//         uint256 supply = 1e18;
//         uint256 price = 1e18;

//         vm.deal(owner, 1000 ether);
//         // vm.startPrank(owner);

//         deployerContract.deploy{value: reserve}(
//             type(InverseBondingCurve).creationCode,
//             type(InverseBondingCurveToken).creationCode,
//             type(InverseBondingCurveProxy).creationCode,
//             supply,
//             price,
//             feeOwner
//         );
//         // vm.stopPrank();
//         (address curveContractAddress, address tokenContractAddress, address proxyContractAddress) =
//             deployerContract.getDeployedContracts();

//         // console2.log("Inverse bonding curve implementation contract address:", curveContractAddress);
//         // console2.log("Inverse bonding curve token contract address:", tokenContractAddress);
//         // console2.log("Inverse bonding curve proxy contract address:", proxyContractAddress);

//         InverseBondingCurve curveContract = InverseBondingCurve(proxyContractAddress);
//         InverseBondingCurveToken tokenContract = InverseBondingCurveToken(tokenContractAddress);

//         CurveParameter memory param = curveContract.curveParameters();
//         require(curveContract.owner() == owner, "Curve contract owner incorrect");
//         require(tokenContract.owner() == proxyContractAddress, "Token contract owner incorrect");
//         require(curveContract.getImplementation() == curveContractAddress, "Curve implementation incorrect");

//         require(param.reserve == reserve, "Reserve Parameter incorrect");
//         require(param.supply == supply, "Supply Parameter incorrect");
//         require(tokenContract.totalSupply() == 0, "Inital IBC token supply incorrect");
//         require(param.price == price, "Initial Price incorrect");
//     }
// }
