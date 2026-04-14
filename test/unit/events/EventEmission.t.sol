// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {EarnTestBase} from "test/shared/EarnTestBase.sol";
import {IEarnCoreSpec} from "test/shared/interfaces/EarnSpecInterfaces.sol";
import {EarnCore} from "src/EarnCore.sol";
import {EarnShareToken} from "src/EarnShareToken.sol";

/// @notice Unit tests that pin expected events for user, admin, treasury, and sponsor flows.
contract EventEmissionTest is EarnTestBase {
    event Deposited(
        address indexed caller,
        address indexed receiver,
        uint256 indexed lotId,
        uint256 assets,
        uint256 shares,
        address sponsor
    );
    event WithdrawalRequested(
        address indexed owner,
        uint256 indexed lotId,
        uint256 requestId,
        uint256 shareAmount,
        uint256 assetAmountSnapshot
    );
    event WithdrawalExecuted(address indexed owner, uint256 indexed lotId, uint256 requestId, uint256 assetsPaid);
    event AprUpdateScheduled(uint256 newAprBps, uint256 effectiveAt);
    event TreasuryRatioUpdated(uint256 newRatioBps);
    event MaxSponsorRateUpdated(uint256 newMaxSponsorRateBps);
    event SponsorAssigned(address indexed user, address indexed sponsor);
    event BlacklistUpdated(address indexed account, bool isBlacklisted);
    event SponsorBudgetFunded(
        address indexed caller, address indexed sponsor, uint256 requestedAmount, uint256 allocatedAmount
    );
    event SponsorRewardClaimed(address indexed sponsor, uint256 amount);
    event ShareTokenSet(address indexed shareToken);
    event WithdrawalCancelled(address indexed owner, uint256 indexed lotId, uint256 requestId);
    event TreasuryTransferred(address indexed caller, address indexed recipient, uint256 amount);

    function test_setShareTokenEmitsEvent() public {
        EarnCore coreImpl = new EarnCore();
        ERC1967Proxy coreProxy =
            new ERC1967Proxy(address(coreImpl), abi.encodeCall(EarnCore.initialize, (admin, asset, block.timestamp, 0)));
        EarnShareToken tokenImpl = new EarnShareToken();
        ERC1967Proxy tokenProxy = new ERC1967Proxy(
            address(tokenImpl), abi.encodeCall(EarnShareToken.initialize, ("EARN LP", "eLP", address(coreProxy)))
        );

        vm.expectEmit(true, false, false, false);
        emit ShareTokenSet(address(tokenProxy));
        vm.prank(admin);
        IEarnCoreSpec(address(coreProxy)).setShareToken(address(tokenProxy));
    }

    function test_withdrawalCancelledEmitsRequestId() public {
        vm.prank(alice);
        uint256 lotId = core.deposit(1_000e6, alice);

        vm.prank(alice);
        core.requestWithdrawal(lotId, 500e6);

        vm.expectEmit(true, true, false, true);
        emit WithdrawalCancelled(alice, lotId, 1);
        vm.prank(alice);
        core.cancelWithdrawal();
    }

    function test_treasuryTransferredEmitsCaller() public {
        vm.prank(admin);
        core.setTreasuryRatio(7_000);

        vm.prank(alice);
        core.deposit(1_000e6, alice);

        vm.expectEmit(true, true, false, true);
        emit TreasuryTransferred(admin, treasury, 700e6);
        vm.prank(admin);
        core.transferToTreasury(treasury, 700e6);
    }

    function test_depositEmitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit Deposited(alice, alice, 1, 1_000e6, 1_000e6, address(0));

        vm.prank(alice);
        core.deposit(1_000e6, alice);
    }

    function test_adminStateChangesEmitEvents() public {
        vm.expectEmit(false, false, false, true);
        emit AprUpdateScheduled(APR_20_PERCENT_BPS, INDEX_START_TIMESTAMP + 24 hours);
        vm.prank(admin);
        core.setApr(APR_20_PERCENT_BPS);

        vm.expectEmit(false, false, false, true);
        emit TreasuryRatioUpdated(5_000);
        vm.prank(admin);
        core.setTreasuryRatio(5_000);

        vm.expectEmit(false, false, false, true);
        emit MaxSponsorRateUpdated(1_500);
        vm.prank(admin);
        core.setMaxSponsorRate(1_500);

        vm.expectEmit(true, true, false, true);
        emit SponsorAssigned(alice, sponsor);
        vm.prank(admin);
        core.setSponsor(alice, sponsor);

        vm.expectEmit(true, false, false, true);
        emit BlacklistUpdated(alice, true);
        vm.prank(admin);
        core.setBlacklist(alice, true);
    }

    function test_withdrawalAndSponsorFlowsEmitEvents() public {
        vm.startPrank(admin);
        core.setSponsor(alice, sponsor);
        core.setSponsorRate(sponsor, 1_500);
        core.setApr(APR_20_PERCENT_BPS);
        vm.stopPrank();

        skip(24 hours);

        vm.prank(alice);
        uint256 lotId = core.deposit(1_000e6, alice);

        skip(180 days);
        uint256 snapshot = _expectedAssetsForShares(500e6, core.currentIndex());

        vm.expectEmit(true, true, false, true);
        emit WithdrawalRequested(alice, 1, 1, 500e6, snapshot);
        vm.prank(alice);
        core.requestWithdrawal(lotId, 500e6);

        uint256 expectedAccrued = _expectedSponsorReward(1_000e6, 1_500, 180 days);

        vm.expectEmit(true, true, false, true);
        emit SponsorBudgetFunded(admin, sponsor, expectedAccrued, expectedAccrued);
        vm.prank(admin);
        core.fundSponsorBudget(sponsor, expectedAccrued);

        skip(24 hours);

        vm.expectEmit(true, true, false, true);
        emit WithdrawalExecuted(alice, 1, 1, snapshot);
        vm.prank(alice);
        core.executeWithdrawal();

        vm.expectEmit(true, false, false, true);
        emit SponsorRewardClaimed(sponsor, 1e6);
        vm.prank(sponsor);
        core.claimSponsorReward(1e6);
    }
}
