// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice EN: Test-only 6-decimal ERC20 used as the USDC asset.
/// @custom:fa ERC20 تستی با ۶ رقم اعشار که نقش دارایی USDC را در تست‌ها دارد.
contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
