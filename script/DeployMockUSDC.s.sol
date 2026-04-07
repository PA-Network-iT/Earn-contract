// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {MockUSDC} from "src/mocks/MockUSDC.sol";

contract DeployMockUSDCScript is Script {
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
