// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/AsterTrader.sol";
import "./Mocks.sol";

contract AsterTraderTest is Test {
    AsterTrader public trader;
    MockERC20 public usdt;
    MockERC20 public btc;
    MockAsterRouter public router;

    address public owner;
    address public user;

    function setUp() public {
        owner = address(this);
        user = address(0x1234);

        // Deploy Mock tokens (18 decimals)
        usdt = new MockERC20("Mock USDT", "USDT", 18);
        btc = new MockERC20("Mock BTC", "BTC", 18);

        // Deploy Mock Router
        router = new MockAsterRouter(address(usdt), address(btc));

        // Deploy AsterTrader
        trader = new AsterTrader(address(usdt), address(btc), address(router));

        // Mint tokens to owner and user
        usdt.mint(owner, 1_000_000 * 1e18); // Mint more for grid trading
        usdt.mint(user, 10_000 * 1e18);

        // Mint token reserves to the Mock Router
        usdt.mint(address(router), 2_000_000 * 1e18);
        btc.mint(address(router), 2_000_000 * 1e18);
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

        // Set BTC price in Mock Router to 60,000 USDT/BTC
        router.setBtcPrice(60_000 * 1e18);

        // Check active cycle
        assertFalse(trader.hasActiveCycle());

        // Step 2: Execute Buy of 1 BTC (using 60,000 USDT)
        uint256 usdtToSpend = 60_000 * 1e18;
        uint256 expectedBtc = 1 * 1e18; // At 60,000 USDT/BTC, 60,000 USDT should yield 1 BTC
        
        trader.executeBuy(usdtToSpend, expectedBtc, block.timestamp + 100);

        // Verify balances
        (uint256 usdtBal, uint256 btcBal) = trader.getBalances();
        assertEq(usdtBal, 0);
        assertEq(btcBal, expectedBtc);

        // Verify trade cycle state
        assertTrue(trader.hasActiveCycle());
        assertEq(trader.getTradeCyclesCount(), 1);
        assertEq(trader.activeCyclesCount(), 1);

        (
            uint256 id,
            uint256 buyAmountUSDT,
            uint256 buyAmountBTC,
            uint256 sellAmountBTC,
            uint256 sellAmountUSDT,
            int256 pnl,
            bool active,
            uint256 startTime,
            uint256 endTime
        ) = trader.getTradeCycle(0);

        assertEq(id, 0);
        assertEq(buyAmountUSDT, usdtToSpend);
        assertEq(buyAmountBTC, expectedBtc);
        assertEq(sellAmountBTC, 0);
        assertEq(sellAmountUSDT, 0);
        assertEq(pnl, 0);
        assertTrue(active);
        assertEq(startTime, block.timestamp);
        assertEq(endTime, 0);

        // Step 3: Set BTC price to 66,000 USDT (10% profit)
        router.setBtcPrice(66_000 * 1e18);

        // Step 4: Execute Sell of Cycle 0
        uint256 expectedUsdtOut = 66_000 * 1e18;
        trader.executeSell(0, expectedUsdtOut, block.timestamp + 100);

        // Verify balances after sell
        (usdtBal, btcBal) = trader.getBalances();
        assertEq(usdtBal, expectedUsdtOut);
        assertEq(btcBal, 0);

        // Verify trade cycle completed
        assertFalse(trader.hasActiveCycle());
        assertEq(trader.activeCyclesCount(), 0);

        (
            ,
            ,
            ,
            sellAmountBTC,
            sellAmountUSDT,
            pnl,
            active,
            ,
            endTime
        ) = trader.getTradeCycle(0);

        assertEq(sellAmountBTC, expectedBtc);
        assertEq(sellAmountUSDT, expectedUsdtOut);
        assertEq(pnl, 6_000 * 1e18); // Profit of 6,000 USDT
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

        // Set BTC price to 60,000 USDT/BTC
        router.setBtcPrice(60_000 * 1e18);

        // Step 2: Buy
        trader.executeBuy(depositAmt, 1 * 1e18, block.timestamp + 100);

        // Set BTC price to 54,000 USDT/BTC (10% loss)
        router.setBtcPrice(54_000 * 1e18);

        // Step 3: Sell Cycle 0
        trader.executeSell(0, 54_000 * 1e18, block.timestamp + 100);

        // Verify trade cycle PnL
        (, , , , , int256 pnl, , , ) = trader.getTradeCycle(0);
        assertEq(pnl, -6_000 * 1e18); // Loss of 6,000 USDT
        assertEq(trader.totalPnL(), -6_000 * 1e18);
    }

    // --- Concurrent Trades & Out-of-Order Sells Test (Grid Trading) ---

    function testConcurrentTradesAndOutOfOrderSells() public {
        // Deposit 300,000 USDT
        uint256 depositAmt = 300_000 * 1e18;
        usdt.approve(address(trader), depositAmt);
        trader.depositUSDT(depositAmt);

        // Set BTC price to 60,000 USDT
        router.setBtcPrice(60_000 * 1e18);

        // Execute 5 buys consecutively
        for (uint256 i = 0; i < 5; i++) {
            trader.executeBuy(60_000 * 1e18, 1 * 1e18, block.timestamp + 100);
        }

        // Verify state
        assertEq(trader.activeCyclesCount(), 5);
        assertEq(trader.getTradeCyclesCount(), 5);
        
        (uint256 usdtBal, uint256 btcBal) = trader.getBalances();
        assertEq(usdtBal, 0);
        assertEq(btcBal, 5 * 1e18);

        uint256[] memory activeIdsBefore = trader.getActiveCycleIds();
        assertEq(activeIdsBefore.length, 5);
        for (uint256 i = 0; i < 5; i++) {
            assertEq(activeIdsBefore[i], i);
        }

        // Price increases: Sell Cycle 2 (out of order)
        router.setBtcPrice(70_000 * 1e18);
        trader.executeSell(2, 70_000 * 1e18, block.timestamp + 100);

        // Verify Cycle 2 state
        (,,,,, int256 pnl2, bool active2,,) = trader.getTradeCycle(2);
        assertFalse(active2);
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
        router.setBtcPrice(50_000 * 1e18);
        trader.executeSell(0, 50_000 * 1e18, block.timestamp + 100);

        // Verify Cycle 0 state
        (,,,,, int256 pnl0, bool active0,,) = trader.getTradeCycle(0);
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
        (usdtBal, btcBal) = trader.getBalances();
        assertEq(usdtBal, 120_000 * 1e18); // 70k + 50k
        assertEq(btcBal, 3 * 1e18); // 5 BTC - 2 BTC
    }

    // --- State Invariants & Boundary Tests ---

    function testCannotExceedMaxActiveCycles() public {
        uint256 depositAmt = 360_000 * 1e18;
        usdt.approve(address(trader), depositAmt);
        trader.depositUSDT(depositAmt);

        router.setBtcPrice(60_000 * 1e18);

        // Buy 5 cycles successfully
        for (uint256 i = 0; i < 5; i++) {
            trader.executeBuy(60_000 * 1e18, 1 * 1e18, block.timestamp + 100);
        }

        // The 6th buy should revert
        vm.expectRevert("AsterTrader: maximum concurrent active cycles reached");
        trader.executeBuy(60_000 * 1e18, 1 * 1e18, block.timestamp + 100);

        // Sell one cycle to free up space
        trader.executeSell(0, 60_000 * 1e18, block.timestamp + 100);
        assertEq(trader.activeCyclesCount(), 4);

        // Now the 6th buy (new index 5) should succeed
        trader.executeBuy(60_000 * 1e18, 1 * 1e18, block.timestamp + 100);
        assertEq(trader.activeCyclesCount(), 5);
        assertEq(trader.getTradeCyclesCount(), 6);
    }

    function testCannotSellInactiveCycle() public {
        uint256 depositAmt = 60_000 * 1e18;
        usdt.approve(address(trader), depositAmt);
        trader.depositUSDT(depositAmt);

        router.setBtcPrice(60_000 * 1e18);

        // Buy and then sell to close Cycle 0
        trader.executeBuy(60_000 * 1e18, 1 * 1e18, block.timestamp + 100);
        trader.executeSell(0, 60_000 * 1e18, block.timestamp + 100);

        // Attempting to sell Cycle 0 again should revert
        vm.expectRevert("AsterTrader: trade cycle is not active");
        trader.executeSell(0, 60_000 * 1e18, block.timestamp + 100);
    }

    function testCannotSellNonExistentCycle() public {
        vm.expectRevert("AsterTrader: invalid trade cycle ID");
        trader.executeSell(999, 50_000 * 1e18, block.timestamp + 100);
    }

    function testCannotBuyWithInsufficientUSDT() public {
        router.setBtcPrice(50_000 * 1e18);

        // Attempt buy without depositing USDT
        vm.expectRevert("AsterTrader: insufficient USDT in contract");
        trader.executeBuy(50_000 * 1e18, 1 * 1e18, block.timestamp + 100);
    }

    function testCannotSellWithInsufficientBTC() public {
        uint256 depositAmt = 50_000 * 1e18;
        usdt.approve(address(trader), depositAmt);
        trader.depositUSDT(depositAmt);

        router.setBtcPrice(50_000 * 1e18);

        // Buy 1 BTC (Cycle 0)
        trader.executeBuy(50_000 * 1e18, 1 * 1e18, block.timestamp + 100);

        // Owner withdraws the BTC directly from the contract
        trader.withdrawBTC(1 * 1e18);

        // Now attempt to sell Cycle 0 should fail because contract doesn't hold the BTC anymore
        vm.expectRevert("AsterTrader: insufficient BTC in contract");
        trader.executeSell(0, 50_000 * 1e18, block.timestamp + 100);
    }

    // --- Router Update Tests ---

    function testUpdateRouter_Owner() public {
        address newRouter = address(0x5678);
        trader.updateRouter(newRouter);
        assertEq(trader.asterRouter(), newRouter);
    }

    function testUpdateRouter_NonOwner_Reverts() public {
        address newRouter = address(0x5678);
        vm.prank(user);
        vm.expectRevert("AsterTrader: caller is not the owner");
        trader.updateRouter(newRouter);
    }
}
