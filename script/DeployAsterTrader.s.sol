// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script, console2} from "forge-std/Script.sol";
import {AsterTrader} from "../src/AsterTrader.sol";
import {ASTER_DEX, BTC_PAIR_BASE, USDT} from "../src/Interface/IAsterDex.sol";

/**
 * @title DeployAsterTrader
 * @notice Forge script to deploy the AsterTrader contract to BNB Smart Chain (BSC) Mainnet.
 */
contract DeployAsterTrader is Script {
    function setUp() public {}

    function run() public returns (AsterTrader trader) {
        // Retrieve deployment private key from the environment variable (or falls back to the broadcaster account)
        uint256 deployerPrivateKey = vm.envOr("PRIVATE_KEY", uint256(0));

        console2.log("Preparing deployment of AsterTrader to BSC Mainnet...");
        console2.log("Using Mainnet Constants:");
        console2.log("USDT Address:  ", USDT);
        console2.log("BTCB Address:  ", BTC_PAIR_BASE);
        console2.log("Aster DEX:     ", ASTER_DEX);

        if (deployerPrivateKey != 0) {
            vm.startBroadcast(deployerPrivateKey);
        } else {
            vm.startBroadcast();
        }

        // Deploy parameterless AsterTrader
        trader = new AsterTrader();

        console2.log("AsterTrader deployed at:", address(trader));

        vm.stopBroadcast();
    }
}
