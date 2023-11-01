// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/Script.sol";
import "../src/InverseBondingCurve.sol";
import "../src/InverseBondingCurveFactory.sol";
import "forge-std/console2.sol";

contract CreateCurveScript is Script {
    function setUp() public {}

    function run() public {
        address factoryAddress = vm.parseAddress("0x7EA558566EcEfC22B7886a213F14ef195C0b4C46");
        // Put secret in .secret file under contracts folder
        string memory seedPhrase = vm.readFile(".secret");
        uint256 privateKey = vm.deriveKey(seedPhrase, 0);
        vm.startBroadcast(privateKey);

        uint256 reserve = 2 ether;

        InverseBondingCurveFactory(factoryAddress).createCurve{value: reserve}(reserve, address(0), vm.addr(privateKey));

        InverseBondingCurve curve = InverseBondingCurve(InverseBondingCurveFactory(factoryAddress).getCurve(address(0)));

        console2.log("ETH curve address:", address(curve));
        console2.log("ETH curve reserve(WETH) address:", curve.reserveTokenAddress());
        console2.log("ETH curve inverseToken(ibETH) address:", curve.inverseTokenAddress());

        CurveParameter memory param = curve.curveParameters();


        console2.log("Curve reserve:", param.reserve);
        console2.log("Curve supply:", param.supply);
        console2.log("Curve price:", param.price);
        console2.log("Curve LP supply:", param.lpSupply);
        console2.log("Curve parameterInvariant:", param.parameterInvariant);

        vm.stopBroadcast();
    }
}