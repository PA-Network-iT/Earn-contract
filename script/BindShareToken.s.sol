// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {EarnCore} from "src/EarnCore.sol";

contract BindShareTokenScript is Script {
    error ZeroAddress(string field);

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
