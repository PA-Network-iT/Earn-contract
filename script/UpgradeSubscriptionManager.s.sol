// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {SubscriptionManager} from "src/subscription/SubscriptionManager.sol";

/// @notice Upgrades an already-deployed SubscriptionManager proxy to the v2 implementation
///         that routes revenue to `_treasuryWallet`, and sets the treasury wallet in the same tx.
/// @dev    Requires a signer with `UPGRADER_ROLE` and `DEFAULT_ADMIN_ROLE` on the proxy
///         (typically the same ops EOA / multisig executor).
///
/// Environment variables:
///   UPGRADER_PRIVATE_KEY   — signer authorized to call `upgradeToAndCall`
///   SMGR_PROXY             — SubscriptionManager proxy (alias: SUBSCRIPTION_MANAGER)
///   EARN_TREASURY_WALLET   — treasury wallet that receives all future revenue
contract UpgradeSubscriptionManagerScript is Script {
    error ZeroAddress(string field);

    function run() external returns (address newImplementation) {
        uint256 upgraderPrivateKey = vm.envUint("UPGRADER_PRIVATE_KEY");
        address managerProxy = vm.envOr("SMGR_PROXY", vm.envAddress("SUBSCRIPTION_MANAGER"));
        address treasuryWallet = vm.envAddress("EARN_TREASURY_WALLET");

        if (managerProxy == address(0)) revert ZeroAddress("SMGR_PROXY");
        if (treasuryWallet == address(0)) revert ZeroAddress("EARN_TREASURY_WALLET");

        vm.startBroadcast(upgraderPrivateKey);

        SubscriptionManager newImpl = new SubscriptionManager();
        SubscriptionManager(managerProxy).upgradeToAndCall(
            address(newImpl), abi.encodeCall(SubscriptionManager.initializeTreasuryWallet, (treasuryWallet))
        );

        vm.stopBroadcast();

        newImplementation = address(newImpl);
        console.log("SubscriptionManager proxy :", managerProxy);
        console.log("New implementation        :", newImplementation);
        console.log("Treasury wallet           :", treasuryWallet);
    }
}
