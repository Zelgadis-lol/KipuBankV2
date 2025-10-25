// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title KipuBank
 * @notice Multi-token bank with access control and USD accounting
 * @dev Implements AccessControl and ReentrancyGuard from OpenZeppelin
 * @dev Uses Chainlink oracles for price feeds and USD conversion
 */
contract KipuBank is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Role identifier for administrators with full permissions
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    
    /// @notice Role identifier for managers with operational permissions
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    /// @notice Stores user balance and pending withdrawal information
    /// @dev Used in nested mapping for multi-token accounting
    struct UserBalance {
        uint256 balance;
        uint256 pendingWithdrawal;
    }

    /// @notice Stores token configuration including price feed and decimals
    /// @dev Contains Chainlink oracle reference and token metadata
    struct TokenInfo {
        AggregatorV3Interface priceFeed;
        uint8 decimals;
        bool isSupported;
    }

    /// @notice Decimal precision for USD accounting (matches USDC)
    uint8 private constant USDC_DECIMALS = 6;
    
    /// @notice Address representation for native ETH
    address private constant NATIVE_ETH = address(0);
    
    /// @notice Maximum USD value allowed per withdrawal request
    uint256 public immutable WITHDRAW_LIMIT_USD;
    
    /// @notice Maximum total USD value the bank can hold
    uint256 public immutable BANK_CAP_USD;

    /// @notice Nested mapping: user address => token address => user balance info
    /// @dev First key is user address, second key is token address (address(0) for ETH)
    mapping(address => mapping(address => UserBalance)) private s_userBalances;
    
    /// @notice Mapping of token addresses to their configuration
    /// @dev Stores price feed oracle, decimals, and support status
    mapping(address => TokenInfo) private s_tokenInfo;
    
    /// @notice Array of all supported token addresses
    /// @dev Used for enumeration, includes address(0) for ETH
    address[] private s_supportedTokens;
    
    /// @notice Total value deposited in the bank (in USD with 6 decimals)
    /// @dev Updated on deposits and withdrawals
    uint256 public s_totalDepositedUSD;
    
    /// @notice Counter for total number of deposits
    /// @dev Incremented on each successful deposit
    uint256 public s_depositCount;
    
    /// @notice Counter for total number of withdrawal requests
    /// @dev Incremented on each withdrawal request
    uint256 public s_withdrawCount;

    /// @notice Emitted when a user deposits tokens
    /// @param user Address of the user making the deposit
    /// @param token Address of the deposited token (address(0) for ETH)
    /// @param amount Amount of tokens deposited (in token decimals)
    /// @param amountUSD Value in USD (6 decimals)
    /// @param newBalance User's new balance after deposit
    event Deposit(address indexed user, address indexed token, uint256 amount, uint256 amountUSD, uint256 newBalance);
    
    /// @notice Emitted when a user requests a withdrawal
    /// @param user Address of the user requesting withdrawal
    /// @param token Address of the token to withdraw
    /// @param amount Amount requested (in token decimals)
    /// @param amountUSD Value in USD (6 decimals)
    event WithdrawRequested(address indexed user, address indexed token, uint256 amount, uint256 amountUSD);
    
    /// @notice Emitted when a withdrawal is completed
    /// @param user Address of the user receiving funds
    /// @param token Address of the withdrawn token
    /// @param amount Amount withdrawn (in token decimals)
    event WithdrawCompleted(address indexed user, address indexed token, uint256 amount);
    
    /// @notice Emitted when a new token is added to the bank
    /// @param token Address of the added token
    /// @param priceFeed Address of the Chainlink price feed
    event TokenAdded(address indexed token, address indexed priceFeed);
    
    /// @notice Emitted when a token is removed from the bank
    /// @param token Address of the removed token
    event TokenRemoved(address indexed token);

    /// @notice Thrown when a zero value is provided where non-zero is required
    error NonZeroRequired();
    
    /// @notice Thrown when user has insufficient balance for operation
    /// @param available Current available balance
    /// @param required Required amount for operation
    error InsufficientBalance(uint256 available, uint256 required);
    
    /// @notice Thrown when deposit would exceed bank capacity
    /// @param attempted Total USD value after deposit
    /// @param cap Maximum allowed bank capacity
    error BankCapExceeded(uint256 attempted, uint256 cap);
    
    /// @notice Thrown when withdrawal amount exceeds limit
    /// @param attempted Withdrawal amount in USD
    /// @param limit Maximum allowed withdrawal in USD
    error WithdrawLimitExceeded(uint256 attempted, uint256 limit);
    
    /// @notice Thrown when attempting to withdraw with no pending amount
    error NoPendingWithdrawal();
    
    /// @notice Thrown when a transfer operation fails
    error TransferFailed();
    
    /// @notice Thrown when token is not supported by the bank
    /// @param token Address of the unsupported token
    error TokenNotSupported(address token);
    
    /// @notice Thrown when price feed data is invalid
    error InvalidPriceFeed();
    
    /// @notice Thrown when attempting to add an already supported token
    /// @param token Address of the token
    error TokenAlreadySupported(address token);
    
    /// @notice Thrown when an invalid address is provided
    error InvalidAddress();
    
    /// @notice Thrown when oracle price data is stale
    error StalePrice();

    /// @notice Ensures the provided amount is non-zero
    /// @param amount The amount to validate
    modifier nonZero(uint256 amount) {
        if (amount == 0) revert NonZeroRequired();
        _;
    }

    /// @notice Ensures the token is supported by the bank
    /// @param token The token address to validate
    modifier onlySupportedToken(address token) {
        if (!s_tokenInfo[token].isSupported) revert TokenNotSupported(token);
        _;
    }

    /// @notice Initializes the bank with limits and ETH price feed
    /// @param withdrawLimitUSD Maximum withdrawal amount in USD (6 decimals)
    /// @param bankCapUSD Maximum total deposits in USD (6 decimals)
    /// @param ethPriceFeed Chainlink ETH/USD price feed address for Sepolia
    constructor(uint256 withdrawLimitUSD, uint256 bankCapUSD, address ethPriceFeed) {
        WITHDRAW_LIMIT_USD = withdrawLimitUSD;
        BANK_CAP_USD = bankCapUSD;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(MANAGER_ROLE, msg.sender);

        _addToken(NATIVE_ETH, ethPriceFeed);
    }

    /// @notice Deposits ETH into the bank
    /// @dev Uses msg.value as deposit amount, converts to USD via oracle
    function depositETH() external payable nonReentrant nonZero(msg.value) {
        _deposit(msg.sender, NATIVE_ETH, msg.value);
    }

    /// @notice Deposits ERC20 tokens into the bank
    /// @param token Address of the ERC20 token to deposit
    /// @param amount Amount of tokens to deposit (in token decimals)
    /// @dev Requires prior token approval, uses SafeERC20 for transfer
    function depositToken(address token, uint256 amount) external nonReentrant nonZero(amount) onlySupportedToken(token) {
        if (token == NATIVE_ETH) revert InvalidAddress();

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        _deposit(msg.sender, token, amount);
    }

    /// @notice Requests withdrawal of ETH from user balance
    /// @param amount Amount of ETH to withdraw (in wei)
    /// @dev Creates pending withdrawal, actual transfer in withdrawETH()
    function requestWithdrawETH(uint256 amount) external nonReentrant nonZero(amount) {
        _requestWithdraw(msg.sender, NATIVE_ETH, amount);
    }

    /// @notice Requests withdrawal of ERC20 tokens from user balance
    /// @param token Address of the token to withdraw
    /// @param amount Amount of tokens to withdraw (in token decimals)
    /// @dev Creates pending withdrawal, actual transfer in withdrawToken()
    function requestWithdrawToken(address token, uint256 amount) external nonReentrant nonZero(amount) onlySupportedToken(token) {
        if (token == NATIVE_ETH) revert InvalidAddress();
        _requestWithdraw(msg.sender, token, amount);
    }

    /// @notice Completes pending ETH withdrawal
    /// @dev Transfers pending ETH to user using call(), follows CEI pattern
    function withdrawETH() external nonReentrant {
        _withdraw(msg.sender, NATIVE_ETH);
    }

    /// @notice Completes pending token withdrawal
    /// @param token Address of the token to withdraw
    /// @dev Transfers pending tokens using SafeERC20
    function withdrawToken(address token) external nonReentrant onlySupportedToken(token) {
        if (token == NATIVE_ETH) revert InvalidAddress();
        _withdraw(msg.sender, token);
    }

    /// @notice Adds a new ERC20 token to the bank
    /// @param token Address of the ERC20 token contract
    /// @param priceFeed Address of the Chainlink price feed for this token
    /// @dev Only callable by ADMIN_ROLE, validates oracle before adding
    function addToken(address token, address priceFeed) external onlyRole(ADMIN_ROLE) {
        if (token == NATIVE_ETH || token == address(0)) revert InvalidAddress();
        if (priceFeed == address(0)) revert InvalidAddress();
        _addToken(token, priceFeed);
    }

    /// @notice Removes a token from the bank's supported list
    /// @param token Address of the token to remove
    /// @dev Only callable by ADMIN_ROLE, cannot remove ETH
    function removeToken(address token) external onlyRole(ADMIN_ROLE) {
        if (token == NATIVE_ETH) revert InvalidAddress();
        if (!s_tokenInfo[token].isSupported) revert TokenNotSupported(token);

        s_tokenInfo[token].isSupported = false;

        for (uint256 i = 0; i < s_supportedTokens.length; ) {
            if (s_supportedTokens[i] == token) {
                s_supportedTokens[i] = s_supportedTokens[s_supportedTokens.length - 1];
                s_supportedTokens.pop();
                break;
            }
            unchecked {
                ++i;
            }
        }

        emit TokenRemoved(token);
    }

    /// @notice Returns user's balance for a specific token
    /// @param user Address of the user
    /// @param token Address of the token (address(0) for ETH)
    /// @return User's current balance in token decimals
    function balanceOf(address user, address token) external view onlySupportedToken(token) returns (uint256) {
        return s_userBalances[user][token].balance;
    }

    /// @notice Returns user's pending withdrawal amount for a token
    /// @param user Address of the user
    /// @param token Address of the token
    /// @return Pending withdrawal amount in token decimals
    function pendingWithdrawalOf(address user, address token) external view onlySupportedToken(token) returns (uint256) {
        return s_userBalances[user][token].pendingWithdrawal;
    }

    /// @notice Returns array of all supported token addresses
    /// @return Array of token addresses (includes address(0) for ETH)
    function getSupportedTokens() external view returns (address[] memory) {
        return s_supportedTokens;
    }

    /// @notice Checks if a token is supported by the bank
    /// @param token Address of the token to check
    /// @return True if token is supported, false otherwise
    function isTokenSupported(address token) external view returns (bool) {
        return s_tokenInfo[token].isSupported;
    }

    /// @notice Returns detailed information about a token
    /// @param token Address of the token
    /// @return priceFeed Address of the Chainlink price feed
    /// @return decimals Number of decimals for the token
    /// @return isSupported Whether the token is currently supported
    function getTokenInfo(address token) external view onlySupportedToken(token) returns (address priceFeed, uint8 decimals, bool isSupported) {
        TokenInfo memory info = s_tokenInfo[token];
        return (address(info.priceFeed), info.decimals, info.isSupported);
    }

    /// @notice Converts token amount to USD value
    /// @param token Address of the token
    /// @param amount Amount in token decimals
    /// @return USD value with 6 decimals (USDC standard)
    function convertToUSD(address token, uint256 amount) external view onlySupportedToken(token) returns (uint256) {
        return _convertToUSD(token, amount);
    }

    /// @notice Returns current token price from Chainlink oracle
    /// @param token Address of the token
    /// @return price Current price from oracle
    /// @return decimals Decimals of the price feed
    /// @return updatedAt Timestamp of last price update
    function getTokenPrice(address token) external view onlySupportedToken(token) returns (uint256 price, uint8 decimals, uint256 updatedAt) {
        TokenInfo memory tokenInfo = s_tokenInfo[token];
        
        (uint80 roundId, int256 answer, , uint256 timestamp, uint80 answeredInRound) = tokenInfo.priceFeed.latestRoundData();
        
        if (answer <= 0 || roundId == 0 || timestamp == 0) revert InvalidPriceFeed();
        if (answeredInRound < roundId) revert StalePrice();
        
        return (uint256(answer), tokenInfo.priceFeed.decimals(), timestamp);
    }

    /// @notice Internal function to add a token with oracle validation
    /// @param token Address of the token to add
    /// @param priceFeed Address of the Chainlink price feed
    /// @dev Validates oracle data before adding, queries token decimals
    function _addToken(address token, address priceFeed) internal {
        if (s_tokenInfo[token].isSupported) revert TokenAlreadySupported(token);

        AggregatorV3Interface oracle = AggregatorV3Interface(priceFeed);
        
        (uint80 roundId, int256 price, , uint256 updatedAt, uint80 answeredInRound) = oracle.latestRoundData();
        
        if (price <= 0 || roundId == 0 || updatedAt == 0) revert InvalidPriceFeed();
        if (answeredInRound < roundId) revert StalePrice();

        uint8 tokenDecimals = (token == NATIVE_ETH) ? 18 : IERC20Metadata(token).decimals();

        s_tokenInfo[token] = TokenInfo({
            priceFeed: oracle,
            decimals: tokenDecimals,
            isSupported: true
        });

        s_supportedTokens.push(token);
        emit TokenAdded(token, priceFeed);
    }

    /// @notice Internal function to process deposits
    /// @param user Address of the depositor
    /// @param token Address of the token being deposited
    /// @param amount Amount being deposited (in token decimals)
    /// @dev Converts to USD, checks bank cap, updates balances
    function _deposit(address user, address token, uint256 amount) internal onlySupportedToken(token) {
        uint256 amountUSD = _convertToUSD(token, amount);
        uint256 newTotalUSD = s_totalDepositedUSD + amountUSD;

        if (newTotalUSD > BANK_CAP_USD) revert BankCapExceeded(newTotalUSD, BANK_CAP_USD);

        UserBalance storage userBalance = s_userBalances[user][token];
        
        unchecked {
            userBalance.balance += amount;
            s_totalDepositedUSD = newTotalUSD;
        }
        
        s_depositCount++;

        emit Deposit(user, token, amount, amountUSD, userBalance.balance);
    }

    /// @notice Internal function to process withdrawal requests
    /// @param user Address of the user requesting withdrawal
    /// @param token Address of the token to withdraw
    /// @param amount Amount to withdraw (in token decimals)
    /// @dev Validates balance, checks limits, creates pending withdrawal
    function _requestWithdraw(address user, address token, uint256 amount) internal {
        UserBalance storage userBalance = s_userBalances[user][token];

        if (userBalance.balance < amount) revert InsufficientBalance(userBalance.balance, amount);

        uint256 amountUSD = _convertToUSD(token, amount);
        if (amountUSD > WITHDRAW_LIMIT_USD) revert WithdrawLimitExceeded(amountUSD, WITHDRAW_LIMIT_USD);

        unchecked {
            userBalance.balance -= amount;
            userBalance.pendingWithdrawal += amount;
            s_totalDepositedUSD -= amountUSD;
        }
        
        s_withdrawCount++;

        emit WithdrawRequested(user, token, amount, amountUSD);
    }

    /// @notice Internal function to complete withdrawals
    /// @param user Address of the user receiving funds
    /// @param token Address of the token to transfer
    /// @dev Transfers pending amount, uses call() for ETH, SafeERC20 for tokens
    function _withdraw(address user, address token) internal {
        UserBalance storage userBalance = s_userBalances[user][token];
        uint256 amount = userBalance.pendingWithdrawal;

        if (amount == 0) revert NoPendingWithdrawal();

        unchecked {
            userBalance.pendingWithdrawal = 0;
        }

        if (token == NATIVE_ETH) {
            (bool success, ) = payable(user).call{value: amount}("");
            if (!success) revert TransferFailed();
        } else {
            IERC20(token).safeTransfer(user, amount);
        }

        emit WithdrawCompleted(user, token, amount);
    }

    /// @notice Internal function to convert token amount to USD
    /// @param token Address of the token
    /// @param amount Amount in token decimals
    /// @return USD value with 6 decimals
    /// @dev Queries Chainlink oracle, handles decimal conversion
    function _convertToUSD(address token, uint256 amount) internal view returns (uint256) {
        TokenInfo memory tokenInfo = s_tokenInfo[token];
        
        (uint80 roundId, int256 price, , uint256 updatedAt, uint80 answeredInRound) = tokenInfo.priceFeed.latestRoundData();
        
        if (price <= 0 || roundId == 0 || updatedAt == 0) revert InvalidPriceFeed();
        if (answeredInRound < roundId) revert StalePrice();

        uint8 priceFeedDecimals = tokenInfo.priceFeed.decimals();
        uint256 priceUint = uint256(price);
        
        uint256 totalDecimals = uint256(tokenInfo.decimals) + uint256(priceFeedDecimals);
        
        if (totalDecimals > USDC_DECIMALS) {
            unchecked {
                return (amount * priceUint) / (10 ** (totalDecimals - USDC_DECIMALS));
            }
        } else if (totalDecimals < USDC_DECIMALS) {
            unchecked {
                return (amount * priceUint) * (10 ** (USDC_DECIMALS - totalDecimals));
            }
        } else {
            return amount * priceUint;
        }
    }

    /// @notice Receives ETH and automatically deposits it
    /// @dev Fallback function for direct ETH transfers
    receive() external payable {
        _deposit(msg.sender, NATIVE_ETH, msg.value);
    }

    /// @notice Fallback function that deposits ETH
    /// @dev Called when no other function matches
    fallback() external payable {
        _deposit(msg.sender, NATIVE_ETH, msg.value);
    }
}