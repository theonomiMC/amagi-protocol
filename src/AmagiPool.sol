// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {AggregatorV3Interface} from "@chainlink/interfaces/AggregatorV3Interface.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

// custom errrors
error ZeroAmount();
error InsufficientBalance();
error InsufficientCollateral();
error InvalidHealthFactor();
error HealthFactorOk();
error InsufficientLiquidity();
error TransferFailed();
error InvalidPrice();
error PriceExpired();

/// @title Lending protocol
/// @author Natalia - theonomiMC
/// @notice
contract AmagiPool is ReentrancyGuard, Initializable, OwnableUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    IERC20 public usdc;
    AggregatorV3Interface public priceFeed;
    uint8 public priceFeedDecimals;

    uint256 public totalDeposits;
    uint256 public constant PRECISION = 1e18;
    uint256 public constant USDC_SCALE = 10 ** 12;

    uint256 public constant LTV = 75;
    uint256 public constant LIQ_THRESHOLD = 80;
    uint256 public constant LIQ_BONUS = 5;
    uint256 public constant INTEREST_RATE = 10;

    uint256 public globalBorrowIndex;
    uint256 public lastUpdatedIndex;

    struct UserData {
        uint128 collateral; //  Slot 1
        uint128 borrowShares; // Slot 1
        uint256 deposit; // Slot 2
    }
    mapping(address => UserData) public users;

    event Deposit(address indexed user, uint256 amount);
    event CollateralDeposited(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event WithdrawCollateral(address indexed user, uint256 amount);
    event Borrow(address indexed user, uint256 amount);
    event Repay(address indexed user, uint256 amount);
    event Liquidate(address indexed user, address indexed liquidator, uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _usdc, address _priceFeed) public initializer {
        __Ownable_init(msg.sender);

        usdc = IERC20(_usdc);
        priceFeed = AggregatorV3Interface(_priceFeed);
        priceFeedDecimals = priceFeed.decimals();

        globalBorrowIndex = 1e18;
        lastUpdatedIndex = block.timestamp;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// @notice Gets the normalized price of the asset from the oracle
    /// @dev Scales the price to 18 decimals regardless of the original feed decimals
    /// @return The normalized price in 1e18 format
    function getPrice() public view returns (uint256) {
        return _price();
    }
    /// @notice Deposits usdc into the pool to earn interest
    /// @dev Uses SafeERC20 for transfer and scales amount to 18 decimals
    /// @param amount The amount of usdc to deposit (6 decimals)
    function deposit(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        uint256 scaledAmount = amount * USDC_SCALE;
        UserData storage user = users[msg.sender];

        totalDeposits += scaledAmount;
        unchecked {
            user.deposit += scaledAmount;
        }

        usdc.safeTransferFrom(msg.sender, address(this), amount);
        emit Deposit(msg.sender, amount);
    }

    /// @notice Deposits ETH as collateral for borrowing
    /// @dev Increases the user's collateral balance by msg.value
    function depositCollateral() external payable {
        if (msg.value == 0) revert ZeroAmount();

        users[msg.sender].collateral += msg.value.toUint128();

        emit CollateralDeposited(msg.sender, msg.value);
    }

    /// @notice Withdraws usdc from the pool
    /// @dev Reverts if there is insufficient liquidity in the contract or user balance
    /// @param amount The amount of usdc to withdraw (6 decimals)
    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        UserData storage user = users[msg.sender];

        uint256 scaledAmount = amount * USDC_SCALE;

        if (user.deposit < scaledAmount) revert InsufficientBalance();

        if (usdc.balanceOf(address(this)) < amount) {
            revert InsufficientLiquidity();
        }

        totalDeposits -= scaledAmount;
        unchecked {
            user.deposit -= scaledAmount;
        }
        usdc.safeTransfer(msg.sender, amount);
        emit Withdraw(msg.sender, amount);
    }

    /// @notice Withdraws ETH collateral from the protocol
    /// @dev Updates the borrow index and checks if the withdrawal keeps the position healthy
    /// @param amount The amount of ETH (in wei) to withdraw
    function withdrawCollateral(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        uint256 index = _updateIndex();
        UserData storage user = users[msg.sender];

        if (user.collateral < amount) revert InsufficientBalance();

        unchecked {
            user.collateral -= amount.toUint128();
        }

        uint256 price = _price();
        uint256 debt = (user.borrowShares * index) / PRECISION;
        uint256 newCollateralValue = (user.collateral * price) / PRECISION;

        if (_isLiquidatable(newCollateralValue, debt)) {
            revert InvalidHealthFactor();
        }

        (bool success,) = msg.sender.call{value: amount}("");
        if (!success) revert TransferFailed();

        emit WithdrawCollateral(msg.sender, amount);
    }

    /// @notice Allows users to borrow usdc against their ETH collateral
    /// @dev Calculates health factor before transferring funds
    /// @param amount The amount of usdc to borrow
    function borrow(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        uint256 index = _updateIndex();

        UserData storage user = users[msg.sender];
        uint256 price = _price();

        uint256 collateralValue = (user.collateral * price) / PRECISION;
        uint256 debt = (user.borrowShares * index) / PRECISION;
        uint256 scaledAmount = amount * USDC_SCALE;

        uint256 maxBorrow = (collateralValue * LTV) / 100;
      
        if (debt + scaledAmount > maxBorrow) revert InsufficientCollateral();

        // shares = amount * PRECISION / globalBorrowIndex
        uint256 shares = (scaledAmount * PRECISION) / index;

        if (usdc.balanceOf(address(this)) < amount) {
            revert InsufficientLiquidity();
        }
        unchecked {
            user.borrowShares += shares.toUint128();
        }
        usdc.safeTransfer(msg.sender, amount);
        emit Borrow(msg.sender, amount);
    }

    /// @notice Repays a usdc loan to reduce debt shares
    /// @dev If the amount exceeds the total debt, it caps the repayment at the current debt
    /// @param amount The amount of usdc to repay
    function repay(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        uint256 index = _updateIndex();

        UserData storage user = users[msg.sender];
        uint256 debt = (user.borrowShares * index) / PRECISION;
        uint256 scaledAmount = amount * USDC_SCALE;

        if (scaledAmount > debt) {
            scaledAmount = debt;
            amount = debt / USDC_SCALE;
        }

        uint256 shares = (scaledAmount * PRECISION) / index;

        unchecked {
            user.borrowShares -= shares.toUint128();
        }

        usdc.safeTransferFrom(msg.sender, address(this), amount);
        emit Repay(msg.sender, amount);
    }

    /// @notice Liquidates an undercollateralized position
    /// @dev Liquidator pays debt and receives collateral + bonus
    /// @param target The address of the user to be liquidated
    /// @param debtToCover The amount of debt the liquidator wants to pay
    function liquidate(address target, uint256 debtToCover) external nonReentrant {
        if (debtToCover == 0) revert ZeroAmount();

        uint256 index = _updateIndex();

        UserData storage user = users[target];
        uint256 price = _price();

        uint256 collateralValue = (user.collateral * price) / PRECISION;
        uint256 debt = (user.borrowShares * index) / PRECISION;

        if (!_isLiquidatable(collateralValue, debt)) revert HealthFactorOk();

        uint256 scaledAmount = debtToCover * USDC_SCALE;
        if (scaledAmount > debt) scaledAmount = debt;

        uint256 collateralOut = (scaledAmount * PRECISION * (100 + LIQ_BONUS)) / (price * 100);

        if (collateralOut > user.collateral) collateralOut = user.collateral;

        uint256 shares = (scaledAmount * PRECISION) / index;

        unchecked {
            user.borrowShares -= shares.toUint128();
            user.collateral -= collateralOut.toUint128();
        }

        uint256 actualDebtToCover = scaledAmount / USDC_SCALE;
        usdc.safeTransferFrom(msg.sender, address(this), actualDebtToCover);

        (bool success,) = msg.sender.call{value: collateralOut}("");
        if (!success) revert TransferFailed();

        emit Liquidate(target, msg.sender, collateralOut);
    }

    /// @dev Updates the global borrow index based on the interest rate and time elapsed
    /// @notice Accrues interest to the entire pool by increasing the global index
    function _updateIndex() internal returns (uint256) {
        uint256 index = globalBorrowIndex; // SLOAD
        uint256 lastUpdated = lastUpdatedIndex; // SLOAD

        uint256 timeElapsed = block.timestamp - lastUpdated;
        if (timeElapsed == 0) return index;

        index += (index * INTEREST_RATE * timeElapsed) / (100 * 365 days);

        globalBorrowIndex = index; // SSTOR
        lastUpdatedIndex = block.timestamp;
        return index;
    }

    /// @dev Fetches and normalizes the asset price from the Chainlink Oracle
    /// @notice Normalizes prices with different decimals to a standard 18-decimal format
    /// @return The normalized price in 1e18 format
    function _price() internal view returns (uint256) {
        (, int256 p,, uint256 updatedAt,) = priceFeed.latestRoundData();

        uint8 decimals = priceFeedDecimals;

        if (p <= 0) revert InvalidPrice();
        if (block.timestamp - updatedAt > 24 hours) revert PriceExpired();

        // casting to 'uint256' is safe because [explain why]
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 price = uint256(p);

        if (decimals < 18) {
            return price * (10 ** (18 - decimals));
        } else if (decimals > 18) {
            return price / (10 ** (decimals - 18));
        }

        return price;
    }

    /// @dev Determines if a position's health factor is below the liquidation threshold
    /// @notice A position is liquidatable if its Health Factor is less than 1 (represented by PRECISION)
    /// @param collateralValue The total value of user's ETH in USD (18 decimals)
    /// @param debt The total value of user's debt in USD (18 decimals)
    /// @return True if the position can be liquidated, false otherwise
    function _isLiquidatable(uint256 collateralValue, uint256 debt) internal pure returns (bool) {
        if (debt == 0) return false;

        uint256 hf = (collateralValue * LIQ_THRESHOLD * PRECISION) / (100 * debt);

        return hf < PRECISION;
    }

    receive() external payable {}

    uint256[50] private __gap;
}
