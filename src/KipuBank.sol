// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/// @title KipuBank - Secure multi-asset vault with access roles, pricing limits, and reporting.
/// @author Kipu Team (updated for 2025 standards)
contract KipuBank is ERC20, AccessControl {
    // Access Control Roles
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Chainlink ETH/USD price feed
    AggregatorV3Interface public immutable priceFeed;

    /// @notice USDC decimals standard
    uint8 public constant USDC_DECIMALS = 6;

    /// @notice Bank cap in USD (6 decimals, USDC units)
    uint256 public immutable bankCapUsd;

    /// @notice Maximum amount allowed per withdrawal (in USD, 6 decimals)
    uint256 public immutable withdrawLimitUsd;

    /// @notice Struct to track user activity per-token
    struct Total {
        uint256 depositsAmountUsd; // In USDC-decimal USD
        uint256 depositsQtt;
        uint256 withdrawsQtt;
    }

    /// @notice Nested mapping: user => token => stats
    mapping(address => mapping(address => Total)) public totals;

    /// @notice Nested mapping: user => token => funds (raw token units)
    mapping(address => mapping(address => uint256)) public funds;

    /// @notice Reentrancy guard lock.
    bool private locked;

    /// @notice Emitted when a user successfully deposits any asset.
    event Deposited(address indexed user, address indexed token, uint256 amount, uint256 amountUsd);

    /// @notice Emitted when a user withdraws any asset.
    event Withdrawn(address indexed user, address indexed token, uint256 amount, uint256 amountUsd);

    /// @notice Thrown if reentrancy detected
    error ReentrancyDetected();
    error ZeroAmount();
    error AboveLimit();
    error NoFund();
    error PriceFeedError();

    modifier noReentrancy() {
        if (locked) revert ReentrancyDetected();
        locked = true;
        _;
        locked = false;
    }

    modifier onlyAdmin() {
        require(hasRole(ADMIN_ROLE, msg.sender), "ADMIN only");
        _;
    }

    /// @param _withdrawLimitUsd Max per-withdrawal (USDC decimals)
    /// @param _bankCapUsd Max vault cap per user (USDC decimals)
    /// @param _priceFeed ETH/USD Chainlink feed address
    constructor(uint256 _withdrawLimitUsd, uint256 _bankCapUsd, address _priceFeed)
        ERC20("MyToken", "MTK")
    {
        require(_withdrawLimitUsd > 0 && _bankCapUsd > 0, "limits required");
        require(_withdrawLimitUsd <= _bankCapUsd, "Withdraw > cap");
        priceFeed = AggregatorV3Interface(_priceFeed);

        withdrawLimitUsd = _withdrawLimitUsd;
        bankCapUsd = _bankCapUsd;
        _mint(msg.sender, 1000 * 10 ** uint256(decimals()));

        _grantRole(ADMIN_ROLE, msg.sender);
    }

    /// @notice Get latest ETH/USD price (Chainlink, 8 decimals)
    function getEthUsdPrice() public view returns (uint256) {
        (
            ,
            int256 price,
            ,
            ,
        ) = priceFeed.latestRoundData();
        if (price <= 0) revert PriceFeedError();
        return uint256(price); // 8 decimals
    }

    /// @notice Converts (token, amount) to USD (USDC decimals)
    function tokenToUsd(address token, uint256 amount) public view returns (uint256) {
        uint8 decs = token == address(0) ? 18 : IERC20Metadata(token).decimals();

        if (token == address(0)) {
            // Native ETH
            uint256 price = getEthUsdPrice(); // 8 decimals
            // Convert ETH amount (18 decimals) to USD (6 decimals)
            // (amount * price) / 1e18 (ETH units) * 1e6 (USDC decimals) / 1e8 (price feed decimals)
            return (amount * price * (10 ** USDC_DECIMALS)) / (1e18 * 1e8);
        } else {
            // For ERC-20, treat price = 1 if pegged to USD, otherwise provide external price through admin
            uint256 price = 1e8; // default=1 USD, for stablecoins (can add priceFeed per token if expanding)
            uint256 normalized = amount * (10 ** USDC_DECIMALS) / (10 ** decs);
            return (normalized * price) / 1e8;
        }
    }

    /// @notice Deposits ETH (address(0)) or ERC-20 (token param)
    /// @param token Asset address (address(0) for ETH)
    /// @param amount Amount to deposit
    function deposit(address token, uint256 amount) external payable noReentrancy {
        if (amount == 0) revert ZeroAmount();

        // ETH requires msg.value == amount
        if (token == address(0)) {
            require(amount == msg.value, "amount != msg.value");
        } else {
            require(msg.value == 0, "nonzero msg.value for ERC20");
            IERC20(token).transferFrom(msg.sender, address(this), amount);
        }

        // Calculate USD value in USDC decimals
        uint256 usdValue = tokenToUsd(token, amount);
        if (totals[msg.sender][token].depositsAmountUsd + usdValue > bankCapUsd) revert AboveLimit();

        _updateTotals(msg.sender, token, usdValue, true);
        funds[msg.sender][token] += amount;

        emit Deposited(msg.sender, token, amount, usdValue);
    }

    /// @notice Withdraw asset (ETH or ERC-20) up to per-transaction USD limit
    function withdraw(address token, uint256 amount) external noReentrancy {
        if (funds[msg.sender][token] == 0) revert NoFund();
        if (amount > funds[msg.sender][token]) revert AboveLimit();

        uint256 usdValue = tokenToUsd(token, amount);
        if (usdValue > withdrawLimitUsd) revert AboveLimit();

        funds[msg.sender][token] -= amount;
        _updateTotals(msg.sender, token, usdValue, false);

        if (token == address(0)) {
            (bool ok, ) = payable(msg.sender).call{value: amount}("");
            require(ok, "ETH transfer failed");
        } else {
            require(IERC20(token).transfer(msg.sender, amount), "ERC20 transfer failed");
        }

        emit Withdrawn(msg.sender, token, amount, usdValue);
    }

    /// @notice Comprehensive stats: balance, totals for user, token
    function getUserTokenStats(address user, address token)
        external
        view
        returns (
            uint256 depositsAmountUsd,
            uint256 depositsQtt,
            uint256 withdrawsQtt,
            uint256 currentBalance
        )
    {
        Total memory t = totals[user][token];
        return (
            t.depositsAmountUsd,
            t.depositsQtt,
            t.withdrawsQtt,
            funds[user][token]
        );
    }

    /// @notice Private helper to update activity counters (in USD units)
    function _updateTotals(address user, address token, uint256 amountUsd, bool isDeposit) private {
        if (isDeposit) {
            totals[user][token].depositsAmountUsd += amountUsd;
            totals[user][token].depositsQtt += 1;
        } else {
            totals[user][token].withdrawsQtt += 1;
        }
    }

    /// @notice Emergency admin withdrawal (for stuck funds, upgrade, etc.)
    function adminWithdraw(address token, uint256 amount, address to) external onlyAdmin {
        if (token == address(0)) {
            (bool ok, ) = payable(to).call{value: amount}("");
            require(ok, "ETH transfer failed");
        } else {
            require(IERC20(token).transfer(to, amount), "ERC20 transfer failed");
        }
    }

    // receive/fallback for ETH
    receive() external payable {
        // Accept ETH when sent directly
        funds[msg.sender][address(0)] += msg.value;
        uint256 usdValue = tokenToUsd(address(0), msg.value);
        _updateTotals(msg.sender, address(0), usdValue, true);
        emit Deposited(msg.sender, address(0), msg.value, usdValue);
    }
}