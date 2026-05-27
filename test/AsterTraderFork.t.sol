// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/AsterTrader.sol";
import {IAsterDex, USDT, BTC_PAIR_BASE, ASTER_DEX, IERC20} from "../src/Interface/IAsterDex.sol";

contract AsterTraderForkTest is Test {
    AsterTrader public trader;
    address public owner;

    // Binance Hot Wallet 20 on BSC (holds substantial USDT and BNB)
    address constant USDT_WHALE = 0xF977814e90dA44bFA03b6295A0616a897441aceC;

    function setUp() public {
        // Determine the owner and trader contract dynamically
        address deployedAddress = address(0);
        try vm.readFile("./deployed_trader.txt") returns (string memory addrStr) {
            deployedAddress = vm.parseAddress(addrStr);
        } catch {}

        if (deployedAddress != address(0) && deployedAddress.code.length > 0) {
            trader = AsterTrader(deployedAddress);
            owner = trader.owner();
            console2.log("Testing against deployed AsterTrader at:", deployedAddress);
        } else {
            // Check if BSC_RPC_URL is set in environment (used for standard fork test mode)
            string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
            if (bytes(rpc).length > 0) {
                vm.createSelectFork(rpc);
            }
            trader = new AsterTrader();
            owner = address(this);
            console2.log("Testing against freshly deployed AsterTrader at:", address(trader));
        }
    }

    function testForkInitialBuy() public {
        // If not on BSC network, skip test (either standard local test run or fork not initialized)
        if (block.chainid != 56) {
            console2.log("Skipping fork test: Chain ID is not 56 (BSC Mainnet/Fork).");
            return;
        }

        // 1. Verify we can fetch the live BTC price from the real Aster DEX contract
        uint256 btcPrice = IAsterDex(ASTER_DEX).getPrice(BTC_PAIR_BASE);
        console2.log("Live BTC Price from Aster DEX (1e8):", btcPrice);
        assertTrue(btcPrice > 0, "Failed to fetch live BTC price");

        // 2. Fund the owner account with USDT from the whale
        uint256 depositAmount = 5000 * 1e18; // 5,000 USDT
        // forge-lint: disable-next-line(unsafe-typecast)
        uint96 marginAmount = uint96(depositAmount);

        vm.startPrank(USDT_WHALE);
        uint256 whaleBalance = IERC20(USDT).balanceOf(USDT_WHALE);
        console2.log("USDT Whale Balance:", whaleBalance / 1e18);
        require(whaleBalance >= depositAmount, "Whale has insufficient USDT");

        bool transferSuccess = IERC20(USDT).transfer(owner, depositAmount);
        assertTrue(transferSuccess, "USDT transfer from Whale failed");
        vm.stopPrank();

        uint256 ownerBalance = IERC20(USDT).balanceOf(owner);
        assertEq(ownerBalance, depositAmount, "USDT funding failed");

        // 3. Deposit USDT into AsterTrader (calling as owner)
        vm.startPrank(owner);
        IERC20(USDT).approve(address(trader), depositAmount);
        trader.depositUSDT(depositAmount);
        vm.stopPrank();

        (uint256 contractUsdt,) = trader.getBalances();
        assertEq(contractUsdt, depositAmount, "USDT deposit into AsterTrader failed");

        // 4. Calculate parameters for a 3,000 USDT value position
        uint256 positionValue = 3000 * 1e18;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint80 btcQty = uint80(positionValue / btcPrice);
        console2.log("Calculated BTC position quantity (1e10):", btcQty);
        assertTrue(btcQty > 0, "Position quantity calculation resulted in 0");

        // 5% slippage tolerance for Long (worstPrice = price * 1.05)
        uint64 worstPrice = uint64((btcPrice * 105) / 100);

        // 5. Execute Buy on AsterTrader (calls live ASTER_DEX openMarketTrade, calling as owner)
        console2.log("Executing buy long on live ASTER_DEX contract on fork...");

        // Expect MarketPendingTrade to be emitted by the real ASTER_DEX
        vm.expectEmit(true, true, false, false, ASTER_DEX);
        emit IAsterDex.MarketPendingTrade(
            address(trader),
            bytes32(0),
            IAsterDex.OpenDataInput({
                pairBase: BTC_PAIR_BASE,
                isLong: true,
                tokenIn: USDT,
                amountIn: marginAmount,
                qty: btcQty,
                price: worstPrice,
                stopLoss: 0,
                takeProfit: 0,
                broker: 0
            })
        );

        vm.startPrank(owner);
        uint256 cycleId = trader.executeBuy(
            marginAmount,
            btcQty,
            worstPrice,
            0, // no stop loss
            0 // no take profit
        );
        vm.stopPrank();

        uint256 totalCycles = trader.getTradeCyclesCount();
        assertTrue(totalCycles > 0, "No trade cycles found");
        uint256 activeCycleId = totalCycles - 1;
        assertEq(cycleId, activeCycleId, "cycleId mismatch");

        (
            uint256 id,
            bytes32 storedHash,
            uint96 marginUSDT,
            uint80 qtyBTC,
            uint64 entryPrice,
            uint64 exitPrice,
            int256 netCashFlow,
            bool active,
            uint256 startTime,
            uint256 endTime
        ) = trader.getTradeCycle(activeCycleId);

        assertEq(id, activeCycleId);
        assertEq(storedHash, bytes32(0)); // remains empty until close
        assertEq(marginUSDT, depositAmount);
        assertEq(qtyBTC, btcQty);
        assertEq(entryPrice, 0);
        assertEq(exitPrice, 0);
        assertEq(netCashFlow, 0);
        assertTrue(active);
        assertTrue(startTime > 0);
        assertEq(endTime, 0);

        console2.log("Fork integration test completed successfully on cycle:", activeCycleId);
    }
}
