// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {EarnShareToken} from "src/EarnShareToken.sol";
import {EarnRoles} from "src/EarnRoles.sol";
import {EarnTypes} from "src/types/EarnTypes.sol";
import {IndexLib} from "src/lib/IndexLib.sol";
import {
    KycAuthorization,
    InvalidKycAuthorization,
    KycAuthorizationExpired,
    InvalidKycSigner,
    KycCallerMismatch
} from "src/lib/KycAuthorization.sol";
import {WithdrawalLib} from "src/lib/WithdrawalLib.sol";
import {EarnStorage} from "src/storage/EarnStorage.sol";
import {ISubscriptionManager} from "src/subscription/ISubscriptionManager.sol";

error Blacklisted(address account);
error InvalidApr(uint256 aprBps);
error InvalidTreasuryRatio(uint256 treasuryRatioBps);
error InvalidReceiver(address receiver);
error DepositBelowMinimum(uint256 assets, uint256 minimumAssets);
error ZeroSharesMinted(uint256 assets, uint256 indexRay);
error ZeroWithdrawalShares();
error InvalidWithdrawalBatchSize(uint256 count);
error InvalidWithdrawalLot(uint256 lotId);
error InvalidEarlyWithdrawalFee(uint256 feeBps);
error InvalidWithdrawalRequest(uint256 requestId);
error UnauthorizedWithdrawalOwner(address caller, address owner);
error RequestWithdrawalPaused();
error ExecuteWithdrawalPaused();
error WithdrawalLockNotElapsed(uint256 executableAt, uint256 currentTime);
error InsufficientLiquidity(uint256 requested, uint256 available);
error ActiveWithdrawalRequest(address owner);
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

