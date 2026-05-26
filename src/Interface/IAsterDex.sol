// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

address constant ASTER_DEX = 0x1b6F2d3844C6ae7D56ceb3C3643b9060ba28FEb0;
address constant BTC_PAIR_BASE = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;
address constant USDT = 0x55d398326f99059fF775485246999027B3197955;

// ─────────────────────────────────────────────────────────────────────────────
// Aster DEX Trading Interface
//
// Contract address (BSC mainnet):
//   0x1b6F2d3844C6ae7D56ceb3C3643b9060ba28FEb0
//
// This is a Diamond (EIP-2535) proxy contract, so all facets share one address.
//
// Key addresses for BTC/USDT trading on BSC:
//   BTC  pairBase : 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c  (BTCB on BSC)
//   USDT tokenIn  : 0x55d398326f99059fF775485246999027B3197955  (BSC-USD / USDT)
//
// Decimal conventions (from official docs):
//   amountIn  – tokenIn native decimals  (USDT = 1e18, so 100 USDT = 100e18)
//   qty       – 1e10  (0.001 BTC = 1e7,  i.e. qty * 1e-10 = BTC amount)
//   price     – 1e8   (BTC at $65,000 → price = 6_500_000_000)
//   stopLoss  – 1e8
//   takeProfit– 1e8
//
// Execution flow for openMarketTrade:
//   1. You call openMarketTrade() → emits MarketPendingTrade
//   2. Aster's oracle callback fires → emits OpenMarketTrade (position live)
//      or PendingTradeRefund if rejected
//   3. To close: call closeTrade(tradeHash) → settlement is async via oracle
// ─────────────────────────────────────────────────────────────────────────────

interface IAsterDex {
    // ─── Core input struct ────────────────────────────────────────────────────
    //
    // Used by openMarketTrade, openMarketTradeBNB, and openLimitOrder.
    //
    struct OpenDataInput {
        // The "base" token of the pair, NOT the margin token.
        // For BTC/USDT this is BTC (BTCB): 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c
        address pairBase;

        // true  = Long  (buy BTC / profit when BTC rises)
        // false = Short (sell BTC / profit when BTC falls)
        bool isLong;

        // The margin token you deposit. For BTC/USDT trading use USDT:
        //   0x55d398326f99059fF775485246999027B3197955
        address tokenIn;

        // Margin amount in tokenIn's native decimals.
        // e.g. 100 USDT = 100 * 1e18 = 100000000000000000000
        uint96 amountIn;

        // Position size in BTC, expressed in 1e10 units.
        // e.g. 0.001 BTC = 0.001 * 1e10 = 10000000
        uint80 qty;

        // For market trades: the WORST acceptable execution price (slippage guard).
        // Set slightly below index for longs, above index for shorts.
        // Price is in 1e8. e.g. $65,000 = 6500000000
        // Tip: fetch index price from https://www.apollox.finance/fapi/v1/premiumIndex
        uint64 price;

        // Stop-loss price in 1e8. Pass 0 to disable.
        uint64 stopLoss;

        // Take-profit price in 1e8. Pass 0 to disable.
        uint64 takeProfit;

        // Broker/referral ID. Use 0 if you have no broker ID.
        uint24 broker;
    }

    // ─── Open a market trade (USDT margin) ───────────────────────────────────
    //
    // You must approve the Aster contract to spend your USDT before calling this.
    // IERC20(USDT).approve(0x1b6F2d3844C6ae7D56ceb3C3643b9060ba28FEb0, amountIn);
    //
    // Emits: MarketPendingTrade  (order submitted, awaiting oracle)
    // Then:  OpenMarketTrade     (position opened, contains tradeHash)
    //     or PendingTradeRefund  (rejected — price moved beyond slippage guard)
    //
    function openMarketTrade(OpenDataInput calldata data) external;

    // ─── Open a market trade paying BNB as margin ─────────────────────────────
    //
    // Alternative when tokenIn is the native BNB.
    // Send BNB as msg.value; set tokenIn = address(0) or the WBNB address.
    //
    function openMarketTradeBNB(OpenDataInput calldata data) external payable;

    // ─── Close an open position ───────────────────────────────────────────────
    //
    // tradeHash is the bytes32 identifier emitted in the OpenMarketTrade event.
    // Closure is also async: oracle confirms price, then settles PnL.
    //
    // Emits: CloseTradeSuccessful (contains closePrice, pnl, fees)
    //     or ExecuteCloseRejected (if close conditions can't be met)
    //
    function closeTrade(bytes32 tradeHash) external;

    // ─── Position management ──────────────────────────────────────────────────

    // Add extra margin to an open position (reduces liquidation risk).
    // amount is in 1e10 units (same scale as qty).
    function addMargin(bytes32 tradeHash, uint96 amount) external payable;

    // Update take-profit and stop-loss on an open position.
    function updateTradeTpAndSl(bytes32 tradeHash, uint64 takeProfit, uint64 stopLoss) external;

    function updateTradeTp(bytes32 tradeHash, uint64 takeProfit) external;
    function updateTradeSl(bytes32 tradeHash, uint64 stopLoss) external;

    // ─── Read positions ───────────────────────────────────────────────────────

