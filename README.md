# AsterTrader

An automated trading system designed to execute USDT/BTC perpetual positions on the **Aster DEX** platform. It manages deposits, withdrawals, grid-trading tracking (supporting up to 5 concurrent active cycles), and handles the asynchronous, oracle-based settlement mechanism of Aster DEX.

---

## 📁 Project Structure

* **src/**: Smart contracts.
  * [AsterTrader.sol](file:///Users/jollywalker/Documents/coding/aster-trader/src/AsterTrader.sol) — Core contract managing deposits, withdrawals, trade cycles, and DEX interactions.
  * [Interface/IAsterDex.sol](file:///Users/jollywalker/Documents/coding/aster-trader/src/Interface/IAsterDex.sol) — Interface and constants for Aster DEX.
* **script/**: Deployment and setup scripts.
  * [DeployAsterTrader.s.sol](file:///Users/jollywalker/Documents/coding/aster-trader/script/DeployAsterTrader.s.sol) — Production Mainnet deployment script.
  * [SetupLocalFork.s.sol](file:///Users/jollywalker/Documents/coding/aster-trader/script/SetupLocalFork.s.sol) — Local fork configuration and deployment script.
* **test/**: Automated test suites.
  * [AsterTrader.t.sol](file:///Users/jollywalker/Documents/coding/aster-trader/test/AsterTrader.t.sol) — Unit tests (using offline mock contracts).
  * [AsterTraderFork.t.sol](file:///Users/jollywalker/Documents/coding/aster-trader/test/AsterTraderFork.t.sol) — Integration tests running on a BSC fork against live contracts.
  * [Mocks.sol](file:///Users/jollywalker/Documents/coding/aster-trader/test/Mocks.sol) — Local mocks of USDT, BTCB, and Aster DEX.

---

## ⚙️ Core Development Commands

### Compile Contracts
```bash
forge build
```

### Run Offline Unit Tests
Verify the contract states, PnL calculations, reentrancy guards, and concurrent cycle limits:
```bash
forge test --match-path test/AsterTrader.t.sol
```

### Format Codebase
```bash
forge fmt
```

---

## 🌐 Local BSC Fork Testing & Interaction

To test interaction directly against the live `ASTER_DEX` contract without deploying to Mainnet, you can run a local BSC fork.

### 1. Configure Environment
Create a `.env` file from the template and set your BSC Mainnet RPC URL:
```bash
cp .env.example .env
```
In `.env`:
```env
BSC_RPC_URL=https://bsc-dataseed.binance.org/
```

### 2. Execution Workflow

This workflow deploys `AsterTrader` onto a running local fork and tests the live deployed contract automatically.

1. **Terminal 1:** Run Anvil with RPC and block height:
   ```bash
   source .env
   anvil --fork-url "$BSC_RPC_URL" --fork-block-number 40000000
   ```

2. **Terminal 2:** Run `SetupLocalFork` to deploy to Anvil (this also writes the deployed address to `./deployed_trader.txt`):
   ```bash
   forge script script/SetupLocalFork.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
   ```

3. **Terminal 2:** Run `AsterTraderFork.t.sol` to automatically verify the deployment against the live `ASTER_DEX` contract:
   ```bash
   forge test --match-path test/AsterTraderFork.t.sol --rpc-url http://127.0.0.1:8545 -vvv
   ```

This test will automatically read the deployed contract address, impersonate a mainnet USDT whale to fund your account, and execute an initial buy long against the live `ASTER_DEX` on-chain to verify the integration.
