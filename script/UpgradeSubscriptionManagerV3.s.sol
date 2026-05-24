// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {SubscriptionManager} from "src/subscription/SubscriptionManager.sol";

/// @notice Logic-only upgrade: ships the sponsor-payout fix
///         (`safeTransfer` -> `safeTransferFrom(msg.sender, sponsor, price)`).
///         No storage layout change, no reinitializer call.
///
/// Environment variables:
///   UPGRADER_PRIVATE_KEY   — signer authorized to call `upgradeToAndCall`
///   SMGR_PROXY             — SubscriptionManager proxy (alias: SUBSCRIPTION_MANAGER)
contract UpgradeSubscriptionManagerV3Script is Script {
    error ZeroAddress(string field);

    function run() external returns (address newImplementation) {
        uint256 upgraderPrivateKey = vm.envUint("UPGRADER_PRIVATE_KEY");
        address managerProxy = vm.envOr("SMGR_PROXY", vm.envAddress("SUBSCRIPTION_MANAGER"));
        if (managerProxy == address(0)) revert ZeroAddress("SMGR_PROXY");

        vm.startBroadcast(upgraderPrivateKey);

        SubscriptionManager newImpl = new SubscriptionManager();
        SubscriptionManager(managerProxy).upgradeToAndCall(address(newImpl), "");

        vm.stopBroadcast();

        newImplementation = address(newImpl);
        console.log("SubscriptionManager proxy :", managerProxy);
        console.log("New implementation        :", newImplementation);
    }
}
