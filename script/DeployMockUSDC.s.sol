// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {MockUSDC} from "src/mocks/MockUSDC.sol";

/// @notice EN: Broadcast script that deploys the local/staging mock USDC token.
/// @custom:fa اسکریپت برادکست برای دیپلوی توکن USDC آزمایشی در محیط محلی یا staging.
contract DeployMockUSDCScript is Script {
    /// @notice EN: Deploys `MockUSDC` and optionally mints an initial balance for testing.
    /// @custom:fa قرارداد `MockUSDC` را دیپلوی می‌کند و در صورت تنظیم، موجودی اولیه تستی mint می‌کند.
    function run() external returns (address tokenAddr) {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address initialMintTo = vm.envAddress("MOCK_USDC_MINT_TO");
        uint256 initialMintAmount = vm.envUint("MOCK_USDC_MINT_AMOUNT");

        vm.startBroadcast(deployerPrivateKey);

        MockUSDC token = new MockUSDC();
        if (initialMintTo != address(0) && initialMintAmount > 0) {
            token.mint(initialMintTo, initialMintAmount);
        }

        vm.stopBroadcast();

        return address(token);
    }
}
