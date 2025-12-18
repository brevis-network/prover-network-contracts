// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title WrappedNativeToken
 * @notice Wrapped native gas token (similar to WETH) for use as staking and market fee token
 * @dev Allows depositing native gas token and receiving ERC20 tokens, and vice versa
 */
contract WrappedNativeToken is ERC20 {
    event Deposit(address indexed account, uint256 amount);
    event Withdrawal(address indexed account, uint256 amount);

    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    /**
     * @notice Deposit native tokens and receive wrapped tokens
     */
    function deposit() public payable {
        _mint(msg.sender, msg.value);
        emit Deposit(msg.sender, msg.value);
    }

    /**
     * @notice Withdraw native tokens by burning wrapped tokens
     * @param amount Amount of wrapped tokens to burn
     */
    function withdraw(uint256 amount) public {
        _burn(msg.sender, amount);
        payable(msg.sender).transfer(amount);
        emit Withdrawal(msg.sender, amount);
    }

    /**
     * @notice Fallback function to allow receiving native tokens
     * @dev Automatically wraps received native tokens
     */
    receive() external payable {
        deposit();
    }
}
