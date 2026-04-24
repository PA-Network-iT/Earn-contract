// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {EarnCore} from "src/EarnCore.sol";

/// @notice Broadcast script that deploys the EARN core implementation and ERC1967 proxy.
contract DeployEarnScript is Script {
    error ZeroAddress(string field);

    /// @notice Deploys `EarnCore`, initializes its proxy, and returns both deployed addresses.
    /// @dev Set EARN_GENESIS_TIMESTAMP to a unix epoch for retroactive or scheduled index launch.
    ///      Omit (or set to 0) to use current block.timestamp.
    ///      Set EARN_INITIAL_APR_BPS for retro-growth from genesis. Omit for APR = 0.
    function run() external returns (address proxyAddr, address implementationAddr) {
        address admin = vm.envAddress("EARN_ADMIN");
        address asset = vm.envAddress("EARN_ASSET");
        address treasuryWallet = vm.envAddress("EARN_TREASURY_WALLET");
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        uint256 genesisTimestamp = vm.envOr("EARN_GENESIS_TIMESTAMP", block.timestamp);
        uint256 initialAprBps = vm.envOr("EARN_INITIAL_APR_BPS", uint256(0));

        if (admin == address(0)) {
            revert ZeroAddress("EARN_ADMIN");
        }
        if (asset == address(0)) {
            revert ZeroAddress("EARN_ASSET");
        }

        vm.startBroadcast(deployerPrivateKey);

        EarnCore implementation = new EarnCore();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(EarnCore.initialize, (admin, asset, treasuryWallet, genesisTimestamp, initialAprBps))
        );

        vm.stopBroadcast();

        return (address(proxy), address(implementation));
    }
}
