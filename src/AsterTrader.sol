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
        bytes32 tradeHash; // The unique hash of the position on Aster DEX
        uint256 startTime;
        uint256 endTime;
        int256 netCashFlow; // Realized net cash flow in USDT after all fees (18 decimals)
        uint96 marginUSDT; // USDT margin spent
        uint80 qtyBTC; // BTC quantity in 1e10
        uint64 entryPrice; // BTC price in 1e8 when opened
        uint64 exitPrice; // BTC price in 1e8 when closed
        bool active; // True if bought but not yet closed
    }

    TradeCycle[] public tradeCycles;
    int256 public totalNetCashFlow;
    uint256 public activeCyclesCount; // Number of currently active trade cycles

    // Active cycle ID tracking (for O(1) active cycle lookup)
    uint256[] public activeCycleIds;

    // Track used trade hashes to prevent mismatches
    mapping(bytes32 => bool) public tradeHashUsed;

    // Events
    event USDTDeposited(address indexed user, uint256 amount);
    event USDTWithdrawn(address indexed owner, uint256 amount);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    event BoughtBTC(uint256 indexed cycleId, uint96 usdtMargin, uint80 btcQty, uint256 timestamp);
    event SoldBTC(uint256 indexed cycleId, uint80 btcSold, uint256 usdtReceived, int256 netCashFlow, uint256 timestamp);
    event CloseInitiated(uint256 indexed cycleId, bytes32 indexed tradeHash, uint256 timestamp);
    event ForceClosed(uint256 indexed cycleId, bytes32 indexed tradeHash, uint256 timestamp);

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
        // Pre-approve Aster DEX to spend USDT margin up to max value
        _safeApprove(USDT, ASTER_DEX, type(uint256).max);
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
     * @notice Rescue any non-USDT tokens stuck in the contract
     * @param token The token address to rescue
     * @param amount The amount to rescue
     */
    function rescueToken(address token, uint256 amount) external onlyOwner nonReentrant {
        require(token != USDT, "AsterTrader: cannot rescue USDT");
        require(amount > 0, "AsterTrader: rescue amount must be > 0");
        uint256 balance = IERC20(token).balanceOf(address(this));
        require(balance >= amount, "AsterTrader: insufficient balance to rescue");
        _safeTransfer(token, owner, amount);
        emit TokenRescued(token, owner, amount);
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
    function executeBuy(uint96 usdtMargin, uint80 btcQty, uint64 worstPrice, uint64 stopLoss, uint64 takeProfit)
        external
        onlyOwner
        nonReentrant
        returns (uint256 cycleId)
    {
        require(usdtMargin > 0, "AsterTrader: buy amount must be > 0");
        require(activeCyclesCount < 5, "AsterTrader: maximum concurrent active cycles reached");

        uint256 contractUsdtBalance = IERC20(USDT).balanceOf(address(this));
        require(contractUsdtBalance >= usdtMargin, "AsterTrader: insufficient USDT in contract");

        // Call Aster DEX (USDT already pre-approved in constructor)
        IAsterDex(ASTER_DEX)
            .openMarketTrade(
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
                tradeHash: bytes32(0), // Set during close
                marginUSDT: usdtMargin,
                qtyBTC: btcQty,
                entryPrice: 0,
                exitPrice: 0,
                netCashFlow: 0,
                active: true,
                startTime: block.timestamp,
                endTime: 0
            })
        );

        activeCycleIds.push(cycleId);
        activeCyclesCount++;

        emit BoughtBTC(cycleId, usdtMargin, btcQty, block.timestamp);
    }

    /**
     * @notice Execute closing of a trade on Aster (Sell) to end a specific trade cycle.
     * Integrates dual execution (auto-settles synchronously in tests/mocks; records pending-close in mainnet).
     * @param cycleId Unique identifier of the active trade cycle to end
     * @param tradeHash Unique transaction hash of the position on Aster DEX
     */
    function executeSell(uint256 cycleId, bytes32 tradeHash) external onlyOwner nonReentrant {
        require(cycleId < tradeCycles.length, "AsterTrader: invalid trade cycle ID");
        TradeCycle storage cycle = tradeCycles[cycleId];
        require(cycle.active, "AsterTrader: trade cycle is not active");

        // Verify/set tradeHash
        if (cycle.tradeHash == bytes32(0)) {
            require(tradeHash != bytes32(0), "AsterTrader: tradeHash cannot be empty");
            require(!tradeHashUsed[tradeHash], "AsterTrader: tradeHash already used");
            cycle.tradeHash = tradeHash;
            tradeHashUsed[tradeHash] = true;
        } else {
            require(cycle.tradeHash == tradeHash, "AsterTrader: tradeHash mismatch");
        }

        // Query position details from Aster to verify it exists and belongs to us
        IAsterDex.Position memory pos = IAsterDex(ASTER_DEX).getPositionByHashV2(tradeHash);
        require(pos.margin > 0, "AsterTrader: position not found on Aster");
        require(pos.marginToken == USDT, "AsterTrader: invalid margin token");
        require(pos.pairBase == BTC_PAIR_BASE, "AsterTrader: invalid pairBase");

        cycle.qtyBTC = pos.qty;
        cycle.entryPrice = pos.entryPrice;

        // Call Aster DEX to close trade
        IAsterDex(ASTER_DEX).closeTrade(tradeHash);

        emit CloseInitiated(cycleId, tradeHash, block.timestamp);
    }

    /**
     * @notice Finalize trade cycle and record net cash flow once oracle settles asynchronously
     * @param cycleId Unique identifier of the trade cycle
     * @param actualUsdtReceived Actual USDT amount received from Aster DEX (18 decimals)
     * @param exitPrice Execution price from Oracle (8 decimals)
     */
    function settleClose(uint256 cycleId, uint256 actualUsdtReceived, uint64 exitPrice)
        external
        onlyOwner
        nonReentrant
    {
        require(cycleId < tradeCycles.length, "AsterTrader: invalid trade cycle ID");
        TradeCycle storage cycle = tradeCycles[cycleId];
        require(cycle.active, "AsterTrader: trade cycle is not active");

        cycle.endTime = block.timestamp;
        cycle.active = false;
        cycle.exitPrice = exitPrice;

        int256 cycleNetCashFlow = SafeCast.toInt256(actualUsdtReceived) - int256(uint256(cycle.marginUSDT));
        cycle.netCashFlow = cycleNetCashFlow;

        totalNetCashFlow += cycleNetCashFlow;
        _removeFromActiveIds(cycleId);
        activeCyclesCount--;

        emit SoldBTC(cycleId, cycle.qtyBTC, actualUsdtReceived, cycleNetCashFlow, block.timestamp);
    }

    /**
     * @notice Force mark a trade cycle closed if it was closed/liquidated on Aster directly
     * @param cycleId Unique identifier of the trade cycle
     */
    function forceMarkClosed(uint256 cycleId) external onlyOwner nonReentrant {
        _forceMarkClosed(cycleId, bytes32(0));
    }

    /**
     * @notice Force mark a trade cycle closed with specific tradeHash if not already associated
     * @param cycleId Unique identifier of the trade cycle
     * @param tradeHash Trade hash from Aster DEX
     */
    function forceMarkClosed(uint256 cycleId, bytes32 tradeHash) external onlyOwner nonReentrant {
        _forceMarkClosed(cycleId, tradeHash);
    }

    /**
     * @notice Associate a trade hash with an active trade cycle
     * @param cycleId Unique identifier of the trade cycle
     * @param tradeHash Trade hash from Aster DEX
     */
    function setTradeHash(uint256 cycleId, bytes32 tradeHash) external onlyOwner {
        require(cycleId < tradeCycles.length, "AsterTrader: invalid trade cycle ID");
        TradeCycle storage cycle = tradeCycles[cycleId];
        require(cycle.active, "AsterTrader: trade cycle is not active");
        require(cycle.tradeHash == bytes32(0), "AsterTrader: tradeHash already set");
        require(tradeHash != bytes32(0), "AsterTrader: tradeHash cannot be empty");
        require(!tradeHashUsed[tradeHash], "AsterTrader: tradeHash already used");

        cycle.tradeHash = tradeHash;
        tradeHashUsed[tradeHash] = true;
    }

    /**
     * @notice Internal helper to force mark a cycle closed
     */
    function _forceMarkClosed(uint256 cycleId, bytes32 tradeHash) internal {
        require(cycleId < tradeCycles.length, "AsterTrader: invalid trade cycle ID");
        TradeCycle storage cycle = tradeCycles[cycleId];
        require(cycle.active, "AsterTrader: trade cycle is not active");

        if (cycle.tradeHash == bytes32(0)) {
            require(tradeHash != bytes32(0), "AsterTrader: tradeHash required");
            require(!tradeHashUsed[tradeHash], "AsterTrader: tradeHash already used");
            cycle.tradeHash = tradeHash;
            tradeHashUsed[tradeHash] = true;
        } else {
            if (tradeHash != bytes32(0)) {
                require(cycle.tradeHash == tradeHash, "AsterTrader: tradeHash mismatch");
            }
        }

        IAsterDex.Position memory pos = IAsterDex(ASTER_DEX).getPositionByHashV2(cycle.tradeHash);
        require(pos.margin == 0, "AsterTrader: Aster position is not gone");

        cycle.endTime = block.timestamp;
        cycle.active = false;

        _removeFromActiveIds(cycleId);
        activeCyclesCount--;

        emit ForceClosed(cycleId, cycle.tradeHash, block.timestamp);
    }

    /**
     * @notice Internal helper to remove a cycleId from the activeCycleIds array
     */
    function _removeFromActiveIds(uint256 cycleId) internal {
        uint256 len = activeCycleIds.length;
        for (uint256 i = 0; i < len; i++) {
            if (activeCycleIds[i] == cycleId) {
                activeCycleIds[i] = activeCycleIds[len - 1];
                activeCycleIds.pop();
                break;
            }
        }
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
    function getTradeCycle(uint256 index)
        external
        view
        returns (
            uint256 id,
            bytes32 tradeHash,
            uint96 marginUSDT,
            uint80 qtyBTC,
            uint64 entryPrice,
            uint64 exitPrice,
            int256 netCashFlow,
            bool active,
            uint256 startTime,
            uint256 endTime
        )
    {
        require(index < tradeCycles.length, "AsterTrader: index out of bounds");
        TradeCycle memory cycle = tradeCycles[index];
        return (
            index, // id is derived from index
            cycle.tradeHash,
            cycle.marginUSDT,
            cycle.qtyBTC,
            cycle.entryPrice,
            cycle.exitPrice,
            cycle.netCashFlow,
            cycle.active,
            cycle.startTime,
            cycle.endTime
        );
    }

    /**
     * @notice Checks if there is currently any active trade cycles
     */
    function hasActiveCycle() external view returns (bool) {
        return activeCyclesCount > 0;
    }

    /**
     * @notice Returns array of all active cycle IDs
     */
    function getActiveCycleIds() external view returns (uint256[] memory) {
        return activeCycleIds;
    }

    /**
     * @notice View the current token balances in the contract
     */
    function getBalances() external view returns (uint256 usdtBalance, uint256 btcBalance) {
        return (IERC20(USDT).balanceOf(address(this)), IERC20(BTC_PAIR_BASE).balanceOf(address(this)));
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
