// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {EarnShareToken} from "src/EarnShareToken.sol";

/// @notice Broadcast script that deploys the non-transferable share token implementation and proxy.
contract DeployEarnShareTokenScript is Script {
    error ZeroAddress(string field);

    /// @notice Deploys `EarnShareToken`, initializes its proxy with the core controller, and returns both addresses.
    function run() external returns (address proxyAddr, address implementationAddr) {
        address coreProxy = vm.envAddress("EARN_PROXY");
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        if (coreProxy == address(0)) {
            revert ZeroAddress("EARN_PROXY");
        }

        vm.startBroadcast(deployerPrivateKey);

        EarnShareToken implementation = new EarnShareToken();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation), abi.encodeCall(EarnShareToken.initialize, ("EARN LP", "eLP", coreProxy))
        );

        vm.stopBroadcast();

        return (address(proxy), address(implementation));
    }
}
