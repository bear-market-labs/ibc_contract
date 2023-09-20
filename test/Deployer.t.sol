// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import "../src/Deployer.sol";
import "../src/InverseBondingCurve.sol";
import "../src/InverseBondingCurveProxy.sol";
import "../src/InverseBondingCurveToken.sol";
import "forge-std/console2.sol";

//TODO: add upgradable related test
contract DeployerTest is Test {
    Deployer deployerContract;

    address owner = vm.addr(2);
    address nonOwner = vm.addr(3);

    function setUp() public {
        deployerContract = new Deployer();
    }

    function testDeploy() public {

        uint256 virtualReserve = 2e21;
        uint256 supply = 1e21;
        uint256 price = 1e18;


        Deployer deployer = new Deployer();

        deployerContract.deploy(
            type(InverseBondingCurve).creationCode,
            type(InverseBondingCurveToken).creationCode,
            type(InverseBondingCurveProxy).creationCode,
            virtualReserve,
            supply,
            price,
            owner
        );
    }
}