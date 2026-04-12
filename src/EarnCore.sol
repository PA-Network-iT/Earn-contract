// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {EarnShareToken} from "src/EarnShareToken.sol";
import {EarnRoles} from "src/EarnRoles.sol";
import {EarnTypes} from "src/types/EarnTypes.sol";
import {IndexLib} from "src/lib/IndexLib.sol";
import {SponsorLib} from "src/lib/SponsorLib.sol";
import {WithdrawalLib} from "src/lib/WithdrawalLib.sol";
import {EarnStorage} from "src/storage/EarnStorage.sol";

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

/// @notice Core contract for the EARN product.
/// @dev Holds assets, manages lots, and coordinates share and sponsor accounting.
contract EarnCore is Initializable, AccessControlUpgradeable, ReentrancyGuard, UUPSUpgradeable, EarnRoles, EarnStorage {
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
        address indexed owner, uint256 indexed lotId, uint256 shareAmount, uint256 assetAmountSnapshot
    );
    event WithdrawalCancelled(address indexed owner, uint256 indexed lotId);
    event WithdrawalExecuted(address indexed owner, uint256 indexed lotId, uint256 assetsPaid);
    event SponsorRewardClaimed(address indexed sponsor, uint256 requestedAmount, uint256 paidAmount);
    event AprUpdateScheduled(uint256 newAprBps, uint256 effectiveAt);
    event TreasuryRatioUpdated(uint256 newRatioBps);
    event SponsorAssigned(address indexed user, address indexed sponsor);
    event MaxSponsorRateUpdated(uint256 newMaxSponsorRateBps);
    event SponsorRateUpdated(address indexed sponsor, uint256 newRateBps);
    event BlacklistUpdated(address indexed account, bool isBlacklisted);
    event WithdrawalPauseUpdated(bool requestPaused, bool executePaused);
    event TreasuryAssetsReported(uint256 assets);
    event SponsorBudgetFunded(address indexed sponsor, uint256 requestedAmount, uint256 allocatedAmount);
    event TreasuryTransferred(address indexed recipient, uint256 amount);
    event BufferReplenished(address indexed caller, uint256 amount, uint256 reclassifiedTreasuryAmount);
    event MinimumDepositUpdated(uint256 newMinimumAssets);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ===== Initialization =====

    /// @notice Initializes the core proxy.
    /// @param admin Address that receives the initial roles.
    /// @param asset_ Deposit and withdrawal asset.
    function initialize(address admin, address asset_) external initializer {
        if (admin == address(0)) {
            revert InvalidAdmin(admin);
        }
        if (asset_ == address(0)) {
            revert InvalidAsset(asset_);
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
        _aprVersions.push(
            EarnTypes.AprVersion({
                startTimestamp: uint64(block.timestamp), aprBps: 0, anchorIndexRay: uint160(IndexLib.ONE_RAY)
            })
        );
        _globalSponsorLiabilityIndexRay = IndexLib.ONE_RAY;
        _maxSponsorRateBps = DEFAULT_MAX_SPONSOR_RATE_BPS;
        _minDeposit = DEFAULT_MIN_DEPOSIT;
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

    // ===== User actions =====

    /// @notice Deposits assets and opens a new lot.
    /// @param assets Asset amount in token decimals.
    /// @param receiver Receiver of the new lot.
    /// @return lotId Newly created lot id.
    function deposit(uint256 assets, address receiver) external nonReentrant returns (uint256 lotId) {
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

        IERC20(_asset).safeTransferFrom(msg.sender, address(this), assets);

        _nextLotId += 1;

        _totals.userPrincipalLiability += assets;
        _totals.bufferAssets += bufferShare;
        _totals.treasuryReportedAssets += treasuryShare;

        address sponsor = _userSponsors[receiver];
        uint256 sponsorAccumulatorRay = 0;
        if (sponsor != address(0)) {
            _trackSponsor(sponsor);
            _trackUserSponsor(receiver, sponsor);
            _checkpointSponsorState(sponsor, indexRay);
            _sponsorActiveShares[sponsor] += shareAmount;
            _userSponsorActiveShares[receiver][sponsor] += shareAmount;
            _globalSponsoredWeightedSharesBps += shareAmount * _currentSponsorRateBps(sponsor);
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

        EarnShareToken(_shareToken).mint(receiver, shareAmount);
        lotId = _nextLotId;
        emit Deposited(msg.sender, receiver, lotId, assets, shareAmount, sponsor);

        return lotId;
    }

    /// @notice Creates a withdrawal request for a lot.
    /// @param lotId Lot to withdraw from.
    /// @param shareAmount Share amount to withdraw.
    function requestWithdrawal(uint256 lotId, uint256 shareAmount) external nonReentrant {
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
        uint256 withdrawnPrincipalAssets = existingLot.principalAssets;
        uint256 sponsorAccumulatorRay = existingLot.lastSponsorAccumulatorRay;

        if (_isSponsorAccrualActive(existingLot)) {
            _checkpointSponsorState(existingLot.sponsor, frozenIndexRay);
            sponsorAccumulatorRay = _sponsorAccounts[existingLot.sponsor].lastAccumulatorRay;
            _sponsorActiveShares[existingLot.sponsor] -= shareAmount;
            _userSponsorActiveShares[existingLot.owner][existingLot.sponsor] -= shareAmount;
            _globalSponsoredWeightedSharesBps -= shareAmount * _currentSponsorRateBps(existingLot.sponsor);
        }

        if (shareAmount == existingLot.shareAmount) {
            existingLot.lastIndexRay = frozenIndexRay;
            existingLot.lastSponsorAccumulatorRay = sponsorAccumulatorRay;
            existingLot.frozenIndexRay = frozenIndexRay;
            existingLot.frozenAt = uint64(block.timestamp);
            existingLot.isFrozen = true;
        } else {
            uint256 originalShareAmount = existingLot.shareAmount;
            withdrawnPrincipalAssets =
                WithdrawalLib.splitProRata(existingLot.principalAssets, shareAmount, originalShareAmount);

            existingLot.shareAmount = originalShareAmount - shareAmount;
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
        emit WithdrawalRequested(msg.sender, lotId, shareAmount, assetAmountSnapshot);
    }

    /// @notice Cancels the caller's active withdrawal request.
    function cancelWithdrawal() external nonReentrant {
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
            _checkpointSponsorState(withdrawalLot.sponsor, currentIndexRay);
            withdrawalLot.lastSponsorAccumulatorRay = _sponsorAccounts[withdrawalLot.sponsor].lastAccumulatorRay;

            if (_lotAccrualCapAt(withdrawalLot) == 0) {
                uint256 restoredShares = request.shareAmount;
                _sponsorActiveShares[withdrawalLot.sponsor] += restoredShares;
                _userSponsorActiveShares[withdrawalLot.owner][withdrawalLot.sponsor] += restoredShares;
                _globalSponsoredWeightedSharesBps += restoredShares * _currentSponsorRateBps(withdrawalLot.sponsor);
            }
        }

        _totals.userPrincipalLiability += withdrawnPrincipalAssets;
        EarnShareToken(_shareToken).unlock(request.owner, request.shareAmount);
        emit WithdrawalCancelled(request.owner, request.lotId);
    }

    /// @notice Executes the caller's active withdrawal request.
    /// @return assetsPaid Asset amount paid to the caller.
    function executeWithdrawal() external nonReentrant returns (uint256 assetsPaid) {
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
        uint256 availableLiquidity = _totals.bufferAssets;
        if (assetsPaid > availableLiquidity) {
            revert InsufficientLiquidity(assetsPaid, availableLiquidity);
        }

        request.executed = true;
        _totals.frozenWithdrawalLiability -= assetsPaid;
        _totals.bufferAssets = availableLiquidity - assetsPaid;

        EarnTypes.Lot storage withdrawalLot = _lots[request.lotId];
        if (withdrawalLot.isFrozen) {
            withdrawalLot.isClosed = true;
        }

        EarnShareToken(_shareToken).burnLocked(request.owner, request.shareAmount);
        emit WithdrawalExecuted(request.owner, request.lotId, assetsPaid);
        IERC20(_asset).safeTransfer(request.owner, assetsPaid);
    }

    /// @notice Claims sponsor rewards up to the requested amount.
    /// @param requestedAmount Requested payout amount.
    /// @return paidAmount Amount paid to the sponsor.
    function claimSponsorReward(uint256 requestedAmount) external nonReentrant returns (uint256 paidAmount) {
        _requireNotBlacklisted(msg.sender);

        _checkpointSponsorState(msg.sender, currentIndex());

        EarnTypes.SponsorAccount storage account = _sponsorAccounts[msg.sender];
        uint256 claimable = account.claimable;
        if (requestedAmount > claimable) {
            revert SponsorRewardNotClaimable(claimable, requestedAmount);
        }

        account.claimable = claimable - requestedAmount;
        account.claimed += requestedAmount;
        _totals.sponsorRewardClaimable -= requestedAmount;
        _totals.sponsorRewardLiability -= requestedAmount;

        emit SponsorRewardClaimed(msg.sender, requestedAmount, requestedAmount);
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
        _checkpointGlobalSponsorLiability(currentIndex());
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
    function setSponsor(address user, address sponsor) external onlyRole(PARAMETER_MANAGER_ROLE) {
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
    function setSponsorRate(address sponsor, uint256 newRateBps) external onlyRole(PARAMETER_MANAGER_ROLE) {
        if (newRateBps > _maxSponsorRateBps) {
            revert InvalidSponsorRate(newRateBps);
        }

        _trackSponsor(sponsor);
        uint256 currentIndexRay = currentIndex();
        _checkpointSponsorState(sponsor, currentIndexRay);

        uint256 activeShares = _sponsorActiveShares[sponsor];
        uint256 previousRateBps = _currentSponsorRateBps(sponsor);
        if (activeShares != 0 && previousRateBps != 0) {
            _globalSponsoredWeightedSharesBps -= activeShares * previousRateBps;
        }

        _sponsorRateVersions[sponsor].appendRateVersion(_aprVersions, newRateBps, block.timestamp);
        if (activeShares != 0 && newRateBps != 0) {
            _globalSponsoredWeightedSharesBps += activeShares * newRateBps;
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
            _deactivateBlacklistedUserSponsorShares(account, currentIndex());
        }
        emit BlacklistUpdated(account, isBlacklisted_);
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
        _checkpointSponsorState(sponsor, currentIndex());

        EarnTypes.SponsorAccount storage account = _sponsorAccounts[sponsor];
        uint256 alreadyAllocated = account.claimed + account.claimable;
        if (account.accrued <= alreadyAllocated) {
            emit SponsorBudgetFunded(sponsor, amount, 0);
            return;
        }

        uint256 allocationNeeded = account.accrued - alreadyAllocated;
        uint256 allocation = allocationNeeded < amount ? allocationNeeded : amount;

        if (allocation != 0) {
            IERC20(_asset).safeTransferFrom(msg.sender, address(this), allocation);
            account.claimable += allocation;
            _totals.sponsorRewardClaimable += allocation;
        }
        emit SponsorBudgetFunded(sponsor, amount, allocation);
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
        emit TreasuryTransferred(recipient, amount);
    }

    /// @notice Replenishes the liquid buffer.
    /// @param amount Asset amount transferred into the core.
    function replenishBuffer(uint256 amount) external nonReentrant onlyRole(TREASURY_MANAGER_ROLE) {
        IERC20(_asset).safeTransferFrom(msg.sender, address(this), amount);
        uint256 reclassifiedTreasuryAssets = amount;
        if (reclassifiedTreasuryAssets > _totals.treasuryReportedAssets) {
            reclassifiedTreasuryAssets = _totals.treasuryReportedAssets;
        }

        _totals.treasuryReportedAssets -= reclassifiedTreasuryAssets;
        _totals.bufferAssets += amount;
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
        totalsView.userYieldLiability = _userYieldLiabilityAt(block.timestamp);
        totalsView.sponsorRewardLiability += _pendingGlobalSponsorLiability(currentIndex());
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
        uint256 reservedBalance = _totals.bufferAssets + _totals.sponsorRewardClaimable;

        if (liquidBalance <= reservedBalance) {
            return 0;
        }

        available = liquidBalance - reservedBalance;
        if (available > _totals.treasuryReportedAssets) {
            available = _totals.treasuryReportedAssets;
        }
    }

    /// @dev Computes live user yield liability at a timestamp.
    function _userYieldLiabilityAt(uint256 timestamp) internal view returns (uint256 liability) {
        for (uint256 lotId = 1; lotId <= _nextLotId; lotId++) {
            EarnTypes.Lot storage activeLot = _lots[lotId];

            if (activeLot.owner == address(0) || activeLot.isClosed || activeLot.isFrozen || activeLot.shareAmount == 0)
            {
                continue;
            }

            uint256 currentAssetValue =
                IndexLib.previewAssetsForShares(activeLot.shareAmount, _indexForLot(activeLot, timestamp));
            if (currentAssetValue > activeLot.principalAssets) {
                liability += currentAssetValue - activeLot.principalAssets;
            }
        }
    }

    /// @dev Returns the configured minimum deposit or the legacy default.
    function _effectiveMinDeposit() internal view returns (uint256) {
        uint256 configuredMinDeposit = _minDeposit;
        if (configuredMinDeposit == 0) {
            return DEFAULT_MIN_DEPOSIT;
        }
        return configuredMinDeposit;
    }

    function _deactivateBlacklistedUserSponsorShares(address user, uint256 currentIndexRay) internal {
        address[] storage sponsors = _userTrackedSponsors[user];

        for (uint256 i = 0; i < sponsors.length; i++) {
            address sponsor = sponsors[i];
            uint256 activeShares = _userSponsorActiveShares[user][sponsor];
            if (activeShares == 0) {
                continue;
            }

            _checkpointSponsorState(sponsor, currentIndexRay);
            _sponsorActiveShares[sponsor] -= activeShares;
            _globalSponsoredWeightedSharesBps -= activeShares * _currentSponsorRateBps(sponsor);
            _userSponsorActiveShares[user][sponsor] = 0;
        }
    }

    /// @dev Records the first blacklist cutoff for every open lot owned by a user.
    function _capBlacklistedUserLots(address user, uint64 cappedAt) internal {
        uint256[] storage lotIds = _userLotIds[user];

        for (uint256 i = 0; i < lotIds.length; i++) {
            EarnTypes.Lot storage userLot = _lots[lotIds[i]];
            if (userLot.isClosed || userLot.shareAmount == 0 || _lotSponsorAccrualCaps[userLot.id] != 0) {
                continue;
            }

            _lotSponsorAccrualCaps[userLot.id] = cappedAt;
        }
    }

    /// @dev Caps a lot at the first recorded blacklist timestamp.
    function _effectiveTimestampForLot(EarnTypes.Lot storage userLot, uint256 timestamp)
        internal
        view
        returns (uint256 effectiveTimestamp)
    {
        effectiveTimestamp = timestamp;

        uint256 cappedAt = _lotAccrualCapAt(userLot);
        if (cappedAt != 0 && cappedAt < effectiveTimestamp) {
            effectiveTimestamp = cappedAt;
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

    function _indexForLot(EarnTypes.Lot storage userLot, uint256 timestamp) internal view returns (uint256) {
        return _aprVersions.currentIndex(_effectiveTimestampForLot(userLot, timestamp));
    }

    function _checkpointSponsorState(address sponsor, uint256 currentIndexRay) internal {
        _checkpointGlobalSponsorLiability(currentIndexRay);

        EarnTypes.SponsorAccount storage account = _sponsorAccounts[sponsor];
        uint256 currentAccumulatorRay = _currentSponsorAccumulator(sponsor);
        account.accrued += _pendingSponsorReward(sponsor, currentAccumulatorRay);
        account.lastAccumulatorRay = currentAccumulatorRay;
    }

    function _pendingSponsorReward(address sponsor, uint256 currentAccumulatorRay) internal view returns (uint256) {
        uint256 activeShares = _sponsorActiveShares[sponsor];
        uint256 lastAccumulatorRay = _sponsorAccounts[sponsor].lastAccumulatorRay;

        if (activeShares == 0 || currentAccumulatorRay <= lastAccumulatorRay) {
            return 0;
        }

        return SponsorLib.rewardFromAccumulatorDelta(activeShares, currentAccumulatorRay - lastAccumulatorRay);
    }

    function _pendingGlobalSponsorLiability(uint256 currentIndexRay) internal view returns (uint256) {
        if (_globalSponsoredWeightedSharesBps == 0 || currentIndexRay <= _globalSponsorLiabilityIndexRay) {
            return 0;
        }

        return (_globalSponsoredWeightedSharesBps * (currentIndexRay - _globalSponsorLiabilityIndexRay))
            / IndexLib.ONE_RAY / IndexLib.BPS_DENOMINATOR;
    }

    function _checkpointGlobalSponsorLiability(uint256 currentIndexRay) internal {
        _totals.sponsorRewardLiability += _pendingGlobalSponsorLiability(currentIndexRay);
        _globalSponsorLiabilityIndexRay = currentIndexRay;
    }

    function _currentSponsorAccumulator(address sponsor) internal view returns (uint256) {
        return _sponsorRateVersions[sponsor].currentAccumulator(_aprVersions, block.timestamp);
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
