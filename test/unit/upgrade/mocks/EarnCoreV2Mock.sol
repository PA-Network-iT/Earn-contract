// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {EarnCore} from "src/EarnCore.sol";

/// @notice EN: Upgrade test implementation that exposes versioning and a controlled storage mutation helper.
/// @custom:fa پیاده‌سازی تست upgrade که version و helper کنترل‌شده برای تغییر storage را expose می‌کند.
contract EarnCoreV2Mock is EarnCore {
    function version() external pure returns (string memory) {
        return "v2";
    }

    function forceMinDeposit(uint256 newMinimumAssets) external {
        _minDeposit = newMinimumAssets;
    }
}
