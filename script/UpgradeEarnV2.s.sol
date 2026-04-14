// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {EarnCore} from "src/EarnCore.sol";

/// @notice Deploys a new EarnCore implementation and upgrades the existing proxy via
///         `upgradeToAndCall`, running `initializeV2` to set a retroactive APR on the
///         genesis checkpoint.
contract UpgradeEarnV2Script is Script {
    function run() external returns (address newImplementation) {
        address proxy = vm.envAddress("EARN_PROXY");
        uint256 initialAprBps = vm.envOr("EARN_INITIAL_APR_BPS", uint256(0));
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        EarnCore impl = new EarnCore();

        EarnCore(proxy).upgradeToAndCall(
            address(impl), abi.encodeCall(EarnCore.initializeV2, (initialAprBps))
        );

        vm.stopBroadcast();

        return address(impl);
    }
}
