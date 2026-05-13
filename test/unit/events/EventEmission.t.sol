// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {EarnTestBase} from "test/shared/EarnTestBase.sol";
import {IEarnCoreSpec} from "test/shared/interfaces/EarnSpecInterfaces.sol";
import {EarnCore} from "src/EarnCore.sol";
import {EarnShareToken} from "src/EarnShareToken.sol";

/// @notice Unit tests that pin expected events for user, admin, and treasury flows.
contract EventEmissionTest is EarnTestBase {
    event Deposited(
        address indexed caller, address indexed receiver, uint256 indexed lotId, uint256 assets, uint256 shares
    );
    event WithdrawalRequested(
        address indexed owner,
        uint256 indexed requestId,
        uint256[] lotIds,
        uint256[] shareAmounts,
        uint256 assetAmountSnapshot,
        uint256 feeAmountSnapshot
    );
    event WithdrawalExecuted(
        address indexed owner, uint256 indexed requestId, uint256[] lotIds, uint256 assetsPaid, uint256 feeAmount
    );
    event AprUpdateScheduled(uint256 newAprBps, uint256 effectiveAt);
    event TreasuryRatioUpdated(uint256 newRatioBps);
    event EarlyWithdrawalFeeUpdated(uint256 newFeeBps);
    event BlacklistUpdated(address indexed account, bool isBlacklisted);
    event ShareTokenSet(address indexed shareToken);
    event WithdrawalCancelled(address indexed owner, uint256 indexed requestId, uint256[] lotIds);
    event TreasuryTransferred(address indexed caller, address indexed recipient, uint256 amount);

    function test_setShareTokenEmitsEvent() public {
        EarnCore coreImpl = new EarnCore();
        ERC1967Proxy coreProxy = new ERC1967Proxy(
            address(coreImpl), abi.encodeCall(EarnCore.initialize, (admin, asset, treasury, block.timestamp, 0))
        );
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
        core.requestWithdrawal(_singleWithdrawal(lotId, 500e6));

        uint256[] memory lotIds = new uint256[](1);
        lotIds[0] = lotId;
        vm.expectEmit(true, true, false, true);
        emit WithdrawalCancelled(alice, 1, lotIds);
        vm.prank(alice);
        core.cancelWithdrawal();
    }

    function test_treasuryTransferredEmitsCaller() public {
        vm.prank(admin);
        core.replenishBuffer(500e6);

        vm.prank(admin);
        core.reportTreasuryAssets(500e6);

        vm.expectEmit(true, true, false, true);
        emit TreasuryTransferred(admin, treasury, 500e6);
        vm.prank(admin);
        core.transferToTreasury(treasury, 500e6);
    }

    function test_depositEmitsEvent() public {
        uint256 expectedShares = (1_000e6 * 1e27) / core.currentIndex();
        vm.expectEmit(true, true, true, true);
        emit Deposited(alice, alice, 1, 1_000e6, expectedShares);

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
        emit EarlyWithdrawalFeeUpdated(1_000);
        vm.prank(admin);
        core.setEarlyWithdrawalFeeBps(1_000);

        vm.expectEmit(true, false, false, true);
        emit BlacklistUpdated(alice, true);
        vm.prank(admin);
        core.setBlacklist(alice, true);
    }

    function test_withdrawalFlowEmitsEvents() public {
        vm.prank(admin);
        core.setApr(APR_20_PERCENT_BPS);

        skip(24 hours);

        vm.prank(alice);
        uint256 lotId = core.deposit(1_000e6, alice);

        skip(180 days);
        uint256 snapshot = _expectedAssetsForShares(500e6, core.currentIndex());
        uint256[] memory lotIds = new uint256[](1);
        lotIds[0] = lotId;
        uint256[] memory shareAmounts = new uint256[](1);
        shareAmounts[0] = 500e6;

        vm.expectEmit(true, true, false, true);
        emit WithdrawalRequested(alice, 1, lotIds, shareAmounts, snapshot, 0);
        vm.prank(alice);
        core.requestWithdrawal(_singleWithdrawal(lotId, 500e6));

        skip(24 hours);

        vm.expectEmit(true, true, false, true);
        emit WithdrawalExecuted(alice, 1, lotIds, snapshot, 0);
        vm.prank(alice);
        core.executeWithdrawal();
    }

    function test_withdrawalExecutedEmitsEarlyWithdrawalFee() public {
        vm.prank(admin);
        core.setTreasuryRatio(0);
        vm.prank(admin);
        core.setEarlyWithdrawalFeeBps(1_000);

        vm.prank(alice);
        uint256 lotId = core.deposit(1_000e6, alice);

        uint256[] memory lotIds = new uint256[](1);
        lotIds[0] = lotId;

        vm.prank(alice);
        core.requestWithdrawal(_singleWithdrawal(lotId, 5_000e6));

        skip(24 hours);

        vm.expectEmit(true, true, false, true);
        emit WithdrawalExecuted(alice, 1, lotIds, 450e6, 50e6);
        vm.prank(alice);
        core.executeWithdrawal();
    }
}
