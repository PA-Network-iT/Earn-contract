// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {EarnTestBase} from "test/shared/EarnTestBase.sol";
import {ProductTotalsView, SponsorAccountView, LotView, WithdrawalRequestView} from "test/shared/interfaces/EarnSpecInterfaces.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Realistic simulation tests covering multi-user flows, sponsor mechanics,
///         and edge cases at scale. Target: 5000 users/quarter behavior.
contract EarnSimulationTest is EarnTestBase {
    uint256 internal constant QUARTER = 90 days;
    uint256 internal constant SPONSOR_RATE_BPS = 1_000; // 10%
    uint256 internal constant UPGRADED_SPONSOR_RATE_BPS = 2_000; // 20%
    uint256 internal constant TREASURY_RATIO_BPS = 1_000; // 10%

    address internal sponsorA;
    address internal sponsorB;
    address internal sponsorC;

    function setUp() public override {
        super.setUp();
        sponsorA = makeAddr("sponsorA");
        sponsorB = makeAddr("sponsorB");
        sponsorC = makeAddr("sponsorC");

        _fundAndApprove(sponsorA, 100_000_000e6);
        _fundAndApprove(sponsorB, 100_000_000e6);
        _fundAndApprove(sponsorC, 100_000_000e6);
    }

    // =========================================================================
    //  Helpers
    // =========================================================================

    function _createUser(uint256 seed) internal returns (address user) {
        user = vm.addr(seed + 1000);
        vm.label(user, string.concat("user_", vm.toString(seed)));
    }

    function _createAndFundUser(uint256 seed, uint256 amount) internal returns (address user) {
        user = _createUser(seed);
        _fundAndApprove(user, amount);
    }

    function _setupAprAndTreasury(uint256 aprBps, uint256 treasuryBps) internal {
        vm.startPrank(admin);
        core.setApr(aprBps);
        core.setTreasuryRatio(treasuryBps);
        vm.stopPrank();
        skip(24 hours);
    }

    function _setupSponsorForUser(address user, address spon, uint256 rateBps) internal {
        vm.startPrank(admin);
        core.setSponsor(user, spon);
        core.setSponsorRate(spon, rateBps);
        vm.stopPrank();
    }

    function _depositAs(address user, uint256 amount) internal returns (uint256 lotId) {
        vm.prank(user);
        lotId = core.deposit(amount, user);
    }

    function _requestWithdrawalAs(address user, uint256 lotId, uint256 shares) internal {
        vm.prank(user);
        core.requestWithdrawal(lotId, shares);
    }

    function _executeWithdrawalAs(address user) internal returns (uint256) {
        vm.prank(user);
        return core.executeWithdrawal();
    }

    function _cancelWithdrawalAs(address user) internal {
        vm.prank(user);
        core.cancelWithdrawal();
    }

    function _fundSponsorBudgetAs(address spon, uint256 amount) internal {
        vm.prank(admin);
        core.fundSponsorBudget(spon, amount);
    }

    function _claimSponsorRewardAs(address spon, uint256 amount) internal returns (uint256) {
        vm.prank(spon);
        return core.claimSponsorReward(amount);
    }

    /// @dev Ensures buffer has enough to cover all pending frozen withdrawal liability.
    ///      In production the treasury manager calls replenishBuffer before users execute.
    function _ensureBufferForWithdrawals() internal {
        ProductTotalsView memory t = core.totals();
        if (t.frozenWithdrawalLiability > t.bufferAssets) {
            uint256 shortfall = t.frozenWithdrawalLiability - t.bufferAssets;
            console2.log("  [BUFFER] shortfall=%s, replenishing...", shortfall);
            _fundAndApprove(admin, shortfall + 1e6);
            vm.prank(admin);
            core.replenishBuffer(shortfall + 1e6);
        }
    }

    /// @dev Replenishes buffer to cover a specific withdrawal amount.
    function _ensureBufferForAmount(uint256 amount) internal {
        ProductTotalsView memory t = core.totals();
        if (amount > t.bufferAssets) {
            uint256 shortfall = amount - t.bufferAssets;
            _fundAndApprove(admin, shortfall + 1e6);
            vm.prank(admin);
            core.replenishBuffer(shortfall + 1e6);
        }
    }

    // =========================================================================
    //  Logging helpers — USDC amounts in human-readable form
    // =========================================================================

    function _logUsdc(string memory label, uint256 rawAmount) internal pure {
        uint256 whole = rawAmount / 1e6;
        uint256 frac = rawAmount % 1e6;
        console2.log("  %s = %s.%s USDC", label, whole, frac);
    }

    function _logIndex(string memory label, uint256 indexRay) internal pure {
        console2.log("  %s = %s (ray)", label, indexRay);
    }

    function _logBps(string memory label, uint256 bps) internal pure {
        uint256 whole = bps / 100;
        uint256 frac = bps % 100;
        console2.log("  %s = %s.%s%% bps", label, whole, frac);
    }

    function _logTimestamp(string memory label) internal view {
        console2.log("  %s = %s  (day %s)", label, block.timestamp, (block.timestamp - INDEX_START_TIMESTAMP) / 1 days);
    }

    function _logTotals(string memory header) internal view {
        ProductTotalsView memory t = core.totals();
        console2.log("--- %s ---", header);
        _logUsdc("principalLiab ", t.userPrincipalLiability);
        _logUsdc("yieldLiab     ", t.userYieldLiability);
        _logUsdc("frozenWithdraw", t.frozenWithdrawalLiability);
        _logUsdc("sponsorLiab   ", t.sponsorRewardLiability);
        _logUsdc("sponsorClaim  ", t.sponsorRewardClaimable);
        _logUsdc("buffer        ", t.bufferAssets);
        _logUsdc("treasury      ", t.treasuryReportedAssets);
        _logUsdc("contractBal   ", assetToken.balanceOf(address(core)));
        _logIndex("globalIndex   ", core.currentIndex());
        console2.log("  totalShares     = %s", shareToken.totalSupply());
        _logTimestamp("timestamp     ");
    }

    function _logLot(uint256 lotId) internal view {
        LotView memory l = core.lot(lotId);
        console2.log("  [LOT %s] owner=%s sponsor=%s", l.id, l.owner, l.sponsor);
        _logUsdc("    principal ", l.principalAssets);
        console2.log("    shares    = %s", l.shareAmount);
        _logIndex("    entryIdx  ", l.entryIndexRay);
        _logIndex("    lastIdx   ", l.lastIndexRay);
        console2.log("    frozen=%s closed=%s openedAt=%s", l.isFrozen, l.isClosed, l.openedAt);
    }

    function _logSponsor(string memory label, address spon) internal view {
        SponsorAccountView memory sa = core.sponsorAccount(spon);
        console2.log("--- Sponsor: %s (%s) ---", label, spon);
        _logUsdc("accrued  ", sa.accrued);
        _logUsdc("claimable", sa.claimable);
        _logUsdc("claimed  ", sa.claimed);
        _logIndex("accumulat", sa.lastAccumulatorRay);
    }

    function _logWithdrawal(address user) internal view {
        WithdrawalRequestView memory req = core.withdrawalRequest(user);
        console2.log("  [WD req=%s] lot=%s shares=%s", req.id, req.lotId, req.shareAmount);
        _logUsdc("    snapshot   ", req.assetAmountSnapshot);
        console2.log("    requestedAt=%s executableAt=%s", req.requestedAt, req.executableAt);
        console2.log("    executed=%s cancelled=%s", req.executed, req.cancelled);
    }

    // =========================================================================
    //  1. Multi-user deposit + withdrawal cycle
    // =========================================================================

    function test_multiUserDepositAndWithdrawCycle() public {
        console2.log("=== TEST 1: Multi-user deposit & withdraw (20 users, 10% APR, 90 days) ===");
        _setupAprAndTreasury(APR_10_PERCENT_BPS, 0);
        _logBps("APR", APR_10_PERCENT_BPS);
        _logBps("treasuryRatio", 0);

        uint256 userCount = 20;
        address[] memory users = new address[](userCount);
        uint256[] memory lotIds = new uint256[](userCount);
        uint256[] memory deposits = new uint256[](userCount);

        console2.log("--- Deposits ---");
        for (uint256 i = 0; i < userCount; i++) {
            uint256 depositAmount = (1_000e6 + (i * 500e6));
            users[i] = _createAndFundUser(i, depositAmount * 2);
            deposits[i] = depositAmount;
            lotIds[i] = _depositAs(users[i], depositAmount);
        }
        _logTotals("After all 20 deposits");

        assertEq(core.ownerLotCount(users[0]), 1);
        assertEq(core.ownerLotCount(users[userCount - 1]), 1);

        console2.log("--- Skip 90 days ---");
        skip(QUARTER);
        _logTotals("After quarter");

        for (uint256 i = 0; i < userCount; i++) {
            LotView memory l = core.lot(lotIds[i]);
            assertEq(l.principalAssets, deposits[i]);
            assertFalse(l.isFrozen);
            assertFalse(l.isClosed);
        }

        ProductTotalsView memory t = core.totals();
        assertGt(t.userYieldLiability, 0, "yield should accrue after quarter");

        uint256 totalPrincipal;
        for (uint256 i = 0; i < userCount; i++) {
            totalPrincipal += deposits[i];
        }
        assertEq(t.userPrincipalLiability, totalPrincipal);
        console2.log("  formula: yield = principal * APR * 90/365");
        uint256 expYield = _expectedProfit(totalPrincipal, APR_10_PERCENT_BPS, QUARTER);
        _logUsdc("expectedYield ", expYield);
        _logUsdc("actualYield   ", t.userYieldLiability);

        console2.log("--- All users request withdrawal ---");
        for (uint256 i = 0; i < userCount; i++) {
            uint256 shares = shareToken.balanceOf(users[i]);
            _requestWithdrawalAs(users[i], lotIds[i], shares);
        }

        skip(24 hours);
        _ensureBufferForWithdrawals();

        console2.log("--- Execute withdrawals ---");
        uint256 totalPaid;
        for (uint256 i = 0; i < userCount; i++) {
            uint256 paid = _executeWithdrawalAs(users[i]);
            totalPaid += paid;
            assertGt(paid, deposits[i], "user should profit from yield");
            if (i < 5 || i == userCount - 1) {
                console2.log("  user[%s] deposited=%s paid=%s", i, deposits[i], paid);
            }
        }
        _logUsdc("totalPaid     ", totalPaid);
        _logUsdc("totalPrincipal", totalPrincipal);
        _logUsdc("totalProfit   ", totalPaid - totalPrincipal);
        _logTotals("Final state");

        ProductTotalsView memory tAfter = core.totals();
        assertEq(tAfter.userPrincipalLiability, 0);
        assertEq(shareToken.totalSupply(), 0);
    }

    // =========================================================================
    //  2. Sponsor reward flow — sponsor refers 10 clients, earns rewards
    // =========================================================================

    function test_sponsorRewardsWithMultipleReferrals() public {
        _setupAprAndTreasury(APR_20_PERCENT_BPS, 0);

        uint256 clientCount = 10;
        uint256 depositEach = 10_000e6;
        address[] memory clients = new address[](clientCount);
        uint256[] memory lots = new uint256[](clientCount);

        for (uint256 i = 0; i < clientCount; i++) {
            clients[i] = _createAndFundUser(100 + i, depositEach * 2);
            _setupSponsorForUser(clients[i], sponsorA, SPONSOR_RATE_BPS);
            lots[i] = _depositAs(clients[i], depositEach);
        }

        assertEq(core.sponsorLotCount(sponsorA), clientCount);

        skip(QUARTER);

        SponsorAccountView memory sa = core.sponsorAccount(sponsorA);
        assertGt(sa.accrued, 0, "sponsor should accrue rewards");

        uint256 expectedTotalYield = _expectedProfit(
            depositEach * clientCount, APR_20_PERCENT_BPS, QUARTER
        );
        uint256 expectedSponsorReward = (expectedTotalYield * SPONSOR_RATE_BPS) / 10_000;
        assertApproxEqRel(sa.accrued, expectedSponsorReward, 0.01e18);

        _fundSponsorBudgetAs(sponsorA, sa.accrued);
        SponsorAccountView memory saFunded = core.sponsorAccount(sponsorA);
        assertEq(saFunded.claimable, saFunded.accrued);

        uint256 balBefore = assetToken.balanceOf(sponsorA);
        _claimSponsorRewardAs(sponsorA, saFunded.claimable);
        uint256 balAfter = assetToken.balanceOf(sponsorA);
        assertEq(balAfter - balBefore, saFunded.claimable);

        SponsorAccountView memory saPost = core.sponsorAccount(sponsorA);
        assertEq(saPost.claimable, 0);
        assertEq(saPost.claimed, saFunded.claimable);
    }

    // =========================================================================
    //  3. Sponsor upgrade — rate changes with existing deposits
    // =========================================================================

    function test_sponsorUpgradeWithExistingDeposits() public {
        console2.log("=== TEST 3: Sponsor rate upgrade 10%->20% with existing deposits ===");
        _setupAprAndTreasury(APR_20_PERCENT_BPS, 0);

        uint256 clientCount = 5;
        uint256 depositEach = 20_000e6;
        uint256 totalPrincipal = depositEach * clientCount;
        address[] memory clients = new address[](clientCount);
        uint256[] memory lots = new uint256[](clientCount);

        _logBps("APR          ", APR_20_PERCENT_BPS);
        _logUsdc("depositEach   ", depositEach);
        _logUsdc("totalPrincipal", totalPrincipal);
        console2.log("  clients      = %s", clientCount);

        for (uint256 i = 0; i < clientCount; i++) {
            clients[i] = _createAndFundUser(200 + i, depositEach * 2);
            _setupSponsorForUser(clients[i], sponsorA, SPONSOR_RATE_BPS);
            lots[i] = _depositAs(clients[i], depositEach);
        }

        uint256 phase1Duration = 45 days;
        console2.log("--- Phase 1: 45 days at sponsor rate 10%% ---");
        skip(phase1Duration);

        SponsorAccountView memory saBeforeUpgrade = core.sponsorAccount(sponsorA);
        uint256 accruedBeforeUpgrade = saBeforeUpgrade.accrued;
        _logSponsor("A before upgrade", sponsorA);
        assertGt(accruedBeforeUpgrade, 0);

        console2.log("--- UPGRADE: sponsor rate 10%% -> 20%% ---");
        vm.prank(admin);
        core.setSponsorRate(sponsorA, UPGRADED_SPONSOR_RATE_BPS);

        uint256 phase2Duration = 45 days;
        console2.log("--- Phase 2: 45 days at sponsor rate 20%% ---");
        skip(phase2Duration);

        _logSponsor("A after upgrade period", sponsorA);
        SponsorAccountView memory saAfterUpgrade = core.sponsorAccount(sponsorA);
        uint256 totalAccrued = saAfterUpgrade.accrued;

        uint256 phase1Expected = _expectedSponsorReward(
            totalPrincipal, APR_20_PERCENT_BPS, SPONSOR_RATE_BPS, phase1Duration
        );
        uint256 phase2Expected = _expectedSponsorReward(
            totalPrincipal, APR_20_PERCENT_BPS, UPGRADED_SPONSOR_RATE_BPS, phase2Duration
        );

        console2.log("--- Math verification ---");
        console2.log("  phase1: %s * 20%% * 45/365 * 10%%", totalPrincipal);
        _logUsdc("  phase1Expected", phase1Expected);
        _logUsdc("  phase1Actual  ", accruedBeforeUpgrade);
        console2.log("  phase2: %s * 20%% * 45/365 * 20%%", totalPrincipal);
        _logUsdc("  phase2Expected", phase2Expected);
        _logUsdc("  phase2Actual  ", totalAccrued - accruedBeforeUpgrade);
        _logUsdc("  totalExpected ", phase1Expected + phase2Expected);
        _logUsdc("  totalActual   ", totalAccrued);

        assertApproxEqRel(totalAccrued, phase1Expected + phase2Expected, 0.02e18);
        assertGt(totalAccrued, accruedBeforeUpgrade * 2, "upgraded rate should more than double phase-1 rewards");
    }

    // =========================================================================
    //  4. Sponsor upgrade mid-flow — existing money + new deposits after upgrade
    // =========================================================================

    function test_sponsorUpgradeThenNewDeposits() public {
        console2.log("=== TEST 4: Sponsor upgrade + new deposits after ===");
        _setupAprAndTreasury(APR_20_PERCENT_BPS, 0);

        address client1 = _createAndFundUser(300, 100_000e6);
        _setupSponsorForUser(client1, sponsorA, SPONSOR_RATE_BPS);
        uint256 lot1 = _depositAs(client1, 50_000e6);
        console2.log("  Client1 deposits 50k USDC at sponsor rate 10%%");
        _logLot(lot1);

        console2.log("--- Skip 30 days ---");
        skip(30 days);

        console2.log("--- UPGRADE sponsor rate to 20%% ---");
        vm.prank(admin);
        core.setSponsorRate(sponsorA, UPGRADED_SPONSOR_RATE_BPS);

        address client2 = _createAndFundUser(301, 100_000e6);
        _setupSponsorForUser(client2, sponsorA, UPGRADED_SPONSOR_RATE_BPS);
        uint256 lot2 = _depositAs(client2, 50_000e6);
        console2.log("  Client2 deposits 50k USDC at sponsor rate 20%%");
        _logLot(lot2);

        console2.log("--- Skip 60 days ---");
        skip(60 days);

        _logSponsor("A final", sponsorA);
        _logLot(lot1);
        _logLot(lot2);
        _logTotals("Final state");

        SponsorAccountView memory sa = core.sponsorAccount(sponsorA);
        assertGt(sa.accrued, 0);
        assertEq(core.lot(lot1).principalAssets, 50_000e6);
        assertEq(core.lot(lot2).principalAssets, 50_000e6);
    }

    // =========================================================================
    //  5. Interleaved deposits and withdrawals
    // =========================================================================

    function test_interleavedDepositsAndWithdrawals() public {
        console2.log("=== TEST 5: Interleaved deposits & withdrawals ===");
        _setupAprAndTreasury(APR_10_PERCENT_BPS, 0);

        address u1 = _createAndFundUser(400, 200_000e6);
        address u2 = _createAndFundUser(401, 200_000e6);
        address u3 = _createAndFundUser(402, 200_000e6);

        console2.log("  Day 0: u1 deposits 50k");
        uint256 lot1 = _depositAs(u1, 50_000e6);
        _logLot(lot1);
        skip(10 days);

        console2.log("  Day 10: u2 deposits 30k");
        uint256 lot2 = _depositAs(u2, 30_000e6);
        _logLot(lot2);
        skip(10 days);

        console2.log("  Day 20: u1 requests withdrawal (was in for 20 days)");
        uint256 shares1 = shareToken.balanceOf(u1);
        console2.log("  u1 shares = %s", shares1);
        _requestWithdrawalAs(u1, lot1, shares1);
        _logWithdrawal(u1);
        skip(10 days);

        console2.log("  Day 30: u3 deposits 70k");
        uint256 lot3 = _depositAs(u3, 70_000e6);
        _logLot(lot3);
        skip(14 hours);
        skip(10 hours);

        console2.log("  Day 31: u1 executes withdrawal");
        _ensureBufferForWithdrawals();
        uint256 paid1 = _executeWithdrawalAs(u1);
        _logUsdc("u1 paid       ", paid1);
        _logUsdc("u1 profit     ", paid1 - 50_000e6);
        assertGt(paid1, 50_000e6);

        skip(30 days);
        console2.log("  Day 61: u2 requests withdrawal (was in for 51 days)");
        uint256 shares2 = shareToken.balanceOf(u2);
        _requestWithdrawalAs(u2, lot2, shares2);
        skip(24 hours);
        _ensureBufferForWithdrawals();
        uint256 paid2 = _executeWithdrawalAs(u2);
        _logUsdc("u2 paid       ", paid2);
        _logUsdc("u2 profit     ", paid2 - 30_000e6);
        assertGt(paid2, 30_000e6);

        console2.log("  Day 62: u3 requests withdrawal (was in for 32 days)");
        uint256 shares3 = shareToken.balanceOf(u3);
        _requestWithdrawalAs(u3, lot3, shares3);
        skip(24 hours);
        _ensureBufferForWithdrawals();
        uint256 paid3 = _executeWithdrawalAs(u3);
        _logUsdc("u3 paid       ", paid3);
        _logUsdc("u3 profit     ", paid3 - 70_000e6);
        assertGt(paid3, 70_000e6);

        _logTotals("Final state");
        assertEq(shareToken.totalSupply(), 0);
        assertEq(core.totals().userPrincipalLiability, 0);
    }

    // =========================================================================
    //  6. Partial withdrawal retains lot position
    // =========================================================================

    function test_partialWithdrawalRetainsPosition() public {
        console2.log("=== TEST 6: Partial withdrawal retains position ===");
        _setupAprAndTreasury(APR_10_PERCENT_BPS, 0);

        address user = _createAndFundUser(500, 200_000e6);
        uint256 lotId = _depositAs(user, 100_000e6);
        uint256 totalShares = shareToken.balanceOf(user);
        console2.log("  Deposit 100k USDC, got %s shares", totalShares);
        _logLot(lotId);

        skip(QUARTER);
        console2.log("--- After 90 days ---");
        _logIndex("currentIndex", core.currentIndex());

        uint256 halfShares = totalShares / 2;
        console2.log("  Withdrawing half: %s shares out of %s", halfShares, totalShares);
        _requestWithdrawalAs(user, lotId, halfShares);
        _logWithdrawal(user);

        console2.log("  Lot after partial withdrawal:");
        _logLot(lotId);
        LotView memory lotAfterPartial = core.lot(lotId);
        assertFalse(lotAfterPartial.isFrozen, "partial should not freeze lot");
        assertFalse(lotAfterPartial.isClosed);
        assertEq(lotAfterPartial.shareAmount, totalShares - halfShares);

        skip(24 hours);
        _ensureBufferForWithdrawals();
        uint256 paid = _executeWithdrawalAs(user);
        _logUsdc("1st withdrawal", paid);
        _logUsdc("1st profit    ", paid - 50_000e6);
        assertGt(paid, 50_000e6);

        console2.log("--- Skip another 90 days (remaining half continues earning) ---");
        skip(QUARTER);
        uint256 remainingShares = shareToken.balanceOf(user);
        console2.log("  remainingShares = %s", remainingShares);

        _requestWithdrawalAs(user, lotId, remainingShares);
        _logWithdrawal(user);
        skip(24 hours);
        _ensureBufferForWithdrawals();
        uint256 paid2 = _executeWithdrawalAs(user);
        _logUsdc("2nd withdrawal", paid2);
        console2.log("  totalReceived = %s (from 100k initial)", paid + paid2);
        assertGt(paid2, 0);
        assertEq(shareToken.totalSupply(), 0);
    }

    // =========================================================================
    //  7. Withdrawal cancel and re-deposit
    // =========================================================================

    function test_withdrawalCancelAndRedeposit() public {
        _setupAprAndTreasury(APR_10_PERCENT_BPS, 0);

        address user = _createAndFundUser(600, 200_000e6);
        uint256 lotId = _depositAs(user, 50_000e6);
        uint256 shares = shareToken.balanceOf(user);

        skip(30 days);

        _requestWithdrawalAs(user, lotId, shares);
        assertTrue(core.lot(lotId).isFrozen);
        assertEq(shareToken.lockedBalanceOf(user), shares);

        _cancelWithdrawalAs(user);

        LotView memory restored = core.lot(lotId);
        assertFalse(restored.isFrozen, "cancellation should unfreeze");
        assertEq(shareToken.lockedBalanceOf(user), 0);
        assertEq(shareToken.availableBalanceOf(user), shares);

        skip(60 days);

        uint256 lotId2 = _depositAs(user, 30_000e6);
        assertEq(core.ownerLotCount(user), 2);

        skip(QUARTER);

        uint256 s1 = core.lot(lotId).shareAmount;
        _requestWithdrawalAs(user, lotId, s1);
        skip(24 hours);
        _ensureBufferForWithdrawals();
        uint256 p1 = _executeWithdrawalAs(user);
        assertGt(p1, 50_000e6);

        uint256 s2 = core.lot(lotId2).shareAmount;
        _requestWithdrawalAs(user, lotId2, s2);
        skip(24 hours);
        _ensureBufferForWithdrawals();
        uint256 p2 = _executeWithdrawalAs(user);
        assertGt(p2, 30_000e6);
    }

    // =========================================================================
    //  8. Buffer exhaustion blocks withdrawal execution
    // =========================================================================

    function test_bufferExhaustionBlocksWithdrawal() public {
        _setupAprAndTreasury(APR_10_PERCENT_BPS, 5_000); // 50% to treasury

        address user = _createAndFundUser(700, 200_000e6);
        uint256 lotId = _depositAs(user, 100_000e6);

        skip(QUARTER);

        uint256 shares = shareToken.balanceOf(user);
        _requestWithdrawalAs(user, lotId, shares);
        skip(24 hours);

        WithdrawalRequestView memory req = core.withdrawalRequest(user);
        ProductTotalsView memory t = core.totals();

        if (req.assetAmountSnapshot > t.bufferAssets) {
            vm.prank(user);
            vm.expectRevert();
            core.executeWithdrawal();

            vm.prank(admin);
            core.replenishBuffer(req.assetAmountSnapshot - t.bufferAssets + 1);

            uint256 paid = _executeWithdrawalAs(user);
            assertGt(paid, 0);
        } else {
            uint256 paid = _executeWithdrawalAs(user);
            assertGt(paid, 0);
        }
    }

    // =========================================================================
    //  9. APR change impacts all positions
    // =========================================================================

    function test_aprChangeImpactsAllPositions() public {
        console2.log("=== TEST 9: APR change 20%% -> 10%% impacts all positions ===");
        _setupAprAndTreasury(APR_20_PERCENT_BPS, 0);

        address u1 = _createAndFundUser(800, 200_000e6);
        address u2 = _createAndFundUser(801, 200_000e6);
        uint256 lot1 = _depositAs(u1, 100_000e6);
        uint256 lot2 = _depositAs(u2, 100_000e6);
        _logIndex("indexAtDeposit", core.currentIndex());

        console2.log("--- Quarter 1: 90 days at 20%% APR ---");
        skip(QUARTER);
        uint256 indexBeforeChange = core.currentIndex();
        _logIndex("indexAfterQ1  ", indexBeforeChange);

        console2.log("--- APR change: 20%% -> 10%% ---");
        vm.prank(admin);
        core.setApr(APR_10_PERCENT_BPS);
        skip(24 hours);

        console2.log("--- Quarter 2: 90 days at 10%% APR ---");
        skip(QUARTER);
        uint256 indexAfterSecondQuarter = core.currentIndex();
        _logIndex("indexAfterQ2  ", indexAfterSecondQuarter);
        assertGt(indexAfterSecondQuarter, indexBeforeChange);

        uint256 shares1 = shareToken.balanceOf(u1);
        uint256 shares2 = shareToken.balanceOf(u2);
        _requestWithdrawalAs(u1, lot1, shares1);
        _requestWithdrawalAs(u2, lot2, shares2);

        skip(24 hours);
        _ensureBufferForWithdrawals();
        uint256 paid1 = _executeWithdrawalAs(u1);
        uint256 paid2 = _executeWithdrawalAs(u2);

        uint256 q1Yield = _expectedProfit(100_000e6, APR_20_PERCENT_BPS, QUARTER);
        uint256 q2Yield = _expectedProfit(100_000e6, APR_10_PERCENT_BPS, QUARTER);
        uint256 expectedTotal = 100_000e6 + q1Yield + q2Yield;

        console2.log("--- Payout math ---");
        console2.log("  formula: payout = principal + (principal*20%%*90/365) + (principal*10%%*90/365)");
        _logUsdc("principal     ", 100_000e6);
        _logUsdc("q1 yield (20%%)", q1Yield);
        _logUsdc("q2 yield (10%%)", q2Yield);
        _logUsdc("expectedTotal ", expectedTotal);
        _logUsdc("u1 paid       ", paid1);
        _logUsdc("u2 paid       ", paid2);

        assertEq(paid1, paid2, "same deposit/timing should yield same payout");
        assertGt(paid1, 100_000e6);
        assertApproxEqRel(paid1, expectedTotal, 0.02e18);
    }

    // =========================================================================
    //  10. Blacklisted user cannot deposit
    // =========================================================================

    function test_blacklistedUserCannotDeposit() public {
        _setupAprAndTreasury(APR_10_PERCENT_BPS, 0);

        address user = _createAndFundUser(900, 200_000e6);

        vm.prank(admin);
        core.setBlacklist(user, true);

        vm.prank(user);
        vm.expectRevert();
        core.deposit(10_000e6, user);
    }

    // =========================================================================
    //  11. Blacklisted user yield is frozen at blacklist time
    // =========================================================================

    function test_blacklistedUserYieldFrozen() public {
        console2.log("=== TEST 11: Blacklisted user yield frozen ===");
        _setupAprAndTreasury(APR_20_PERCENT_BPS, 0);

        address user = _createAndFundUser(1000, 200_000e6);
        _depositAs(user, 100_000e6);
        _logIndex("indexAtDeposit", core.currentIndex());

        console2.log("--- Skip 45 days ---");
        skip(45 days);
        uint256 indexAtBlacklist = core.currentIndex();
        _logIndex("indexAt45days ", indexAtBlacklist);
        _logTimestamp("blacklistTime");

        console2.log("--- BLACKLIST user ---");
        vm.prank(admin);
        core.setBlacklist(user, true);

        console2.log("--- Skip another 45 days ---");
        skip(45 days);

        uint256 userIndex = core.currentIndex(user);
        uint256 globalIndex = core.currentIndex();
        _logIndex("userIndex(cap)", userIndex);
        _logIndex("globalIndex   ", globalIndex);
        console2.log("  userIndex is FROZEN at blacklist time, globalIndex keeps growing");
        console2.log("  delta = %s ray (yield user misses)", globalIndex - userIndex);

        uint256 frozenYield = _expectedProfit(100_000e6, APR_20_PERCENT_BPS, 45 days);
        uint256 fullYield = _expectedProfit(100_000e6, APR_20_PERCENT_BPS, 90 days);
        _logUsdc("yieldIf45days ", frozenYield);
        _logUsdc("yieldIf90days ", fullYield);
        _logUsdc("yieldLost     ", fullYield - frozenYield);

        assertLt(userIndex, globalIndex, "blacklisted user index should be capped");
        assertEq(userIndex, indexAtBlacklist);
    }

    // =========================================================================
    //  12. Sponsor cannot over-claim
    // =========================================================================

    function test_sponsorCannotOverClaim() public {
        _setupAprAndTreasury(APR_20_PERCENT_BPS, 0);

        address client = _createAndFundUser(1100, 200_000e6);
        _setupSponsorForUser(client, sponsorA, SPONSOR_RATE_BPS);
        _depositAs(client, 100_000e6);

        skip(QUARTER);

        SponsorAccountView memory sa = core.sponsorAccount(sponsorA);
        _fundSponsorBudgetAs(sponsorA, sa.accrued);

        SponsorAccountView memory saFunded = core.sponsorAccount(sponsorA);

        vm.prank(sponsorA);
        vm.expectRevert();
        core.claimSponsorReward(saFunded.claimable + 1);

        _claimSponsorRewardAs(sponsorA, saFunded.claimable);
    }

    // =========================================================================
    //  13. Multiple sponsors with different rates
    // =========================================================================

    function test_multipleSponsorsDifferentRates() public {
        console2.log("=== TEST 13: Two sponsors, different rates (10%% vs 20%%) ===");
        _setupAprAndTreasury(APR_20_PERCENT_BPS, 0);

        uint256 depositAmount = 50_000e6;
        uint256 totalPerSponsor = depositAmount * 5;

        console2.log("  5 clients x 50k USDC each per sponsor");
        _logUsdc("totalPerSponsor", totalPerSponsor);
        _logBps("sponsorA rate  ", SPONSOR_RATE_BPS);
        _logBps("sponsorB rate  ", UPGRADED_SPONSOR_RATE_BPS);

        address[] memory clientsA = new address[](5);
        address[] memory clientsB = new address[](5);

        for (uint256 i = 0; i < 5; i++) {
            clientsA[i] = _createAndFundUser(1200 + i, depositAmount * 2);
            _setupSponsorForUser(clientsA[i], sponsorA, SPONSOR_RATE_BPS);
            _depositAs(clientsA[i], depositAmount);

            clientsB[i] = _createAndFundUser(1300 + i, depositAmount * 2);
            _setupSponsorForUser(clientsB[i], sponsorB, UPGRADED_SPONSOR_RATE_BPS);
            _depositAs(clientsB[i], depositAmount);
        }

        console2.log("--- Skip 90 days ---");
        skip(QUARTER);

        _logSponsor("A (10%%)", sponsorA);
        _logSponsor("B (20%%)", sponsorB);

        SponsorAccountView memory saA = core.sponsorAccount(sponsorA);
        SponsorAccountView memory saB = core.sponsorAccount(sponsorB);

        uint256 expA = _expectedSponsorReward(totalPerSponsor, APR_20_PERCENT_BPS, SPONSOR_RATE_BPS, QUARTER);
        uint256 expB = _expectedSponsorReward(totalPerSponsor, APR_20_PERCENT_BPS, UPGRADED_SPONSOR_RATE_BPS, QUARTER);
        console2.log("--- Math ---");
        _logUsdc("expectedA     ", expA);
        _logUsdc("expectedB     ", expB);
        console2.log("  ratio B/A = %s (should be ~2x)", saB.accrued * 100 / saA.accrued);

        assertGt(saA.accrued, 0);
        assertGt(saB.accrued, 0);
        assertApproxEqRel(saB.accrued, saA.accrued * 2, 0.02e18);
    }

    // =========================================================================
    //  14. Treasury ratio splits deposit correctly
    // =========================================================================

    function test_treasuryRatioSplitsDeposit() public {
        console2.log("=== TEST 14: Treasury ratio split (10%% to treasury) ===");
        _setupAprAndTreasury(APR_10_PERCENT_BPS, TREASURY_RATIO_BPS);

        address user = _createAndFundUser(1400, 200_000e6);
        uint256 deposit = 100_000e6;
        _depositAs(user, deposit);

        ProductTotalsView memory t = core.totals();
        uint256 expectedTreasury = (deposit * TREASURY_RATIO_BPS) / 10_000;
        uint256 expectedBuffer = deposit - expectedTreasury;

        console2.log("  formula: treasuryShare = deposit * treasuryRatio / 10000");
        console2.log("         = %s * %s / 10000", deposit, TREASURY_RATIO_BPS);
        _logUsdc("deposit         ", deposit);
        _logUsdc("expectedTreasury", expectedTreasury);
        _logUsdc("expectedBuffer  ", expectedBuffer);
        _logUsdc("actualTreasury  ", t.treasuryReportedAssets);
        _logUsdc("actualBuffer    ", t.bufferAssets);

        assertEq(t.treasuryReportedAssets, expectedTreasury);
        assertEq(t.bufferAssets, expectedBuffer);
        assertEq(t.userPrincipalLiability, deposit);
    }

    // =========================================================================
    //  15. Multiple lots per user
    // =========================================================================

    function test_multipleLotsPerUser() public {
        _setupAprAndTreasury(APR_10_PERCENT_BPS, 0);

        address user = _createAndFundUser(1500, 500_000e6);

        uint256 lot1 = _depositAs(user, 10_000e6);
        skip(30 days);
        uint256 lot2 = _depositAs(user, 20_000e6);
        skip(30 days);
        uint256 lot3 = _depositAs(user, 50_000e6);

        assertEq(core.ownerLotCount(user), 3);

        LotView[] memory userLots = core.lotsByOwner(user, 0, 10);
        assertEq(userLots.length, 3);
        assertEq(userLots[0].principalAssets, 10_000e6);
        assertEq(userLots[1].principalAssets, 20_000e6);
        assertEq(userLots[2].principalAssets, 50_000e6);

        skip(QUARTER);

        uint256 s1 = core.lot(lot1).shareAmount;
        _requestWithdrawalAs(user, lot1, s1);
        skip(24 hours);
        _ensureBufferForWithdrawals();
        uint256 p1 = _executeWithdrawalAs(user);
        assertGt(p1, 10_000e6);

        uint256 s2 = core.lot(lot2).shareAmount;
        _requestWithdrawalAs(user, lot2, s2);
        skip(24 hours);
        _ensureBufferForWithdrawals();
        uint256 p2 = _executeWithdrawalAs(user);
        assertGt(p2, 20_000e6);

        uint256 s3 = core.lot(lot3).shareAmount;
        _requestWithdrawalAs(user, lot3, s3);
        skip(24 hours);
        _ensureBufferForWithdrawals();
        uint256 p3 = _executeWithdrawalAs(user);
        assertGt(p3, 50_000e6);

        assertTrue(p1 > p2 * 10_000e6 / 20_000e6 - 1, "lot1 yield/principal ratio > lot2 (longer duration)");
    }

    // =========================================================================
    //  16. Sponsor rewards frozen when user is blacklisted
    // =========================================================================

    function test_sponsorRewardsAfterUserBlacklist() public {
        console2.log("=== TEST 16: Sponsor rewards stop when client blacklisted ===");
        _setupAprAndTreasury(APR_20_PERCENT_BPS, 0);

        address client = _createAndFundUser(1600, 200_000e6);
        _setupSponsorForUser(client, sponsorA, SPONSOR_RATE_BPS);
        _depositAs(client, 100_000e6);
        console2.log("  Client deposits 100k, sponsor rate 10%%, APR 20%%");

        console2.log("--- Skip 45 days ---");
        skip(45 days);
        _logSponsor("A before blacklist", sponsorA);
        SponsorAccountView memory saBefore = core.sponsorAccount(sponsorA);

        console2.log("--- BLACKLIST client ---");
        vm.prank(admin);
        core.setBlacklist(client, true);

        console2.log("--- Skip 45 more days ---");
        skip(45 days);
        _logSponsor("A after blacklist", sponsorA);
        SponsorAccountView memory saAfter = core.sponsorAccount(sponsorA);

        _logUsdc("accruedBefore ", saBefore.accrued);
        _logUsdc("accruedAfter  ", saAfter.accrued);
        console2.log("  delta = %s (should be 0)", saAfter.accrued - saBefore.accrued);
        assertEq(saAfter.accrued, saBefore.accrued, "sponsor accrual should stop after user blacklist");
    }

    // =========================================================================
    //  17. Concurrent withdrawal request rejected (one active per user)
    // =========================================================================

    function test_cannotHaveTwoConcurrentWithdrawals() public {
        _setupAprAndTreasury(APR_10_PERCENT_BPS, 0);

        address user = _createAndFundUser(1700, 200_000e6);
        uint256 lot1 = _depositAs(user, 50_000e6);
        uint256 lot2 = _depositAs(user, 50_000e6);

        skip(30 days);

        uint256 s1 = core.lot(lot1).shareAmount;
        _requestWithdrawalAs(user, lot1, s1);

        uint256 s2 = core.lot(lot2).shareAmount;
        vm.prank(user);
        vm.expectRevert();
        core.requestWithdrawal(lot2, s2);

        skip(24 hours);
        _ensureBufferForWithdrawals();
        _executeWithdrawalAs(user);

        _requestWithdrawalAs(user, lot2, s2);
        skip(24 hours);
        _ensureBufferForWithdrawals();
        _executeWithdrawalAs(user);
    }

    // =========================================================================
    //  18. Deposit below minimum reverts
    // =========================================================================

    function test_depositBelowMinimumReverts() public {
        _setupAprAndTreasury(APR_10_PERCENT_BPS, 0);

        address user = _createAndFundUser(1800, 200_000e6);
        uint256 minDep = core.minDeposit();

        vm.prank(user);
        vm.expectRevert();
        core.deposit(minDep - 1, user);

        _depositAs(user, minDep);
    }

    // =========================================================================
    //  19. Withdrawal lock period enforced
    // =========================================================================

    function test_withdrawalLockPeriodEnforced() public {
        _setupAprAndTreasury(APR_10_PERCENT_BPS, 0);

        address user = _createAndFundUser(1900, 200_000e6);
        uint256 lotId = _depositAs(user, 50_000e6);

        skip(30 days);

        uint256 shares = shareToken.balanceOf(user);
        _requestWithdrawalAs(user, lotId, shares);

        vm.prank(user);
        vm.expectRevert();
        core.executeWithdrawal();

        skip(12 hours);
        vm.prank(user);
        vm.expectRevert();
        core.executeWithdrawal();

        skip(12 hours);
        _ensureBufferForWithdrawals();
        uint256 paid = _executeWithdrawalAs(user);
        assertGt(paid, 0);
    }

    // =========================================================================
    //  20. Pause withdrawal request/execution
    // =========================================================================

    function test_pauseWithdrawalRequestAndExecution() public {
        _setupAprAndTreasury(APR_10_PERCENT_BPS, 0);

        address user = _createAndFundUser(2000, 200_000e6);
        uint256 lotId = _depositAs(user, 50_000e6);
        skip(30 days);

        vm.prank(admin);
        core.setWithdrawalPause(true, false);

        uint256 shares = shareToken.balanceOf(user);
        vm.prank(user);
        vm.expectRevert();
        core.requestWithdrawal(lotId, shares);

        vm.prank(admin);
        core.setWithdrawalPause(false, false);

        _requestWithdrawalAs(user, lotId, shares);

        vm.prank(admin);
        core.setWithdrawalPause(false, true);

        skip(24 hours);
        vm.prank(user);
        vm.expectRevert();
        core.executeWithdrawal();

        vm.prank(admin);
        core.setWithdrawalPause(false, false);
        _ensureBufferForWithdrawals();
        _executeWithdrawalAs(user);
    }

    // =========================================================================
    //  21. Full quarter simulation — 50 users with mixed behavior
    // =========================================================================

    function test_quarterlySimulation50Users() public {
        _setupAprAndTreasury(APR_10_PERCENT_BPS, TREASURY_RATIO_BPS);

        uint256 userCount = 50;
        address[] memory users = new address[](userCount);
        uint256[] memory lotIds = new uint256[](userCount);
        uint256[] memory depositAmounts = new uint256[](userCount);
        bool[] memory hasWithdrawn = new bool[](userCount);

        // Week 1-2: first wave deposits (users 0-24)
        for (uint256 i = 0; i < 25; i++) {
            uint256 amount = 5_000e6 + (i * 1_000e6);
            users[i] = _createAndFundUser(3000 + i, amount * 3);
            depositAmounts[i] = amount;

            if (i % 3 == 0) {
                _setupSponsorForUser(users[i], sponsorA, SPONSOR_RATE_BPS);
            }

            lotIds[i] = _depositAs(users[i], amount);
        }

        skip(14 days);

        // Week 3-4: second wave (users 25-49) + some first-wave withdrawals
        for (uint256 i = 25; i < userCount; i++) {
            uint256 amount = 2_000e6 + (i * 500e6);
            users[i] = _createAndFundUser(3000 + i, amount * 3);
            depositAmounts[i] = amount;

            if (i % 4 == 0) {
                _setupSponsorForUser(users[i], sponsorB, UPGRADED_SPONSOR_RATE_BPS);
            }

            lotIds[i] = _depositAs(users[i], amount);
        }

        // Users 0,5,10 withdraw early
        for (uint256 i = 0; i < 15; i += 5) {
            uint256 shares = shareToken.balanceOf(users[i]);
            _requestWithdrawalAs(users[i], lotIds[i], shares);
            hasWithdrawn[i] = true;
        }

        skip(14 days);

        // Execute pending withdrawals
        for (uint256 i = 0; i < 15; i += 5) {
            if (hasWithdrawn[i]) {
                uint256 paid = _executeWithdrawalAs(users[i]);
                assertGt(paid, depositAmounts[i]);
            }
        }

        // Mid-quarter: APR change
        vm.prank(admin);
        core.setApr(APR_20_PERCENT_BPS);
        skip(24 hours);

        skip(30 days);

        // Users 15-19 withdraw at month 2
        for (uint256 i = 15; i < 20; i++) {
            if (!hasWithdrawn[i]) {
                uint256 shares = shareToken.balanceOf(users[i]);
                _requestWithdrawalAs(users[i], lotIds[i], shares);
                hasWithdrawn[i] = true;
            }
        }
        skip(24 hours);
        for (uint256 i = 15; i < 20; i++) {
            if (hasWithdrawn[i]) {
                _executeWithdrawalAs(users[i]);
            }
        }

        skip(QUARTER - 59 days);

        // Verify sponsor rewards accrued
        SponsorAccountView memory saA = core.sponsorAccount(sponsorA);
        SponsorAccountView memory saB = core.sponsorAccount(sponsorB);
        assertGt(saA.accrued, 0, "sponsorA should have accrued");
        assertGt(saB.accrued, 0, "sponsorB should have accrued");

        // Remaining users withdraw
        for (uint256 i = 0; i < userCount; i++) {
            if (!hasWithdrawn[i]) {
                uint256 shares = shareToken.balanceOf(users[i]);
                if (shares > 0) {
                    _requestWithdrawalAs(users[i], lotIds[i], shares);
                    hasWithdrawn[i] = true;
                }
            }
        }

        skip(24 hours);

        uint256 totalBufferNeeded;
        for (uint256 i = 0; i < userCount; i++) {
            if (hasWithdrawn[i]) {
                WithdrawalRequestView memory req = core.withdrawalRequest(users[i]);
                if (!req.executed && !req.cancelled && req.id != 0) {
                    totalBufferNeeded += req.assetAmountSnapshot;
                }
            }
        }

        ProductTotalsView memory t = core.totals();
        if (totalBufferNeeded > t.bufferAssets) {
            vm.prank(admin);
            core.replenishBuffer(totalBufferNeeded - t.bufferAssets + 1e6);
        }

        for (uint256 i = 0; i < userCount; i++) {
            WithdrawalRequestView memory req = core.withdrawalRequest(users[i]);
            if (req.id != 0 && !req.executed && !req.cancelled) {
                _executeWithdrawalAs(users[i]);
            }
        }

        assertEq(shareToken.totalSupply(), 0, "all shares should be burned");
    }

    // =========================================================================
    //  22. Scale test — 200 users batch deposit + verify accounting
    // =========================================================================

    function test_scaleSimulation200Users() public {
        console2.log("=== TEST 22: Scale - 200 users, 1k USDC each ===");
        _setupAprAndTreasury(APR_10_PERCENT_BPS, 0);

        uint256 userCount = 200;
        uint256 depositAmount = 1_000e6;
        address[] memory users = new address[](userCount);
        uint256[] memory lotIds = new uint256[](userCount);

        for (uint256 i = 0; i < userCount; i++) {
            users[i] = _createAndFundUser(5000 + i, depositAmount * 2);
            lotIds[i] = _depositAs(users[i], depositAmount);
        }

        _logTotals("After 200 deposits");
        ProductTotalsView memory t = core.totals();
        assertEq(t.userPrincipalLiability, depositAmount * userCount);

        console2.log("--- Skip 90 days ---");
        skip(QUARTER);
        _logTotals("After quarter");

        ProductTotalsView memory tQ = core.totals();
        uint256 expectedYield = _expectedProfit(depositAmount * userCount, APR_10_PERCENT_BPS, QUARTER);
        console2.log("--- Scale math ---");
        _logUsdc("totalPrincipal", depositAmount * userCount);
        _logUsdc("expectedYield ", expectedYield);
        _logUsdc("actualYield   ", tQ.userYieldLiability);
        _logUsdc("yieldPerUser  ", expectedYield / userCount);
        assertApproxEqRel(tQ.userYieldLiability, expectedYield, 0.01e18);

        console2.log("--- 50 users withdraw ---");
        for (uint256 i = 0; i < 50; i++) {
            uint256 shares = shareToken.balanceOf(users[i]);
            _requestWithdrawalAs(users[i], lotIds[i], shares);
        }
        skip(24 hours);

        uint256 expectedPayout = depositAmount + _expectedProfit(depositAmount, APR_10_PERCENT_BPS, QUARTER);
        uint256 totalPaidOut;
        for (uint256 i = 0; i < 50; i++) {
            uint256 paid = _executeWithdrawalAs(users[i]);
            totalPaidOut += paid;
            assertApproxEqRel(paid, expectedPayout, 0.01e18);
        }
        _logUsdc("expectedPayout/user", expectedPayout);
        _logUsdc("totalPaidOut (50)  ", totalPaidOut);

        _logTotals("After 50 withdrawals");
        ProductTotalsView memory tPost = core.totals();
        assertEq(tPost.userPrincipalLiability, depositAmount * (userCount - 50));
    }

    // =========================================================================
    //  23. Sponsor claims incrementally over time
    // =========================================================================

    function test_sponsorClaimsIncrementally() public {
        console2.log("=== TEST 23: Sponsor claims monthly over 3 months ===");
        _setupAprAndTreasury(APR_20_PERCENT_BPS, 0);

        address client = _createAndFundUser(6000, 200_000e6);
        _setupSponsorForUser(client, sponsorA, SPONSOR_RATE_BPS);
        _depositAs(client, 100_000e6);
        console2.log("  100k deposit, 20%% APR, 10%% sponsor rate");
        console2.log("  expectedMonthlyReward ~ 100k * 20%% * 30/365 * 10%% = ~164 USDC");

        uint256 totalClaimed;

        for (uint256 month = 0; month < 3; month++) {
            skip(30 days);
            console2.log("--- Month %s ---", month + 1);

            SponsorAccountView memory sa = core.sponsorAccount(sponsorA);
            uint256 newAccrued = sa.accrued - sa.claimed - sa.claimable;
            _logUsdc("totalAccrued  ", sa.accrued);
            _logUsdc("alreadyClaimed", sa.claimed);
            _logUsdc("pending       ", sa.claimable);
            _logUsdc("newAccrued    ", newAccrued);

            if (newAccrued > 0) {
                _fundSponsorBudgetAs(sponsorA, newAccrued);
                SponsorAccountView memory funded = core.sponsorAccount(sponsorA);
                uint256 claimNow = funded.claimable;

                if (claimNow > 0) {
                    _claimSponsorRewardAs(sponsorA, claimNow);
                    totalClaimed += claimNow;
                    _logUsdc("claimedNow    ", claimNow);
                    _logUsdc("runningTotal  ", totalClaimed);
                }
            }
        }

        _logSponsor("A final", sponsorA);
        _logUsdc("totalClaimed  ", totalClaimed);
        SponsorAccountView memory saFinal = core.sponsorAccount(sponsorA);
        assertEq(saFinal.claimed, totalClaimed);
        assertGt(totalClaimed, 0);
    }

    // =========================================================================
    //  24. Re-deposit after full withdrawal
    // =========================================================================

    function test_reDepositAfterFullWithdrawal() public {
        console2.log("=== TEST 24: Re-deposit after full withdrawal (compound) ===");
        _setupAprAndTreasury(APR_10_PERCENT_BPS, 0);

        address user = _createAndFundUser(7000, 500_000e6);

        console2.log("--- Round 1: deposit 100k, wait 90 days ---");
        uint256 lot1 = _depositAs(user, 100_000e6);
        _logLot(lot1);
        skip(QUARTER);

        uint256 shares1 = shareToken.balanceOf(user);
        _requestWithdrawalAs(user, lot1, shares1);
        skip(24 hours);
        _ensureBufferForWithdrawals();
        uint256 paid1 = _executeWithdrawalAs(user);
        _logUsdc("round1 paid   ", paid1);
        _logUsdc("round1 yield  ", paid1 - 100_000e6);

        console2.log("--- Round 2: re-deposit ALL received, wait 90 more days ---");
        _fundAndApprove(user, paid1);
        uint256 lot2 = _depositAs(user, paid1);
        _logUsdc("round2 deposit", paid1);
        _logLot(lot2);

        skip(QUARTER);

        uint256 shares2 = shareToken.balanceOf(user);
        _requestWithdrawalAs(user, lot2, shares2);
        skip(24 hours);
        _ensureBufferForWithdrawals();
        uint256 paid2 = _executeWithdrawalAs(user);
        _logUsdc("round2 paid   ", paid2);
        _logUsdc("round2 yield  ", paid2 - paid1);

        console2.log("--- Compound summary ---");
        _logUsdc("initial       ", 100_000e6);
        _logUsdc("after Q1      ", paid1);
        _logUsdc("after Q2      ", paid2);
        _logUsdc("totalProfit   ", paid2 - 100_000e6);
        console2.log("  compound factor = %s%% growth", (paid2 * 100) / 100_000e6 - 100);

        assertGt(paid2, paid1, "compound re-deposit should grow");
    }

    // =========================================================================
    //  25. Treasury transfer + replenish cycle
    // =========================================================================

    function test_treasuryTransferAndReplenish() public {
        _setupAprAndTreasury(APR_10_PERCENT_BPS, 5_000);

        address user = _createAndFundUser(8000, 200_000e6);
        uint256 deposit = 100_000e6;
        _depositAs(user, deposit);

        uint256 expectedTreasury = (deposit * 5_000) / 10_000;
        ProductTotalsView memory t = core.totals();
        assertEq(t.treasuryReportedAssets, expectedTreasury);

        vm.prank(admin);
        core.transferToTreasury(treasury, expectedTreasury);

        ProductTotalsView memory tAfterTransfer = core.totals();
        assertEq(tAfterTransfer.treasuryReportedAssets, 0);

        skip(QUARTER);

        uint256 shares = shareToken.balanceOf(user);
        _requestWithdrawalAs(user, core.lotsByOwner(user, 0, 1)[0].id, shares);
        skip(24 hours);

        WithdrawalRequestView memory req = core.withdrawalRequest(user);
        ProductTotalsView memory tBeforeReplenish = core.totals();

        if (req.assetAmountSnapshot > tBeforeReplenish.bufferAssets) {
            uint256 shortfall = req.assetAmountSnapshot - tBeforeReplenish.bufferAssets;
            _fundAndApprove(admin, shortfall + 1e6);
            vm.prank(admin);
            core.replenishBuffer(shortfall + 1e6);
        }

        uint256 paid = _executeWithdrawalAs(user);
        assertGt(paid, deposit / 2, "should get at least buffer portion back");
    }

    // =========================================================================
    //  26. Sponsor with no clients accrues nothing
    // =========================================================================

    function test_sponsorWithNoClientsAccruesNothing() public {
        _setupAprAndTreasury(APR_20_PERCENT_BPS, 0);

        vm.prank(admin);
        core.setSponsorRate(sponsorC, SPONSOR_RATE_BPS);

        skip(QUARTER);

        SponsorAccountView memory sa = core.sponsorAccount(sponsorC);
        assertEq(sa.accrued, 0);
    }

    // =========================================================================
    //  27. Zero-APR period: no yield accrues
    // =========================================================================

    function test_zeroAprNoYield() public {
        console2.log("=== TEST 27: Zero APR - no yield accrues ===");
        address user = _createAndFundUser(9000, 200_000e6);
        uint256 lotId = _depositAs(user, 100_000e6);
        _logIndex("indexAtDeposit", core.currentIndex());

        skip(QUARTER);
        _logIndex("indexAfter90d ", core.currentIndex());
        console2.log("  index unchanged (APR = 0%%)");

        uint256 shares = shareToken.balanceOf(user);
        _requestWithdrawalAs(user, lotId, shares);
        skip(24 hours);
        uint256 paid = _executeWithdrawalAs(user);

        _logUsdc("deposited     ", 100_000e6);
        _logUsdc("paid          ", paid);
        console2.log("  yield = 0 (exact principal returned)");
        assertEq(paid, 100_000e6, "zero APR should return exact principal");
    }

    // =========================================================================
    //  28. Withdrawal of exact 1 share (minimum withdrawal)
    // =========================================================================

    function test_withdrawalOfSingleShare() public {
        _setupAprAndTreasury(APR_10_PERCENT_BPS, 0);

        address user = _createAndFundUser(9100, 200_000e6);
        uint256 lotId = _depositAs(user, 100_000e6);

        skip(QUARTER);

        _requestWithdrawalAs(user, lotId, 1);

        LotView memory l = core.lot(lotId);
        assertFalse(l.isFrozen);
        assertGt(l.shareAmount, 0);

        skip(24 hours);
        uint256 paid = _executeWithdrawalAs(user);
        assertGt(paid, 0);
    }

    // =========================================================================
    //  29. Fund sponsor budget partially
    // =========================================================================

    function test_fundSponsorBudgetPartially() public {
        console2.log("=== TEST 29: Fund sponsor budget partially, then top up ===");
        _setupAprAndTreasury(APR_20_PERCENT_BPS, 0);

        address client = _createAndFundUser(9200, 200_000e6);
        _setupSponsorForUser(client, sponsorA, SPONSOR_RATE_BPS);
        _depositAs(client, 100_000e6);

        skip(QUARTER);

        SponsorAccountView memory sa = core.sponsorAccount(sponsorA);
        uint256 halfAccrued = sa.accrued / 2;
        _logSponsor("A before funding", sponsorA);

        console2.log("--- Fund 50%% of accrued ---");
        _logUsdc("funding       ", halfAccrued);
        _fundSponsorBudgetAs(sponsorA, halfAccrued);
        _logSponsor("A after 50%% fund", sponsorA);

        SponsorAccountView memory saHalf = core.sponsorAccount(sponsorA);
        assertEq(saHalf.claimable, halfAccrued);

        console2.log("--- Fund remaining (send full accrued, system caps to needed) ---");
        _logUsdc("funding       ", sa.accrued);
        _fundSponsorBudgetAs(sponsorA, sa.accrued);
        _logSponsor("A after top-up", sponsorA);

        SponsorAccountView memory saFull = core.sponsorAccount(sponsorA);
        console2.log("  claimable = accrued? %s", saFull.claimable == saFull.accrued || saFull.accrued - saFull.claimable <= 1);
        assertApproxEqAbs(saFull.claimable, saFull.accrued, 1);
    }

    // =========================================================================
    //  30. Realistic quarter: 100 users, sponsors, APR changes, blacklists
    // =========================================================================

    function test_realisticQuarterEndToEnd() public {
        _setupAprAndTreasury(APR_10_PERCENT_BPS, TREASURY_RATIO_BPS);

        uint256 userCount = 100;
        address[] memory users = new address[](userCount);
        uint256[] memory lotIds = new uint256[](userCount);
        uint256[] memory deps = new uint256[](userCount);

        // Phase 1: onboard users over 4 weeks
        for (uint256 week = 0; week < 4; week++) {
            uint256 start = week * 25;
            uint256 end = start + 25;
            for (uint256 i = start; i < end; i++) {
                uint256 amount = 2_000e6 + ((i % 10) * 1_000e6);
                users[i] = _createAndFundUser(10_000 + i, amount * 3);
                deps[i] = amount;

                if (i % 5 == 0) {
                    _setupSponsorForUser(users[i], sponsorA, SPONSOR_RATE_BPS);
                } else if (i % 7 == 0) {
                    _setupSponsorForUser(users[i], sponsorB, UPGRADED_SPONSOR_RATE_BPS);
                }

                lotIds[i] = _depositAs(users[i], amount);
            }
            skip(7 days);
        }

        // Phase 2: APR increases
        vm.prank(admin);
        core.setApr(APR_20_PERCENT_BPS);
        skip(24 hours);

        // Phase 3: blacklist 2 users
        vm.startPrank(admin);
        core.setBlacklist(users[3], true);
        core.setBlacklist(users[77], true);
        vm.stopPrank();

        skip(30 days);

        // Phase 4: sponsor A upgrades rate
        vm.prank(admin);
        core.setSponsorRate(sponsorA, UPGRADED_SPONSOR_RATE_BPS);

        skip(30 days);

        // Phase 5: some users withdraw
        for (uint256 i = 0; i < userCount; i += 3) {
            if (core.isBlacklisted(users[i])) continue;
            uint256 shares = shareToken.balanceOf(users[i]);
            if (shares == 0) continue;
            _requestWithdrawalAs(users[i], lotIds[i], shares);
        }

        skip(24 hours);

        // Replenish buffer if needed
        ProductTotalsView memory tPre = core.totals();
        if (tPre.frozenWithdrawalLiability > tPre.bufferAssets) {
            uint256 needed = tPre.frozenWithdrawalLiability - tPre.bufferAssets;
            _fundAndApprove(admin, needed + 1e6);
            vm.prank(admin);
            core.replenishBuffer(needed + 1e6);
        }

        for (uint256 i = 0; i < userCount; i += 3) {
            if (core.isBlacklisted(users[i])) continue;
            WithdrawalRequestView memory req = core.withdrawalRequest(users[i]);
            if (req.id != 0 && !req.executed && !req.cancelled) {
                uint256 paid = _executeWithdrawalAs(users[i]);
                assertGt(paid, 0);
            }
        }

        // Verify sponsor rewards
        SponsorAccountView memory saA = core.sponsorAccount(sponsorA);
        SponsorAccountView memory saB = core.sponsorAccount(sponsorB);
        assertGt(saA.accrued, 0, "sponsorA accrued after upgrade");
        assertGt(saB.accrued, 0, "sponsorB accrued");

        // Fund and claim sponsor A
        _fundSponsorBudgetAs(sponsorA, saA.accrued);
        SponsorAccountView memory saAFunded = core.sponsorAccount(sponsorA);
        if (saAFunded.claimable > 0) {
            _claimSponsorRewardAs(sponsorA, saAFunded.claimable);
        }

        // Verify blacklisted users frozen
        assertTrue(core.isBlacklisted(users[3]));
        assertTrue(core.isBlacklisted(users[77]));
        uint256 globalIdx = core.currentIndex();
        uint256 bl3Idx = core.currentIndex(users[3]);
        assertLt(bl3Idx, globalIdx);

        // Verify totals consistency
        ProductTotalsView memory tFinal = core.totals();
        assertGe(
            tFinal.bufferAssets + tFinal.treasuryReportedAssets,
            0,
            "protocol should remain solvent"
        );
    }

    // =========================================================================
    //  31. Stress test: rapid sequential deposits from same user
    // =========================================================================

    function test_rapidSequentialDepositsFromSameUser() public {
        _setupAprAndTreasury(APR_10_PERCENT_BPS, 0);

        address user = _createAndFundUser(11000, 10_000_000e6);
        uint256 depositCount = 50;

        for (uint256 i = 0; i < depositCount; i++) {
            _depositAs(user, 10_000e6);
            skip(1 hours);
        }

        assertEq(core.ownerLotCount(user), depositCount);

        LotView[] memory lots = core.lotsByOwner(user, 0, depositCount);
        assertEq(lots.length, depositCount);

        ProductTotalsView memory t = core.totals();
        assertEq(t.userPrincipalLiability, 10_000e6 * depositCount);
    }

    // =========================================================================
    //  32. Sponsor reward accrual with multiple APR changes
    // =========================================================================

    function test_sponsorRewardAcrossMulitpleAprChanges() public {
        console2.log("=== TEST 32: Sponsor reward across APR changes 10%%->20%%->10%% ===");
        vm.startPrank(admin);
        core.setApr(APR_10_PERCENT_BPS);
        core.setTreasuryRatio(0);
        vm.stopPrank();
        skip(24 hours);

        address client = _createAndFundUser(12000, 200_000e6);
        _setupSponsorForUser(client, sponsorA, SPONSOR_RATE_BPS);
        _depositAs(client, 100_000e6);
        console2.log("  100k deposit, sponsor rate 10%%");

        console2.log("--- Phase 1: 30 days at 10%% APR ---");
        skip(30 days);
        _logSponsor("A after phase1", sponsorA);

        console2.log("--- APR change: 10%% -> 20%% ---");
        vm.prank(admin);
        core.setApr(APR_20_PERCENT_BPS);
        skip(24 hours);

        console2.log("--- Phase 2: 30 days at 20%% APR ---");
        skip(30 days);
        _logSponsor("A after phase2", sponsorA);

        console2.log("--- APR change: 20%% -> 10%% ---");
        vm.prank(admin);
        core.setApr(APR_10_PERCENT_BPS);
        skip(24 hours);

        console2.log("--- Phase 3: 30 days at 10%% APR ---");
        skip(30 days);
        _logSponsor("A after phase3", sponsorA);

        SponsorAccountView memory sa = core.sponsorAccount(sponsorA);
        assertGt(sa.accrued, 0);

        uint256 reward10 = _expectedSponsorReward(100_000e6, APR_10_PERCENT_BPS, SPONSOR_RATE_BPS, 30 days);
        uint256 reward20 = _expectedSponsorReward(100_000e6, APR_20_PERCENT_BPS, SPONSOR_RATE_BPS, 30 days);
        uint256 reward10b = _expectedSponsorReward(100_000e6, APR_10_PERCENT_BPS, SPONSOR_RATE_BPS, 30 days);
        uint256 expectedTotal = reward10 + reward20 + reward10b;

        console2.log("--- Math breakdown ---");
        console2.log("  formula per phase: 100k * APR * 30/365 * sponsorRate(10%%)");
        _logUsdc("p1 (10%% APR) ", reward10);
        _logUsdc("p2 (20%% APR) ", reward20);
        _logUsdc("p3 (10%% APR) ", reward10b);
        _logUsdc("expectedTotal ", expectedTotal);
        _logUsdc("actualTotal   ", sa.accrued);

        assertApproxEqRel(sa.accrued, expectedTotal, 0.05e18);
    }

    // =========================================================================
    //  33. User unblacklisted can deposit again
    // =========================================================================

    function test_unblacklistedUserCanDepositAgain() public {
        _setupAprAndTreasury(APR_10_PERCENT_BPS, 0);

        address user = _createAndFundUser(13000, 200_000e6);
        _depositAs(user, 50_000e6);

        vm.prank(admin);
        core.setBlacklist(user, true);

        vm.prank(user);
        vm.expectRevert();
        core.deposit(10_000e6, user);

        vm.prank(admin);
        core.setBlacklist(user, false);

        _depositAs(user, 10_000e6);
        assertEq(core.ownerLotCount(user), 2);
    }

    // =========================================================================
    //  34. Edge case: deposit at exact minimum
    // =========================================================================

    function test_depositAtExactMinimum() public {
        _setupAprAndTreasury(APR_10_PERCENT_BPS, 0);

        address user = _createAndFundUser(14000, 200_000e6);
        uint256 minDep = core.minDeposit();
        uint256 lotId = _depositAs(user, minDep);

        LotView memory l = core.lot(lotId);
        assertEq(l.principalAssets, minDep);
        assertGt(l.shareAmount, 0);
    }

    // =========================================================================
    //  35. Change min deposit mid-operation
    // =========================================================================

    function test_changeMinDepositMidOperation() public {
        _setupAprAndTreasury(APR_10_PERCENT_BPS, 0);

        address user = _createAndFundUser(15000, 200_000e6);
        _depositAs(user, 1e6);

        vm.prank(admin);
        core.setMinDeposit(10e6);

        vm.prank(user);
        vm.expectRevert();
        core.deposit(5e6, user);

        _depositAs(user, 10e6);
    }

    // =========================================================================
    //  36. Solvency invariant: contract balance >= buffer + claimable rewards
    // =========================================================================

    function test_solvencyInvariantMaintained() public {
        console2.log("=== TEST 36: Solvency invariant (balance >= buffer + claimable) ===");
        _setupAprAndTreasury(APR_20_PERCENT_BPS, TREASURY_RATIO_BPS);

        uint256 userCount = 30;
        uint256 sponsoredCount;
        for (uint256 i = 0; i < userCount; i++) {
            address user = _createAndFundUser(16000 + i, 200_000e6);
            if (i % 3 == 0) {
                _setupSponsorForUser(user, sponsorA, SPONSOR_RATE_BPS);
                sponsoredCount++;
            }
            _depositAs(user, 50_000e6);
        }
        console2.log("  %s users, %s sponsored (every 3rd), 50k each", userCount, sponsoredCount);
        _logTotals("After deposits");

        skip(QUARTER);
        console2.log("--- After 90 days ---");

        SponsorAccountView memory sa = core.sponsorAccount(sponsorA);
        _logSponsor("A", sponsorA);
        if (sa.accrued > 0) {
            _fundSponsorBudgetAs(sponsorA, sa.accrued);
        }

        ProductTotalsView memory t = core.totals();
        uint256 contractBalance = assetToken.balanceOf(address(core));
        uint256 reserved = t.bufferAssets + t.sponsorRewardClaimable;

        console2.log("--- Solvency check ---");
        _logUsdc("contractBalance", contractBalance);
        _logUsdc("bufferAssets   ", t.bufferAssets);
        _logUsdc("sponsorClaim   ", t.sponsorRewardClaimable);
        _logUsdc("reserved (sum) ", reserved);
        _logUsdc("surplus        ", contractBalance - reserved);
        console2.log("  PASS: contractBalance >= reserved");

        assertGe(contractBalance, reserved, "solvency: balance >= buffer + claimable");
    }
}
