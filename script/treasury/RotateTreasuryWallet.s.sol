// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {ITreasuryWalletTimelock} from "src/treasury/ITreasuryWalletTimelock.sol";

/// @notice Step 1 of the two-step treasury wallet rotation.
/// @dev Works for `EarnCore` and `SubscriptionManager`. The signer must hold `DEFAULT_ADMIN_ROLE`
///      on the target proxy. Nothing changes until `AcceptTreasuryWalletScript` runs after
///      `TREASURY_WALLET_CHANGE_DELAY`.
///
///      Environment variables:
///        TREASURY_ADMIN_PRIVATE_KEY — signer holding DEFAULT_ADMIN_ROLE on the target
///        TREASURY_TARGET            — EarnCore or SubscriptionManager proxy
///        EARN_TREASURY_WALLET       — candidate treasury wallet
contract ProposeTreasuryWalletScript is Script {
    error ZeroAddress(string field);

    function run() external returns (uint64 executableAt) {
        uint256 adminPrivateKey = vm.envUint("TREASURY_ADMIN_PRIVATE_KEY");
        address target = vm.envAddress("TREASURY_TARGET");
        address newTreasuryWallet = vm.envAddress("EARN_TREASURY_WALLET");

        if (target == address(0)) revert ZeroAddress("TREASURY_TARGET");
        if (newTreasuryWallet == address(0)) revert ZeroAddress("EARN_TREASURY_WALLET");

        vm.startBroadcast(adminPrivateKey);
        ITreasuryWalletTimelock(target).proposeTreasuryWallet(newTreasuryWallet);
        vm.stopBroadcast();

        (address pending,, uint64 readyAt) = ITreasuryWalletTimelock(target).pendingTreasuryWallet();
        executableAt = readyAt;

        console.log("Target               :", target);
        console.log("Current wallet       :", ITreasuryWalletTimelock(target).treasuryWallet());
        console.log("Proposed wallet      :", pending);
        console.log("Acceptable at (unix) :", executableAt);
    }
}

/// @notice Step 2 of the two-step treasury wallet rotation.
/// @dev Fails fast (before broadcasting) when nothing is pending, the pending wallet differs from
///      the expected one, or the delay has not elapsed — the target enforces the same rules
///      on-chain.
///
///      Environment variables:
///        TREASURY_ADMIN_PRIVATE_KEY — signer holding DEFAULT_ADMIN_ROLE on the target
///        TREASURY_TARGET            — EarnCore or SubscriptionManager proxy
///        EARN_TREASURY_WALLET       — wallet expected to be pending
contract AcceptTreasuryWalletScript is Script {
    error ZeroAddress(string field);
    error NothingProposed(address target);
    error PendingWalletMismatch(address pending, address expected);
    error DelayNotElapsed(uint256 executableAt, uint256 currentTime);

    function run() external {
        uint256 adminPrivateKey = vm.envUint("TREASURY_ADMIN_PRIVATE_KEY");
        address target = vm.envAddress("TREASURY_TARGET");
        address expectedTreasuryWallet = vm.envAddress("EARN_TREASURY_WALLET");

        if (target == address(0)) revert ZeroAddress("TREASURY_TARGET");
        if (expectedTreasuryWallet == address(0)) revert ZeroAddress("EARN_TREASURY_WALLET");

        (address pending,, uint64 executableAt) = ITreasuryWalletTimelock(target).pendingTreasuryWallet();
        if (pending == address(0)) revert NothingProposed(target);
        if (pending != expectedTreasuryWallet) revert PendingWalletMismatch(pending, expectedTreasuryWallet);
        if (block.timestamp < executableAt) revert DelayNotElapsed(executableAt, block.timestamp);

        vm.startBroadcast(adminPrivateKey);
        ITreasuryWalletTimelock(target).acceptTreasuryWallet(expectedTreasuryWallet);
        vm.stopBroadcast();

        console.log("Target             :", target);
        console.log("New treasury wallet:", ITreasuryWalletTimelock(target).treasuryWallet());
    }
}

/// @notice Cancels a pending treasury wallet rotation.
/// @dev Environment variables: `TREASURY_ADMIN_PRIVATE_KEY`, `TREASURY_TARGET`.
contract CancelTreasuryWalletProposalScript is Script {
    error ZeroAddress(string field);

    function run() external {
        uint256 adminPrivateKey = vm.envUint("TREASURY_ADMIN_PRIVATE_KEY");
        address target = vm.envAddress("TREASURY_TARGET");
        if (target == address(0)) revert ZeroAddress("TREASURY_TARGET");

        vm.startBroadcast(adminPrivateKey);
        ITreasuryWalletTimelock(target).cancelTreasuryWalletProposal();
        vm.stopBroadcast();

        console.log("Cancelled pending treasury wallet on:", target);
    }
}
