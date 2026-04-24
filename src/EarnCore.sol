// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {EarnShareToken} from "src/EarnShareToken.sol";
import {EarnRoles} from "src/EarnRoles.sol";
import {EarnTypes} from "src/types/EarnTypes.sol";
import {IndexLib} from "src/lib/IndexLib.sol";
import {SponsorLib} from "src/lib/SponsorLib.sol";
import {WithdrawalLib} from "src/lib/WithdrawalLib.sol";
import {EarnStorage} from "src/storage/EarnStorage.sol";
import {ISubscriptionManager} from "src/subscription/ISubscriptionManager.sol";

error Blacklisted(address account);
error InvalidApr(uint256 aprBps);
error InvalidTreasuryRatio(uint256 treasuryRatioBps);
error InvalidSponsorRate(uint256 sponsorRateBps);
error InvalidReceiver(address receiver);
error DepositBelowMinimum(uint256 assets, uint256 minimumAssets);
error ZeroSharesMinted(uint256 assets, uint256 indexRay);
error ZeroWithdrawalShares();
error InvalidWithdrawalLot(uint256 lotId);
error InvalidWithdrawalRequest(uint256 requestId);
error UnauthorizedWithdrawalOwner(address caller, address owner);
error RequestWithdrawalPaused();
error ExecuteWithdrawalPaused();
error WithdrawalLockNotElapsed(uint256 executableAt, uint256 currentTime);
error InsufficientLiquidity(uint256 requested, uint256 available);
error ActiveWithdrawalRequest(address owner);
error SponsorRewardNotClaimable(uint256 claimable, uint256 requested);
error UnauthorizedUpgrade(address caller);
error InsufficientTreasuryTransferCapacity(uint256 requested, uint256 available);
error PendingAprUpdate(uint256 effectiveAt);
error InvalidShareToken(address shareToken);
error ShareTokenAlreadySet(address shareToken);
error InvalidMinimumDeposit(uint256 minimumAssets);
error InvalidAdmin(address admin);
error InvalidAsset(address asset);
error InvalidGenesisTimestamp(uint256 genesisTimestamp);
error InvalidTreasuryWallet(address treasuryWallet);
error NotBlacklisted(address account);
error InvalidForceWithdrawalLot(uint256 lotId);
error SubscriptionRequired(address user);
error InvalidSubscriptionManager(address manager);
error UnauthorizedSponsorManager(address caller);

