# KipuBank V2 - Multi-Token Bank with USD Accounting - por CC

A decentralized multi-token bank smart contract with role-based access control, Chainlink oracle integration for USD accounting, and comprehensive security features.

## Contrato desplegado

- Dirección: `0xa08Ac9B458619e8EbeFE879816d21e9a57145a43`
- [Ver código verificado en SepoliaScan](https://sepolia.etherscan.io/address/0xa08Ac9B458619e8EbeFE879816d21e9a57145a43#code)

## 🎯 High-Level Improvements

### 1. **Access Control System**

- Implemented OpenZeppelin's `AccessControl` with two roles:
  - `ADMIN_ROLE`: Full permissions for token management
  - `MANAGER_ROLE`: Operational permissions for future features
- **Rationale**: Provides granular permission management and allows delegation of responsibilities without compromising security.

### 2. **Multi-Token Support**

- Extended support beyond native ETH to include any ERC-20 token
- Native ETH represented as `address(0)` for consistent internal accounting
- **Rationale**: Increases utility by allowing users to deposit various assets while maintaining a unified accounting system.

### 3. **Internal USD Accounting**

- All balances tracked internally in USD with 6 decimals (USDC standard)
- Nested mapping: `user => token => UserBalance`
- **Rationale**: Simplifies cross-token operations and enables USD-based limits regardless of token volatility.

### 4. **Chainlink Oracle Integration**

- Real-time price feeds for token-to-USD conversion
- Comprehensive validation:
  - Price > 0
  - Valid roundId and timestamp
  - Stale price detection (`answeredInRound < roundId`)
- **Rationale**: Ensures accurate, tamper-proof pricing critical for USD accounting and risk management.

### 5. **Decimal Conversion System**

- Handles tokens with different decimals (e.g., USDC: 6, ETH: 18)
- Converts all values to 6-decimal USD standard
- Formula: `(amount * price) / 10^(tokenDecimals + priceDecimals - 6)`
- **Rationale**: Prevents precision loss and maintains consistent accounting across diverse token standards.

### 6. **Security & Gas Optimization**

- **Check-Effects-Interactions (CEI)** pattern in all state-changing functions
- **ReentrancyGuard** on all external deposit/withdrawal functions
- **SafeERC20** for token transfers (handles non-standard tokens like USDT)
- `call()` instead of `transfer()` for ETH (no 2300 gas limit)
- `unchecked` blocks for provably safe operations (balance updates protected by caps)
- **Rationale**: Defense-in-depth approach combining multiple security layers while optimizing gas costs.

### 7. **Two-Step Withdrawal Pattern**

- Step 1: `requestWithdraw()` - Validates and creates pending withdrawal
- Step 2: `withdraw()` - Completes transfer
- **Rationale**: Separates validation from execution, enabling future features like withdrawal delays or admin approval flows.

### 8. **Bank Capacity & Limits**

- `BANK_CAP_USD`: Maximum total deposits allowed
- `WITHDRAW_LIMIT_USD`: Maximum per-withdrawal limit
- **Rationale**: Risk management to prevent over-exposure and enable gradual liquidity management.

### 9. **Naming Conventions & Documentation**

- State variables: `s_` prefix (e.g., `s_userBalances`)
- Constants: `UPPER_SNAKE_CASE`
- Functions: `lowerCamelCase`
- Comprehensive NatSpec documentation on all functions, events, and errors
- **Rationale**: Follows Solidity best practices for readability, maintainability, and tooling compatibility.

---

## 🚀 Deployment Instructions

### Prerequisites

- MetaMask wallet with Sepolia testnet ETH
- Remix IDE (https://remix.ethereum.org)
- Sepolia testnet selected in MetaMask

### Deployment Steps

1. **Open Remix IDE**

   - Navigate to https://remix.ethereum.org
   - Create a new file: `KipuBank.sol`
   - Copy the contract code

2. **Compile Contract**

   - Go to "Solidity Compiler" tab
   - Select compiler version: `0.8.20`
   - Enable optimization: **200 runs**
   - Click "Compile KipuBank.sol"

3. **Deploy to Sepolia**

   - Go to "Deploy & Run Transactions" tab
   - Environment: **Injected Provider - MetaMask**
   - Confirm MetaMask is on **Sepolia testnet**
   - Constructor parameters:
     ```
     withdrawLimitUSD: 1000000000     (1,000 USD with 6 decimals)
     bankCapUSD: 100000000000         (100,000 USD with 6 decimals)
     ethPriceFeed: 0x694AA1769357215DE4FAC081bf1f309aDC325306
     ```
   - Click "Deploy" and confirm in MetaMask

4. **Verify Contract on Etherscan** (Optional)
   - Go to Sepolia Etherscan
   - Find your deployed contract
   - Click "Verify and Publish"
   - Compiler: `0.8.20`, Optimization: **Yes (200 runs)**
   - Paste source code

---

## 💡 Interaction Guide

### Initial Setup

1. **Verify ETH Support**

   ```
   isTokenSupported(0x0000000000000000000000000000000000000000)
   // Should return: true
   ```

2. **Check ETH Price**
   ```
   getTokenPrice(0x0000000000000000000000000000000000000000)
   // Returns: (price, decimals, timestamp)
   ```

### Depositing ETH

1. **Deposit ETH**

   - Function: `depositETH()`
   - **VALUE**: `1000000000000000000` (1 ETH in wei)
   - Gas: ~150,000

2. **Check Balance**
   ```
   balanceOf(YOUR_ADDRESS, 0x0000000000000000000000000000000000000000)
   // Returns balance in wei
   ```

### Withdrawing ETH

1. **Request Withdrawal**

   ```
   requestWithdrawETH(500000000000000000)  // 0.5 ETH
   ```

2. **Check Pending Withdrawal**

   ```
   pendingWithdrawalOf(YOUR_ADDRESS, 0x0000000000000000000000000000000000000000)
   ```

3. **Complete Withdrawal**
   ```
   withdrawETH()
   // Transfers pending amount to your wallet
   ```

### Adding New Tokens (Admin Only)

**Example: Add USDC on Sepolia**

```
addToken(
  0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238,  // USDC token address
  0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E   // USDC/USD price feed
)
```

**Available Sepolia Price Feeds:**

- ETH/USD: `0x694AA1769357215DE4FAC081bf1f309aDC325306`
- USDC/USD: `0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E`
- LINK/USD: `0xc59E3633BAAC79493d908e63626716e204A45EdF`

---

## 🏗️ Design Decisions & Trade-offs

### 1. **Nested Mappings vs Separate Mappings**

- **Decision**: Use `mapping(user => mapping(token => UserBalance))`
- **Trade-off**:
  - ✅ **Pro**: O(1) lookups, gas-efficient per-user-token queries
  - ❌ **Con**: Cannot enumerate all users or calculate total supply without events
- **Rationale**: Individual user queries are the primary use case; aggregations can be done off-chain via events.

### 2. **Two-Step Withdrawal vs Direct Withdrawal**

- **Decision**: Separate `requestWithdraw()` and `withdraw()` functions
- **Trade-off**:
  - ✅ **Pro**: Enables future features (withdrawal delays, approvals), better separation of concerns
  - ❌ **Con**: Requires two transactions, slightly higher gas cost
- **Rationale**: Flexibility for future enhancements (timelock, admin review) outweighs the convenience of single-step withdrawals.

### 3. **USD Accounting vs Native Token Accounting**

- **Decision**: Track all balances in USD internally
- **Trade-off**:
  - ✅ **Pro**: Unified limits across tokens, simplified multi-token logic
  - ❌ **Con**: Oracle dependency, price volatility between operations
- **Rationale**: Enables coherent risk management and cross-token features; oracle risk mitigated by comprehensive validation.

### 4. **address(0) for ETH vs Wrapped ETH**

- **Decision**: Use `address(0)` as ETH identifier
- **Trade-off**:
  - ✅ **Pro**: No wrapping/unwrapping overhead, simpler user experience
  - ❌ **Con**: Special case handling in code
- **Rationale**: Users prefer native ETH; internal complexity is minimal with proper abstractions.

### 5. **Immutable Limits vs Adjustable Limits**

- **Decision**: `WITHDRAW_LIMIT_USD` and `BANK_CAP_USD` are immutable
- **Trade-off**:
  - ✅ **Pro**: Deployment-time commitment, no governance attack surface
  - ❌ **Con**: Cannot adapt to changing market conditions without redeployment
- **Rationale**: Security and trust through immutability; future versions can implement adjustable limits with governance.

### 6. **ReentrancyGuard on View Functions**

- **Decision**: Only apply `nonReentrant` on state-changing functions
- **Trade-off**:
  - ✅ **Pro**: Saves gas on read operations
  - ❌ **Con**: Theoretical read-only reentrancy (mitigated by CEI pattern)
- **Rationale**: View functions don't modify state; CEI pattern already prevents reentrancy issues.

### 7. **Custom Errors vs require() with Strings**

- **Decision**: Use custom errors throughout
- **Trade-off**:
  - ✅ **Pro**: Significant gas savings (~50 gas per revert), better parameter handling
  - ❌ **Con**: Slightly less human-readable in basic block explorers
- **Rationale**: Modern Solidity best practice; gas savings compound with usage.

### 8. **Public State Variables vs Getters**

- **Decision**: Make counters public (`s_depositCount`, `s_withdrawCount`, `s_totalDepositedUSD`)
- **Trade-off**:
  - ✅ **Pro**: Auto-generated getters, less code
  - ❌ **Con**: Exposes internal state (acceptable for counters)
- **Rationale**: Transparency is valuable for these metrics; sensitive data (balances) uses custom getters.

---

## 📊 Contract Statistics

- **Solidity Version**: 0.8.20
- **Lines of Code**: ~460
- **External Functions**: 12
- **View Functions**: 8
- **Events**: 5
- **Custom Errors**: 11
- **Supported Networks**: Ethereum Sepolia Testnet

---

## 🔐 Security Considerations

1. **Oracle Dependency**: Contract relies on Chainlink oracles; if oracle fails, deposits/withdrawals halt
2. **Price Volatility**: USD value can change between request and withdrawal completion
3. **Admin Trust**: `ADMIN_ROLE` can add/remove tokens; use multisig in production
4. **Immutable Limits**: Cannot change caps without redeployment; plan conservatively

---

## 📝 Testing Recommendations

1. **Unit Tests**: Test each function with edge cases (zero amounts, overflow attempts, invalid tokens)
2. **Integration Tests**: Test full deposit-withdraw cycles with multiple tokens
3. **Oracle Tests**: Mock stale/invalid oracle data to verify error handling
4. **Fuzz Tests**: Random inputs to discover unexpected behaviors
5. **Gas Profiling**: Measure gas costs for common operations

---

## 🔗 Useful Links

- **Chainlink Price Feeds**: https://docs.chain.link/data-feeds/price-feeds/addresses?network=ethereum&page=1#sepolia-testnet
- **OpenZeppelin Contracts**: https://docs.openzeppelin.com/contracts/
- **Solidity Documentation**: https://docs.soliditylang.org/

---

## 📄 License

MIT License - See contract header for details

---