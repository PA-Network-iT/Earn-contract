// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {EarnCore} from "src/EarnCore.sol";
import {SubscriptionManager} from "src/subscription/SubscriptionManager.sol";
import {SubscriptionNFT} from "src/subscription/SubscriptionNFT.sol";
import {PackagePassNFT} from "src/subscription/PackagePassNFT.sol";

/// @notice Step 1 of the timelocked upgrade flow: deploy the new implementation contract.
/// @dev Every proxy in this repo now enforces `scheduleUpgrade` → wait `UPGRADE_DELAY` →
///      `upgradeToAndCall`. Deploying the implementation is intentionally a separate transaction so
///      the address can be published and reviewed before the timelock starts.
///
///      Usage:
///        forge script script/upgrade/DeployImplementations.s.sol:DeployEarnCoreImplScript \
///          --tc DeployEarnCoreImplScript --rpc-url $RPC_URL --broadcast
///
///      Environment variables:
///        DEPLOYER_PRIVATE_KEY — deployer EOA
contract DeployEarnCoreImplScript is Script {
    function run() external returns (address implementation) {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);
        implementation = address(new EarnCore());
        vm.stopBroadcast();

        console.log("EarnCore implementation :", implementation);
    }
}

/// @notice Deploys a fresh `SubscriptionManager` implementation.
contract DeploySubscriptionManagerImplScript is Script {
    function run() external returns (address implementation) {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);
        implementation = address(new SubscriptionManager());
        vm.stopBroadcast();

        console.log("SubscriptionManager implementation :", implementation);
    }
}

/// @notice Deploys a fresh `SubscriptionNFT` implementation.
contract DeploySubscriptionNFTImplScript is Script {
    function run() external returns (address implementation) {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);
        implementation = address(new SubscriptionNFT());
        vm.stopBroadcast();

        console.log("SubscriptionNFT implementation :", implementation);
    }
}

/// @notice Deploys a fresh `PackagePassNFT` implementation.
contract DeployPackagePassNFTImplScript is Script {
    function run() external returns (address implementation) {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);
        implementation = address(new PackagePassNFT());
        vm.stopBroadcast();

        console.log("PackagePassNFT implementation :", implementation);
    }
}
