// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/Script.sol";
import "../src/InverseBondingCurve.sol";
import "../src/InverseBondingCurveToken.sol";
import "forge-std/console2.sol";

// contract UpgradeCurve is Script {
//     function setUp() public {}

//     function run() public {
//         // Put secret in .secret file under contracts folder
//         string memory seedPhrase = vm.readFile(".secret");
//         uint256 privateKey = vm.deriveKey(seedPhrase, 0);
//         address payable proxyContractAddress = payable(vm.parseAddress("0x7a5ec257391817ef241ef8451642cc6b222d4f8c"));
//         address newCurveContractAddress = vm.parseAddress("0xabebe9a2d62af9a89e86eb208b51321e748640c3");
//         address oneLiqudityProvider = vm.parseAddress("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266");
//         vm.startBroadcast(privateKey);

//         InverseBondingCurve curveContract = InverseBondingCurve(proxyContractAddress);

//         (uint256 lpBalance, uint256 ibcCredit) = curveContract.liquidityPositionOf(oneLiqudityProvider);
//         console2.log("LP balance:", lpBalance);
//         console2.log(
//             "LP IBC balance:",
//             InverseBondingCurveToken(curveContract.inverseTokenAddress()).balanceOf(oneLiqudityProvider)
//         );
//         console2.log("IBC token address remain:", curveContract.inverseTokenAddress());
//         curveContract.upgradeTo(newCurveContractAddress);
//         console2.log("IBC token address remain:", curveContract.inverseTokenAddress());
//         (lpBalance, ibcCredit) = curveContract.liquidityPositionOf(oneLiqudityProvider);
//         console2.log("LP balance after upgrade:", lpBalance);
//         console2.log(
//             "LP IBC balance after upgrade:",
//             InverseBondingCurveToken(curveContract.inverseTokenAddress()).balanceOf(oneLiqudityProvider)
//         );
//         vm.stopBroadcast();
//     }
// }