/// @notice Core contract for the EARN product.
/// @dev Holds assets, manages lots, and coordinates share accounting.
contract EarnCore is
    Initializable,
    AccessControlUpgradeable,
    EIP712Upgradeable,
    ReentrancyGuardTransient,
    UUPSUpgradeable,
    EarnRoles,
    EarnStorage
{
    using SafeERC20 for IERC20;
    using IndexLib for EarnTypes.AprVersion[];

    uint256 internal constant MAX_APR_BPS = IndexLib.BPS_DENOMINATOR;
    uint256 internal constant DEFAULT_MIN_DEPOSIT = 1e6;
    uint256 internal constant APR_UPDATE_DELAY = 24 hours;
    uint256 internal constant MAX_WITHDRAWAL_BATCH_SIZE = 50;
    uint256 internal constant EARLY_WITHDRAWAL_WINDOW = 365 days;
    uint256 internal constant KYC_DEPOSIT_THRESHOLD = 1_000e6;

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
    event WithdrawalCancelled(address indexed owner, uint256 indexed requestId, uint256[] lotIds);
    event WithdrawalExecuted(
        address indexed owner, uint256 indexed requestId, uint256[] lotIds, uint256 assetsPaid, uint256 feeAmount
    );
    event AprUpdateScheduled(uint256 newAprBps, uint256 effectiveAt);
    event TreasuryRatioUpdated(uint256 newRatioBps);
    event BlacklistUpdated(address indexed account, bool isBlacklisted);
    event WithdrawalPauseUpdated(bool requestPaused, bool executePaused);
    event TreasuryAssetsReported(uint256 assets);
    event TreasuryTransferred(address indexed caller, address indexed recipient, uint256 amount);
    event BufferReplenished(address indexed caller, uint256 amount, uint256 reclassifiedTreasuryAmount);
    event MinimumDepositUpdated(uint256 newMinimumAssets);
    event EarlyWithdrawalFeeUpdated(uint256 newFeeBps);
    event TreasuryWalletUpdated(address indexed newTreasuryWallet);
    event ShareTokenSet(address indexed shareToken);
    event ForceWithdrawalExecuted(
        address indexed user, uint256 indexed lotId, uint256 assetsPaid, uint256 payoutIndexRay
    );
    event UserRehabilitated(address indexed account, uint256 lotsRestored);
    event SubscriptionManagerSet(address indexed subscriptionManager);
    event KycSignerUpdated(address indexed signer);
    event KycAuthorizationConsumed(address indexed user, uint8 indexed scope, uint256 nonce, uint64 expiresAt);

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
        __EIP712_init("PAiT Earn KYC", "1");
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

    /// @notice Returns the early withdrawal fee in basis points.
    function earlyWithdrawalFeeBps() external view returns (uint256) {
        return _earlyWithdrawalFeeBps;
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

    /// @notice Updates the early withdrawal fee charged on lot items younger than one year.
    /// @param newFeeBps Fee in basis points.
    function setEarlyWithdrawalFeeBps(uint256 newFeeBps) external onlyRole(PARAMETER_MANAGER_ROLE) {
        if (newFeeBps > IndexLib.BPS_DENOMINATOR) {
            revert InvalidEarlyWithdrawalFee(newFeeBps);
        }
        _earlyWithdrawalFeeBps = newFeeBps;
        emit EarlyWithdrawalFeeUpdated(newFeeBps);
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

    /// @notice Returns the backend signer trusted for KYC authorizations.
    function kycSigner() external view returns (address signer) {
        return _kycSigner;
    }

    /// @notice Returns the next KYC authorization nonce expected for `user`.
    function kycNonce(address user) external view returns (uint256 nonce) {
        return _kycNonces[user];
    }

    /// @notice Returns capped cumulative deposits used by the KYC threshold gate.
    function cumulativeDeposited(address user) external view returns (uint256 assets) {
        return _cumulativeDeposited[user];
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

    /// @notice Sets the backend signer trusted for EIP-712 KYC authorizations.
    function setKycSigner(address signer) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setKycSigner(signer);
    }

    /// @notice Initializes KYC EIP-712 state after upgrading an already-initialized proxy.
    function initializeKycSigner(address signer) external onlyRole(DEFAULT_ADMIN_ROLE) reinitializer(3) {
        __EIP712_init("PAiT Earn KYC", "1");
        _setKycSigner(signer);
    }

    function _setKycSigner(address signer) internal {
        if (signer == address(0) || signer.code.length != 0) {
            revert InvalidKycSigner(signer);
        }
        _kycSigner = signer;
        emit KycSignerUpdated(signer);
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
        return _deposit(assets, receiver, "");
    }

    /// @notice Deposits assets and opens a new lot, with optional KYC authorization.
    /// @param assets Asset amount in token decimals.
    /// @param receiver Receiver of the new lot.
    /// @param kycAuthorization ABI-encoded `(uint64 expiresAt, uint256 nonce, bytes signature)`.
    /// @return lotId Newly created lot id.
    function deposit(uint256 assets, address receiver, bytes calldata kycAuthorization)
        external
        nonReentrant
        onlyActiveSubscriber(receiver)
        returns (uint256 lotId)
    {
        return _deposit(assets, receiver, kycAuthorization);
    }

    function _deposit(uint256 assets, address receiver, bytes memory kycAuthorization)
        internal
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

        _enforceDepositKyc(receiver, assets, kycAuthorization);

        uint256 treasuryShare = (assets * _treasuryRatioBps) / IndexLib.BPS_DENOMINATOR;
        uint256 bufferShare = assets - treasuryShare;

        IERC20(_asset).safeTransferFrom(msg.sender, address(this), bufferShare);
        if (treasuryShare > 0) {
            IERC20(_asset).safeTransferFrom(msg.sender, _treasuryWallet, treasuryShare);
        }

        _nextLotId += 1;

        _totals.userPrincipalLiability += assets;

        _lots[_nextLotId] = EarnTypes.Lot({
            id: _nextLotId,
            owner: receiver,
            principalAssets: assets,
            shareAmount: shareAmount,
            entryIndexRay: indexRay,
            lastIndexRay: indexRay,
            frozenIndexRay: 0,
            openedAt: uint64(block.timestamp),
            frozenAt: 0,
            isFrozen: false,
            isClosed: false
        });

        _userLotIds[receiver].push(_nextLotId);

        _totalUncappedShares += shareAmount;
        _totalUncappedPrincipal += assets;

        EarnShareToken(_shareToken).mint(receiver, shareAmount);
        lotId = _nextLotId;
        emit Deposited(msg.sender, receiver, lotId, assets, shareAmount);

        return lotId;
    }

    /// @notice Creates a withdrawal request for one or more lots.
    /// @param withdrawals Lot slices to withdraw as one atomic request.
    function requestWithdrawal(EarnTypes.WithdrawalLotInput[] calldata withdrawals)
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
        uint256 withdrawalCount = withdrawals.length;
        if (withdrawalCount == 0 || withdrawalCount > MAX_WITHDRAWAL_BATCH_SIZE) {
            revert InvalidWithdrawalBatchSize(withdrawalCount);
        }

        uint256 frozenIndexRay = currentIndex();
        uint256[] memory lotIds = new uint256[](withdrawalCount);
        uint256[] memory shareAmounts = new uint256[](withdrawalCount);
        uint256[] memory principalAssets = new uint256[](withdrawalCount);
        uint256 totalShareAmount;
        uint256 totalPrincipalAssets;
        uint256 assetAmountSnapshot;
        uint256 feeAmountSnapshot;

        for (uint256 i; i < withdrawalCount; ++i) {
            uint256 lotId = withdrawals[i].lotId;
            uint256 shareAmount = withdrawals[i].shareAmount;
            if (shareAmount == 0) {
                revert ZeroWithdrawalShares();
            }
            for (uint256 j; j < i; ++j) {
                if (lotIds[j] == lotId) {
                    revert InvalidWithdrawalLot(lotId);
                }
            }

            EarnTypes.Lot storage existingLot = _lots[lotId];
            if (
                existingLot.owner != msg.sender || existingLot.shareAmount == 0 || existingLot.isFrozen
                    || existingLot.isClosed || shareAmount > existingLot.shareAmount
            ) {
                revert InvalidWithdrawalLot(lotId);
            }

            uint256 withdrawnPrincipalAssets;
            if (shareAmount == existingLot.shareAmount) {
                withdrawnPrincipalAssets = existingLot.principalAssets;
            } else {
                withdrawnPrincipalAssets =
                    WithdrawalLib.splitProRata(existingLot.principalAssets, shareAmount, existingLot.shareAmount);
            }

            lotIds[i] = lotId;
            shareAmounts[i] = shareAmount;
            principalAssets[i] = withdrawnPrincipalAssets;
            totalShareAmount += shareAmount;
            totalPrincipalAssets += withdrawnPrincipalAssets;
            uint256 itemAssetSnapshot = WithdrawalLib.snapshotAssetsForShares(shareAmount, frozenIndexRay);
            assetAmountSnapshot += itemAssetSnapshot;
            feeAmountSnapshot += _earlyWithdrawalFee(existingLot, itemAssetSnapshot);
        }

        EarnShareToken(_shareToken).lock(msg.sender, totalShareAmount);

        for (uint256 i; i < withdrawalCount; ++i) {
            EarnTypes.Lot storage existingLot = _lots[lotIds[i]];
            uint256 shareAmount = shareAmounts[i];
            uint256 withdrawnPrincipalAssets = principalAssets[i];

            if (shareAmount == existingLot.shareAmount) {
                existingLot.lastIndexRay = frozenIndexRay;
                existingLot.frozenIndexRay = frozenIndexRay;
                existingLot.frozenAt = uint64(block.timestamp);
                existingLot.isFrozen = true;
            } else {
                existingLot.shareAmount -= shareAmount;
                existingLot.principalAssets -= withdrawnPrincipalAssets;
                existingLot.lastIndexRay = frozenIndexRay;
            }

            _adjustYieldTrackingOnWithdrawal(existingLot, shareAmount, withdrawnPrincipalAssets);
        }

        _nextRequestId += 1;
        uint256 requestId = _nextRequestId;

        EarnTypes.WithdrawalRequest storage request = _withdrawalRequests[requestId];
        request.id = requestId;
        request.owner = msg.sender;
        request.assetAmountSnapshot = assetAmountSnapshot;
        request.feeAmountSnapshot = feeAmountSnapshot;
        request.requestedAt = uint64(block.timestamp);
        request.executableAt = WithdrawalLib.executableAt(block.timestamp);
        for (uint256 i; i < withdrawalCount; ++i) {
            request.lotIds.push(lotIds[i]);
            request.shareAmounts.push(shareAmounts[i]);
            _withdrawalRequestPrincipalAssets[requestId].push(principalAssets[i]);
        }

        _activeWithdrawalRequestIds[msg.sender] = requestId;
        _totals.userPrincipalLiability -= totalPrincipalAssets;
        _totals.frozenWithdrawalLiability += _netWithdrawalAssets(request);

        emit WithdrawalRequested(msg.sender, requestId, lotIds, shareAmounts, assetAmountSnapshot, feeAmountSnapshot);
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

        uint256[] memory lotIds = _copyUintArray(request.lotIds);
        uint256 totalShareAmount = _cancelWithdrawalRequest(request, requestId);
        EarnShareToken(_shareToken).unlock(request.owner, totalShareAmount);
        emit WithdrawalCancelled(request.owner, requestId, lotIds);
    }

    /// @notice Executes the caller's active withdrawal request.
    /// @return assetsPaid Asset amount paid to the caller.
    function executeWithdrawal() external nonReentrant onlyActiveSubscriber(msg.sender) returns (uint256 assetsPaid) {
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

        assetsPaid = _netWithdrawalAssets(request);
        uint256 liquidity = _availableLiquidity();
        if (assetsPaid > liquidity) {
            revert InsufficientLiquidity(assetsPaid, liquidity);
        }

        request.executed = true;
        _totals.frozenWithdrawalLiability -= assetsPaid;

        uint256 totalShareAmount;
        uint256 lotCount = request.lotIds.length;
        for (uint256 i; i < lotCount; ++i) {
            totalShareAmount += request.shareAmounts[i];
            EarnTypes.Lot storage withdrawalLot = _lots[request.lotIds[i]];
            if (withdrawalLot.isFrozen) {
                withdrawalLot.isClosed = true;
                withdrawalLot.isFrozen = false;
                withdrawalLot.frozenAt = 0;
                withdrawalLot.frozenIndexRay = 0;
            }
        }

        uint256[] memory lotIds = _copyUintArray(request.lotIds);
        EarnShareToken(_shareToken).burnLocked(request.owner, totalShareAmount);
        emit WithdrawalExecuted(request.owner, requestId, lotIds, assetsPaid, request.feeAmountSnapshot);
        IERC20(_asset).safeTransfer(request.owner, assetsPaid);
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

        uint256 requestId = _activeWithdrawalRequestIds[user];
        if (requestId != 0) {
            EarnTypes.WithdrawalRequest storage req = _withdrawalRequests[requestId];
            if (req.id != 0 && !req.executed && !req.cancelled && _withdrawalRequestContainsLot(req, lotId)) {
                uint256[] memory lotIds = _copyUintArray(req.lotIds);
                uint256 totalShareAmount = _cancelWithdrawalRequest(req, requestId);
                EarnShareToken(_shareToken).unlock(user, totalShareAmount);
                emit WithdrawalCancelled(user, requestId, lotIds);
            }
        }

        uint256 shareAmount = userLot.shareAmount;
        uint256 principalAssets = userLot.principalAssets;

        uint64 capAt = _lotAccrualCaps[userLot.id];
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

    /// @notice Returns the number of lots created for an owner.
    /// @param owner Owner address.
    /// @return Number of tracked lots.
    function ownerLotCount(address owner) external view returns (uint256) {
        return _userLotIds[owner].length;
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

    /// @notice Returns the active withdrawal request for an owner.
    /// @param owner Owner address.
    /// @return requestView Withdrawal request view.
    function withdrawalRequest(address owner) external view returns (EarnTypes.WithdrawalRequest memory requestView) {
        return _withdrawalRequests[_activeWithdrawalRequestIds[owner]];
    }

    /// @notice Returns aggregate protocol totals.
    /// @return totalsView Product totals view.
    function totals() external view returns (EarnTypes.ProductTotals memory totalsView) {
        totalsView = _totals;
        uint256 uncappedAssetValue = IndexLib.previewAssetsForShares(_totalUncappedShares, currentIndex());
        uint256 uncappedYield =
            uncappedAssetValue > _totalUncappedPrincipal ? uncappedAssetValue - _totalUncappedPrincipal : 0;
        totalsView.userYieldLiability = uncappedYield + _cappedYieldLiability;
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

    /// @dev Returns treasury assets that can leave the contract without touching reserved balances.
    function _transferableTreasuryAssets() internal view returns (uint256 available) {
        uint256 liquidBalance = IERC20(_asset).balanceOf(address(this));

        available = liquidBalance;
        if (available > _totals.treasuryReportedAssets) {
            available = _totals.treasuryReportedAssets;
        }
    }

    /// @dev Returns the available liquidity derived from the actual USDC balance.
    function _availableLiquidity() internal view returns (uint256) {
        return IERC20(_asset).balanceOf(address(this));
    }

    /// @dev Returns the configured minimum deposit or the legacy default.
    function _effectiveMinDeposit() internal view returns (uint256) {
        uint256 configuredMinDeposit = _minDeposit;
        if (configuredMinDeposit == 0) {
            return DEFAULT_MIN_DEPOSIT;
        }
        return configuredMinDeposit;
    }

    function _enforceDepositKyc(address receiver, uint256 assets, bytes memory kycAuthorization) internal {
        uint256 deposited = _cumulativeDeposited[receiver];

        if (deposited >= KYC_DEPOSIT_THRESHOLD) {
            if (msg.sender != receiver) {
                revert KycCallerMismatch(msg.sender, receiver);
            }
            _consumeKycAuthorization(receiver, KycAuthorization.SCOPE_DEPOSIT, kycAuthorization);
            return;
        }

        uint256 newTotal = deposited + assets;
        if (newTotal <= KYC_DEPOSIT_THRESHOLD) {
            _cumulativeDeposited[receiver] = newTotal;
            return;
        }

        if (msg.sender != receiver) {
            revert KycCallerMismatch(msg.sender, receiver);
        }
        _consumeKycAuthorization(receiver, KycAuthorization.SCOPE_DEPOSIT, kycAuthorization);
        _cumulativeDeposited[receiver] = KYC_DEPOSIT_THRESHOLD;
    }

    function _consumeKycAuthorization(address user, uint8 scope, bytes memory authorization) internal {
        address signer = _kycSigner;
        if (signer == address(0)) {
            revert InvalidKycSigner(signer);
        }

        (uint64 expiresAt, uint256 nonce, bytes memory signature) = KycAuthorization.decode(user, authorization);
        if (expiresAt < block.timestamp) {
            revert KycAuthorizationExpired(user);
        }
        if (expiresAt > block.timestamp + KycAuthorization.MAX_TTL) {
            revert InvalidKycAuthorization(user);
        }
        if (nonce != _kycNonces[user]) {
            revert InvalidKycAuthorization(user);
        }

        bytes32 structHash = keccak256(abi.encode(KycAuthorization.TYPEHASH, user, scope, expiresAt, nonce));
        address recovered = ECDSA.recover(_hashTypedDataV4(structHash), signature);
        if (recovered != signer) {
            revert InvalidKycAuthorization(user);
        }

        _kycNonces[user] = nonce + 1;
        emit KycAuthorizationConsumed(user, scope, nonce, expiresAt);
    }

    /// @dev Reverses the effects of blacklisting for every open lot owned by a user.
    ///      Moves non-frozen lots from capped back to uncapped yield tracking.
    function _rehabilitateUserLots(address user) internal {
        uint256[] storage lotIds = _userLotIds[user];
        uint256 restored = 0;

        for (uint256 i = 0; i < lotIds.length; i++) {
            EarnTypes.Lot storage userLot = _lots[lotIds[i]];
            uint64 capAt = _lotAccrualCaps[userLot.id];
            if (capAt == 0 || userLot.isClosed) {
                continue;
            }

            _lotAccrualCaps[userLot.id] = 0;
            restored++;

            if (!userLot.isFrozen && userLot.shareAmount > 0) {
                uint256 cappedIndex = _aprVersions.currentIndex(capAt);
                uint256 assetValue = IndexLib.previewAssetsForShares(userLot.shareAmount, cappedIndex);
                if (assetValue > userLot.principalAssets) {
                    _cappedYieldLiability -= (assetValue - userLot.principalAssets);
                }
                _totalUncappedShares += userLot.shareAmount;
                _totalUncappedPrincipal += userLot.principalAssets;
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
            if (userLot.isClosed || userLot.shareAmount == 0 || _lotAccrualCaps[userLot.id] != 0) {
                continue;
            }

            _lotAccrualCaps[userLot.id] = cappedAt;

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

    function _copyUintArray(uint256[] storage values) internal view returns (uint256[] memory copied) {
        uint256 length = values.length;
        copied = new uint256[](length);
        for (uint256 i; i < length; ++i) {
            copied[i] = values[i];
        }
    }

    function _withdrawalRequestContainsLot(EarnTypes.WithdrawalRequest storage request, uint256 lotId)
        internal
        view
        returns (bool)
    {
        uint256 length = request.lotIds.length;
        for (uint256 i; i < length; ++i) {
            if (request.lotIds[i] == lotId) {
                return true;
            }
        }
        return false;
    }

    function _earlyWithdrawalFee(EarnTypes.Lot storage lotRef, uint256 assetAmount) internal view returns (uint256) {
        uint256 feeBps = _earlyWithdrawalFeeBps;
        if (feeBps == 0 || block.timestamp >= uint256(lotRef.openedAt) + EARLY_WITHDRAWAL_WINDOW) {
            return 0;
        }
        return (assetAmount * feeBps) / IndexLib.BPS_DENOMINATOR;
    }

    function _netWithdrawalAssets(EarnTypes.WithdrawalRequest storage request) internal view returns (uint256) {
        return request.assetAmountSnapshot - request.feeAmountSnapshot;
    }

    function _cancelWithdrawalRequest(EarnTypes.WithdrawalRequest storage request, uint256 requestId)
        internal
        returns (uint256 totalShareAmount)
    {
        request.cancelled = true;
        _totals.frozenWithdrawalLiability -= _netWithdrawalAssets(request);

        uint256 currentIndexRay = currentIndex();
        uint256 totalPrincipalAssets;
        uint256 lotCount = request.lotIds.length;

        for (uint256 i; i < lotCount; ++i) {
            EarnTypes.Lot storage withdrawalLot = _lots[request.lotIds[i]];
            uint256 shareAmount = request.shareAmounts[i];
            uint256 withdrawnPrincipalAssets = _withdrawalRequestPrincipalAssets[requestId][i];

            if (withdrawalLot.isFrozen) {
                withdrawalLot.isFrozen = false;
                withdrawalLot.frozenAt = 0;
                withdrawalLot.frozenIndexRay = 0;
                withdrawalLot.lastIndexRay = currentIndexRay;
            } else {
                withdrawalLot.shareAmount += shareAmount;
                withdrawalLot.principalAssets += withdrawnPrincipalAssets;
                withdrawalLot.lastIndexRay = currentIndexRay;
            }

            totalShareAmount += shareAmount;
            totalPrincipalAssets += withdrawnPrincipalAssets;
            _restoreYieldTrackingOnCancel(withdrawalLot, shareAmount, withdrawnPrincipalAssets);
        }

        _totals.userPrincipalLiability += totalPrincipalAssets;
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
        cappedAt = _lotAccrualCaps[userLot.id];
        if (cappedAt != 0) {
            return cappedAt;
        }

        uint256 blacklistedAt = _blacklistTimestamps[userLot.owner];
        if (blacklistedAt != 0 && userLot.openedAt <= blacklistedAt) {
            return blacklistedAt;
        }
    }
}