    struct Position {
        bytes32 positionHash;
        string pair; // e.g. "BTC/USD"
        address pairBase;
        address marginToken;
        bool isLong;
        uint96 margin;
        uint80 qty;
        uint64 entryPrice;
        uint64 stopLoss;
        uint64 takeProfit;
        uint96 openFee;
        uint96 executionFee;
        int256 fundingFee;
        uint40 timestamp;
        uint96 holdingFee;
    }

    // Get all open positions for a user on a given pair.
    // Pass address(0) for pairBase to get positions across all pairs.
    function getPositionsV2(address user, address pairBase) external view returns (Position[] memory);

    // Get a single position by its trade hash.
    function getPositionByHashV2(bytes32 tradeHash) external view returns (Position memory);

    // ─── Price helpers ────────────────────────────────────────────────────────

    // Get the cached oracle price for a token (in 1e8).
    function getPrice(address token) external view returns (uint256);

    // ─── Events (for your contract to listen/index) ───────────────────────────

    event MarketPendingTrade(address indexed user, bytes32 indexed tradeHash, OpenDataInput data);

    event OpenMarketTrade(
        address indexed user,
        bytes32 indexed tradeHash,
        // Full OpenTrade struct emitted — use tradeHash for subsequent calls
        bytes ot // abi-encoded ITrading.OpenTrade — decode off-chain
    );

    event CloseTradeSuccessful(
        address indexed user,
        bytes32 indexed tradeHash,
        // closePrice, pnl, fees encoded in closeInfo tuple
        bytes closeInfo
    );
}

// ─────────────────────────────────────────────────────────────────────────────
// Example usage contract
// ─────────────────────────────────────────────────────────────────────────────

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

contract AsterBtcTrader {
    // ── Constants ──────────────────────────────────────────────────────────────
    IAsterDex public constant ASTER = IAsterDex(ASTER_DEX);

    address public immutable owner;

    constructor() {
        owner = msg.sender;
        // Pre-approve max so we don't need to approve each trade.
        IERC20(USDT).approve(address(ASTER), type(uint256).max);
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    // ── Open a BTC Long (buy BTC) ─────────────────────────────────────────────
    //
    // @param usdtMargin   Amount of USDT margin in 1e18. e.g. 100 USDT = 100e18
    // @param btcQty       BTC quantity in 1e10.         e.g. 0.001 BTC = 1e7
    // @param worstPrice   Worst acceptable price in 1e8. e.g. $65,000 = 6_500_000_000
    //                     For a long, set this BELOW current price to guard against
    //                     slippage (if oracle fills above worstPrice, tx reverts).
    //                     Tip: set to currentPrice * 101 / 100 for 1% slippage tolerance.
    // @param stopLoss     Stop-loss price in 1e8. Pass 0 to disable.
    // @param takeProfit   Take-profit price in 1e8. Pass 0 to disable.
    //
    function buyBtc(uint96 usdtMargin, uint80 btcQty, uint64 worstPrice, uint64 stopLoss, uint64 takeProfit)
        external
        onlyOwner
    {
        // Pull USDT from caller into this contract first
        IERC20(USDT).transferFrom(msg.sender, address(this), usdtMargin);

        ASTER.openMarketTrade(
            IAsterDex.OpenDataInput({
                pairBase: BTC_PAIR_BASE,
                isLong: true, // Long = buy BTC
                tokenIn: USDT,
                amountIn: usdtMargin,
                qty: btcQty,
                price: worstPrice,
                stopLoss: stopLoss,
                takeProfit: takeProfit,
                broker: 0 // no broker ID
            })
        );
    }

    // ── Open a BTC Short (sell BTC) ───────────────────────────────────────────
    //
    // @param worstPrice  For a short, set this ABOVE current price (slippage guard
    //                    means: reject if oracle fills below this price).
    //
    function sellBtc(uint96 usdtMargin, uint80 btcQty, uint64 worstPrice, uint64 stopLoss, uint64 takeProfit)
        external
        onlyOwner
    {
        IERC20(USDT).transferFrom(msg.sender, address(this), usdtMargin);

        ASTER.openMarketTrade(
            IAsterDex.OpenDataInput({
                pairBase: BTC_PAIR_BASE,
                isLong: false, // Short = sell BTC
                tokenIn: USDT,
                amountIn: usdtMargin,
                qty: btcQty,
                price: worstPrice,
                stopLoss: stopLoss,
                takeProfit: takeProfit,
                broker: 0
            })
        );
    }

    // ── Close any open position ────────────────────────────────────────────────
    //
    // tradeHash comes from the OpenMarketTrade event emitted after your open call.
    // Listen for it off-chain: event OpenMarketTrade(address indexed user, bytes32 indexed tradeHash, ...)
    //
    function closePosition(bytes32 tradeHash) external onlyOwner {
        ASTER.closeTrade(tradeHash);
    }

    // ── Read your open BTC positions ───────────────────────────────────────────
    function getMyBtcPositions() external view returns (IAsterDex.Position[] memory) {
        return ASTER.getPositionsV2(address(this), BTC_PAIR_BASE);
    }

    // ── Get current BTC oracle price (1e8) ────────────────────────────────────
    function getBtcPrice() external view returns (uint256) {
        return ASTER.getPrice(BTC_PAIR_BASE);
    }

    // ── Withdraw USDT from this contract ──────────────────────────────────────
    function withdrawUsdt(uint256 amount) external onlyOwner {
        IERC20(USDT).transferFrom(address(this), owner, amount);
    }
}
