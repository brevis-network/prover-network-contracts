// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title TokenFaucet
 * @notice Testnet token faucet with cooldown and percentage-based limits
 */
contract TokenFaucet is Ownable {
    using SafeERC20 for IERC20;

    /// @notice Maximum percentage of balance drippable (in basis points, e.g., 100 = 1%)
    uint256 public dripPercentBps = 1; // default: 0.01%

    /// @notice Maximum amount per drip for each token (0 = use percentage only)
    mapping(address => uint256) public maxDripAmount;

    /// @notice Cooldown period between drips (in seconds)
    uint256 public cooldownPeriod = 43200; // default: 12 hours

    /// @notice Tracks the last drip timestamp for each address
    mapping(address => uint256) public lastDripTime;

    error DripTooSoon(uint256 remainingTime);
    error FaucetEmpty();
    error InvalidPercent();

    constructor() Ownable(msg.sender) {}

    function drip(address[] calldata tokens) external {
        uint256 lastDrip = lastDripTime[msg.sender];

        if (block.timestamp - lastDrip < cooldownPeriod) {
            revert DripTooSoon(cooldownPeriod - (block.timestamp - lastDrip));
        }
        lastDripTime[msg.sender] = block.timestamp;

        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 drippableAmount = getDripAmount(tokens[i]);
            if (drippableAmount == 0) revert FaucetEmpty();

            IERC20(tokens[i]).safeTransfer(msg.sender, drippableAmount);
        }
    }

    function getDripAmount(address token) public view returns (uint256) {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance == 0) return 0;

        uint256 percentAmount = (balance * dripPercentBps) / 10000;
        uint256 maxAmount = maxDripAmount[token];

        return maxAmount == 0 ? percentAmount : (maxAmount < percentAmount ? maxAmount : percentAmount);
    }

    function getRemainingCooldown(address account) external view returns (uint256) {
        uint256 lastDrip = lastDripTime[account];
        if (lastDrip == 0) return 0;

        uint256 timeElapsed = block.timestamp - lastDrip;
        return timeElapsed >= cooldownPeriod ? 0 : cooldownPeriod - timeElapsed;
    }

    function setMaxDripAmount(address token, uint256 amount) external onlyOwner {
        maxDripAmount[token] = amount;
    }

    function setDripPercentBps(uint256 _dripPercentBps) external onlyOwner {
        if (_dripPercentBps == 0 || _dripPercentBps > 10000) revert InvalidPercent();
        dripPercentBps = _dripPercentBps;
    }

    function setCooldownPeriod(uint256 _cooldownPeriod) external onlyOwner {
        cooldownPeriod = _cooldownPeriod;
    }

    function drainToken(address token, address recipient, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(recipient, amount);
    }
}
