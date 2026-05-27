// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script, console2} from "forge-std/Script.sol";
import {AsterTrader} from "../src/AsterTrader.sol";
import {USDT, ASTER_DEX} from "../src/Interface/IAsterDex.sol";

contract SetupLocalFork is Script {
    function setUp() public {}

    function run() public returns (AsterTrader trader) {
        uint256 deployerPrivateKey = vm.envOr("PRIVATE_KEY", uint256(0));
        address deployer;

        if (deployerPrivateKey != 0) {
            deployer = vm.addr(deployerPrivateKey);
            vm.startBroadcast(deployerPrivateKey);
        } else {
            // Default Anvil Account 0 address
            deployer = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
            vm.startBroadcast(deployer);
        }

        console2.log("Deploying AsterTrader on local fork...");
        trader = new AsterTrader();

        // Write the deployed contract address to a file so that tests can read it
        vm.writeFile("./deployed_trader.txt", vm.toString(address(trader)));

        console2.log("-----------------------------------------");
        console2.log("AsterTrader deployed at: ", address(trader));
        console2.log("Deployer Address:        ", deployer);
        console2.log("-----------------------------------------");

        vm.stopBroadcast();
    }
}
