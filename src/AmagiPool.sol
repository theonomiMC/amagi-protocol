// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AggregatorV3Interface} from "@chainlink/interfaces/AggregatorV3Interface.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

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
contract AmagiPool is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable USDC;
    AggregatorV3Interface public priceFeed;

    uint256 public constant PRECISION = 1e18;
    uint256 public constant USDC_SCALE = 1e12;

    uint256 public constant LTV = 75;
    uint256 public constant LIQ_THRESHOLD = 80;
    uint256 public constant LIQ_BONUS = 5;
    uint256 public constant INTEREST_RATE = 10;

    uint256 public globalBorrowIndex;
    uint256 public lastUpdatedIndex;

    struct UserData {
        uint256 collateral; // ETH (1e18)
        uint256 deposit; // USDC scaled to 1e18 internally
        uint256 borrowShares; // debt shares
    }
    mapping(address => UserData) public users;

    event Deposit(address indexed user, uint256 amount);
    event CollateralDeposited(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event Borrow(address indexed user, uint256 amount);
    event Repay(address indexed user, uint256 amount);
    event Liquidate(address indexed user, address indexed liquidator, uint256 amount);

    constructor(address _usdc, address _priceFeed) {
        USDC = IERC20(_usdc);
        priceFeed = AggregatorV3Interface(_priceFeed);

        globalBorrowIndex = PRECISION; // 1e18
        lastUpdatedIndex = block.timestamp;
    }

    function getPrice() public view returns (uint256) {
        return _price();
    }

    function deposit(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        UserData storage user = users[msg.sender];
        unchecked {
            user.deposit += amount * USDC_SCALE;
        }

        USDC.safeTransferFrom(msg.sender, address(this), amount);
        emit Deposit(msg.sender, amount);
    }

    function depositCollateral() external payable {
        if (msg.value == 0) revert ZeroAmount();

        users[msg.sender].collateral += msg.value;

        emit CollateralDeposited(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        UserData storage user = users[msg.sender];

        uint256 scaled = amount * USDC_SCALE;

        if (user.deposit < scaled) revert InsufficientBalance();

        if (USDC.balanceOf(address(this)) < amount) {
            revert InsufficientLiquidity();
        }
        unchecked {
            user.deposit -= scaled;
        }
        USDC.safeTransfer(msg.sender, amount);
        emit Withdraw(msg.sender, amount);
    }

    function withdrawCollateral(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        _updateIndex();

        UserData storage user = users[msg.sender];

        if (user.collateral < amount) revert InsufficientBalance();

        uint256 price = _price();
        uint256 index = globalBorrowIndex;

        unchecked {
            user.collateral -= amount;
        }

        uint256 debt = (user.borrowShares * index) / PRECISION;
        uint256 newCollateralValue = (user.collateral * price) / PRECISION;

        if (_isLiquidatable(newCollateralValue, debt)) {
            revert InvalidHealthFactor();
        }

        (bool success,) = msg.sender.call{value: amount}("");
        if (!success) revert TransferFailed();

        emit Withdraw(msg.sender, amount);
    }

    function borrow(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        _updateIndex();

        UserData storage user = users[msg.sender];

        uint256 index = globalBorrowIndex;
        uint256 price = _price();

        uint256 collateralValue = (user.collateral * price) / PRECISION;
        uint256 debt = (user.borrowShares * index) / PRECISION;
        uint256 scaledAmount = amount * USDC_SCALE;

        uint256 maxBorrow = (collateralValue * LTV) / 100;

        if (debt + scaledAmount > maxBorrow) revert InsufficientCollateral();

        // shares = amount * PRECISION / globalBorrowIndex
        uint256 shares = (scaledAmount * PRECISION) / index;

        if (USDC.balanceOf(address(this)) < amount) {
            revert InsufficientLiquidity();
        }
        unchecked {
            user.borrowShares += shares;
        }
        USDC.safeTransfer(msg.sender, amount);
        emit Borrow(msg.sender, amount);
    }

    function repay(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        _updateIndex();

        UserData storage user = users[msg.sender];

        uint256 index = globalBorrowIndex;

        uint256 debt = (user.borrowShares * index) / PRECISION;
        uint256 scaled = amount * USDC_SCALE;

        if (scaled > debt) {
            scaled = debt;
            amount = debt / USDC_SCALE;
        }

        uint256 shares = (scaled * PRECISION) / index;

        unchecked {
            user.borrowShares -= shares;
        }

        USDC.safeTransferFrom(msg.sender, address(this), amount);
        emit Repay(msg.sender, amount);
    }

    function liquidate(address target, uint256 debtToCover) external nonReentrant {
        if (debtToCover == 0) revert ZeroAmount();

        _updateIndex();

        UserData storage user = users[target];

        uint256 index = globalBorrowIndex;
        uint256 price = _price();

        uint256 collateralValue = (user.collateral * price) / PRECISION;
        uint256 debt = (user.borrowShares * index) / PRECISION;

        if (!_isLiquidatable(collateralValue, debt)) revert HealthFactorOk();

        uint256 scaled = debtToCover * USDC_SCALE;
        if (scaled > debt) scaled = debt;

        uint256 collateralOut = (scaled * PRECISION * (100 + LIQ_BONUS)) / (price * 100);

        if (collateralOut > user.collateral) collateralOut = user.collateral;

        uint256 shares = (scaled * PRECISION) / index;
        // if (shares == 0) revert ZeroAmount();

        unchecked {
            user.borrowShares -= shares;
            user.collateral -= collateralOut;
        }

        uint256 actualDebtToCover = scaled / USDC_SCALE;
        USDC.safeTransferFrom(msg.sender, address(this), actualDebtToCover);

        (bool success,) = msg.sender.call{value: collateralOut}("");
        if (!success) revert TransferFailed();

        emit Liquidate(target, msg.sender, collateralOut);
    }

    // INTERNAL
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

    function _price() internal view returns (uint256) {
        (, int256 p,, uint256 updatedAt,) = priceFeed.latestRoundData();

        uint8 decimals = priceFeed.decimals();

        if (p <= 0) revert InvalidPrice();
        if (block.timestamp - updatedAt > 24 hours) revert PriceExpired();

        uint256 price = uint256(p);

        if (decimals < 18) {
            return price * (10 ** (18 - decimals));
        } else if (decimals > 18) {
            return price / (10 ** (decimals - 18));
        }

        return price;
    }

    function _isLiquidatable(uint256 collateralValue, uint256 debt) internal pure returns (bool) {
        if (debt == 0) return false;

        uint256 hf = (collateralValue * LIQ_THRESHOLD * PRECISION) / (100 * debt);

        return hf < PRECISION;
    }

    receive() external payable {}
}
