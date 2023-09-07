// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/Script.sol";
import "../src/InverseBondingCurve.sol";
import "../src/InverseBondingCurveToken.sol";
import "forge-std/console2.sol";

contract UpgradeCurve is Script {
    function setUp() public {}

    function run() public {
        // Put secret in .secret file under contracts folder
        string memory seedPhrase = vm.readFile(".secret");
        uint256 privateKey = vm.deriveKey(seedPhrase, 0);
        address payable proxyContractAddress = payable(vm.parseAddress("0xfc073209b7936a771f77f63d42019a3a93311869"));
        address newCurveContractAddress = vm.parseAddress("0x8b64968f69e669facc86fa3484fd946f1bbe7c91");
        address oneLiqudityProvider = vm.parseAddress("0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266");
        vm.startBroadcast(privateKey);

        InverseBondingCurve curveContract = InverseBondingCurve(proxyContractAddress);

        console2.log("LP balance:", curveContract.balanceOf(oneLiqudityProvider));
        console2.log(
            "LP IBC balance:",
            InverseBondingCurveToken(curveContract.inverseTokenAddress()).balanceOf(oneLiqudityProvider)
        );
        console2.log("IBC token address remain:", curveContract.inverseTokenAddress());
        curveContract.upgradeTo(newCurveContractAddress);
        console2.log("LP balance after upgrade:", curveContract.balanceOf(oneLiqudityProvider));
        console2.log("LP IBC balance after upgrade:", InverseBondingCurveToken(curveContract.inverseTokenAddress()).balanceOf(oneLiqudityProvider));
        vm.stopBroadcast();
    }
}
