// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Simple 6 decimal mock token used in tests and scripts.
contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}

    /// @notice Returns the token decimals.
    /// @return Token decimals.
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Mints tokens to an account.
    /// @param to Receiver of minted tokens.
    /// @param amount Amount to mint.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
