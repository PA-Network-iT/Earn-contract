// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

error TransfersDisabled();
error InsufficientUnlockedBalance(address account, uint256 requested, uint256 available);
error InsufficientLockedBalance(address account, uint256 requested, uint256 lockedAmount);
error UnauthorizedCore(address caller);
error Blacklisted(address account);
error RequestWithdrawalPaused();
error ExecuteWithdrawalPaused();
error WithdrawalLockNotElapsed(uint256 executableAt, uint256 currentTime);
error InsufficientLiquidity(uint256 requested, uint256 available);
error ActiveWithdrawalRequest(address owner);
error InvalidInitialization();
error InvalidApr(uint256 aprBps);
error InvalidTreasuryRatio(uint256 treasuryRatioBps);
error InvalidSponsorRate(uint256 sponsorRateBps);
error InvalidReceiver(address receiver);
error ZeroSharesMinted(uint256 assets, uint256 indexRay);
error DepositBelowMinimum(uint256 assets, uint256 minimumAssets);
error UnauthorizedUpgrade(address caller);
error SponsorRewardNotClaimable(uint256 claimable, uint256 requested);
error NotImplemented(bytes4 selector);
error PendingAprUpdate(uint256 effectiveAt);
error InvalidShareToken(address shareToken);
error ShareTokenAlreadySet(address shareToken);
error InvalidMinimumDeposit(uint256 minimumAssets);
error InvalidAdmin(address admin);
error InvalidAsset(address asset);

/// @notice Test-side view of a core lot; mirrors `EarnTypes.Lot` field order exactly.
struct LotView {
    uint256 id;
    address owner;
    uint256 principalAssets;
    uint256 shareAmount;
    uint256 entryIndexRay;
    uint256 lastIndexRay;
    uint256 frozenIndexRay;
    uint256 lastSponsorAccumulatorRay;
    uint64 openedAt;
    uint64 frozenAt;
    bool isFrozen;
    bool isClosed;
    address sponsor;
}

/// @notice Test-side view of a withdrawal request; mirrors `EarnTypes.WithdrawalRequest`.
struct WithdrawalRequestView {
    uint256 id;
    address owner;
    uint256 lotId;
    uint256 shareAmount;
    uint256 assetAmountSnapshot;
    uint64 requestedAt;
    uint64 executableAt;
    bool executed;
    bool cancelled;
}

/// @notice Test-side view of sponsor accounting; mirrors `EarnTypes.SponsorAccount`.
struct SponsorAccountView {
    uint256 accrued;
    uint256 claimable;
    uint256 claimed;
    uint256 lastAccumulatorRay;
}

/// @notice Test-side view of aggregate product accounting; mirrors `EarnTypes.ProductTotals`.
struct ProductTotalsView {
    uint256 userPrincipalLiability;
    uint256 userYieldLiability;
    uint256 frozenWithdrawalLiability;
    uint256 sponsorRewardLiability;
    uint256 sponsorRewardClaimable;
    uint256 bufferAssets;
    uint256 treasuryReportedAssets;
}

/// @notice Behavioral interface used by tests to exercise share-token implementations.
interface IEarnShareTokenSpec {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function lockedBalanceOf(address account) external view returns (uint256);
    function availableBalanceOf(address account) external view returns (uint256);
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
    function burnLocked(address from, uint256 amount) external;
    function lock(address account, uint256 amount) external;
    function unlock(address account, uint256 amount) external;
}

/// @notice Behavioral interface used by tests to exercise core implementations and upgrade mocks.
interface IEarnCoreSpec {
    function initialize(address admin, address asset, uint256 genesisTimestamp, uint256 initialAprBps) external;
    function initializeV2(uint256 initialAprBps) external;
    function shareToken() external view returns (address);
    function setShareToken(address shareToken) external;
    function grantRole(bytes32 role, address account) external;
    function revokeRole(bytes32 role, address account) external;
    function hasRole(bytes32 role, address account) external view returns (bool);
    function PARAMETER_MANAGER_ROLE() external view returns (bytes32);
    function TREASURY_MANAGER_ROLE() external view returns (bytes32);
    function COMPLIANCE_ROLE() external view returns (bytes32);
    function REPORTER_ROLE() external view returns (bytes32);
    function PAUSER_ROLE() external view returns (bytes32);
    function UPGRADER_ROLE() external view returns (bytes32);
    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);

    function deposit(uint256 assets, address receiver) external returns (uint256 lotId);
    function requestWithdrawal(uint256 lotId, uint256 shareAmount) external;
    function cancelWithdrawal() external;
    function executeWithdrawal() external returns (uint256 assetsPaid);
    function claimSponsorReward(uint256 requestedAmount) external returns (uint256 paidAmount);

    function setApr(uint256 newAprBps) external;
    function setMinDeposit(uint256 newMinimumAssets) external;
    function setTreasuryRatio(uint256 newRatioBps) external;
    function setSponsor(address user, address sponsor) external;
    function setMaxSponsorRate(uint256 newMaxSponsorRateBps) external;
    function setSponsorRate(address sponsor, uint256 newRateBps) external;
    function setBlacklist(address account, bool isBlacklisted) external;
    function setWithdrawalPause(bool requestPaused, bool executePaused) external;
    function reportTreasuryAssets(uint256 assets) external;
    function fundSponsorBudget(address sponsor, uint256 amount) external;
    function transferToTreasury(address recipient, uint256 amount) external;
    function replenishBuffer(uint256 amount) external;
    function upgradeToAndCall(address newImplementation, bytes calldata data) external;

    function currentIndex() external view returns (uint256);
    function currentIndex(address account) external view returns (uint256);
    function maxSponsorRateBps() external view returns (uint256);
    function minDeposit() external view returns (uint256);
    function ownerLotCount(address owner) external view returns (uint256);
    function sponsorLotCount(address sponsor) external view returns (uint256);
    function lot(uint256 lotId) external view returns (LotView memory);
    function lotsByOwner(address owner, uint256 offset, uint256 limit) external view returns (LotView[] memory);
    function lotsBySponsor(address sponsor, uint256 offset, uint256 limit) external view returns (LotView[] memory);
    function withdrawalRequest(address owner) external view returns (WithdrawalRequestView memory);
    function sponsorAccount(address sponsor) external view returns (SponsorAccountView memory);
    function totals() external view returns (ProductTotalsView memory);
    function isBlacklisted(address account) external view returns (bool);
    function requestWithdrawalPaused() external view returns (bool);
    function executeWithdrawalPaused() external view returns (bool);
}
