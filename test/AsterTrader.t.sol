// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/AsterTrader.sol";
import "./Mocks.sol";
import {IAsterDex, USDT, BTC_PAIR_BASE, ASTER_DEX} from "../src/Interface/IAsterDex.sol";

contract AsterTraderTest is Test {
    AsterTrader public trader;
    MockUSDT public usdt;
    MockBTC public btc;
    MockAsterDex public router; // Etched at ASTER_DEX address

    address public owner;
    address public user;

    function setUp() public {
        owner = address(this);
        user = address(0x1234);

        // Deploy Mock USDT and etch it at standard USDT address
        MockUSDT mockUsdt = new MockUSDT();
        vm.etch(USDT, address(mockUsdt).code);
        usdt = MockUSDT(USDT);

        // Deploy Mock BTC and etch it at standard BTCB address
        MockBTC mockBtc = new MockBTC();
        vm.etch(BTC_PAIR_BASE, address(mockBtc).code);
        btc = MockBTC(BTC_PAIR_BASE);

        // Deploy Mock Aster DEX and etch it at ASTER_DEX address
        MockAsterDex mockDex = new MockAsterDex();
        vm.etch(ASTER_DEX, address(mockDex).code);
        router = MockAsterDex(ASTER_DEX);

        // Set default BTC price in the etched Mock DEX
        router.setBtcPrice(60_000 * 1e8);

        // Deploy AsterTrader (parameterless constructor, uses constants)
        trader = new AsterTrader();

        // Mint tokens to owner and user
        usdt.mint(owner, 1_000_000 * 1e18);
        usdt.mint(user, 10_000 * 1e18);

        // Mint token reserves to the etched Mock DEX
        usdt.mint(ASTER_DEX, 2_000_000 * 1e18);
        btc.mint(ASTER_DEX, 2_000_000 * 1e18);
    }

    // --- Deposit & Withdrawal Tests ---

    function testDepositUSDT() public {
        uint256 depositAmt = 5_000 * 1e18;

        // Approve and deposit
        usdt.approve(address(trader), depositAmt);
        trader.depositUSDT(depositAmt);

        // Check balances
        (uint256 usdtBal, uint256 btcBal) = trader.getBalances();
        assertEq(usdtBal, depositAmt);
        assertEq(btcBal, 0);
    }

    function testWithdrawUSDT_Owner() public {
        uint256 depositAmt = 5_000 * 1e18;

        // Deposit
        usdt.approve(address(trader), depositAmt);
        trader.depositUSDT(depositAmt);

        uint256 balanceBefore = usdt.balanceOf(owner);

        // Withdraw
        trader.withdrawUSDT(depositAmt);

        uint256 balanceAfter = usdt.balanceOf(owner);
        assertEq(balanceAfter - balanceBefore, depositAmt);

        (uint256 usdtBal, ) = trader.getBalances();
        assertEq(usdtBal, 0);
    }

    function testWithdrawUSDT_NonOwner_Reverts() public {
        uint256 depositAmt = 5_000 * 1e18;

        // Deposit
        usdt.approve(address(trader), depositAmt);
        trader.depositUSDT(depositAmt);

        // Try to withdraw as non-owner
        vm.prank(user);
        vm.expectRevert("AsterTrader: caller is not the owner");
        trader.withdrawUSDT(depositAmt);
    }

    // --- Trading Execution & PnL Cycle Tests ---

    function testExecuteBuyAndSell_Profit() public {
        // Step 1: Deposit USDT
        uint256 depositAmt = 60_000 * 1e18; // 60,000 USDT
        usdt.approve(address(trader), depositAmt);
        trader.depositUSDT(depositAmt);

        // Set BTC price in Mock DEX to 60,000 USDT/BTC (in 1e8)
        router.setBtcPrice(60_000 * 1e8);

        // Check active cycle
        assertFalse(trader.hasActiveCycle());

        // Step 2: Execute Buy of 1 BTC position
        uint96 usdtMargin = 60_000 * 1e18;
        uint80 btcQty = 1 * 1e10; 
        
        trader.executeBuy(usdtMargin, btcQty, 60_000 * 1e8, 0, 0);

        // Verify USDT is pulled from contract
        (uint256 usdtBal, uint256 btcBal) = trader.getBalances();
        assertEq(usdtBal, 0);
        assertEq(btcBal, 0); 

        // Verify trade cycle state
        assertTrue(trader.hasActiveCycle());
        assertEq(trader.getTradeCyclesCount(), 1);
        assertEq(trader.activeCyclesCount(), 1);

        // Fetch position hash from Mock DEX
        IAsterDex.Position[] memory openPositions = trader.getMyPositions();
        assertEq(openPositions.length, 1);
        bytes32 tradeHash = openPositions[0].positionHash;

        (
            uint256 id,
            bytes32 storedHash,
            uint96 marginUSDT,
            uint80 qtyBTC,
            uint64 entryPrice,
            uint64 exitPrice,
            int256 pnl,
            bool active,
            uint256 startTime,
            uint256 endTime
        ) = trader.getTradeCycle(0);

        assertEq(id, 0);
        assertEq(storedHash, bytes32(0)); // Set to 0 until closure in executeSell
        assertEq(marginUSDT, usdtMargin);
        assertEq(qtyBTC, btcQty);
        assertEq(entryPrice, 0); // Populated during close
        assertEq(exitPrice, 0);
        assertEq(pnl, 0);
        assertTrue(active);
        assertEq(startTime, block.timestamp);
        assertEq(endTime, 0);

        // Step 3: Set BTC price to 66,000 USDT (in 1e8) -> Profit scenario
        router.setBtcPrice(66_000 * 1e8);

        // Step 4: Execute Sell of Cycle 0
        trader.executeSell(0, tradeHash);

        // Verify balances after sell
        (usdtBal, btcBal) = trader.getBalances();
        assertEq(usdtBal, 66_000 * 1e18);
        assertEq(btcBal, 0);

        // Verify trade cycle completed
        assertFalse(trader.hasActiveCycle());
        assertEq(trader.activeCyclesCount(), 0);

        (
            ,
            storedHash,
            ,
            ,
            entryPrice,
            exitPrice,
            pnl,
            active,
            ,
            endTime
        ) = trader.getTradeCycle(0);

        assertEq(storedHash, tradeHash);
        assertEq(entryPrice, 60_000 * 1e8);
        assertEq(exitPrice, 66_000 * 1e8);
        assertEq(pnl, 6_000 * 1e18); 
        assertFalse(active);
        assertEq(endTime, block.timestamp);

        // Check global PnL
        assertEq(trader.totalPnL(), 6_000 * 1e18);
    }

    function testExecuteBuyAndSell_Loss() public {
        // Step 1: Deposit USDT
        uint256 depositAmt = 60_000 * 1e18;
        usdt.approve(address(trader), depositAmt);
        trader.depositUSDT(depositAmt);

        // Set BTC price to 60,000 * 1e8
        router.setBtcPrice(60_000 * 1e8);

        // Step 2: Buy
        trader.executeBuy(uint96(depositAmt), 1 * 1e10, 60_000 * 1e8, 0, 0);

        IAsterDex.Position[] memory openPositions = trader.getMyPositions();
        bytes32 tradeHash = openPositions[0].positionHash;

        // Set BTC price to 54,000 * 1e8 (10% loss)
        router.setBtcPrice(54_000 * 1e8);

        // Step 3: Sell Cycle 0
        trader.executeSell(0, tradeHash);

        // Verify trade cycle PnL
        (,,,,,, int256 pnl,,,) = trader.getTradeCycle(0);
        assertEq(pnl, -6_000 * 1e18); 
        assertEq(trader.totalPnL(), -6_000 * 1e18);
    }

    // --- Concurrent Trades & Out-of-Order Sells Test (Grid Trading) ---

    function testConcurrentTradesAndOutOfOrderSells() public {
        // Deposit 300,000 USDT
        uint256 depositAmt = 300_000 * 1e18;
        usdt.approve(address(trader), depositAmt);
        trader.depositUSDT(depositAmt);

        // Set BTC price to 60,000 * 1e8
        router.setBtcPrice(60_000 * 1e8);

        // Execute 5 buys consecutively
        for (uint256 i = 0; i < 5; i++) {
            trader.executeBuy(60_000 * 1e18, 1 * 1e10, 60_000 * 1e8, 0, 0);
        }

        // Verify state
        assertEq(trader.activeCyclesCount(), 5);
        assertEq(trader.getTradeCyclesCount(), 5);
        
        (uint256 usdtBal, ) = trader.getBalances();
        assertEq(usdtBal, 0);

        IAsterDex.Position[] memory openPositions = trader.getMyPositions();
        assertEq(openPositions.length, 5);

        bytes32[] memory hashes = new bytes32[](5);
        for (uint256 i = 0; i < 5; i++) {
            hashes[i] = openPositions[i].positionHash;
        }

        // Price increases: Sell Cycle 2 (out of order)
        router.setBtcPrice(70_000 * 1e8);
        trader.executeSell(2, hashes[2]);

        // Verify Cycle 2 state
        (,,,,, uint64 exitPrice, int256 pnl2, bool active2,,) = trader.getTradeCycle(2);
        assertFalse(active2);
        assertEq(exitPrice, 70_000 * 1e8);
        assertEq(pnl2, 10_000 * 1e18);

        // Verify active cycle list doesn't include 2
        uint256[] memory activeIdsAfterFirstSell = trader.getActiveCycleIds();
        assertEq(activeIdsAfterFirstSell.length, 4);
        assertEq(activeIdsAfterFirstSell[0], 0);
        assertEq(activeIdsAfterFirstSell[1], 1);
        assertEq(activeIdsAfterFirstSell[2], 3);
        assertEq(activeIdsAfterFirstSell[3], 4);
        assertEq(trader.activeCyclesCount(), 4);

        // Price decreases: Sell Cycle 0 (loss)
        router.setBtcPrice(50_000 * 1e8);
        trader.executeSell(0, hashes[0]);

        // Verify Cycle 0 state
        (,,,,,, int256 pnl0, bool active0,,) = trader.getTradeCycle(0);
        assertFalse(active0);
        assertEq(pnl0, -10_000 * 1e18);

        // Verify active cycle list doesn't include 0 or 2
        uint256[] memory activeIdsAfterSecondSell = trader.getActiveCycleIds();
        assertEq(activeIdsAfterSecondSell.length, 3);
        assertEq(activeIdsAfterSecondSell[0], 1);
        assertEq(activeIdsAfterSecondSell[1], 3);
        assertEq(activeIdsAfterSecondSell[2], 4);
        assertEq(trader.activeCyclesCount(), 3);

        // Verify cumulative PnL: +10,000 + (-10,000) = 0
        assertEq(trader.totalPnL(), 0);

        // Verify remaining token balances
        (usdtBal, ) = trader.getBalances();
        assertEq(usdtBal, 120_000 * 1e18); 
    }

    // --- State Invariants & Boundary Tests ---

    function testCannotExceedMaxActiveCycles() public {
        uint256 depositAmt = 360_000 * 1e18;
        usdt.approve(address(trader), depositAmt);
        trader.depositUSDT(depositAmt);

        router.setBtcPrice(60_000 * 1e8);

        // Buy 5 cycles successfully
        for (uint256 i = 0; i < 5; i++) {
            trader.executeBuy(60_000 * 1e18, 1 * 1e10, 60_000 * 1e8, 0, 0);
        }

        // The 6th buy should revert
        vm.expectRevert("AsterTrader: maximum concurrent active cycles reached");
        trader.executeBuy(60_000 * 1e18, 1 * 1e10, 60_000 * 1e8, 0, 0);

        IAsterDex.Position[] memory openPositions = trader.getMyPositions();
        bytes32 hash0 = openPositions[0].positionHash;

        // Sell one cycle to free up space
        trader.executeSell(0, hash0);
        assertEq(trader.activeCyclesCount(), 4);

        // Now the 6th buy should succeed
        trader.executeBuy(60_000 * 1e18, 1 * 1e10, 60_000 * 1e8, 0, 0);
        assertEq(trader.activeCyclesCount(), 5);
        assertEq(trader.getTradeCyclesCount(), 6);
    }

    function testCannotSellInactiveCycle() public {
        uint256 depositAmt = 60_000 * 1e18;
        usdt.approve(address(trader), depositAmt);
        trader.depositUSDT(depositAmt);

        router.setBtcPrice(60_000 * 1e8);

        // Buy and then sell to close Cycle 0
        trader.executeBuy(60_000 * 1e18, 1 * 1e10, 60_000 * 1e8, 0, 0);
        
        IAsterDex.Position[] memory openPositions = trader.getMyPositions();
        bytes32 hash0 = openPositions[0].positionHash;

        trader.executeSell(0, hash0);

        // Attempting to sell Cycle 0 again should revert
        vm.expectRevert("AsterTrader: trade cycle is not active");
        trader.executeSell(0, hash0);
    }

    function testCannotSellNonExistentPosition() public {
        uint256 depositAmt = 60_000 * 1e18;
        usdt.approve(address(trader), depositAmt);
        trader.depositUSDT(depositAmt);

        router.setBtcPrice(60_000 * 1e8);
        trader.executeBuy(60_000 * 1e18, 1 * 1e10, 60_000 * 1e8, 0, 0);

        vm.expectRevert("AsterTrader: position not found on Aster");
        trader.executeSell(0, bytes32(hex"12345678"));
    }

    function testCannotSellNonExistentCycle() public {
        vm.expectRevert("AsterTrader: invalid trade cycle ID");
        trader.executeSell(999, bytes32(hex"12345678"));
    }

    function testCannotBuyWithInsufficientUSDT() public {
        router.setBtcPrice(50_000 * 1e8);

        // Attempt buy without depositing USDT
        vm.expectRevert("AsterTrader: insufficient USDT in contract");
        trader.executeBuy(50_000 * 1e18, 1 * 1e10, 50_000 * 1e8, 0, 0);
    }

    // --- Asynchronous Manual Close Settlement Test ---

    function testAsynchronousManualSettlement() public {
        // Setup trade
        uint256 depositAmt = 60_000 * 1e18;
        usdt.approve(address(trader), depositAmt);
        trader.depositUSDT(depositAmt);

        router.setBtcPrice(60_000 * 1e8);
        trader.executeBuy(60_000 * 1e18, 1 * 1e10, 60_000 * 1e8, 0, 0);

        // We will call settleClose manually representing the off-chain oracle settlement.
        uint256 actualUsdtReceived = 63_000 * 1e18;
        uint64 exitPrice = 63_000 * 1e8;

        trader.settleClose(0, actualUsdtReceived, exitPrice);

        // Verify status
        assertFalse(trader.hasActiveCycle());
        assertEq(trader.activeCyclesCount(), 0);

        (,,,,,, int256 pnl,,,) = trader.getTradeCycle(0);
        assertEq(pnl, 3_000 * 1e18);
        assertEq(trader.totalPnL(), 3_000 * 1e18);
    }
}