/// @notice Core contract for the EARN product.
/// @dev Holds assets, manages lots, and coordinates share and sponsor accounting.
contract EarnCore is Initializable, AccessControlUpgradeable, ReentrancyGuardTransient, UUPSUpgradeable, EarnRoles, EarnStorage {
    using SafeERC20 for IERC20;
    using IndexLib for EarnTypes.AprVersion[];
    using SponsorLib for EarnTypes.SponsorRateVersion[];

    uint256 internal constant MAX_APR_BPS = IndexLib.BPS_DENOMINATOR;
    uint256 internal constant DEFAULT_MIN_DEPOSIT = 1e6;
    uint256 internal constant HARD_MAX_SPONSOR_RATE_BPS = 2_000;
    uint256 internal constant DEFAULT_MAX_SPONSOR_RATE_BPS = 2_000;
    uint256 internal constant APR_UPDATE_DELAY = 24 hours;

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
    event WithdrawalCancelled(address indexed owner, uint256 indexed lotId, uint256 requestId);
    event WithdrawalExecuted(address indexed owner, uint256 indexed lotId, uint256 requestId, uint256 assetsPaid);
    event SponsorRewardClaimed(address indexed sponsor, uint256 amount);
    event AprUpdateScheduled(uint256 newAprBps, uint256 effectiveAt);
    event TreasuryRatioUpdated(uint256 newRatioBps);
    event SponsorAssigned(address indexed user, address indexed sponsor);
    event MaxSponsorRateUpdated(uint256 newMaxSponsorRateBps);
    event SponsorRateUpdated(address indexed sponsor, uint256 newRateBps);
    event BlacklistUpdated(address indexed account, bool isBlacklisted);
    event WithdrawalPauseUpdated(bool requestPaused, bool executePaused);
    event TreasuryAssetsReported(uint256 assets);
    event SponsorBudgetFunded(
        address indexed caller, address indexed sponsor, uint256 requestedAmount, uint256 allocatedAmount
    );
    event TreasuryTransferred(address indexed caller, address indexed recipient, uint256 amount);
    event BufferReplenished(address indexed caller, uint256 amount, uint256 reclassifiedTreasuryAmount);
    event MinimumDepositUpdated(uint256 newMinimumAssets);
    event TreasuryWalletUpdated(address indexed newTreasuryWallet);
    event ShareTokenSet(address indexed shareToken);
    event ForceWithdrawalExecuted(
        address indexed user, uint256 indexed lotId, uint256 assetsPaid, uint256 payoutIndexRay
    );
    event UserRehabilitated(address indexed account, uint256 lotsRestored);
    event SubscriptionManagerSet(address indexed subscriptionManager);

    /// @dev Reverts when the subscription gate is active and `user` has no active subscription.
    ///      Gate is intentionally permissive while `_subscriptionManager` is zero so that the
    ///      bootstrap sequence (deploy v2 impl → upgrade → setSubscriptionManager) cannot brick
    ///      existing users in the short window between the upgrade and the wiring transaction.
    modifier onlyActiveSubscriber(address user) {
        address manager = _subscriptionManager;
        if (manager != address(0) && !ISubscriptionManager(manager).hasActiveSubscription(user)) {
            revert SubscriptionRequired(user);
        }
        _;
    }

    modifier onlySponsorManager() {
        if (!hasRole(PARAMETER_MANAGER_ROLE, msg.sender) && !hasRole(SUBSCRIPTION_MANAGER_ROLE, msg.sender)) {
            revert UnauthorizedSponsorManager(msg.sender);
        }
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ===== Initialization =====

    /// @notice Initializes the core proxy.
    /// @param admin Address that receives the initial roles.
    /// @param asset_ Deposit and withdrawal asset.
    /// @param treasuryWallet_ Wallet that receives the treasury portion of deposits.
    /// @param genesisTimestamp Index epoch start. Can be in the past (retroactive launch)
    ///        or in the future (scheduled launch). Must not be zero.
    /// @param initialAprBps APR in basis points active from genesis. Pass 0 for a flat index until the first setApr call.
    function initialize(
        address admin,
        address asset_,
        address treasuryWallet_,
        uint256 genesisTimestamp,
        uint256 initialAprBps
    ) external initializer {
        if (admin == address(0)) {
            revert InvalidAdmin(admin);
        }
        if (asset_ == address(0)) {
            revert InvalidAsset(asset_);
        }
        if (treasuryWallet_ == address(0)) {
            revert InvalidTreasuryWallet(treasuryWallet_);
        }
        if (genesisTimestamp == 0) {
            revert InvalidGenesisTimestamp(genesisTimestamp);
        }

        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PARAMETER_MANAGER_ROLE, admin);
        _grantRole(TREASURY_MANAGER_ROLE, admin);
        _grantRole(COMPLIANCE_ROLE, admin);
        _grantRole(REPORTER_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);

        _asset = asset_;
        _treasuryWallet = treasuryWallet_;
        _aprVersions.push(
            EarnTypes.AprVersion({
                startTimestamp: uint64(genesisTimestamp),
                aprBps: _checkedGenesisAprBps(initialAprBps),
                anchorIndexRay: uint160(IndexLib.ONE_RAY / 10)
            })
        );
        _globalSponsorLiabilityIndexRay = genesisTimestamp;
        _maxSponsorRateBps = DEFAULT_MAX_SPONSOR_RATE_BPS;
        _minDeposit = DEFAULT_MIN_DEPOSIT;
    }

    /// @dev Validates and downcasts the genesis APR value.
    function _checkedGenesisAprBps(uint256 initialAprBps) private pure returns (uint32) {
        if (initialAprBps > MAX_APR_BPS) {
            revert InvalidApr(initialAprBps);
        }
        return uint32(initialAprBps);
    }

    // ===== Configuration =====

    /// @notice Returns the registered share token.
    /// @return Share token address.
    function shareToken() external view returns (address) {
        return _shareToken;
    }

    /// @notice Returns the effective minimum deposit.
    /// @return Minimum deposit in asset units.
    function minDeposit() external view returns (uint256) {
        return _effectiveMinDeposit();
    }

    /// @notice Registers the share token used by the core.
    /// @param shareToken_ Share token proxy address.
    function setShareToken(address shareToken_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (shareToken_ == address(0) || shareToken_.code.length == 0) {
            revert InvalidShareToken(shareToken_);
        }
        if (_shareToken != address(0)) {
            revert ShareTokenAlreadySet(_shareToken);
        }
        if (EarnShareToken(shareToken_).owner() != address(this)) {
            revert InvalidShareToken(shareToken_);
        }
        _shareToken = shareToken_;
        emit ShareTokenSet(shareToken_);
    }

    /// @notice Updates the minimum deposit.
    /// @param newMinimumAssets Minimum deposit in asset units.
    function setMinDeposit(uint256 newMinimumAssets) external onlyRole(PARAMETER_MANAGER_ROLE) {
        if (newMinimumAssets == 0) {
            revert InvalidMinimumDeposit(newMinimumAssets);
        }
        _minDeposit = newMinimumAssets;
        emit MinimumDepositUpdated(newMinimumAssets);
    }

    /// @notice Returns the treasury wallet address.
    /// @return Treasury wallet address.
    function treasuryWallet() external view returns (address) {
        return _treasuryWallet;
    }

    /// @notice Returns the currently wired SubscriptionManager. Zero means gate is inactive.
    /// @return manager SubscriptionManager address.
    function subscriptionManager() external view returns (address manager) {
        return _subscriptionManager;
    }

    /// @notice Wires the SubscriptionManager that gates user-facing operations.
    /// @param manager SubscriptionManager proxy address. Must be non-zero and contain bytecode.
    function setSubscriptionManager(address manager) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (manager == address(0) || manager.code.length == 0) {
            revert InvalidSubscriptionManager(manager);
        }
        _subscriptionManager = manager;
        emit SubscriptionManagerSet(manager);
    }

    /// @notice Updates the treasury wallet address.
    /// @param newTreasuryWallet New treasury wallet address.
    function setTreasuryWallet(address newTreasuryWallet) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newTreasuryWallet == address(0)) {
            revert InvalidTreasuryWallet(newTreasuryWallet);
        }
        _treasuryWallet = newTreasuryWallet;
        emit TreasuryWalletUpdated(newTreasuryWallet);
    }

    /// @notice Returns the available liquidity in the contract (actual USDC balance minus reserves).
    /// @return Available liquidity in asset units.
    function availableLiquidity() external view returns (uint256) {
        return _availableLiquidity();
    }

    // ===== User actions =====

    /// @notice Deposits assets and opens a new lot.
    /// @param assets Asset amount in token decimals.
    /// @param receiver Receiver of the new lot.
    /// @return lotId Newly created lot id.
    function deposit(uint256 assets, address receiver)
        external
        nonReentrant
        onlyActiveSubscriber(receiver)
        returns (uint256 lotId)
    {
        _requireNotBlacklisted(msg.sender);
        _requireNotBlacklisted(receiver);
        if (receiver == address(0)) {
            revert InvalidReceiver(receiver);
        }
        uint256 minimumDeposit = _effectiveMinDeposit();
        if (assets < minimumDeposit) {
            revert DepositBelowMinimum(assets, minimumDeposit);
        }

        uint256 indexRay = currentIndex();
        uint256 shareAmount = IndexLib.previewSharesForDeposit(assets, indexRay);
        if (shareAmount == 0) {
            revert ZeroSharesMinted(assets, indexRay);
        }

        uint256 treasuryShare = (assets * _treasuryRatioBps) / IndexLib.BPS_DENOMINATOR;
        uint256 bufferShare = assets - treasuryShare;

        IERC20(_asset).safeTransferFrom(msg.sender, address(this), bufferShare);
        if (treasuryShare > 0) {
            IERC20(_asset).safeTransferFrom(msg.sender, _treasuryWallet, treasuryShare);
        }

        _nextLotId += 1;

        _totals.userPrincipalLiability += assets;

        address sponsor = _userSponsors[receiver];
        uint256 sponsorAccumulatorRay = 0;
        if (sponsor != address(0)) {
            _trackSponsor(sponsor);
            _trackUserSponsor(receiver, sponsor);
            _checkpointSponsorState(sponsor);
            _sponsorActiveShares[sponsor] += assets;
            _userSponsorActiveShares[receiver][sponsor] += assets;
            _globalSponsoredWeightedSharesBps += assets * _currentSponsorRateBps(sponsor);
            sponsorAccumulatorRay = _sponsorAccounts[sponsor].lastAccumulatorRay;
        }

        _lots[_nextLotId] = EarnTypes.Lot({
            id: _nextLotId,
            owner: receiver,
            principalAssets: assets,
            shareAmount: shareAmount,
            entryIndexRay: indexRay,
            lastIndexRay: indexRay,
            frozenIndexRay: 0,
            lastSponsorAccumulatorRay: sponsorAccumulatorRay,
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

        _totalUncappedShares += shareAmount;
        _totalUncappedPrincipal += assets;

        EarnShareToken(_shareToken).mint(receiver, shareAmount);
        lotId = _nextLotId;
        emit Deposited(msg.sender, receiver, lotId, assets, shareAmount, sponsor);

        return lotId;
    }

    /// @notice Creates a withdrawal request for a lot.
    /// @param lotId Lot to withdraw from.
    /// @param shareAmount Share amount to withdraw.
    function requestWithdrawal(uint256 lotId, uint256 shareAmount)
        external
        nonReentrant
        onlyActiveSubscriber(msg.sender)
    {
        _requireNotBlacklisted(msg.sender);

        if (_requestWithdrawalPaused) {
            revert RequestWithdrawalPaused();
        }
        uint256 latestRequestId = _activeWithdrawalRequestIds[msg.sender];
        if (latestRequestId != 0) {
            EarnTypes.WithdrawalRequest storage activeRequest = _withdrawalRequests[latestRequestId];
            if (!activeRequest.executed && !activeRequest.cancelled) {
                revert ActiveWithdrawalRequest(msg.sender);
            }
        }
        if (shareAmount == 0) {
            revert ZeroWithdrawalShares();
        }

        EarnTypes.Lot storage existingLot = _lots[lotId];
        if (
            existingLot.owner != msg.sender || existingLot.shareAmount == 0 || existingLot.isFrozen
                || existingLot.isClosed || shareAmount > existingLot.shareAmount
        ) {
            revert InvalidWithdrawalLot(lotId);
        }

        EarnShareToken(_shareToken).lock(msg.sender, shareAmount);

        uint256 frozenIndexRay = currentIndex();
        uint256 sponsorAccumulatorRay = existingLot.lastSponsorAccumulatorRay;

        uint256 withdrawnPrincipalAssets;
        if (shareAmount == existingLot.shareAmount) {
            withdrawnPrincipalAssets = existingLot.principalAssets;
        } else {
            withdrawnPrincipalAssets =
                WithdrawalLib.splitProRata(existingLot.principalAssets, shareAmount, existingLot.shareAmount);
        }

        if (_isSponsorAccrualActive(existingLot)) {
            _checkpointSponsorState(existingLot.sponsor);
            sponsorAccumulatorRay = _sponsorAccounts[existingLot.sponsor].lastAccumulatorRay;
            _sponsorActiveShares[existingLot.sponsor] -= withdrawnPrincipalAssets;
            _userSponsorActiveShares[existingLot.owner][existingLot.sponsor] -= withdrawnPrincipalAssets;
            _globalSponsoredWeightedSharesBps -= withdrawnPrincipalAssets * _currentSponsorRateBps(existingLot.sponsor);
        }

        if (shareAmount == existingLot.shareAmount) {
            existingLot.lastIndexRay = frozenIndexRay;
            existingLot.lastSponsorAccumulatorRay = sponsorAccumulatorRay;
            existingLot.frozenIndexRay = frozenIndexRay;
            existingLot.frozenAt = uint64(block.timestamp);
            existingLot.isFrozen = true;
        } else {
            existingLot.shareAmount -= shareAmount;
            existingLot.principalAssets -= withdrawnPrincipalAssets;
            existingLot.lastIndexRay = frozenIndexRay;
            existingLot.lastSponsorAccumulatorRay = sponsorAccumulatorRay;
        }

        uint256 assetAmountSnapshot = WithdrawalLib.snapshotAssetsForShares(shareAmount, frozenIndexRay);

        _nextRequestId += 1;
        uint256 requestId = _nextRequestId;

        _withdrawalRequests[requestId] = EarnTypes.WithdrawalRequest({
            id: requestId,
            owner: msg.sender,
            lotId: lotId,
            shareAmount: shareAmount,
            assetAmountSnapshot: assetAmountSnapshot,
            requestedAt: uint64(block.timestamp),
            executableAt: WithdrawalLib.executableAt(block.timestamp),
            executed: false,
            cancelled: false
        });

        _withdrawalRequestPrincipalAssets[requestId] = withdrawnPrincipalAssets;
        _activeWithdrawalRequestIds[msg.sender] = requestId;
        _totals.userPrincipalLiability -= withdrawnPrincipalAssets;
        _totals.frozenWithdrawalLiability += assetAmountSnapshot;

        _adjustYieldTrackingOnWithdrawal(existingLot, shareAmount, withdrawnPrincipalAssets);

        emit WithdrawalRequested(msg.sender, lotId, requestId, shareAmount, assetAmountSnapshot);
    }

    /// @notice Cancels the caller's active withdrawal request.
    function cancelWithdrawal() external nonReentrant onlyActiveSubscriber(msg.sender) {
        _requireNotBlacklisted(msg.sender);
        uint256 requestId = _activeWithdrawalRequestIds[msg.sender];
        EarnTypes.WithdrawalRequest storage request = _withdrawalRequests[requestId];
        if (request.id == 0 || request.executed || request.cancelled) {
            revert InvalidWithdrawalRequest(requestId);
        }
        if (request.owner != msg.sender) {
            revert UnauthorizedWithdrawalOwner(msg.sender, request.owner);
        }

        request.cancelled = true;
        _totals.frozenWithdrawalLiability -= request.assetAmountSnapshot;

        EarnTypes.Lot storage withdrawalLot = _lots[request.lotId];
        uint256 currentIndexRay = currentIndex();
        uint256 withdrawnPrincipalAssets = _withdrawalRequestPrincipalAssets[requestId];

        if (withdrawalLot.isFrozen) {
            withdrawalLot.isFrozen = false;
            withdrawalLot.frozenAt = 0;
            withdrawalLot.frozenIndexRay = 0;
            withdrawalLot.lastIndexRay = currentIndexRay;
        } else {
            withdrawalLot.shareAmount += request.shareAmount;
            withdrawalLot.principalAssets += withdrawnPrincipalAssets;
            withdrawalLot.lastIndexRay = currentIndexRay;
        }

        if (withdrawalLot.sponsor != address(0)) {
            _checkpointSponsorState(withdrawalLot.sponsor);
            withdrawalLot.lastSponsorAccumulatorRay = _sponsorAccounts[withdrawalLot.sponsor].lastAccumulatorRay;

            if (_lotAccrualCapAt(withdrawalLot) == 0) {
                _sponsorActiveShares[withdrawalLot.sponsor] += withdrawnPrincipalAssets;
                _userSponsorActiveShares[withdrawalLot.owner][withdrawalLot.sponsor] += withdrawnPrincipalAssets;
                _globalSponsoredWeightedSharesBps += withdrawnPrincipalAssets * _currentSponsorRateBps(withdrawalLot.sponsor);
            }
        }

        _totals.userPrincipalLiability += withdrawnPrincipalAssets;
        _restoreYieldTrackingOnCancel(withdrawalLot, request.shareAmount, withdrawnPrincipalAssets);

        EarnShareToken(_shareToken).unlock(request.owner, request.shareAmount);
        emit WithdrawalCancelled(request.owner, request.lotId, requestId);
    }

    /// @notice Executes the caller's active withdrawal request.
    /// @return assetsPaid Asset amount paid to the caller.
    function executeWithdrawal()
        external
        nonReentrant
        onlyActiveSubscriber(msg.sender)
        returns (uint256 assetsPaid)
    {
        _requireNotBlacklisted(msg.sender);

        if (_executeWithdrawalPaused) {
            revert ExecuteWithdrawalPaused();
        }

        uint256 requestId = _activeWithdrawalRequestIds[msg.sender];
        EarnTypes.WithdrawalRequest storage request = _withdrawalRequests[requestId];
        if (request.id == 0 || request.executed || request.cancelled) {
            revert InvalidWithdrawalRequest(requestId);
        }
        if (request.owner != msg.sender) {
            revert UnauthorizedWithdrawalOwner(msg.sender, request.owner);
        }
        if (block.timestamp < request.executableAt) {
            revert WithdrawalLockNotElapsed(request.executableAt, block.timestamp);
        }

        assetsPaid = request.assetAmountSnapshot;
        uint256 liquidity = _availableLiquidity();
        if (assetsPaid > liquidity) {
            revert InsufficientLiquidity(assetsPaid, liquidity);
        }

        request.executed = true;
        _totals.frozenWithdrawalLiability -= assetsPaid;

        EarnTypes.Lot storage withdrawalLot = _lots[request.lotId];
        if (withdrawalLot.isFrozen) {
            withdrawalLot.isClosed = true;
        }

        EarnShareToken(_shareToken).burnLocked(request.owner, request.shareAmount);
        emit WithdrawalExecuted(request.owner, request.lotId, requestId, assetsPaid);
        IERC20(_asset).safeTransfer(request.owner, assetsPaid);
    }

    /// @notice Claims sponsor rewards up to the requested amount.
    /// @param requestedAmount Requested payout amount.
    /// @return paidAmount Amount paid to the sponsor.
    function claimSponsorReward(uint256 requestedAmount)
        external
        nonReentrant
        onlyActiveSubscriber(msg.sender)
        returns (uint256 paidAmount)
    {
        _requireNotBlacklisted(msg.sender);

        _checkpointSponsorState(msg.sender);

        EarnTypes.SponsorAccount storage account = _sponsorAccounts[msg.sender];
        uint256 claimable = account.claimable;
        if (requestedAmount > claimable) {
            revert SponsorRewardNotClaimable(claimable, requestedAmount);
        }

        account.claimable = claimable - requestedAmount;
        account.claimed += requestedAmount;
        _totals.sponsorRewardClaimable -= requestedAmount;
        _totals.sponsorRewardLiability -= requestedAmount;

        emit SponsorRewardClaimed(msg.sender, requestedAmount);
        IERC20(_asset).safeTransfer(msg.sender, requestedAmount);
        return requestedAmount;
    }

    /// @notice Schedules a new APR checkpoint.
    /// @param newAprBps APR in basis points.
    function setApr(uint256 newAprBps) external onlyRole(PARAMETER_MANAGER_ROLE) {
        if (newAprBps > MAX_APR_BPS) {
            revert InvalidApr(newAprBps);
        }
        uint256 effectiveAt = block.timestamp + APR_UPDATE_DELAY;
        uint256 versionCount = _aprVersions.length;
        if (versionCount != 0) {
            uint256 latestVersionStart = _aprVersions[versionCount - 1].startTimestamp;
            if (latestVersionStart > block.timestamp) {
                revert PendingAprUpdate(latestVersionStart);
            }
        }
        _checkpointGlobalSponsorLiability();
        _aprVersions.appendAprVersion(newAprBps, effectiveAt);
        emit AprUpdateScheduled(newAprBps, effectiveAt);
    }

    /// @notice Updates the treasury ratio.
    /// @param newRatioBps Treasury ratio in basis points.
    function setTreasuryRatio(uint256 newRatioBps) external onlyRole(PARAMETER_MANAGER_ROLE) {
        if (newRatioBps > IndexLib.BPS_DENOMINATOR) {
            revert InvalidTreasuryRatio(newRatioBps);
        }
        _treasuryRatioBps = newRatioBps;
        emit TreasuryRatioUpdated(newRatioBps);
    }

    /// @notice Assigns a sponsor to a user for future deposits.
    /// @param user User address.
    /// @param sponsor Sponsor address.
    function setSponsor(address user, address sponsor) external onlySponsorManager {
        _userSponsors[user] = sponsor;
        if (sponsor != address(0)) {
            _trackSponsor(sponsor);
        }
        emit SponsorAssigned(user, sponsor);
    }

    /// @notice Updates the protocol sponsor rate ceiling.
    /// @param newMaxSponsorRateBps New ceiling in basis points.
    function setMaxSponsorRate(uint256 newMaxSponsorRateBps) external onlyRole(PARAMETER_MANAGER_ROLE) {
        if (newMaxSponsorRateBps > HARD_MAX_SPONSOR_RATE_BPS) {
            revert InvalidSponsorRate(newMaxSponsorRateBps);
        }
        _maxSponsorRateBps = newMaxSponsorRateBps;
        emit MaxSponsorRateUpdated(newMaxSponsorRateBps);
    }

    /// @notice Updates the rate for a sponsor.
    /// @param sponsor Sponsor address.
    /// @param newRateBps New rate in basis points.
    function setSponsorRate(address sponsor, uint256 newRateBps) external onlySponsorManager {
        if (newRateBps > _maxSponsorRateBps) {
            revert InvalidSponsorRate(newRateBps);
        }

        _trackSponsor(sponsor);
        _checkpointSponsorState(sponsor);

        uint256 activePrincipal = _sponsorActiveShares[sponsor];
        uint256 previousRateBps = _currentSponsorRateBps(sponsor);
        if (activePrincipal != 0 && previousRateBps != 0) {
            _globalSponsoredWeightedSharesBps -= activePrincipal * previousRateBps;
        }

        _sponsorRateVersions[sponsor].appendRateVersion(newRateBps, block.timestamp);
        if (activePrincipal != 0 && newRateBps != 0) {
            _globalSponsoredWeightedSharesBps += activePrincipal * newRateBps;
        }
        emit SponsorRateUpdated(sponsor, newRateBps);
    }

    /// @notice Updates blacklist status for an account.
    /// @dev Blacklisting records a cutoff timestamp for existing lots.
    /// @dev Unblacklisting reopens access checks but does not remove that historical cutoff.
    /// @param account Account to update.
    /// @param isBlacklisted_ New blacklist flag.
    function setBlacklist(address account, bool isBlacklisted_) external onlyRole(COMPLIANCE_ROLE) {
        _blacklisted[account] = isBlacklisted_;
        if (isBlacklisted_) {
            uint64 cappedAt = uint64(block.timestamp);
            _blacklistTimestamps[account] = cappedAt;
            _capBlacklistedUserLots(account, cappedAt);
            _deactivateBlacklistedUserSponsorShares(account);
        } else {
            _rehabilitateUserLots(account);
        }
        emit BlacklistUpdated(account, isBlacklisted_);
    }

    /// @notice Force-withdraws a blacklisted user's lot at the capped index.
    /// @dev Used when compliance decides the user should not continue using the protocol.
    /// @param user Blacklisted account whose lot is being closed.
    /// @param lotId Lot to force-close.
    /// @return assetsPaid Amount transferred to the user.
    function forceWithdrawBlacklisted(address user, uint256 lotId)
        external
        nonReentrant
        onlyRole(COMPLIANCE_ROLE)
        returns (uint256 assetsPaid)
    {
        if (!_blacklisted[user]) {
            revert NotBlacklisted(user);
        }

        EarnTypes.Lot storage userLot = _lots[lotId];
        if (userLot.owner != user || userLot.isClosed || userLot.shareAmount == 0) {
            revert InvalidForceWithdrawalLot(lotId);
        }

        // Cancel pending withdrawal request for this lot if any
        uint256 requestId = _activeWithdrawalRequestIds[user];
        if (requestId != 0) {
            EarnTypes.WithdrawalRequest storage req = _withdrawalRequests[requestId];
            if (req.id != 0 && !req.executed && !req.cancelled && req.lotId == lotId) {
                req.cancelled = true;
                _totals.frozenWithdrawalLiability -= req.assetAmountSnapshot;

                uint256 reqPrincipal = _withdrawalRequestPrincipalAssets[requestId];
                _totals.userPrincipalLiability += reqPrincipal;
                _restoreYieldTrackingOnCancel(userLot, req.shareAmount, reqPrincipal);

                if (userLot.isFrozen) {
                    userLot.isFrozen = false;
                    userLot.frozenAt = 0;
                    userLot.frozenIndexRay = 0;
                } else {
                    userLot.shareAmount += req.shareAmount;
                    userLot.principalAssets += reqPrincipal;
                }

                EarnShareToken(_shareToken).unlock(user, req.shareAmount);
            }
        }

        uint256 shareAmount = userLot.shareAmount;
        uint256 principalAssets = userLot.principalAssets;

        uint64 capAt = _lotSponsorAccrualCaps[userLot.id];
        if (capAt == 0) {
            capAt = _blacklistTimestamps[user];
        }
        uint256 payoutIndex = capAt != 0 ? _aprVersions.currentIndex(capAt) : currentIndex();
        assetsPaid = IndexLib.previewAssetsForShares(shareAmount, payoutIndex);

        uint256 liquidity = _availableLiquidity();
        if (assetsPaid > liquidity) {
            revert InsufficientLiquidity(assetsPaid, liquidity);
        }

        _adjustYieldTrackingOnWithdrawal(userLot, shareAmount, principalAssets);

        _totals.userPrincipalLiability -= principalAssets;

        userLot.isClosed = true;

        EarnShareToken(_shareToken).burn(user, shareAmount);

        emit ForceWithdrawalExecuted(user, lotId, assetsPaid, payoutIndex);
        IERC20(_asset).safeTransfer(user, assetsPaid);
    }

    /// @notice Updates withdrawal pause switches.
    /// @param requestPaused New request pause flag.
    /// @param executePaused New execute pause flag.
    function setWithdrawalPause(bool requestPaused, bool executePaused) external onlyRole(PAUSER_ROLE) {
        _requestWithdrawalPaused = requestPaused;
        _executeWithdrawalPaused = executePaused;
        emit WithdrawalPauseUpdated(requestPaused, executePaused);
    }

    /// @notice Reports treasury assets into protocol accounting.
    /// @param assets Treasury asset amount.
    function reportTreasuryAssets(uint256 assets) external onlyRole(REPORTER_ROLE) {
        _totals.treasuryReportedAssets = assets;
        emit TreasuryAssetsReported(assets);
    }

    /// @notice Funds sponsor claimable balance.
    /// @param sponsor Sponsor that receives the budget.
    /// @param amount Requested funding amount.
    function fundSponsorBudget(address sponsor, uint256 amount) external nonReentrant onlyRole(TREASURY_MANAGER_ROLE) {
        _checkpointSponsorState(sponsor);

        EarnTypes.SponsorAccount storage account = _sponsorAccounts[sponsor];
        uint256 alreadyAllocated = account.claimed + account.claimable;
        if (account.accrued <= alreadyAllocated) {
            emit SponsorBudgetFunded(msg.sender, sponsor, amount, 0);
            return;
        }

        uint256 allocationNeeded = account.accrued - alreadyAllocated;
        uint256 allocation = allocationNeeded < amount ? allocationNeeded : amount;

        if (allocation != 0) {
            IERC20(_asset).safeTransferFrom(msg.sender, address(this), allocation);
            account.claimable += allocation;
            _totals.sponsorRewardClaimable += allocation;
        }
        emit SponsorBudgetFunded(msg.sender, sponsor, amount, allocation);
    }

    /// @notice Transfers available treasury assets out of the core.
    /// @param recipient Transfer recipient.
    /// @param amount Requested transfer amount.
    function transferToTreasury(address recipient, uint256 amount)
        external
        nonReentrant
        onlyRole(TREASURY_MANAGER_ROLE)
    {
        uint256 available = _transferableTreasuryAssets();
        if (amount > available) {
            revert InsufficientTreasuryTransferCapacity(amount, available);
        }

        _totals.treasuryReportedAssets -= amount;
        IERC20(_asset).safeTransfer(recipient, amount);
        emit TreasuryTransferred(msg.sender, recipient, amount);
    }

    /// @notice Replenishes the liquid buffer by transferring assets into the core.
    /// @param amount Asset amount transferred into the core.
    function replenishBuffer(uint256 amount) external nonReentrant onlyRole(TREASURY_MANAGER_ROLE) {
        IERC20(_asset).safeTransferFrom(msg.sender, address(this), amount);
        uint256 reclassifiedTreasuryAssets = amount;
        if (reclassifiedTreasuryAssets > _totals.treasuryReportedAssets) {
            reclassifiedTreasuryAssets = _totals.treasuryReportedAssets;
        }

        _totals.treasuryReportedAssets -= reclassifiedTreasuryAssets;
        emit BufferReplenished(msg.sender, amount, reclassifiedTreasuryAssets);
    }

    /// @notice Upgrades the implementation and optionally executes setup logic.
    /// @param newImplementation New implementation address.
    /// @param data Optional setup calldata.
    function upgradeToAndCall(address newImplementation, bytes memory data) public payable override(UUPSUpgradeable) {
        super.upgradeToAndCall(newImplementation, data);
    }

    /// @dev Restricts upgrades to the upgrader role.
    function _authorizeUpgrade(address) internal view override {
        if (!hasRole(UPGRADER_ROLE, msg.sender)) {
            revert UnauthorizedUpgrade(msg.sender);
        }
    }

    /// @notice Returns the current protocol index.
    /// @return Index in ray precision.
    function currentIndex() public view returns (uint256) {
        return _aprVersions.currentIndex(block.timestamp);
    }

    /// @notice Returns the effective index for an account.
    /// @dev Blacklisted accounts are capped at their blacklist timestamp.
    /// @param account Account to query.
    /// @return Index in ray precision.
    function currentIndex(address account) public view returns (uint256) {
        uint256 effectiveTimestamp = block.timestamp;
        if (_blacklisted[account]) {
            uint256 blacklistedAt = _blacklistTimestamps[account];
            if (blacklistedAt != 0 && blacklistedAt < effectiveTimestamp) {
                effectiveTimestamp = blacklistedAt;
            }
        }
        return _aprVersions.currentIndex(effectiveTimestamp);
    }

    /// @notice Returns the current sponsor rate ceiling.
    /// @return Sponsor rate ceiling in basis points.
    function maxSponsorRateBps() external view returns (uint256) {
        return _maxSponsorRateBps;
    }

    /// @notice Returns the number of lots created for an owner.
    /// @param owner Owner address.
    /// @return Number of tracked lots.
    function ownerLotCount(address owner) external view returns (uint256) {
        return _userLotIds[owner].length;
    }

    /// @notice Returns the number of lots linked to a sponsor.
    /// @param sponsor Sponsor address.
    /// @return Number of tracked lots.
    function sponsorLotCount(address sponsor) external view returns (uint256) {
        return _sponsorLotIds[sponsor].length;
    }

    /// @notice Returns a lot by id.
    /// @param lotId Lot identifier.
    /// @return Lot view.
    function lot(uint256 lotId) external view returns (EarnTypes.Lot memory) {
        return _lots[lotId];
    }

    /// @notice Returns a slice of lots created for an owner.
    /// @param owner Owner address.
    /// @param offset Zero based start index.
    /// @param limit Maximum number of lots to return.
    /// @return lots Lot views in creation order.
    function lotsByOwner(address owner, uint256 offset, uint256 limit)
        external
        view
        returns (EarnTypes.Lot[] memory lots)
    {
        return _lotsFromIds(_userLotIds[owner], offset, limit);
    }

    /// @notice Returns a slice of lots linked to a sponsor.
    /// @param sponsor Sponsor address.
    /// @param offset Zero based start index.
    /// @param limit Maximum number of lots to return.
    /// @return lots Lot views in creation order.
    function lotsBySponsor(address sponsor, uint256 offset, uint256 limit)
        external
        view
        returns (EarnTypes.Lot[] memory lots)
    {
        return _lotsFromIds(_sponsorLotIds[sponsor], offset, limit);
    }

    /// @notice Returns the active withdrawal request for an owner.
    /// @param owner Owner address.
    /// @return requestView Withdrawal request view.
    function withdrawalRequest(address owner) external view returns (EarnTypes.WithdrawalRequest memory requestView) {
        return _withdrawalRequests[_activeWithdrawalRequestIds[owner]];
    }

    /// @notice Returns sponsor accounting for an address.
    /// @param sponsor Sponsor address.
    /// @return sponsorView Sponsor account view.
    function sponsorAccount(address sponsor) external view returns (EarnTypes.SponsorAccount memory sponsorView) {
        EarnTypes.SponsorAccount storage account = _sponsorAccounts[sponsor];
        sponsorView.accrued = account.accrued + _pendingSponsorReward(sponsor, _currentSponsorAccumulator(sponsor));
        sponsorView.claimable = account.claimable;
        sponsorView.claimed = account.claimed;
        sponsorView.lastAccumulatorRay = _currentSponsorAccumulator(sponsor);
        return sponsorView;
    }

    /// @notice Returns aggregate protocol totals.
    /// @return totalsView Product totals view.
    function totals() external view returns (EarnTypes.ProductTotals memory totalsView) {
        totalsView = _totals;
        uint256 uncappedAssetValue = IndexLib.previewAssetsForShares(_totalUncappedShares, currentIndex());
        uint256 uncappedYield =
            uncappedAssetValue > _totalUncappedPrincipal ? uncappedAssetValue - _totalUncappedPrincipal : 0;
        totalsView.userYieldLiability = uncappedYield + _cappedYieldLiability;
        totalsView.sponsorRewardLiability += _pendingGlobalSponsorLiability();
        return totalsView;
    }

    /// @notice Returns blacklist status for an account.
    /// @param account Account to query.
    /// @return Whether the account is blacklisted.
    function isBlacklisted(address account) external view returns (bool) {
        return _blacklisted[account];
    }

    /// @notice Returns whether withdrawal requests are paused.
    /// @return Pause flag.
    function requestWithdrawalPaused() external view returns (bool) {
        return _requestWithdrawalPaused;
    }

    /// @notice Returns whether withdrawal execution is paused.
    /// @return Pause flag.
    function executeWithdrawalPaused() external view returns (bool) {
        return _executeWithdrawalPaused;
    }

    // ===== Internal helpers =====

    /// @dev Reverts when an account is blacklisted.
    function _requireNotBlacklisted(address account) internal view {
        if (_blacklisted[account]) {
            revert Blacklisted(account);
        }
    }

    /// @dev Materializes a paginated slice of lot views from a stored id registry.
    function _lotsFromIds(uint256[] storage lotIds, uint256 offset, uint256 limit)
        internal
        view
        returns (EarnTypes.Lot[] memory lots)
    {
        uint256 length = lotIds.length;
        if (offset >= length || limit == 0) {
            return new EarnTypes.Lot[](0);
        }

        uint256 remaining = length - offset;
        uint256 pageSize = limit > remaining ? remaining : limit;
        uint256 end = offset + pageSize;

        lots = new EarnTypes.Lot[](end - offset);
        for (uint256 i = offset; i < end; ++i) {
            lots[i - offset] = _lots[lotIds[i]];
        }
        return lots;
    }

    /// @dev Adds a sponsor to the global registry once.
    function _trackSponsor(address sponsor) internal {
        if (!_knownSponsors[sponsor]) {
            _knownSponsors[sponsor] = true;
            _sponsors.push(sponsor);
        }
    }

    /// @dev Adds a sponsor to the user scoped registry once.
    function _trackUserSponsor(address user, address sponsor) internal {
        if (!_userKnownSponsors[user][sponsor]) {
            _userKnownSponsors[user][sponsor] = true;
            _userTrackedSponsors[user].push(sponsor);
        }
    }

    /// @dev Returns treasury assets that can leave the contract without touching reserved balances.
    function _transferableTreasuryAssets() internal view returns (uint256 available) {
        uint256 liquidBalance = IERC20(_asset).balanceOf(address(this));
        uint256 reserved = _totals.sponsorRewardClaimable;

        if (liquidBalance <= reserved) {
            return 0;
        }

        available = liquidBalance - reserved;
        if (available > _totals.treasuryReportedAssets) {
            available = _totals.treasuryReportedAssets;
        }
    }

    /// @dev Returns the available liquidity derived from the actual USDC balance minus reserved sponsor rewards.
    function _availableLiquidity() internal view returns (uint256) {
        uint256 balance = IERC20(_asset).balanceOf(address(this));
        uint256 reserved = _totals.sponsorRewardClaimable;
        return balance > reserved ? balance - reserved : 0;
    }

    /// @dev Returns the configured minimum deposit or the legacy default.
    function _effectiveMinDeposit() internal view returns (uint256) {
        uint256 configuredMinDeposit = _minDeposit;
        if (configuredMinDeposit == 0) {
            return DEFAULT_MIN_DEPOSIT;
        }
        return configuredMinDeposit;
    }

    function _deactivateBlacklistedUserSponsorShares(address user) internal {
        address[] storage sponsors = _userTrackedSponsors[user];

        for (uint256 i = 0; i < sponsors.length; i++) {
            address sponsor = sponsors[i];
            uint256 activePrincipal = _userSponsorActiveShares[user][sponsor];
            if (activePrincipal == 0) {
                continue;
            }

            _checkpointSponsorState(sponsor);
            _sponsorActiveShares[sponsor] -= activePrincipal;
            _globalSponsoredWeightedSharesBps -= activePrincipal * _currentSponsorRateBps(sponsor);
            _userSponsorActiveShares[user][sponsor] = 0;
        }
    }

    /// @dev Reverses the effects of blacklisting for every open lot owned by a user.
    ///      Moves non-frozen lots from capped back to uncapped yield tracking and restores sponsor shares.
    function _rehabilitateUserLots(address user) internal {
        uint256[] storage lotIds = _userLotIds[user];
        uint256 restored = 0;

        for (uint256 i = 0; i < lotIds.length; i++) {
            EarnTypes.Lot storage userLot = _lots[lotIds[i]];
            uint64 capAt = _lotSponsorAccrualCaps[userLot.id];
            if (capAt == 0 || userLot.isClosed) {
                continue;
            }

            _lotSponsorAccrualCaps[userLot.id] = 0;
            restored++;

            if (!userLot.isFrozen && userLot.shareAmount > 0) {
                uint256 cappedIndex = _aprVersions.currentIndex(capAt);
                uint256 assetValue = IndexLib.previewAssetsForShares(userLot.shareAmount, cappedIndex);
                if (assetValue > userLot.principalAssets) {
                    _cappedYieldLiability -= (assetValue - userLot.principalAssets);
                }
                _totalUncappedShares += userLot.shareAmount;
                _totalUncappedPrincipal += userLot.principalAssets;

                if (userLot.sponsor != address(0)) {
                    _checkpointSponsorState(userLot.sponsor);
                    userLot.lastSponsorAccumulatorRay = _sponsorAccounts[userLot.sponsor].lastAccumulatorRay;
                    uint256 rateBps = _currentSponsorRateBps(userLot.sponsor);
                    _sponsorActiveShares[userLot.sponsor] += userLot.principalAssets;
                    _userSponsorActiveShares[user][userLot.sponsor] += userLot.principalAssets;
                    if (rateBps != 0) {
                        _globalSponsoredWeightedSharesBps += userLot.principalAssets * rateBps;
                    }
                }
            }
        }

        _blacklistTimestamps[user] = 0;
        if (restored > 0) {
            emit UserRehabilitated(user, restored);
        }
    }

    /// @dev Records the first blacklist cutoff for every open lot owned by a user
    ///      and moves non-frozen lots from uncapped to capped yield tracking.
    function _capBlacklistedUserLots(address user, uint64 cappedAt) internal {
        uint256[] storage lotIds = _userLotIds[user];
        uint256 cappedIndex = _aprVersions.currentIndex(cappedAt);

        for (uint256 i = 0; i < lotIds.length; i++) {
            EarnTypes.Lot storage userLot = _lots[lotIds[i]];
            if (userLot.isClosed || userLot.shareAmount == 0 || _lotSponsorAccrualCaps[userLot.id] != 0) {
                continue;
            }

            _lotSponsorAccrualCaps[userLot.id] = cappedAt;

            if (!userLot.isFrozen) {
                _totalUncappedShares -= userLot.shareAmount;
                _totalUncappedPrincipal -= userLot.principalAssets;

                uint256 assetValue = IndexLib.previewAssetsForShares(userLot.shareAmount, cappedIndex);
                if (assetValue > userLot.principalAssets) {
                    _cappedYieldLiability += assetValue - userLot.principalAssets;
                }
            }
        }
    }

    /// @dev Subtracts a withdrawn portion from the appropriate yield counter.
    function _adjustYieldTrackingOnWithdrawal(
        EarnTypes.Lot storage lotRef,
        uint256 shareAmount,
        uint256 principalAmount
    ) internal {
        uint256 capAt = _lotAccrualCapAt(lotRef);
        if (capAt != 0) {
            uint256 cappedIndex = _aprVersions.currentIndex(capAt);
            uint256 assetValue = IndexLib.previewAssetsForShares(shareAmount, cappedIndex);
            if (assetValue > principalAmount) {
                _cappedYieldLiability -= (assetValue - principalAmount);
            }
        } else {
            _totalUncappedShares -= shareAmount;
            _totalUncappedPrincipal -= principalAmount;
        }
    }

    /// @dev Restores a cancelled portion into the appropriate yield counter.
    function _restoreYieldTrackingOnCancel(EarnTypes.Lot storage lotRef, uint256 shareAmount, uint256 principalAmount)
        internal
    {
        uint256 capAt = _lotAccrualCapAt(lotRef);
        if (capAt != 0) {
            uint256 cappedIndex = _aprVersions.currentIndex(capAt);
            uint256 assetValue = IndexLib.previewAssetsForShares(shareAmount, cappedIndex);
            if (assetValue > principalAmount) {
                _cappedYieldLiability += assetValue - principalAmount;
            }
        } else {
            _totalUncappedShares += shareAmount;
            _totalUncappedPrincipal += principalAmount;
        }
    }

    /// @dev Returns a lot-level cutoff, falling back to legacy account-level blacklist state if needed.
    function _lotAccrualCapAt(EarnTypes.Lot storage userLot) internal view returns (uint256 cappedAt) {
        cappedAt = _lotSponsorAccrualCaps[userLot.id];
        if (cappedAt != 0) {
            return cappedAt;
        }

        uint256 blacklistedAt = _blacklistTimestamps[userLot.owner];
        if (blacklistedAt != 0 && userLot.openedAt <= blacklistedAt) {
            return blacklistedAt;
        }
    }

    function _checkpointSponsorState(address sponsor) internal {
        _checkpointGlobalSponsorLiability();

        EarnTypes.SponsorAccount storage account = _sponsorAccounts[sponsor];
        uint256 currentAccumulatorRay = _currentSponsorAccumulator(sponsor);
        account.accrued += _pendingSponsorReward(sponsor, currentAccumulatorRay);
        account.lastAccumulatorRay = currentAccumulatorRay;
    }

    function _pendingSponsorReward(address sponsor, uint256 currentAccumulatorRay) internal view returns (uint256) {
        uint256 activePrincipal = _sponsorActiveShares[sponsor];
        uint256 lastAccumulatorRay = _sponsorAccounts[sponsor].lastAccumulatorRay;

        if (activePrincipal == 0 || currentAccumulatorRay <= lastAccumulatorRay) {
            return 0;
        }

        return SponsorLib.rewardFromAccumulatorDelta(activePrincipal, currentAccumulatorRay - lastAccumulatorRay);
    }

    function _pendingGlobalSponsorLiability() internal view returns (uint256) {
        if (_globalSponsoredWeightedSharesBps == 0 || block.timestamp <= _globalSponsorLiabilityIndexRay) {
            return 0;
        }

        return (_globalSponsoredWeightedSharesBps * (block.timestamp - _globalSponsorLiabilityIndexRay))
            / IndexLib.YEAR_IN_SECONDS / IndexLib.BPS_DENOMINATOR;
    }

    function _checkpointGlobalSponsorLiability() internal {
        _totals.sponsorRewardLiability += _pendingGlobalSponsorLiability();
        _globalSponsorLiabilityIndexRay = block.timestamp;
    }

    function _currentSponsorAccumulator(address sponsor) internal view returns (uint256) {
        return _sponsorRateVersions[sponsor].currentAccumulator(block.timestamp);
    }

    function _currentSponsorRateBps(address sponsor) internal view returns (uint256) {
        uint256 versionCount = _sponsorRateVersions[sponsor].length;
        if (versionCount == 0) {
            return 0;
        }

        return _sponsorRateVersions[sponsor][versionCount - 1].sponsorRateBps;
    }

    function _isSponsorAccrualActive(EarnTypes.Lot storage userLot) internal view returns (bool) {
        return userLot.sponsor != address(0) && !userLot.isClosed && !userLot.isFrozen && userLot.shareAmount != 0
            && _lotAccrualCapAt(userLot) == 0;
    }
}
