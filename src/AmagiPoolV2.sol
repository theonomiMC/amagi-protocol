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

/// @notice Thrawn when protocol paused
error ProtocolPaused();
/// @notice Thrown when a zero amount is passed to a function
error ZeroAmount();
/// @notice Thrown when the user does not have enough balance to complete the operation
error InsufficientBalance();
/// @notice Thrown when collateral is insufficient to cover the borrow or withdrawal
error InsufficientCollateral();
/// @notice Thrown when a withdrawal or borrow would leave the position undercollateralized
error InvalidHealthFactor();
/// @notice Thrown when trying to liquidate a healthy position
error HealthFactorOk();
/// @notice Thrown when collateral is insufficient to cover the borrow or withdrawal
error InsufficientLiquidity();
/// @notice Thrown when a native ETH transfer fails
error TransferFailed();
/// @notice Thrown when the Chainlink oracle returns a zero or negative price
error InvalidPrice();
/// @notice Thrown when the Chainlink oracle price is older than 24 hours
error PriceExpired();

contract AmagiPoolV2 is
    ReentrancyGuard,
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /// @notice The USDC token used for deposits and borrows
    IERC20 public usdc;

    /// @notice Chainlink price feed for ETH/USD
    AggregatorV3Interface public priceFeed;
    /// @notice Decimal precision of the Chainlink price feed
    uint8 public priceFeedDecimals;

    /// @notice Total USDC deposit shares
    /// in V1  - raw USDC deposited
    uint256 public totalDeposits;
    /// @notice Base precision unit used for share and price calculations
    uint256 public constant PRECISION = 1e18;
    /// @notice Scaling factor to convert USDC (6 decimals) to 18 decimals
    uint256 public constant USDC_SCALE = 10 ** 12;

    /// @notice Loan-to-value ratio — max borrow is 75% of collateral value
    uint256 public constant LTV = 75;
    /// @notice Liquidation threshold — position is liquidatable below 80% collateral ratio
    uint256 public constant LIQ_THRESHOLD = 80;
    /// @notice Liquidation bonus — liquidator receives 5% extra collateral
    uint256 public constant LIQ_BONUS = 5;

    /// @notice Global borrow index — tracks accumulated interest over time (scaled to 1e18)
    uint256 public globalBorrowIndex;
    /// @notice Timestamp of the last borrow index update
    uint256 public lastUpdatedIndex;

    /// @notice Per-user accounting data packed into two storage slots
    /// @dev collateral and borrowShares share Slot 1; deposit occupies Slot 2
    struct UserData {
        uint128 collateral;
        uint128 borrowShares;
        uint256 deposit; // user's depositShares (in V1 - user's raw deposit)
    }
    /// @notice Maps each user address to their pool position
    mapping(address => UserData) public users;

    /// @notice Maps each user address to their pool position
    event Deposit(address indexed user, uint256 amount);
    /// @notice Emitted when a user deposits ETH as collateral
    event CollateralDeposited(address indexed user, uint256 amount);
    /// @notice Emitted when a user withdraws USDC from the pool
    event Withdraw(address indexed user, uint256 amount);
    /// @notice Emitted when a user withdraws ETH collateral
    event WithdrawCollateral(address indexed user, uint256 amount);
    /// @notice Emitted when a user borrows USDC against their collateral
    event Borrow(address indexed user, uint256 amount);
    /// @notice Emitted when a user repays their USDC debt
    event Repay(address indexed user, uint256 amount);
    /// @notice Emitted when a position is liquidated
    event Liquidate(
        address indexed user,
        address indexed liquidator,
        uint256 amount
    );

    // V2 states
    /// @notice paused status. by default is false (V2 variable)
    bool public paused;
    uint256 public globalDepositIndex;
    uint256 public totalBorrowShares;
    uint256 public BASE_RATE;
    uint256 public SLOPE1;
    uint256 public SLOPE2;
    uint256 public OPTIMAL_UTIL;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initializeV2() public reinitializer(2) onlyOwner {
        BASE_RATE = 0.02e18;
        SLOPE1 = 0.1e18;
        SLOPE2 = 4.5e18;
        OPTIMAL_UTIL = 0.8e18;

        if (globalDepositIndex == 0) {
            globalDepositIndex = 1e18;
        }
        if (globalBorrowIndex == 0) globalBorrowIndex = 1e18;
        lastUpdatedIndex = block.timestamp;
        paused = false;
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}

    function setIrmParams(
        uint256 _baseRate,
        uint256 _slope1,
        uint256 _slope2,
        uint256 _optimalUtil
    ) external onlyOwner {
        BASE_RATE = _baseRate;
        SLOPE1 = _slope1;
        SLOPE2 = _slope2;
        OPTIMAL_UTIL = _optimalUtil;
    }

    function setPaused(bool status) public onlyOwner {
        paused = status;
    }

    function getUtilization() public view returns (uint256) {
        if (totalDeposits == 0) return 0; // totalDeposits = Total Shares

        uint256 totalBorrowed = _toAssets(totalBorrowShares, globalBorrowIndex);
        // Convert Global Shares back to USDC for the ratio
        uint256 totalLiquidity = _toAssets(totalDeposits, globalDepositIndex);

        return (totalBorrowed * PRECISION) / totalLiquidity;
    }

    function getBorrowRate(uint256 utilization) public view returns (uint256) {
        uint256 rate;

        if (utilization <= OPTIMAL_UTIL) {
            rate = BASE_RATE + (SLOPE1 * utilization) / PRECISION;
        } else {
            rate =
                BASE_RATE +
                (SLOPE1 * OPTIMAL_UTIL) /
                PRECISION +
                (SLOPE2 * (utilization - OPTIMAL_UTIL)) /
                PRECISION;
        }
        return rate;
    }

    function balanceOf(address _user) public view returns (uint256) {
        UserData storage user = users[_user];
        uint256 balance = _toAssets(user.deposit, globalDepositIndex);

        return balance / USDC_SCALE;
    }

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
        if (paused) revert ProtocolPaused();
        if (amount == 0) revert ZeroAmount();

        (, uint256 dIndex) = _updateIndex();

        UserData storage user = users[msg.sender];

        uint256 scaledAmount = amount * USDC_SCALE;
        uint256 shares = _toShares(scaledAmount, dIndex);

        totalDeposits += shares;
        unchecked {
            user.deposit += shares;
        }

        usdc.safeTransferFrom(msg.sender, address(this), amount);
        emit Deposit(msg.sender, amount);
    }

    /// @notice Deposits ETH as collateral for borrowing
    /// @dev msg.value is used directly; no amount parameter needed
    function depositCollateral() external payable {
        if (paused) revert ProtocolPaused();
        if (msg.value == 0) revert ZeroAmount();

        users[msg.sender].collateral += msg.value.toUint128();

        emit CollateralDeposited(msg.sender, msg.value);
    }

    /// @notice Withdraws USDC from the pool
    /// @dev Reverts if the user has insufficient balance or the pool lacks liquidity
    /// @param amount The amount of USDC to withdraw (6 decimals)
    function withdraw(uint256 amount) external nonReentrant {
        if (paused) revert ProtocolPaused();
        if (amount == 0) revert ZeroAmount();

        (, uint256 dIndex) = _updateIndex();

        UserData storage user = users[msg.sender];

        uint256 scaledAmount = amount * USDC_SCALE;
        uint256 shares = _toShares(scaledAmount, dIndex);

        if (user.deposit < shares) revert InsufficientBalance();
        if (usdc.balanceOf(address(this)) < amount) {
            revert InsufficientLiquidity();
        }

        totalDeposits -= shares;
        unchecked {
            user.deposit -= shares;
        }
        usdc.safeTransfer(msg.sender, amount);
        emit Withdraw(msg.sender, amount);
    }

    /// @notice Withdraws ETH collateral from the protocol
    /// @dev Accrues interest via _updateIndex before checking the resulting health factor
    /// @param amount The amount of ETH to withdraw (in wei)
    function withdrawCollateral(uint256 amount) external nonReentrant {
        if (paused) revert ProtocolPaused();
        if (amount == 0) revert ZeroAmount();

        (uint256 bIndex, ) = _updateIndex();
        UserData storage user = users[msg.sender];

        if (user.collateral < amount) revert InsufficientBalance();

        unchecked {
            user.collateral -= amount.toUint128();
        }

        uint256 price = _price();
        uint256 debt = _toAssets(user.borrowShares, bIndex);
        uint256 newCollateralValue = (user.collateral * price) / PRECISION;

        if (_isLiquidatable(newCollateralValue, debt)) {
            revert InvalidHealthFactor();
        }

        (bool success, ) = msg.sender.call{value: amount}("");
        if (!success) revert TransferFailed();

        emit WithdrawCollateral(msg.sender, amount);
    }

    /// @notice Borrows USDC against the caller's ETH collateral
    /// @dev Accrues interest and checks LTV before issuing debt shares
    /// @param amount The amount of USDC to borrow (6 decimals)
    function borrow(uint256 amount) external nonReentrant {
        if (paused) revert ProtocolPaused();
        if (amount == 0) revert ZeroAmount();

        (uint256 bIndex, ) = _updateIndex();

        UserData storage user = users[msg.sender];
        uint256 price = _price();

        uint256 collateralValue = (user.collateral * price) / PRECISION;
        uint256 debt = _toAssets(user.borrowShares, bIndex);
        uint256 scaledAmount = amount * USDC_SCALE;

        uint256 maxBorrow = (collateralValue * LTV) / 100;

        if (debt + scaledAmount > maxBorrow) revert InsufficientCollateral();

        // shares = amount * PRECISION / globalBorrowIndex
        uint256 shares = _toShares(scaledAmount, bIndex);

        if (usdc.balanceOf(address(this)) < amount) {
            revert InsufficientLiquidity();
        }
        totalBorrowShares += shares;
        unchecked {
            user.borrowShares += shares.toUint128();
        }
        usdc.safeTransfer(msg.sender, amount);
        emit Borrow(msg.sender, amount);
    }

    /// @notice Repays USDC debt to reduce the caller's borrow shares
    /// @dev If amount exceeds total debt, repayment is capped at current debt
    /// @param amount The amount of USDC to repay (6 decimals)
    function repay(uint256 amount) external nonReentrant {
        if (paused) revert ProtocolPaused();
        if (amount == 0) revert ZeroAmount();

        (uint256 bIndex, ) = _updateIndex();

        UserData storage user = users[msg.sender];
        uint256 debt = _toAssets(user.borrowShares, bIndex);
        if (debt == 0) revert ZeroAmount();
        
        uint256 scaledAmount = amount * USDC_SCALE;

        if (scaledAmount > debt) {
            scaledAmount = debt;
            amount = debt / USDC_SCALE;
        }

        uint256 shares = _toShares(scaledAmount, bIndex);

        totalBorrowShares -= shares;
        unchecked {
            user.borrowShares -= shares.toUint128();
        }

        usdc.safeTransferFrom(msg.sender, address(this), amount);
        emit Repay(msg.sender, amount);
    }

    /// @notice Liquidates an undercollateralized position
    /// @dev Liquidator covers part or all of the debt and receives collateral plus a bonus
    /// @param target The address of the user to be liquidated
    /// @param debtToCover The amount of USDC debt the liquidator wants to cover (6 decimals)
    function liquidate(
        address target,
        uint256 debtToCover
    ) external nonReentrant {
        if (paused) revert ProtocolPaused();
        if (debtToCover == 0) revert ZeroAmount();

        (uint256 bIndex, ) = _updateIndex();

        UserData storage user = users[target];
        uint256 price = _price();

        uint256 collateralValue = (user.collateral * price) / PRECISION;
        uint256 debt = _toAssets(user.borrowShares, bIndex);

        if (!_isLiquidatable(collateralValue, debt)) revert HealthFactorOk();

        uint256 scaledAmount = debtToCover * USDC_SCALE;
        if (scaledAmount > debt) scaledAmount = debt;

        uint256 collateralOut = (scaledAmount * PRECISION * (100 + LIQ_BONUS)) /
            (price * 100);

        if (collateralOut > user.collateral) {
            collateralOut = user.collateral;
            scaledAmount =
                (collateralOut * price * 100) /
                (PRECISION * (100 + LIQ_BONUS));
        }
        uint256 shares = _toShares(scaledAmount, bIndex);

        unchecked {
            user.borrowShares -= shares.toUint128();
            user.collateral -= collateralOut.toUint128();
            totalBorrowShares -= shares;
        }

        uint256 actualDebtToCover = scaledAmount / USDC_SCALE;
        usdc.safeTransferFrom(msg.sender, address(this), actualDebtToCover);

        (bool success, ) = msg.sender.call{value: collateralOut}("");
        if (!success) revert TransferFailed();

        emit Liquidate(target, msg.sender, collateralOut);
    }

    // @notice Calculate assets to shares
    /// @param assets Amount of assets
    /// @param index Current index
    function _toShares(
        uint256 assets,
        uint256 index
    ) internal pure returns (uint256) {
        return (assets * PRECISION) / index;
    }

    /// @notice Calculate shares to assets
    /// @param shares Amount of shares
    /// @param index Current index
    function _toAssets(
        uint256 shares,
        uint256 index
    ) internal pure returns (uint256) {
        return (shares * index) / PRECISION;
    }

    /// @return bIndex Updated global borrow index
    /// @return dIndex Updated global deposit index
    function _updateIndex() internal returns (uint256 bIndex, uint256 dIndex) {
        uint256 lastUpdated = lastUpdatedIndex; // SLOAD
        uint256 timeElapsed = block.timestamp - lastUpdated;
        bIndex = globalBorrowIndex; // SLOAD
        dIndex = globalDepositIndex;

        if (timeElapsed == 0) return (bIndex, dIndex);

        uint256 utilization = getUtilization();
        uint256 borrowRate = getBorrowRate(utilization);

        bIndex += (bIndex * borrowRate * timeElapsed) / (PRECISION * 365 days);

        uint256 depositRate = (borrowRate * utilization) / PRECISION;
        dIndex += (dIndex * depositRate * timeElapsed) / (PRECISION * 365 days);

        // update SSTOR
        globalBorrowIndex = bIndex;
        globalDepositIndex = dIndex;
        lastUpdatedIndex = block.timestamp;

        return (bIndex, dIndex);
    }

    /// @notice Returns the current ETH/USD price from Chainlink, normalized to 18 decimals
    /// @dev Reverts if price is stale (>24h) or non-positive
    /// @return The normalized price in 1e18 format
    function _price() internal view returns (uint256) {
        (, int256 p, , uint256 updatedAt, ) = priceFeed.latestRoundData();

        uint8 decimals = priceFeedDecimals;

        if (p <= 0) revert InvalidPrice();
        if (block.timestamp - updatedAt > 24 hours) revert PriceExpired();

        // casting to 'uint256' is safe because p > 0 is checked above (if p <= 0 revert)
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 price = uint256(p);

        if (decimals < 18) {
            return price * (10 ** (18 - decimals));
        } else if (decimals > 18) {
            return price / (10 ** (decimals - 18));
        }

        return price;
    }

    /// @notice Returns true if a position's health factor is below the liquidation threshold
    /// @dev Health factor = (collateralValue * LIQ_THRESHOLD * PRECISION) / (100 * debt)
    ///      Position is liquidatable when hf < PRECISION (i.e. health factor < 1)
    /// @param collateralValue Total ETH collateral value in USD (18 decimals)
    /// @param debt Total outstanding debt in USD (18 decimals)
    /// @return True if the position can be liquidated, false otherwise
    function _isLiquidatable(
        uint256 collateralValue,
        uint256 debt
    ) internal pure returns (bool) {
        if (debt == 0) return false;

        uint256 hf = (collateralValue * LIQ_THRESHOLD * PRECISION) /
            (100 * debt);

        return hf < PRECISION;
    }

    /// @notice Allows the contract to receive plain ETH transfers
    receive() external payable {}

    /// @dev Storage gap for future upgrades — preserves storage layout across versions
    uint256[43] private __gap;
}
