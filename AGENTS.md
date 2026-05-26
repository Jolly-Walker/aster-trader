# Aster Trader Agent Guide

This repository contains the smart contracts and scripts for **AsterTrader**, an automated trading system that executes USDT/BTC perpetual perps on the **Aster DEX** platform. It is configured to support grid-trading style features (with up to 5 concurrent active trade cycles) and handles the asynchronous oracle-based settlement mechanism of Aster DEX.

---

## 📁 Project Structure

The project is structured as follows:

* **Contracts & Interfaces:**
  * [AsterTrader.sol](file:///Users/jollywalker/Documents/coding/aster-trader/src/AsterTrader.sol): Main trading contract that manages deposits, withdrawals, grid tracking, and trade execution.
  * [IAsterDex.sol](file:///Users/jollywalker/Documents/coding/aster-trader/src/Interface/IAsterDex.sol): Facet interface and constants used for routing orders to Aster DEX.
* **Testing & Mocks:**
  * [AsterTrader.t.sol](file:///Users/jollywalker/Documents/coding/aster-trader/test/AsterTrader.t.sol): Complete test suite with 12 unit tests validating synchronous and asynchronous settlement flow, PnL math, and out-of-order execution.
  * [Mocks.sol](file:///Users/jollywalker/Documents/coding/aster-trader/test/Mocks.sol): Mock implementations of USDT, BTC, and Aster DEX for local integration testing.
* **Deployment Scripts:**
  * [DeployAsterTrader.s.sol](file:///Users/jollywalker/Documents/coding/aster-trader/script/DeployAsterTrader.s.sol): Forge deployment script targeting BSC Mainnet.

---

## ⚙️ Core Architecture & Invariants

### 1. Hardcoded Constant Addresses
To optimize gas usage, all target contract addresses are declared as compile-time constants in [IAsterDex.sol](file:///Users/jollywalker/Documents/coding/aster-trader/src/Interface/IAsterDex.sol):
* **Aster DEX Diamond Proxy (`ASTER_DEX`):** `0x1b6F2d3844C6ae7D56ceb3C3643b9060ba28FEb0`
* **BTCB Pair Base (`BTC_PAIR_BASE`):** `0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c`
* **USDT Token Address (`USDT`):** `0x55d398326f99059fF775485246999027B3197955`

The [AsterTrader](file:///Users/jollywalker/Documents/coding/aster-trader/src/AsterTrader.sol) contract exposes a parameterless constructor utilizing these constants. Tests mock these addresses on-the-fly using `vm.etch`.

### 2. Concurrent Grid Trading Cycles
* The contract tracks independent trade cycles in the `tradeCycles` array using the `TradeCycle` struct.
* There is a strict limit of **5 concurrent active trade cycles** (`activeCyclesCount < 5`).
* When closing a trade via [executeSell](file:///Users/jollywalker/Documents/coding/aster-trader/src/AsterTrader.sol#L191-L239), you must supply the specific `cycleId` of the trade cycle you are ending.

### 3. Dual-Mode Sync & Async Settlement
Aster DEX trades on BSC Mainnet settle asynchronously. The contract addresses this via a dual-execution flow:
* **Synchronous (Tests / Mocks):** [executeSell](file:///Users/jollywalker/Documents/coding/aster-trader/src/AsterTrader.sol#L191-L239) checks if the position was immediately cleared. If so, it processes realized PnL and updates states instantly.
* **Asynchronous (Mainnet):** [executeSell](file:///Users/jollywalker/Documents/coding/aster-trader/src/AsterTrader.sol#L191-L239) triggers `closeTrade` and transitions to a pending-close state, emitting `CloseInitiated`. When the off-chain oracle settles the close, the owner calls [settleClose](file:///Users/jollywalker/Documents/coding/aster-trader/src/AsterTrader.sol#L247-L267) to record PnL, close the cycle, and free up a grid slot.

---

## 🛠️ Development & Command Reference

### Compilation
The contract is configured to compile via IR (`via_ir = true`) and requires optimizer settings to prevent Stack Too Deep errors.

```bash
forge build
```

### Testing
Verify all 12 tests representing different edge cases:

```bash
forge test
```

### Formatting
Format the Solidity codebase according to project standards:

```bash
forge fmt
```

### Mainnet Deployment
Deploy to BSC Mainnet using the following script (requires `PRIVATE_KEY` and a BSC RPC URL):

```bash
forge script script/DeployAsterTrader.s.sol:DeployAsterTrader --rpc-url <BSC_RPC_URL> --broadcast --verify
```
