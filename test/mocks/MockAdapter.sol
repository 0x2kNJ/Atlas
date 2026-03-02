// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAdapter} from "../../contracts/interfaces/IAdapter.sol";

/// @notice Configurable adapter for testing. Pulls tokenIn from caller, pushes tokenOut to caller.
///         Caller must load the adapter with tokenOut before calling execute().
contract MockAdapter is IAdapter {
    using SafeERC20 for IERC20;

    uint256 public mockAmountOut;
    bool    public mockValidationFails;
    string  public mockFailReason;

    function setMockAmountOut(uint256 amount) external { mockAmountOut = amount; }

    function setValidation(bool fails, string calldata reason) external {
        mockValidationFails = fails;
        mockFailReason      = reason;
    }

    function name() external pure override returns (string memory) { return "MockAdapter"; }

    function target() external pure override returns (address) { return address(0); }

    function quote(address, address, uint256, bytes calldata)
        external view override returns (uint256)
    {
        return mockAmountOut;
    }

    function validate(address tokenIn, address tokenOut, uint256 amountIn, bytes calldata)
        external view override returns (bool, string memory)
    {
        if (tokenIn == address(0))  return (false, "tokenIn is zero");
        if (tokenOut == address(0)) return (false, "tokenOut is zero");
        if (amountIn == 0)          return (false, "amountIn is zero");
        if (mockValidationFails)    return (false, mockFailReason);
        return (true, "");
    }

    /// @notice Pulls amountIn of tokenIn from msg.sender, sends mockAmountOut of tokenOut to msg.sender.
    ///         Deliberately does NOT enforce minAmountOut — that check lives in CapabilityKernel.
    ///         This lets tests exercise the kernel's InsufficientOutput path independently.
    function execute(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256,          // minAmountOut — not enforced here
        bytes calldata
    ) external override returns (uint256 amountOut) {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        amountOut = mockAmountOut;
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
    }
}
