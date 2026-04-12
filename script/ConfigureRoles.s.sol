// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {EarnCore} from "src/EarnCore.sol";

/// @notice Broadcast script that grants operational roles to configured addresses.
contract ConfigureRolesScript is Script {
    /// @notice Loads role recipients from environment variables and grants each missing role.
    function run() external {
        EarnCore core = EarnCore(vm.envAddress("EARN_PROXY"));
        uint256 adminPrivateKey = vm.envUint("CONFIGURE_ROLES_PRIVATE_KEY");

        address parameterManager = vm.envAddress("ROLE_PARAMETER_MANAGER");
        address treasuryManager = vm.envAddress("ROLE_TREASURY_MANAGER");
        address complianceManager = vm.envAddress("ROLE_COMPLIANCE");
        address reporter = vm.envAddress("ROLE_REPORTER");
        address pauser = vm.envAddress("ROLE_PAUSER");
        address upgrader = vm.envAddress("ROLE_UPGRADER");

        vm.startBroadcast(adminPrivateKey);

        _grantIfMissing(core, core.PARAMETER_MANAGER_ROLE(), parameterManager);
        _grantIfMissing(core, core.TREASURY_MANAGER_ROLE(), treasuryManager);
        _grantIfMissing(core, core.COMPLIANCE_ROLE(), complianceManager);
        _grantIfMissing(core, core.REPORTER_ROLE(), reporter);
        _grantIfMissing(core, core.PAUSER_ROLE(), pauser);
        _grantIfMissing(core, core.UPGRADER_ROLE(), upgrader);

        vm.stopBroadcast();
    }

    /// @notice Grants a role only when a non-zero account does not already have it.
    function _grantIfMissing(EarnCore core, bytes32 role, address account) internal {
        if (account == address(0)) {
            return;
        }
        if (!core.hasRole(role, account)) {
            core.grantRole(role, account);
        }
    }
}
