// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {EarnCore} from "src/EarnCore.sol";

contract DeployEarnScript is Script {
    error ZeroAddress(string field);

    function run() external returns (address proxyAddr, address implementationAddr) {
        address admin = vm.envAddress("EARN_ADMIN");
        address asset = vm.envAddress("EARN_ASSET");
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        if (admin == address(0)) {
            revert ZeroAddress("EARN_ADMIN");
        }
        if (asset == address(0)) {
            revert ZeroAddress("EARN_ASSET");
        }

        vm.startBroadcast(deployerPrivateKey);

        EarnCore implementation = new EarnCore();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(implementation), abi.encodeCall(EarnCore.initialize, (admin, asset)));

        vm.stopBroadcast();

        return (address(proxy), address(implementation));
    }
}
