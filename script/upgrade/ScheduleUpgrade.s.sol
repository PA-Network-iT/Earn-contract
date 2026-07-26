// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {IDelayedUpgradeable} from "src/upgrade/IDelayedUpgradeable.sol";

/// @notice Step 2 of the timelocked upgrade flow: start the delay for a deployed implementation.
/// @dev Works for every proxy in this repo (EarnCore, SubscriptionManager, SubscriptionNFT,
///      PackagePassNFT). The signer must hold `UPGRADER_ROLE` on the proxy.
///
///      Environment variables:
///        UPGRADER_PRIVATE_KEY   — signer holding UPGRADER_ROLE on the proxy
///        UPGRADE_PROXY          — proxy whose implementation should change
///        UPGRADE_IMPLEMENTATION — implementation deployed by `DeployImplementations.s.sol`
contract ScheduleUpgradeScript is Script {
    error ZeroAddress(string field);

    function run() external returns (uint64 executableAt) {
        uint256 upgraderPrivateKey = vm.envUint("UPGRADER_PRIVATE_KEY");
        address proxy = vm.envAddress("UPGRADE_PROXY");
        address implementation = vm.envAddress("UPGRADE_IMPLEMENTATION");

        if (proxy == address(0)) revert ZeroAddress("UPGRADE_PROXY");
        if (implementation == address(0)) revert ZeroAddress("UPGRADE_IMPLEMENTATION");

        vm.startBroadcast(upgraderPrivateKey);
        IDelayedUpgradeable(proxy).scheduleUpgrade(implementation);
        vm.stopBroadcast();

        (address scheduled,, uint64 readyAt) = IDelayedUpgradeable(proxy).scheduledUpgrade();
        executableAt = readyAt;

        console.log("Proxy                :", proxy);
        console.log("Scheduled impl       :", scheduled);
        console.log("Executable at (unix) :", executableAt);
        console.log("Run ExecuteUpgrade.s.sol after that timestamp.");
    }
}
