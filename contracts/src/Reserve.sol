// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title Reserve
/// @notice Holds ETH and tokens for one purpose: the safety fund, the boosted-pools reserve or the expansion reserve.
///         Every payment out is made by the owner, the 48-hour timelock of the admin Safe, so it is public two days
///         before it happens, with a reason. It has no other way out: no swap, no approval.
contract Reserve is Ownable2Step {
    using SafeERC20 for IERC20;

    string public purpose;

    event In(address indexed from, uint256 amount);
    event Paid(address indexed to, uint256 amount, string reason);
    event PaidToken(address indexed token, address indexed to, uint256 amount, string reason);

    error TransferFailed();

    constructor(address owner_, string memory purpose_) Ownable(owner_) {
        purpose = purpose_;
    }

    receive() external payable {
        emit In(msg.sender, msg.value);
    }

    function pay(address to, uint256 amount, string calldata reason) external onlyOwner {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit Paid(to, amount, reason);
    }

    function payToken(address token, address to, uint256 amount, string calldata reason) external onlyOwner {
        IERC20(token).safeTransfer(to, amount);
        emit PaidToken(token, to, amount, reason);
    }
}
