// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
}

interface IAsterRouter {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

/**
 * @title AsterTrader
 * @notice Smart contract to manage USDT/BTC trading cycles on Aster DEX.
 * Handles deposits/withdrawals, concurrent trade executions (up to 5 active cycles),
 * and individual PnL tracking per trade cycle.
 */
contract AsterTrader {
    // Ownership
    address public owner;
    
    // Reentrancy status
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status;

    // Tokens & Router addresses
    address public usdtToken;
    address public btcToken;
    address public asterRouter;

    // Trade Cycle Tracking
    struct TradeCycle {
        uint256 id;
        uint256 buyAmountUSDT;    // USDT spent to buy BTC
        uint256 buyAmountBTC;     // BTC received from buying
        uint256 sellAmountBTC;    // BTC sold
        uint256 sellAmountUSDT;   // USDT received from selling
        int256 pnl;               // Profit or loss in USDT for this cycle
        bool active;              // True if bought but not yet closed
        uint256 startTime;        // Buy timestamp
        uint256 endTime;          // Sell timestamp
    }

    TradeCycle[] public tradeCycles;
    int256 public totalPnL;
    uint256 public activeCyclesCount; // Number of currently active trade cycles

    // Events
    event USDTDeposited(address indexed user, uint256 amount);
    event USDTWithdrawn(address indexed owner, uint256 amount);
    event BTCWithdrawn(address indexed owner, uint256 amount);
    event RouterUpdated(address indexed oldRouter, address indexed newRouter);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    event BoughtBTC(
        uint256 indexed cycleId,
        uint256 usdtSpent,
        uint256 btcReceived,
        uint256 timestamp
    );
    event SoldBTC(
        uint256 indexed cycleId,
        uint256 btcSold,
        uint256 usdtReceived,
        int256 pnl,
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

    /**
     * @param _usdtToken Address of USDT ERC-20 token
     * @param _btcToken Address of BTC ERC-20 token
     * @param _asterRouter Address of Aster DEX Router
     */
    constructor(address _usdtToken, address _btcToken, address _asterRouter) {
        require(_usdtToken != address(0), "AsterTrader: USDT address cannot be 0");
        require(_btcToken != address(0), "AsterTrader: BTC address cannot be 0");
        require(_asterRouter != address(0), "AsterTrader: Router address cannot be 0");
        
        owner = msg.sender;
        _status = _NOT_ENTERED;
        
        usdtToken = _usdtToken;
        btcToken = _btcToken;
        asterRouter = _asterRouter;
    }

    /**
     * @notice Deposit USDT into the contract for trading
     * @param amount The amount of USDT to deposit
     */
    function depositUSDT(uint256 amount) external nonReentrant {
        require(amount > 0, "AsterTrader: deposit amount must be > 0");
        _safeTransferFrom(usdtToken, msg.sender, address(this), amount);
        emit USDTDeposited(msg.sender, amount);
    }

    /**
     * @notice Withdraw USDT back to the owner
     * @param amount The amount of USDT to withdraw
     */
    function withdrawUSDT(uint256 amount) external onlyOwner nonReentrant {
        require(amount > 0, "AsterTrader: withdraw amount must be > 0");
        uint256 balance = IERC20(usdtToken).balanceOf(address(this));
        require(balance >= amount, "AsterTrader: insufficient USDT balance");
        _safeTransfer(usdtToken, owner, amount);
        emit USDTWithdrawn(owner, amount);
    }

    /**
     * @notice Withdraw BTC back to the owner
     * @param amount The amount of BTC to withdraw
     */
    function withdrawBTC(uint256 amount) external onlyOwner nonReentrant {
        require(amount > 0, "AsterTrader: withdraw amount must be > 0");
        uint256 balance = IERC20(btcToken).balanceOf(address(this));
        require(balance >= amount, "AsterTrader: insufficient BTC balance");
        _safeTransfer(btcToken, owner, amount);
        emit BTCWithdrawn(owner, amount);
    }

    /**
     * @notice Expose owner function to update the Aster Router address if it migrates
     * @param _newRouter Address of the new router
     */
    function updateRouter(address _newRouter) external onlyOwner {
        require(_newRouter != address(0), "AsterTrader: new router cannot be 0");
        emit RouterUpdated(asterRouter, _newRouter);
        asterRouter = _newRouter;
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
     * @notice Execute a swap of USDT to BTC on Aster (Buy) to start a trade cycle.
     * Supports up to 5 concurrent active trade cycles.
     * @param usdtAmount Amount of USDT to spend
     * @param minBtcOut Minimum amount of BTC expected to receive (slippage protection)
     * @param deadline Unix timestamp deadline for the trade
     */
    function executeBuy(
        uint256 usdtAmount,
        uint256 minBtcOut,
        uint256 deadline
    ) external onlyOwner nonReentrant returns (uint256 btcReceived) {
        require(usdtAmount > 0, "AsterTrader: buy amount must be > 0");
        require(activeCyclesCount < 5, "AsterTrader: maximum concurrent active cycles reached");
        
        uint256 contractUsdtBalance = IERC20(usdtToken).balanceOf(address(this));
        require(contractUsdtBalance >= usdtAmount, "AsterTrader: insufficient USDT in contract");

        // Approve Aster Router to spend USDT
        _safeApprove(usdtToken, asterRouter, usdtAmount);

        // Construct path: USDT -> BTC
        address[] memory path = new address[](2);
        path[0] = usdtToken;
        path[1] = btcToken;

        uint256 initialBtcBalance = IERC20(btcToken).balanceOf(address(this));

        // Call Aster Router swap
        IAsterRouter(asterRouter).swapExactTokensForTokens(
            usdtAmount,
            minBtcOut,
            path,
            address(this),
            deadline
        );

        uint256 newBtcBalance = IERC20(btcToken).balanceOf(address(this));
        btcReceived = newBtcBalance - initialBtcBalance;
        require(btcReceived >= minBtcOut, "AsterTrader: slippage too high");

        // Record the buy in a new TradeCycle
        uint256 cycleId = tradeCycles.length;
        tradeCycles.push(
            TradeCycle({
                id: cycleId,
                buyAmountUSDT: usdtAmount,
                buyAmountBTC: btcReceived,
                sellAmountBTC: 0,
                sellAmountUSDT: 0,
                pnl: 0,
                active: true,
                startTime: block.timestamp,
                endTime: 0
            })
        );

        activeCyclesCount++;

        emit BoughtBTC(cycleId, usdtAmount, btcReceived, block.timestamp);
    }

    /**
     * @notice Execute a swap of BTC to USDT on Aster (Sell) to end a specific trade cycle.
     * @param cycleId Unique identifier of the active trade cycle to end
     * @param minUsdtOut Minimum amount of USDT expected to receive (slippage protection)
     * @param deadline Unix timestamp deadline for the trade
     */
    function executeSell(
        uint256 cycleId,
        uint256 minUsdtOut,
        uint256 deadline
    ) external onlyOwner nonReentrant returns (uint256 usdtReceived) {
        require(cycleId < tradeCycles.length, "AsterTrader: invalid trade cycle ID");
        TradeCycle storage cycle = tradeCycles[cycleId];
        require(cycle.active, "AsterTrader: trade cycle is not active");

        uint256 btcAmount = cycle.buyAmountBTC;
        uint256 contractBtcBalance = IERC20(btcToken).balanceOf(address(this));
        require(contractBtcBalance >= btcAmount, "AsterTrader: insufficient BTC in contract");

        // Approve Aster Router to spend BTC
        _safeApprove(btcToken, asterRouter, btcAmount);

        // Construct path: BTC -> USDT
        address[] memory path = new address[](2);
        path[0] = btcToken;
        path[1] = usdtToken;

        uint256 initialUsdtBalance = IERC20(usdtToken).balanceOf(address(this));

        // Call Aster Router swap
        IAsterRouter(asterRouter).swapExactTokensForTokens(
            btcAmount,
            minUsdtOut,
            path,
            address(this),
            deadline
        );

        uint256 newUsdtBalance = IERC20(usdtToken).balanceOf(address(this));
        usdtReceived = newUsdtBalance - initialUsdtBalance;
        require(usdtReceived >= minUsdtOut, "AsterTrader: slippage too high");

        // Update trade cycle records
        cycle.sellAmountBTC = btcAmount;
        cycle.sellAmountUSDT = usdtReceived;
        cycle.endTime = block.timestamp;
        cycle.active = false;
        
        // Calculate PnL (profit/loss in USDT)
        int256 cyclePnL = int256(usdtReceived) - int256(cycle.buyAmountUSDT);
        cycle.pnl = cyclePnL;

        // Update global cumulative PnL and active cycles counter
        totalPnL += cyclePnL;
        activeCyclesCount--;

        emit SoldBTC(cycleId, btcAmount, usdtReceived, cyclePnL, block.timestamp);
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
        uint256 buyAmountUSDT,
        uint256 buyAmountBTC,
        uint256 sellAmountBTC,
        uint256 sellAmountUSDT,
        int256 pnl,
        bool active,
        uint256 startTime,
        uint256 endTime
    ) {
        require(index < tradeCycles.length, "AsterTrader: index out of bounds");
        TradeCycle memory cycle = tradeCycles[index];
        return (
            cycle.id,
            cycle.buyAmountUSDT,
            cycle.buyAmountBTC,
            cycle.sellAmountBTC,
            cycle.sellAmountUSDT,
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
            IERC20(usdtToken).balanceOf(address(this)),
            IERC20(btcToken).balanceOf(address(this))
        );
    }

    // Low-level helper functions to safely handle ERC-20 transfers (works with non-standard tokens like USDT)
    function _safeTransfer(address token, address to, uint256 value) internal {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0xa9059cbb, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "SafeERC20: transfer failed");
    }

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
