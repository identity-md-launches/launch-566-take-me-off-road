// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Fare for Medallion 447
/// @notice A fixed-supply ERC-20 with voluntary burns and no privileged accounts.
/// @dev The deployer receives exactly 1e27 units. The separate MedallionHook intentionally
/// designates the requester's wallet as CREATOR; this token grants that wallet no privileges.
contract FareToken {
    string public constant name = "Fare for Medallion 447";
    string public constant symbol = "FARE447";
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address account => uint256 amount) public balanceOf;
    mapping(address account => mapping(address spender => uint256 amount)) public allowance;

    error InvalidReceiver();
    error InvalidSpender();
    error InsufficientBalance();
    error InsufficientAllowance();

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor() {
        totalSupply = 1e27;
        balanceOf[msg.sender] = 1e27;
        emit Transfer(address(0), msg.sender, 1e27);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        if (spender == address(0)) revert InvalidSpender();
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount);
        return true;
    }

    /// @notice Destroy the caller's tokens and reduce total supply.
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    /// @notice Destroy another holder's tokens, consuming their allowance to the caller.
    function burnFrom(address from, uint256 amount) external {
        _spendAllowance(from, msg.sender, amount);
        _burn(from, amount);
    }

    function _transfer(address from, address to, uint256 amount) private {
        if (to == address(0)) revert InvalidReceiver();
        uint256 balance = balanceOf[from];
        if (amount > balance) revert InsufficientBalance();
        unchecked {
            balanceOf[from] = balance - amount;
            // Supply is bounded by 1e27; no account can exceed it. Self-transfers are preserved.
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }

    function _burn(address from, uint256 amount) private {
        uint256 balance = balanceOf[from];
        if (amount > balance) revert InsufficientBalance();
        unchecked {
            balanceOf[from] = balance - amount;
            totalSupply -= amount;
        }
        emit Transfer(from, address(0), amount);
    }

    function _spendAllowance(address from, address spender, uint256 amount) private {
        uint256 approved = allowance[from][spender];
        if (approved != type(uint256).max) {
            if (amount > approved) revert InsufficientAllowance();
            unchecked {
                allowance[from][spender] = approved - amount;
            }
        }
    }
}
