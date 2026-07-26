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
error ZeroWithdrawalShares();
error InvalidWithdrawalBatchSize(uint256 count);
error InvalidWithdrawalLot(uint256 lotId);
error InvalidEarlyWithdrawalFee(uint256 feeBps);
error InvalidInitialization();
error InvalidApr(uint256 aprBps);
error InvalidTreasuryRatio(uint256 treasuryRatioBps);
error InvalidReceiver(address receiver);
error ZeroSharesMinted(uint256 assets, uint256 indexRay);
error DepositBelowMinimum(uint256 assets, uint256 minimumAssets);
error UnauthorizedUpgrade(address caller);
error NotImplemented(bytes4 selector);
error PendingAprUpdate(uint256 effectiveAt);
error InvalidShareToken(address shareToken);
error ShareTokenAlreadySet(address shareToken);
error InvalidMinimumDeposit(uint256 minimumAssets);
error InvalidAdmin(address admin);
error InvalidAsset(address asset);
error UpgradeImplementationInvalid(address implementation);
error UpgradeNotScheduled(address implementation);
error UpgradeDelayNotElapsed(uint256 executableAt, uint256 currentTime);
error NoScheduledUpgrade();
error InvalidTreasuryWallet(address treasuryWallet);
error NoPendingTreasuryWallet();
error TreasuryWalletDelayNotElapsed(uint256 executableAt, uint256 currentTime);
error UnexpectedTreasuryWallet(address expected, address pending);
error TreasuryWalletChangeIsTwoStep();

/// @notice Test-side view of a core lot; mirrors `EarnTypes.Lot` field order exactly.
struct LotView {
    uint256 id;
    address owner;
    uint256 principalAssets;
    uint256 shareAmount;
    uint256 entryIndexRay;
    uint256 lastIndexRay;
    uint256 frozenIndexRay;
    uint64 openedAt;
    uint64 frozenAt;
    bool isFrozen;
    bool isClosed;
}

/// @notice Test-side view of a withdrawal request; mirrors `EarnTypes.WithdrawalRequest`.
struct WithdrawalRequestView {
    uint256 id;
    address owner;
    uint256[] lotIds;
    uint256[] shareAmounts;
    uint256 assetAmountSnapshot;
    uint256 feeAmountSnapshot;
    uint64 requestedAt;
    uint64 executableAt;
    bool executed;
    bool cancelled;
}

/// @notice Test-side batch withdrawal input.
struct WithdrawalLotInputView {
    uint256 lotId;
    uint256 shareAmount;
}

/// @notice Test-side view of aggregate product accounting; mirrors `EarnTypes.ProductTotals`.
struct ProductTotalsView {
    uint256 userPrincipalLiability;
    uint256 userYieldLiability;
    uint256 frozenWithdrawalLiability;
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
    function initialize(
        address admin,
        address asset,
        address treasuryWallet,
        uint256 genesisTimestamp,
        uint256 initialAprBps
    ) external;
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
    function requestWithdrawal(WithdrawalLotInputView[] calldata withdrawals) external;
    function cancelWithdrawal() external;
    function executeWithdrawal() external returns (uint256 assetsPaid);
    function setApr(uint256 newAprBps) external;
    function setMinDeposit(uint256 newMinimumAssets) external;
    function setTreasuryRatio(uint256 newRatioBps) external;
    function setEarlyWithdrawalFeeBps(uint256 newFeeBps) external;
    function setBlacklist(address account, bool isBlacklisted) external;
    function forceWithdrawBlacklisted(address user, uint256 lotId) external returns (uint256 assetsPaid);
    function setWithdrawalPause(bool requestPaused, bool executePaused) external;
    function reportTreasuryAssets(uint256 assets) external;
    function transferToTreasury(address recipient, uint256 amount) external;
    function replenishBuffer(uint256 amount) external;

    function scheduleUpgrade(address newImplementation) external;
    function cancelScheduledUpgrade() external;
    function upgradeToAndCall(address newImplementation, bytes calldata data) external;
    function scheduledUpgrade()
        external
        view
        returns (address implementation, uint64 scheduledAt, uint64 executableAt);
    function UPGRADE_DELAY() external view returns (uint256);

    function proposeTreasuryWallet(address newTreasuryWallet) external;
    function acceptTreasuryWallet(address expectedTreasuryWallet) external;
    function cancelTreasuryWalletProposal() external;
    function pendingTreasuryWallet() external view returns (address wallet, uint64 proposedAt, uint64 executableAt);
    function setTreasuryWallet(address newTreasuryWallet) external;
    function TREASURY_WALLET_CHANGE_DELAY() external view returns (uint256);

    function availableLiquidity() external view returns (uint256);
    function treasuryWallet() external view returns (address);
    function currentIndex() external view returns (uint256);
    function currentIndex(address account) external view returns (uint256);
    function minDeposit() external view returns (uint256);
    function earlyWithdrawalFeeBps() external view returns (uint256);
    function ownerLotCount(address owner) external view returns (uint256);
    function lot(uint256 lotId) external view returns (LotView memory);
    function lotsByOwner(address owner, uint256 offset, uint256 limit) external view returns (LotView[] memory);
    function withdrawalRequest(address owner) external view returns (WithdrawalRequestView memory);
    function totals() external view returns (ProductTotalsView memory);
    function isBlacklisted(address account) external view returns (bool);
    function requestWithdrawalPaused() external view returns (bool);
    function executeWithdrawalPaused() external view returns (bool);
}
