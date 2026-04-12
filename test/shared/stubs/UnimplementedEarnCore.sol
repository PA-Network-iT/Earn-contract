// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {
    IEarnCoreSpec,
    LotView,
    WithdrawalRequestView,
    SponsorAccountView,
    ProductTotalsView
} from "test/shared/interfaces/EarnSpecInterfaces.sol";
import {EarnShareToken} from "src/EarnShareToken.sol";

/// @notice Minimal stub core used where tests need the interface shape without full protocol behavior.
contract UnimplementedEarnCore is IEarnCoreSpec {
    uint256 private constant ONE_RAY = 1e27;
    bytes32 private constant _DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 private constant _PARAMETER_MANAGER_ROLE = keccak256("PARAMETER_MANAGER_ROLE");
    bytes32 private constant _TREASURY_MANAGER_ROLE = keccak256("TREASURY_MANAGER_ROLE");
    bytes32 private constant _COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");
    bytes32 private constant _REPORTER_ROLE = keccak256("REPORTER_ROLE");
    bytes32 private constant _PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 private constant _UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    address private immutable _shareToken;
    uint256 private _nextLotId;
    uint256 private _treasuryRatioBps;
    ProductTotalsView private _totals;
    mapping(uint256 lotId => LotView lotView) private _lots;
    mapping(address owner => uint256[] lotIds) private _userLotIds;
    mapping(address sponsor => uint256[] lotIds) private _sponsorLotIds;
    mapping(address user => address sponsor) private _userSponsors;

    constructor() {
        EarnShareToken implementation = new EarnShareToken();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation), abi.encodeCall(EarnShareToken.initialize, ("EARN LP", "eLP", address(this)))
        );
        _shareToken = address(proxy);
    }

    function initialize(address, address, uint256) external pure {}

    function shareToken() external view returns (address) {
        return _shareToken;
    }

    function setShareToken(address) external pure {}

    function grantRole(bytes32, address) external pure {}

    function revokeRole(bytes32, address) external pure {}

    function hasRole(bytes32 role, address account) external pure returns (bool) {
        return role == _DEFAULT_ADMIN_ROLE && account != address(0);
    }

    function PARAMETER_MANAGER_ROLE() external pure returns (bytes32) {
        return _PARAMETER_MANAGER_ROLE;
    }

    function TREASURY_MANAGER_ROLE() external pure returns (bytes32) {
        return _TREASURY_MANAGER_ROLE;
    }

    function COMPLIANCE_ROLE() external pure returns (bytes32) {
        return _COMPLIANCE_ROLE;
    }

    function REPORTER_ROLE() external pure returns (bytes32) {
        return _REPORTER_ROLE;
    }

    function PAUSER_ROLE() external pure returns (bytes32) {
        return _PAUSER_ROLE;
    }

    function UPGRADER_ROLE() external pure returns (bytes32) {
        return _UPGRADER_ROLE;
    }

    function DEFAULT_ADMIN_ROLE() external pure returns (bytes32) {
        return _DEFAULT_ADMIN_ROLE;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256) {
        _nextLotId += 1;
        address sponsor = _userSponsors[receiver];

        uint256 treasuryShare = (assets * _treasuryRatioBps) / 10_000;
        uint256 bufferShare = assets - treasuryShare;

        _totals.userPrincipalLiability += assets;
        _totals.bufferAssets += bufferShare;
        _totals.treasuryReportedAssets += treasuryShare;

        _lots[_nextLotId] = LotView({
            id: _nextLotId,
            owner: receiver,
            principalAssets: assets,
            shareAmount: assets,
            entryIndexRay: ONE_RAY,
            lastIndexRay: ONE_RAY,
            frozenIndexRay: 0,
            lastSponsorAccumulatorRay: 0,
            openedAt: uint64(block.timestamp),
            frozenAt: 0,
            isFrozen: false,
            isClosed: false,
            sponsor: sponsor
        });

        _userLotIds[receiver].push(_nextLotId);
        if (sponsor != address(0)) {
            _sponsorLotIds[sponsor].push(_nextLotId);
        }

        EarnShareToken(_shareToken).mint(receiver, assets);
        return _nextLotId;
    }

    function requestWithdrawal(uint256, uint256) external pure {}

    function cancelWithdrawal() external pure {}

    function executeWithdrawal() external pure returns (uint256) {
        return 0;
    }

    function claimSponsorReward(uint256) external pure returns (uint256) {
        return 0;
    }

    function setApr(uint256) external pure {}

    function setMinDeposit(uint256) external pure {}

    function setTreasuryRatio(uint256 newRatioBps) external {
        _treasuryRatioBps = newRatioBps;
    }

    function setSponsor(address user, address sponsor) external {
        _userSponsors[user] = sponsor;
    }

    function setMaxSponsorRate(uint256) external pure {}

    function setSponsorRate(address, uint256) external pure {}

    function setBlacklist(address, bool) external pure {}

    function setWithdrawalPause(bool, bool) external pure {}

    function reportTreasuryAssets(uint256) external pure {}

    function fundSponsorBudget(address, uint256) external pure {}

    function transferToTreasury(address, uint256) external pure {}

    function replenishBuffer(uint256) external pure {}

    function upgradeToAndCall(address, bytes calldata) external pure {}

    function currentIndex() external pure returns (uint256) {
        return ONE_RAY;
    }

    function currentIndex(address) external pure returns (uint256) {
        return ONE_RAY;
    }

    function maxSponsorRateBps() external pure returns (uint256) {
        return 2_000;
    }

    function minDeposit() external pure returns (uint256) {
        return 1_000_000;
    }

    function ownerLotCount(address owner) external view returns (uint256) {
        return _userLotIds[owner].length;
    }

    function sponsorLotCount(address sponsor) external view returns (uint256) {
        return _sponsorLotIds[sponsor].length;
    }

    function lot(uint256 lotId) external view returns (LotView memory lotView) {
        return _lots[lotId];
    }

    function lotsByOwner(address owner, uint256 offset, uint256 limit) external view returns (LotView[] memory lots) {
        return _sliceLots(_userLotIds[owner], offset, limit);
    }

    function lotsBySponsor(address sponsor, uint256 offset, uint256 limit)
        external
        view
        returns (LotView[] memory lots)
    {
        return _sliceLots(_sponsorLotIds[sponsor], offset, limit);
    }

    function withdrawalRequest(address) external pure returns (WithdrawalRequestView memory requestView) {
        return requestView;
    }

    function sponsorAccount(address) external pure returns (SponsorAccountView memory sponsorView) {
        return sponsorView;
    }

    function totals() external view returns (ProductTotalsView memory totalsView) {
        return _totals;
    }

    function isBlacklisted(address) external pure returns (bool) {
        return false;
    }

    function requestWithdrawalPaused() external pure returns (bool) {
        return false;
    }

    function executeWithdrawalPaused() external pure returns (bool) {
        return false;
    }

    function _sliceLots(uint256[] storage lotIds, uint256 offset, uint256 limit)
        internal
        view
        returns (LotView[] memory lots)
    {
        uint256 length = lotIds.length;
        if (offset >= length || limit == 0) {
            return new LotView[](0);
        }

        uint256 remaining = length - offset;
        uint256 pageSize = limit > remaining ? remaining : limit;
        uint256 end = offset + pageSize;

        lots = new LotView[](end - offset);
        for (uint256 i = offset; i < end; ++i) {
            lots[i - offset] = _lots[lotIds[i]];
        }
        return lots;
    }
}
