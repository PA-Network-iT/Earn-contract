// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SubscriptionManager} from "src/subscription/SubscriptionManager.sol";

/// @notice Sweeps USDC (or any token) still sitting on SubscriptionManager after the v1 era.
/// @dev    Run once after `UpgradeSubscriptionManager.s.sol` if the proxy held collected revenue.
///
/// Environment variables:
///   TREASURY_MANAGER_PRIVATE_KEY — signer with `TREASURY_MANAGER_ROLE`
///   SMGR_PROXY                   — SubscriptionManager proxy (alias: SUBSCRIPTION_MANAGER)
///   EARN_ASSET                   — payment token to sweep (USDC on mainnet)
///   EARN_TREASURY_WALLET         — sweep destination
///   SWEEP_AMOUNT                 — optional; defaults to full on-chain balance of EARN_ASSET
contract SweepSubscriptionManagerScript is Script {
    error ZeroAddress(string field);

    function run() external {
        uint256 signerPrivateKey = vm.envUint("TREASURY_MANAGER_PRIVATE_KEY");
        address managerProxy = vm.envOr("SMGR_PROXY", vm.envAddress("SUBSCRIPTION_MANAGER"));
        address paymentToken = vm.envAddress("EARN_ASSET");
        address destination = vm.envAddress("EARN_TREASURY_WALLET");

        if (managerProxy == address(0)) revert ZeroAddress("SMGR_PROXY");
        if (paymentToken == address(0)) revert ZeroAddress("EARN_ASSET");
        if (destination == address(0)) revert ZeroAddress("EARN_TREASURY_WALLET");

        uint256 amount = vm.envOr("SWEEP_AMOUNT", IERC20(paymentToken).balanceOf(managerProxy));
        if (amount == 0) {
            console.log("Nothing to sweep on", managerProxy);
            return;
        }

        vm.startBroadcast(signerPrivateKey);
        SubscriptionManager(managerProxy).sweep(paymentToken, destination, amount);
        vm.stopBroadcast();

        console.log("Swept token   :", paymentToken);
        console.log("Amount        :", amount);
        console.log("Destination   :", destination);
    }
}
