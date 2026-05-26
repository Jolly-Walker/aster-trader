// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

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

contract MockAsterRouter {
    address public usdt;
    address public btc;
    uint256 public btcPriceInUsdt; // 1 BTC = btcPriceInUsdt USDT (both using 18 decimals)

    constructor(address _usdt, address _btc) {
        usdt = _usdt;
        btc = _btc;
        btcPriceInUsdt = 60000 * 1e18; // Default: 60,000 USDT per BTC
    }

    function setBtcPrice(uint256 newPrice) external {
        btcPriceInUsdt = newPrice;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts) {
        require(deadline >= block.timestamp, "MockAsterRouter: expired");
        require(path.length == 2, "MockAsterRouter: invalid path length");
        
        address tokenIn = path[0];
        address tokenOut = path[1];
        require(tokenIn == usdt || tokenIn == btc, "MockAsterRouter: invalid input token");
        require(tokenOut == usdt || tokenOut == btc, "MockAsterRouter: invalid output token");
        require(tokenIn != tokenOut, "MockAsterRouter: identical tokens");

        amounts = new uint256[](2);
        amounts[0] = amountIn;

        // Pull the input tokens from sender
        MockERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);

        uint256 amountOut;
        if (tokenIn == usdt && tokenOut == btc) {
            // Swap USDT -> BTC
            // amountOut = amountIn * 1e18 / btcPriceInUsdt
            amountOut = (amountIn * 1e18) / btcPriceInUsdt;
        } else {
            // Swap BTC -> USDT
            // amountOut = amountIn * btcPriceInUsdt / 1e18
            amountOut = (amountIn * btcPriceInUsdt) / 1e18;
        }

        require(amountOut >= amountOutMin, "MockAsterRouter: slippage limit exceeded");
        amounts[1] = amountOut;

        // Send output tokens to recipient
        MockERC20(tokenOut).transfer(to, amountOut);
    }
}
