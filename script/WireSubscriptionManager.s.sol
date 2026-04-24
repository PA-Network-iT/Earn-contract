// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {EarnCore} from "src/EarnCore.sol";
import {SubscriptionManager} from "src/subscription/SubscriptionManager.sol";

/// @notice Wires a deployed SubscriptionManager into an already-upgraded EarnCore v2.
/// @dev    Performs three idempotent actions from an address holding DEFAULT_ADMIN_ROLE on EarnCore:
///           1. Grants SUBSCRIPTION_MANAGER_ROLE to the SubscriptionManager proxy (so it can call
///              `setSponsor` / `setSponsorRate` on the core).
///           2. Calls `EarnCore.setSubscriptionManager(manager)` which activates the subscription gate.
///           3. Optionally mints a genesis subscription to the admin address so it can act as a
///              bootstrap sponsor for new users (set `SUBSCRIPTION_MINT_GENESIS=true`).
///
/// Environment variables:
///   EARN_ADMIN_PRIVATE_KEY           — signer holding DEFAULT_ADMIN_ROLE on EarnCore AND
///                                       DEFAULT_ADMIN_ROLE on SubscriptionManager.
///   EARN_PROXY                       — EarnCore proxy address.
///   SUBSCRIPTION_MANAGER             — SubscriptionManager proxy address.
///   SUBSCRIPTION_GENESIS_USER        — optional, defaults to the signer. The address that will
///                                       receive the genesis subscription when
///                                       SUBSCRIPTION_MINT_GENESIS=true.
///   SUBSCRIPTION_MINT_GENESIS        — optional, default `false`. When `true` the script also
///                                       mints a genesis subscription.
contract WireSubscriptionManagerScript is Script {
    error ZeroAddress(string field);

    function run() external {
        uint256 adminPrivateKey = vm.envUint("EARN_ADMIN_PRIVATE_KEY");
        address earnCore = vm.envAddress("EARN_PROXY");
        address subscriptionManager = vm.envAddress("SUBSCRIPTION_MANAGER");
        bool mintGenesis = vm.envOr("SUBSCRIPTION_MINT_GENESIS", false);
        address genesisUser = vm.envOr("SUBSCRIPTION_GENESIS_USER", vm.addr(adminPrivateKey));

        if (earnCore == address(0)) revert ZeroAddress("EARN_PROXY");
        if (subscriptionManager == address(0)) revert ZeroAddress("SUBSCRIPTION_MANAGER");

        EarnCore core = EarnCore(earnCore);
        SubscriptionManager manager = SubscriptionManager(subscriptionManager);

        bytes32 smRole = core.SUBSCRIPTION_MANAGER_ROLE();

        vm.startBroadcast(adminPrivateKey);

        if (!core.hasRole(smRole, subscriptionManager)) {
            core.grantRole(smRole, subscriptionManager);
            console.log("Granted SUBSCRIPTION_MANAGER_ROLE to:", subscriptionManager);
        } else {
            console.log("SUBSCRIPTION_MANAGER_ROLE already granted, skipping");
        }

        if (core.subscriptionManager() != subscriptionManager) {
            core.setSubscriptionManager(subscriptionManager);
            console.log("EarnCore.subscriptionManager set to  :", subscriptionManager);
        } else {
            console.log("EarnCore.subscriptionManager already set, skipping");
        }

        if (mintGenesis && genesisUser != address(0)) {
            manager.adminMintGenesisSubscription(genesisUser);
            console.log("Minted genesis subscription for      :", genesisUser);
        }

        vm.stopBroadcast();
    }
}
