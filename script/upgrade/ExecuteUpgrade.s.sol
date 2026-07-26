// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {IDelayedUpgradeable} from "src/upgrade/IDelayedUpgradeable.sol";

/// @notice Step 3 of the timelocked upgrade flow: install a scheduled implementation.
/// @dev Fails fast (before broadcasting) when nothing is scheduled, when the scheduled address does
///      not match, or when the delay has not elapsed — the proxy enforces the same rules on-chain.
///
///      Environment variables:
///        UPGRADER_PRIVATE_KEY   — signer holding UPGRADER_ROLE on the proxy
///        UPGRADE_PROXY          — proxy whose implementation should change
///        UPGRADE_IMPLEMENTATION — implementation previously passed to `scheduleUpgrade`
///        UPGRADE_CALLDATA       — optional post-upgrade call (e.g. a reinitializer), default empty
contract ExecuteUpgradeScript is Script {
    error ZeroAddress(string field);
    error NothingScheduled(address proxy);
    error ScheduledImplementationMismatch(address scheduled, address requested);
    error DelayNotElapsed(uint256 executableAt, uint256 currentTime);

    function run() external {
        uint256 upgraderPrivateKey = vm.envUint("UPGRADER_PRIVATE_KEY");
        address proxy = vm.envAddress("UPGRADE_PROXY");
        address implementation = vm.envAddress("UPGRADE_IMPLEMENTATION");
        bytes memory data = vm.envOr("UPGRADE_CALLDATA", bytes(""));

        if (proxy == address(0)) revert ZeroAddress("UPGRADE_PROXY");
        if (implementation == address(0)) revert ZeroAddress("UPGRADE_IMPLEMENTATION");

        (address scheduled,, uint64 executableAt) = IDelayedUpgradeable(proxy).scheduledUpgrade();
        if (scheduled == address(0)) revert NothingScheduled(proxy);
        if (scheduled != implementation) revert ScheduledImplementationMismatch(scheduled, implementation);
        if (block.timestamp < executableAt) revert DelayNotElapsed(executableAt, block.timestamp);

        vm.startBroadcast(upgraderPrivateKey);
        IDelayedUpgradeable(proxy).upgradeToAndCall(implementation, data);
        vm.stopBroadcast();

        console.log("Proxy          :", proxy);
        console.log("New impl       :", implementation);
        console.log("Upgrade executed.");
    }
}
