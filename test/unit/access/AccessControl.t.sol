// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {EarnTestBase} from "test/shared/EarnTestBase.sol";
import {IEarnCoreSpec} from "test/shared/interfaces/EarnSpecInterfaces.sol";
import {
    UnauthorizedUpgrade,
    InvalidShareToken,
    ShareTokenAlreadySet
} from "test/shared/interfaces/EarnSpecInterfaces.sol";
import {EarnCore} from "src/EarnCore.sol";
import {EarnShareToken} from "src/EarnShareToken.sol";
import {EarnCoreV2Mock} from "test/unit/upgrade/mocks/EarnCoreV2Mock.sol";

contract AccessControlTest is EarnTestBase {
    address internal parameterManager = makeAddr("parameterManager");
    address internal treasuryManager = makeAddr("treasuryManager");
    address internal complianceOfficer = makeAddr("complianceOfficer");
    address internal reporter = makeAddr("reporter");
    address internal pauser = makeAddr("pauser");
    address internal upgrader = makeAddr("upgrader");

    function setUp() public override {
        super.setUp();
        _fundAndApprove(treasuryManager, 10_000_000e6);
    }

    function test_adminStartsWithAllOperationalRoles() public view {
        assertTrue(core.hasRole(core.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(core.hasRole(core.PARAMETER_MANAGER_ROLE(), admin));
        assertTrue(core.hasRole(core.TREASURY_MANAGER_ROLE(), admin));
        assertTrue(core.hasRole(core.COMPLIANCE_ROLE(), admin));
        assertTrue(core.hasRole(core.REPORTER_ROLE(), admin));
        assertTrue(core.hasRole(core.PAUSER_ROLE(), admin));
        assertTrue(core.hasRole(core.UPGRADER_ROLE(), admin));
    }

    function test_scopedRolesGateAdminFunctions() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, core.PARAMETER_MANAGER_ROLE()
            )
        );
        vm.prank(alice);
        core.setApr(APR_20_PERCENT_BPS);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, core.PARAMETER_MANAGER_ROLE()
            )
        );
        vm.prank(alice);
        core.setMinDeposit(100_000);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, core.COMPLIANCE_ROLE()
            )
        );
        vm.prank(alice);
        core.setBlacklist(alice, true);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, core.PAUSER_ROLE())
        );
        vm.prank(alice);
        core.setWithdrawalPause(true, true);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, core.REPORTER_ROLE()
            )
        );
        vm.prank(alice);
        core.reportTreasuryAssets(1_000e6);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, core.TREASURY_MANAGER_ROLE()
            )
        );
        vm.prank(alice);
        core.fundSponsorBudget(sponsor, 1_000e6);
    }

    function test_defaultAdminCanDelegateScopedRoles() public {
        EarnCoreV2Mock newImplementation = new EarnCoreV2Mock();

        vm.startPrank(admin);
        core.grantRole(core.PARAMETER_MANAGER_ROLE(), parameterManager);
        core.grantRole(core.TREASURY_MANAGER_ROLE(), treasuryManager);
        core.grantRole(core.COMPLIANCE_ROLE(), complianceOfficer);
        core.grantRole(core.REPORTER_ROLE(), reporter);
        core.grantRole(core.PAUSER_ROLE(), pauser);
        core.grantRole(core.UPGRADER_ROLE(), upgrader);
        vm.stopPrank();

        vm.prank(parameterManager);
        core.setApr(APR_20_PERCENT_BPS);

        vm.prank(parameterManager);
        core.setTreasuryRatio(5_000);

        vm.prank(parameterManager);
        core.setMinDeposit(100_000);

        vm.prank(complianceOfficer);
        core.setBlacklist(alice, true);
        assertTrue(core.isBlacklisted(alice));

        vm.prank(pauser);
        core.setWithdrawalPause(true, false);
        assertTrue(core.requestWithdrawalPaused());

        vm.prank(reporter);
        core.reportTreasuryAssets(123e6);
        assertEq(core.totals().treasuryReportedAssets, 123e6);

        vm.prank(parameterManager);
        core.setSponsor(alice, sponsor);
        vm.prank(parameterManager);
        core.setSponsorRate(sponsor, 1_000);

        vm.prank(treasuryManager);
        core.fundSponsorBudget(sponsor, 1e6);

        vm.prank(upgrader);
        core.upgradeToAndCall(address(newImplementation), "");
    }

    function test_nonAdminCannotGrantRoles() public {
        bytes32 adminRole = core.DEFAULT_ADMIN_ROLE();
        bytes32 parameterRole = core.PARAMETER_MANAGER_ROLE();

        vm.startPrank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, adminRole)
        );
        core.grantRole(parameterRole, parameterManager);
        vm.stopPrank();
    }

    function test_revokedRoleLosesAccess() public {
        vm.startPrank(admin);
        core.grantRole(core.REPORTER_ROLE(), reporter);
        core.revokeRole(core.REPORTER_ROLE(), reporter);
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, reporter, core.REPORTER_ROLE()
            )
        );
        vm.prank(reporter);
        core.reportTreasuryAssets(1_000e6);
    }

    function test_upgradeStillRejectsCallerWithoutUpgraderRole() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(UnauthorizedUpgrade.selector, alice));
        core.upgradeToAndCall(address(0xBEEF), "");
    }

    function test_onlyDefaultAdminCanSetShareToken() public {
        EarnShareToken implementation = new EarnShareToken();
        ERC1967Proxy tokenProxy = new ERC1967Proxy(
            address(implementation), abi.encodeCall(EarnShareToken.initialize, ("EARN LP", "eLP", address(core)))
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, core.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(alice);
        core.setShareToken(address(tokenProxy));
    }

    function test_shareTokenCanOnlyBeSetOnce() public {
        EarnShareToken implementation = new EarnShareToken();
        ERC1967Proxy tokenProxy = new ERC1967Proxy(
            address(implementation), abi.encodeCall(EarnShareToken.initialize, ("EARN LP", "eLP", address(core)))
        );

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ShareTokenAlreadySet.selector, address(shareToken)));
        core.setShareToken(address(tokenProxy));
    }

    function test_shareTokenMustBeOwnedByCore() public {
        EarnCore coreImplementation = new EarnCore();
        ERC1967Proxy coreProxy =
            new ERC1967Proxy(address(coreImplementation), abi.encodeCall(EarnCore.initialize, (admin, asset)));
        IEarnCoreSpec freshCore = IEarnCoreSpec(address(coreProxy));

        EarnShareToken implementation = new EarnShareToken();
        ERC1967Proxy tokenProxy = new ERC1967Proxy(
            address(implementation), abi.encodeCall(EarnShareToken.initialize, ("EARN LP", "eLP", admin))
        );

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(InvalidShareToken.selector, address(tokenProxy)));
        freshCore.setShareToken(address(tokenProxy));
    }
}
