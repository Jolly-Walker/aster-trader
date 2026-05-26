// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IAsterDex, IERC20, ASTER_DEX, BTC_PAIR_BASE, USDT} from "./Interface/IAsterDex.sol";

/**
 * @title AsterTrader
 * @notice Smart contract to manage USDT/BTC trading cycles on Aster DEX.
 * Handles deposits/withdrawals, concurrent trade executions (up to 5 active cycles) using IAsterDex constants.
 */
contract AsterTrader {
    // Ownership
    address public owner;
    
    // Reentrancy status
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status;

    // Trade Cycle Tracking
    struct TradeCycle {
        uint256 id;
        bytes32 tradeHash;       // The unique hash of the position on Aster DEX
        uint96 marginUSDT;       // USDT margin spent
        uint80 qtyBTC;           // BTC quantity in 1e10
        uint64 entryPrice;       // BTC price in 1e8 when opened
        uint64 exitPrice;        // BTC price in 1e8 when closed
        int256 pnl;              // Realized PnL in USDT (18 decimals)
        bool active;             // True if bought but not yet closed
        uint256 startTime;
        uint256 endTime;
    }

    TradeCycle[] public tradeCycles;
    int256 public totalPnL;
    uint256 public activeCyclesCount; // Number of currently active trade cycles

    // Events
    event USDTDeposited(address indexed user, uint256 amount);
    event USDTWithdrawn(address indexed owner, uint256 amount);
    event BTCWithdrawn(address indexed owner, uint256 amount);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    event BoughtBTC(
        uint256 indexed cycleId,
        uint96 usdtMargin,
        uint80 btcQty,
        uint256 timestamp
    );
    event SoldBTC(
        uint256 indexed cycleId,
        uint80 btcSold,
        uint256 usdtReceived,
        int256 pnl,
        uint256 timestamp
    );
    event CloseInitiated(
        uint256 indexed cycleId,
        bytes32 indexed tradeHash,
        uint256 timestamp
    );

    modifier onlyOwner() {
        require(msg.sender == owner, "AsterTrader: caller is not the owner");
        _;
    }

    modifier nonReentrant() {
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    constructor() {
        owner = msg.sender;
        _status = _NOT_ENTERED;
    }

    /**
     * @notice Deposit USDT into the contract for trading
     * @param amount The amount of USDT to deposit
     */
    function depositUSDT(uint256 amount) external nonReentrant {
        require(amount > 0, "AsterTrader: deposit amount must be > 0");
        _safeTransferFrom(USDT, msg.sender, address(this), amount);
        emit USDTDeposited(msg.sender, amount);
    }

    /**
     * @notice Withdraw USDT back to the owner
     * @param amount The amount of USDT to withdraw
     */
    function withdrawUSDT(uint256 amount) external onlyOwner nonReentrant {
        require(amount > 0, "AsterTrader: withdraw amount must be > 0");
        uint256 balance = IERC20(USDT).balanceOf(address(this));
        require(balance >= amount, "AsterTrader: insufficient USDT balance");
        _safeTransfer(USDT, owner, amount);
        emit USDTWithdrawn(owner, amount);
    }

    /**
     * @notice Withdraw BTC back to the owner (if direct BTC payout occurs)
     * @param amount The amount of BTC to withdraw
     */
    function withdrawBTC(uint256 amount) external onlyOwner nonReentrant {
        require(amount > 0, "AsterTrader: withdraw amount must be > 0");
        uint256 balance = IERC20(BTC_PAIR_BASE).balanceOf(address(this));
        require(balance >= amount, "AsterTrader: insufficient BTC balance");
        _safeTransfer(BTC_PAIR_BASE, owner, amount);
        emit BTCWithdrawn(owner, amount);
    }

    /**
     * @notice Transfers ownership of the contract
     * @param newOwner Address of the new owner
     */
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "AsterTrader: new owner cannot be 0");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    /**
     * @notice Execute a swap of USDT to BTC on Aster (Buy Long) to start a trade cycle.
     * Supports up to 5 concurrent active trade cycles.
     * @param usdtMargin Amount of USDT margin to spend (18 decimals)
     * @param btcQty BTC position quantity (10 decimals)
     * @param worstPrice Worst acceptable price for long (8 decimals)
     * @param stopLoss Stop loss price (8 decimals, 0 to disable)
     * @param takeProfit Take profit price (8 decimals, 0 to disable)
     */
    function executeBuy(
        uint96 usdtMargin,
        uint80 btcQty,
        uint64 worstPrice,
        uint64 stopLoss,
        uint64 takeProfit
    ) external onlyOwner nonReentrant returns (uint256 cycleId) {
        require(usdtMargin > 0, "AsterTrader: buy amount must be > 0");
        require(activeCyclesCount < 5, "AsterTrader: maximum concurrent active cycles reached");
        
        uint256 contractUsdtBalance = IERC20(USDT).balanceOf(address(this));
        require(contractUsdtBalance >= usdtMargin, "AsterTrader: insufficient USDT in contract");

        // Approve Aster DEX to spend USDT margin
        _safeApprove(USDT, ASTER_DEX, usdtMargin);

        // Call Aster DEX
        IAsterDex(ASTER_DEX).openMarketTrade(
            IAsterDex.OpenDataInput({
                pairBase: BTC_PAIR_BASE,
                isLong: true,
                tokenIn: USDT,
                amountIn: usdtMargin,
                qty: btcQty,
                price: worstPrice,
                stopLoss: stopLoss,
                takeProfit: takeProfit,
                broker: 0
            })
        );

        cycleId = tradeCycles.length;
        tradeCycles.push(
            TradeCycle({
                id: cycleId,
                tradeHash: bytes32(0), // Set during close
                marginUSDT: usdtMargin,
                qtyBTC: btcQty,
                entryPrice: 0,
                exitPrice: 0,
                pnl: 0,
                active: true,
                startTime: block.timestamp,
                endTime: 0
            })
        );

        activeCyclesCount++;

        emit BoughtBTC(cycleId, usdtMargin, btcQty, block.timestamp);
    }

    /**
     * @notice Execute closing of a trade on Aster (Sell) to end a specific trade cycle.
     * Integrates dual execution (auto-settles synchronously in tests/mocks; records pending-close in mainnet).
     * @param cycleId Unique identifier of the active trade cycle to end
     * @param tradeHash Unique transaction hash of the position on Aster DEX
     */
    function executeSell(
        uint256 cycleId,
        bytes32 tradeHash
    ) external onlyOwner nonReentrant returns (uint256 usdtReceived) {
        require(cycleId < tradeCycles.length, "AsterTrader: invalid trade cycle ID");
        TradeCycle storage cycle = tradeCycles[cycleId];
        require(cycle.active, "AsterTrader: trade cycle is not active");

        // Query position details from Aster to verify it exists and belongs to us
        IAsterDex.Position memory pos = IAsterDex(ASTER_DEX).getPositionByHashV2(tradeHash);
        require(pos.margin > 0, "AsterTrader: position not found on Aster");
        require(pos.marginToken == USDT, "AsterTrader: invalid margin token");
        require(pos.pairBase == BTC_PAIR_BASE, "AsterTrader: invalid pairBase");

        cycle.tradeHash = tradeHash;
        cycle.qtyBTC = pos.qty;
        cycle.entryPrice = pos.entryPrice;

        uint256 balanceBefore = IERC20(USDT).balanceOf(address(this));

        // Call Aster DEX to close trade
        IAsterDex(ASTER_DEX).closeTrade(tradeHash);

        uint256 balanceAfter = IERC20(USDT).balanceOf(address(this));

        // Verify if the position has been cleared from Aster DEX storage immediately (synchronous mock check)
        IAsterDex.Position memory posAfter = IAsterDex(ASTER_DEX).getPositionByHashV2(tradeHash);
        bool isCleared = (posAfter.margin == 0);

        if (isCleared) {
            // Synchronous settlement (Mock / Test execution)
            usdtReceived = balanceAfter > balanceBefore ? (balanceAfter - balanceBefore) : 0;
            
            cycle.endTime = block.timestamp;
            cycle.active = false;
            cycle.exitPrice = uint64(IAsterDex(ASTER_DEX).getPrice(BTC_PAIR_BASE));

            int256 cyclePnL = int256(usdtReceived) - int256(uint256(cycle.marginUSDT));
            cycle.pnl = cyclePnL;

            totalPnL += cyclePnL;
            activeCyclesCount--;

            emit SoldBTC(cycleId, pos.qty, usdtReceived, cyclePnL, block.timestamp);
        } else {
            // Asynchronous settlement (BSC Mainnet)
            emit CloseInitiated(cycleId, tradeHash, block.timestamp);
        }
    }

    /**
     * @notice Finalize trade cycle and record PnL on contract once oracle settles asynchronously
     * @param cycleId Unique identifier of the trade cycle
     * @param actualUsdtReceived Actual USDT amount received from Aster DEX (18 decimals)
     * @param exitPrice Execution price from Oracle (8 decimals)
     */
    function settleClose(
        uint256 cycleId,
        uint256 actualUsdtReceived,
        uint64 exitPrice
    ) external onlyOwner nonReentrant {
        require(cycleId < tradeCycles.length, "AsterTrader: invalid trade cycle ID");
        TradeCycle storage cycle = tradeCycles[cycleId];
        require(cycle.active, "AsterTrader: trade cycle is not active");

        cycle.endTime = block.timestamp;
        cycle.active = false;
        cycle.exitPrice = exitPrice;

        int256 cyclePnL = int256(actualUsdtReceived) - int256(uint256(cycle.marginUSDT));
        cycle.pnl = cyclePnL;

        totalPnL += cyclePnL;
        activeCyclesCount--;

        emit SoldBTC(cycleId, cycle.qtyBTC, actualUsdtReceived, cyclePnL, block.timestamp);
    }

    /**
     * @notice View function to get the total number of trade cycles (active and inactive)
     */
    function getTradeCyclesCount() external view returns (uint256) {
        return tradeCycles.length;
    }

    /**
     * @notice View function to get a specific trade cycle detail
     * @param index The index of the cycle in the array
     */
    function getTradeCycle(uint256 index) external view returns (
        uint256 id,
        bytes32 tradeHash,
        uint96 marginUSDT,
        uint80 qtyBTC,
        uint64 entryPrice,
        uint64 exitPrice,
        int256 pnl,
        bool active,
        uint256 startTime,
        uint256 endTime
    ) {
        require(index < tradeCycles.length, "AsterTrader: index out of bounds");
        TradeCycle memory cycle = tradeCycles[index];
        return (
            cycle.id,
            cycle.tradeHash,
            cycle.marginUSDT,
            cycle.qtyBTC,
            cycle.entryPrice,
            cycle.exitPrice,
            cycle.pnl,
            cycle.active,
            cycle.startTime,
            cycle.endTime
        );
    }

    /**
     * @notice Checks if there is currently any active trade cycles
     */
    function hasActiveCycle() public view returns (bool) {
        return activeCyclesCount > 0;
    }

    /**
     * @notice Returns array of all active cycle IDs
     */
    function getActiveCycleIds() external view returns (uint256[] memory) {
        uint256[] memory activeIds = new uint256[](activeCyclesCount);
        uint256 count = 0;
        for (uint256 i = 0; i < tradeCycles.length; i++) {
            if (tradeCycles[i].active) {
                activeIds[count] = i;
                count++;
            }
        }
        return activeIds;
    }

    /**
     * @notice View the current token balances in the contract
     */
    function getBalances() external view returns (uint256 usdtBalance, uint256 btcBalance) {
        return (
            IERC20(USDT).balanceOf(address(this)),
            IERC20(BTC_PAIR_BASE).balanceOf(address(this))
        );
    }

    /**
     * @notice Helper to fetch all open positions of this trader from Aster directly
     */
    function getMyPositions() external view returns (IAsterDex.Position[] memory) {
        return IAsterDex(ASTER_DEX).getPositionsV2(address(this), BTC_PAIR_BASE);
    }

    // Low-level helper functions to safely handle ERC-20 transfers (works with non-standard tokens like USDT)
    function _safeTransfer(address token, address to, uint256 value) internal {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0xa9059cbb, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "SafeERC20: transfer failed");
    }

    // Low-level helper function for transferFrom
    function _safeTransferFrom(address token, address from, address to, uint256 value) internal {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x23b872dd, from, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "SafeERC20: transferFrom failed");
    }

    // Safely handles approve. Sets approval to 0 first to prevent ERC-20 race conditions (required by USDT)
    function _safeApprove(address token, address spender, uint256 value) internal {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x095ea7b3, spender, 0));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "SafeERC20: approve reset failed");
        
        (success, data) = token.call(abi.encodeWithSelector(0x095ea7b3, spender, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "SafeERC20: approve value failed");
    }
}
