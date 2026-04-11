// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {EarnCore} from "src/EarnCore.sol";

/// @notice EN: Broadcast script that binds an already deployed share token proxy to the core proxy.
/// @custom:fa اسکریپت برادکست برای اتصال پراکسی توکن سهمِ از قبل دیپلوی‌شده به پراکسی هسته.
contract BindShareTokenScript is Script {
    error ZeroAddress(string field);

    /// @notice EN: Reads binding inputs from the environment and calls `setShareToken` on the core proxy.
    /// @custom:fa ورودی‌های اتصال را از محیط می‌خواند و `setShareToken` را روی پراکسی هسته اجرا می‌کند.
    function run() external {
        address coreProxy = vm.envAddress("EARN_PROXY");
        address shareToken = vm.envAddress("EARN_SHARE_TOKEN");
        uint256 signerPrivateKey = vm.envUint("BIND_SHARE_TOKEN_PRIVATE_KEY");

        if (coreProxy == address(0)) {
            revert ZeroAddress("EARN_PROXY");
        }
        if (shareToken == address(0)) {
            revert ZeroAddress("EARN_SHARE_TOKEN");
        }

        vm.startBroadcast(signerPrivateKey);
        EarnCore(coreProxy).setShareToken(shareToken);
        vm.stopBroadcast();
    }
}
