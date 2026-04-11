// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {EarnCore} from "src/EarnCore.sol";

/// @notice EN: Broadcast script that deploys the EARN core implementation and ERC1967 proxy.
/// @custom:fa اسکریپت برادکست برای دیپلوی پیاده‌سازی هسته EARN و پراکسی ERC1967.
contract DeployEarnScript is Script {
    error ZeroAddress(string field);

    /// @notice EN: Deploys `EarnCore`, initializes its proxy, and returns both deployed addresses.
    /// @custom:fa قرارداد `EarnCore` را دیپلوی می‌کند، پراکسی آن را مقداردهی اولیه می‌کند و هر دو آدرس را برمی‌گرداند.
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
