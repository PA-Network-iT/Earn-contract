// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {SubscriptionNFT} from "src/subscription/SubscriptionNFT.sol";
import {PackagePassNFT} from "src/subscription/PackagePassNFT.sol";
import {SubscriptionManager} from "src/subscription/SubscriptionManager.sol";

/// @notice Deploys the subscription suite (SubscriptionNFT, PackagePassNFT, SubscriptionManager)
///         behind ERC1967 proxies and wires the NFTs to the manager.
/// @dev    Run AFTER `EarnCore` is deployed. Run BEFORE calling `EarnCore.setSubscriptionManager`
///         (see `WireSubscriptionManager.s.sol`).
///
/// Environment variables:
///   DEPLOYER_PRIVATE_KEY             — deployer EOA (sends all three deploys + setManager calls)
///   SUBSCRIPTION_ADMIN               — admin for NFT proxies + SubscriptionManager
///                                       (must also hold DEFAULT_ADMIN_ROLE on EarnCore to run the
///                                       second script)
///   EARN_PROXY                       — EarnCore proxy (passed into SubscriptionManager.initialize)
///   EARN_ASSET                       — payment token (USDC) consumed by SubscriptionManager
///   SUBSCRIPTION_PRICE               — initial subscription price in token decimals (e.g. 1e6 USDC)
///   SUBSCRIPTION_SET_MANAGER         — optional, default `true`. When true, the deployer calls
///                                       `setManager` on both NFTs so SubscriptionManager can mint.
///                                       Requires deployer to hold DEFAULT_ADMIN_ROLE on the NFTs
///                                       at the moment of the call (true by construction because
///                                       the proxies were just initialized with `admin=deployer`
///                                       if SUBSCRIPTION_ADMIN equals the deployer, or must be
///                                       performed manually otherwise — set to `false` in that
///                                       case).
contract DeploySubscriptionSuiteScript is Script {
    error ZeroAddress(string field);
    error InvalidPrice();

    struct Deployment {
        address subscriptionNFTProxy;
        address subscriptionNFTImpl;
        address packagePassNFTProxy;
        address packagePassNFTImpl;
        address subscriptionManagerProxy;
        address subscriptionManagerImpl;
    }

    function run() external returns (Deployment memory deployment) {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address admin = vm.envAddress("SUBSCRIPTION_ADMIN");
        address earnCore = vm.envAddress("EARN_PROXY");
        address asset = vm.envAddress("EARN_ASSET");
        uint256 subscriptionPrice = vm.envUint("SUBSCRIPTION_PRICE");
        bool setManager = vm.envOr("SUBSCRIPTION_SET_MANAGER", true);

        if (admin == address(0)) revert ZeroAddress("SUBSCRIPTION_ADMIN");
        if (earnCore == address(0)) revert ZeroAddress("EARN_PROXY");
        if (asset == address(0)) revert ZeroAddress("EARN_ASSET");
        if (subscriptionPrice == 0) revert InvalidPrice();

        vm.startBroadcast(deployerPrivateKey);

        SubscriptionNFT subImpl = new SubscriptionNFT();
        ERC1967Proxy subProxy = new ERC1967Proxy(
            address(subImpl), abi.encodeCall(SubscriptionNFT.initialize, (admin))
        );

        PackagePassNFT passImpl = new PackagePassNFT();
        ERC1967Proxy passProxy = new ERC1967Proxy(
            address(passImpl), abi.encodeCall(PackagePassNFT.initialize, (admin))
        );

        SubscriptionManager managerImpl = new SubscriptionManager();
        ERC1967Proxy managerProxy = new ERC1967Proxy(
            address(managerImpl),
            abi.encodeCall(
                SubscriptionManager.initialize,
                (admin, earnCore, address(subProxy), address(passProxy), asset, subscriptionPrice)
            )
        );

        if (setManager) {
            SubscriptionNFT(address(subProxy)).setManager(address(managerProxy));
            PackagePassNFT(address(passProxy)).setManager(address(managerProxy));
        }

        vm.stopBroadcast();

        deployment = Deployment({
            subscriptionNFTProxy: address(subProxy),
            subscriptionNFTImpl: address(subImpl),
            packagePassNFTProxy: address(passProxy),
            packagePassNFTImpl: address(passImpl),
            subscriptionManagerProxy: address(managerProxy),
            subscriptionManagerImpl: address(managerImpl)
        });

        console.log("SubscriptionNFT proxy     :", deployment.subscriptionNFTProxy);
        console.log("SubscriptionNFT impl      :", deployment.subscriptionNFTImpl);
        console.log("PackagePassNFT  proxy     :", deployment.packagePassNFTProxy);
        console.log("PackagePassNFT  impl      :", deployment.packagePassNFTImpl);
        console.log("SubscriptionManager proxy :", deployment.subscriptionManagerProxy);
        console.log("SubscriptionManager impl  :", deployment.subscriptionManagerImpl);
    }
}
