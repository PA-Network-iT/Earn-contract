// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {
    IEarnCoreSpec,
    IEarnShareTokenSpec,
    SponsorAccountView,
    ProductTotalsView,
    LotView
} from "test/shared/interfaces/EarnSpecInterfaces.sol";
import {EarnCore} from "src/EarnCore.sol";
import {EarnShareToken} from "src/EarnShareToken.sol";
import {MockUSDC} from "test/shared/mocks/MockUSDC.sol";

/// @notice Shared Foundry fixture that deploys the core proxy, share-token proxy, and mock asset.
abstract contract EarnTestBase is Test {
    uint256 internal constant ONE_RAY = 1e27;
    uint256 internal constant INITIAL_INDEX_RAY = 1e26;
    uint256 internal constant YEAR_IN_SECONDS = 365 days;
    uint256 internal constant APR_20_PERCENT_BPS = 2_000;
    uint256 internal constant APR_10_PERCENT_BPS = 1_000;
    uint256 internal constant INDEX_START_TIMESTAMP = 1_743_465_600;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal sponsor = makeAddr("sponsor");
    address internal treasury = makeAddr("treasury");
    address internal asset;

    IEarnCoreSpec internal core;
    IEarnShareTokenSpec internal shareToken;
    MockUSDC internal assetToken;

    function setUp() public virtual {
        vm.warp(INDEX_START_TIMESTAMP);
        assetToken = new MockUSDC();
        asset = address(assetToken);

        EarnCore implementation = new EarnCore();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(implementation), abi.encodeCall(EarnCore.initialize, (admin, asset, treasury, block.timestamp, 0)));
        EarnShareToken tokenImplementation = new EarnShareToken();
        ERC1967Proxy tokenProxy = new ERC1967Proxy(
            address(tokenImplementation), abi.encodeCall(EarnShareToken.initialize, ("EARN LP", "eLP", address(proxy)))
        );
        core = IEarnCoreSpec(address(proxy));
        vm.prank(admin);
        core.setShareToken(address(tokenProxy));
        shareToken = IEarnShareTokenSpec(core.shareToken());

        _fundAndApprove(alice, 10_000_000e6);
        _fundAndApprove(bob, 10_000_000e6);
        _fundAndApprove(sponsor, 10_000_000e6);
        _fundAndApprove(admin, 10_000_000e6);
    }

    function _expectedLinearIndex(uint256 aprBps, uint256 elapsed) internal pure returns (uint256) {
        return INITIAL_INDEX_RAY + ((INITIAL_INDEX_RAY * aprBps * elapsed) / (YEAR_IN_SECONDS * 10_000));
    }

    function _expectedLinearIndexFromAnchor(uint256 anchorIndexRay, uint256 aprBps, uint256 elapsed)
        internal
        pure
        returns (uint256)
    {
        return anchorIndexRay + ((anchorIndexRay * aprBps * elapsed) / (YEAR_IN_SECONDS * 10_000));
    }

    function _expectedSharesForDeposit(uint256 assets, uint256 indexRay) internal pure returns (uint256) {
        return (assets * ONE_RAY) / indexRay;
    }

    function _expectedAssetsForShares(uint256 shares, uint256 indexRay) internal pure returns (uint256) {
        return (shares * indexRay) / ONE_RAY;
    }

    function _expectedProfit(uint256 principalAssets, uint256 aprBps, uint256 elapsed) internal pure returns (uint256) {
        return (principalAssets * aprBps * elapsed) / (YEAR_IN_SECONDS * 10_000);
    }

    function _expectedSponsorReward(uint256 principalAssets, uint256 sponsorRateBps, uint256 elapsed)
        internal
        pure
        returns (uint256)
    {
        return (principalAssets * sponsorRateBps * elapsed) / (YEAR_IN_SECONDS * 10_000);
    }

    function _expectedPiecewiseSponsorReward(
        uint256 principalAssets,
        uint256 firstRateBps,
        uint256 firstElapsed,
        uint256 secondRateBps,
        uint256 secondElapsed
    ) internal pure returns (uint256) {
        return _expectedSponsorReward(principalAssets, firstRateBps, firstElapsed)
            + _expectedSponsorReward(principalAssets, secondRateBps, secondElapsed);
    }

    function _assertPopulatedLot(
        LotView memory lotView,
        uint256 expectedId,
        address expectedOwner,
        uint256 expectedAssets
    ) internal pure {
        assertEq(lotView.id, expectedId);
        assertEq(lotView.owner, expectedOwner);
        assertEq(lotView.principalAssets, expectedAssets);
        assertGt(lotView.entryIndexRay, 0);
    }

    function _assertDefaultTotals(ProductTotalsView memory totalsView) internal pure {
        assertEq(totalsView.userPrincipalLiability, 0);
        assertEq(totalsView.userYieldLiability, 0);
        assertEq(totalsView.frozenWithdrawalLiability, 0);
        assertEq(totalsView.sponsorRewardLiability, 0);
    }

    function _assertDefaultSponsor(SponsorAccountView memory sponsorView) internal pure {
        assertEq(sponsorView.accrued, 0);
        assertEq(sponsorView.claimable, 0);
        assertEq(sponsorView.claimed, 0);
    }

    function _fundAndApprove(address account, uint256 amount) internal {
        assetToken.mint(account, amount);

        vm.prank(account);
        assetToken.approve(address(core), type(uint256).max);
    }
}
