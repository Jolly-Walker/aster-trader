// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IAsterDex, USDT, BTC_PAIR_BASE} from "../src/Interface/IAsterDex.sol";

contract MockUSDT {
    string public constant name = "Mock USDT";
    string public constant symbol = "USDT";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function transfer(address to, uint256 value) public returns (bool) {
        require(balanceOf[msg.sender] >= value, "MockERC20: insufficient balance");
        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;
        emit Transfer(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint256 value) public returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) public returns (bool) {
        require(balanceOf[from] >= value, "MockERC20: insufficient balance");
        if (allowance[from][msg.sender] != type(uint256).max) {
            require(allowance[from][msg.sender] >= value, "MockERC20: insufficient allowance");
            allowance[from][msg.sender] -= value;
        }
        balanceOf[from] -= value;
        balanceOf[to] += value;
        emit Transfer(from, to, value);
        return true;
    }

    function mint(address to, uint256 value) public {
        totalSupply += value;
        balanceOf[to] += value;
        emit Transfer(address(0), to, value);
    }
}

contract MockBTC {
    string public constant name = "Mock BTC";
    string public constant symbol = "BTC";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function transfer(address to, uint256 value) public returns (bool) {
        require(balanceOf[msg.sender] >= value, "MockERC20: insufficient balance");
        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;
        emit Transfer(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint256 value) public returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) public returns (bool) {
        require(balanceOf[from] >= value, "MockERC20: insufficient balance");
        if (allowance[from][msg.sender] != type(uint256).max) {
            require(allowance[from][msg.sender] >= value, "MockERC20: insufficient allowance");
            allowance[from][msg.sender] -= value;
        }
        balanceOf[from] -= value;
        balanceOf[to] += value;
        emit Transfer(from, to, value);
        return true;
    }

    function mint(address to, uint256 value) public {
        totalSupply += value;
        balanceOf[to] += value;
        emit Transfer(address(0), to, value);
    }
}

contract MockAsterDex is IAsterDex {
    uint256 public btcPrice; // BTC price in 1e8. e.g. 60,000 * 1e8
    uint256 private nonce;

    mapping(bytes32 => Position) public positions;
    mapping(address => bytes32[]) public userPositions;

    constructor() {
        btcPrice = 60000 * 1e8; // Default: 60,000 USD (in 1e8)
    }

    function setBtcPrice(uint256 newPrice) external {
        btcPrice = newPrice;
    }

    function openMarketTrade(OpenDataInput calldata data) external override {
        require(data.amountIn > 0, "MockAsterDex: zero amount");
        require(data.tokenIn == USDT, "MockAsterDex: invalid margin token");
        require(data.pairBase == BTC_PAIR_BASE, "MockAsterDex: invalid pairBase");

        // Pull USDT margin from the sender (AsterTrader)
        MockUSDT(USDT).transferFrom(msg.sender, address(this), data.amountIn);

        // Generate unique tradeHash
        bytes32 tradeHash = keccak256(abi.encodePacked(msg.sender, nonce, data.qty));
        nonce++;

        // Save position details
        positions[tradeHash] = Position({
            positionHash: tradeHash,
            pair: "BTC/USDT",
            pairBase: data.pairBase,
            marginToken: data.tokenIn,
            isLong: data.isLong,
            margin: data.amountIn,
            qty: data.qty,
            entryPrice: uint64(btcPrice),
            stopLoss: data.stopLoss,
            takeProfit: data.takeProfit,
            openFee: 0,
            executionFee: 0,
            fundingFee: 0,
            timestamp: uint40(block.timestamp),
            holdingFee: 0
        });

        userPositions[msg.sender].push(tradeHash);

        emit MarketPendingTrade(msg.sender, tradeHash, data);
        emit OpenMarketTrade(msg.sender, tradeHash, "");
    }

    // Unused but declared in interface
    function openMarketTradeBNB(OpenDataInput calldata data) external payable override {}

    function closeTrade(bytes32 tradeHash) external override {
        Position memory pos = positions[tradeHash];
        require(pos.margin > 0, "MockAsterDex: position not found");

        // Calculate realized PnL
        // price (8 decimals) * qty (10 decimals) = PnL (18 decimals)
        int256 priceDiff;
        if (pos.isLong) {
            priceDiff = int256(btcPrice) - int256(uint256(pos.entryPrice));
        } else {
            priceDiff = int256(uint256(pos.entryPrice)) - int256(btcPrice);
        }

        int256 pnl = priceDiff * int256(uint256(pos.qty));
        int256 payout = int256(uint256(pos.margin)) + pnl;
        if (payout < 0) {
            payout = 0;
        }

        // Delete position records
        delete positions[tradeHash];

        // Remove hash from user list
        bytes32[] storage hashes = userPositions[msg.sender];
        for (uint256 i = 0; i < hashes.length; i++) {
            if (hashes[i] == tradeHash) {
                hashes[i] = hashes[hashes.length - 1];
                hashes.pop();
                break;
            }
        }

        // Send payout back to caller
        if (payout > 0) {
            MockUSDT(USDT).transfer(msg.sender, uint256(payout));
        }

        emit CloseTradeSuccessful(msg.sender, tradeHash, "");
    }

    function addMargin(bytes32 tradeHash, uint96 amount) external payable override {}
    function updateTradeTpAndSl(bytes32 tradeHash, uint64 takeProfit, uint64 stopLoss) external override {}
    function updateTradeTp(bytes32 tradeHash, uint64 takeProfit) external override {}
    function updateTradeSl(bytes32 tradeHash, uint64 stopLoss) external override {}

    function getPositionsV2(address user, address pairBase) external view override returns (Position[] memory) {
        bytes32[] memory hashes = userPositions[user];

        // Count matching pairs
        uint256 count = 0;
        for (uint256 i = 0; i < hashes.length; i++) {
            if (pairBase == address(0) || positions[hashes[i]].pairBase == pairBase) {
                count++;
            }
        }

        Position[] memory result = new Position[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < hashes.length; i++) {
            if (pairBase == address(0) || positions[hashes[i]].pairBase == pairBase) {
                result[index] = positions[hashes[i]];
                index++;
            }
        }
        return result;
    }

    function getPositionByHashV2(bytes32 tradeHash) external view override returns (Position memory) {
        return positions[tradeHash];
    }

    function getPrice(address token) external view override returns (uint256) {
        if (token == BTC_PAIR_BASE) {
            return btcPrice;
        }
        return 1e8; // Default mock price
    }
}
