// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {
    IEarnCoreSpec,
    IEarnShareTokenSpec,
    ProductTotalsView,
    LotView,
    WithdrawalLotInputView
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
    uint256 internal constant TEST_KYC_SIGNER_PK = 0xA11CE;
    uint256 internal constant TEST_KYC_DEPOSIT_THRESHOLD = 1_000e6;
    uint8 internal constant TEST_KYC_SCOPE_DEPOSIT = 1;
    bytes32 internal constant TEST_KYC_AUTHORIZATION_TYPEHASH =
        keccak256("KycAuthorization(address user,uint8 scope,uint64 expiresAt,uint256 nonce)");
    bytes32 internal constant TEST_EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal treasury = makeAddr("treasury");
    address internal asset;
    address internal testKycSigner;

    IEarnCoreSpec internal core;
    IEarnShareTokenSpec internal shareToken;
    MockUSDC internal assetToken;

    function setUp() public virtual {
        vm.warp(INDEX_START_TIMESTAMP);
        assetToken = new MockUSDC();
        asset = address(assetToken);

        EarnCore implementation = new EarnCore();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation), abi.encodeCall(EarnCore.initialize, (admin, asset, treasury, block.timestamp, 0))
        );
        EarnShareToken tokenImplementation = new EarnShareToken();
        ERC1967Proxy tokenProxy = new ERC1967Proxy(
            address(tokenImplementation), abi.encodeCall(EarnShareToken.initialize, ("EARN LP", "eLP", address(proxy)))
        );
        core = IEarnCoreSpec(address(proxy));
        vm.prank(admin);
        core.setShareToken(address(tokenProxy));
        testKycSigner = vm.addr(TEST_KYC_SIGNER_PK);
        vm.prank(admin);
        EarnCore(address(core)).setKycSigner(testKycSigner);
        shareToken = IEarnShareTokenSpec(core.shareToken());

        _fundAndApprove(alice, 10_000_000e6);
        _fundAndApprove(bob, 10_000_000e6);
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
    }

    function _fundAndApprove(address account, uint256 amount) internal {
        assetToken.mint(account, amount);

        vm.prank(account);
        assetToken.approve(address(core), type(uint256).max);
    }

    function _deposit(address caller, uint256 assets, address receiver) internal returns (uint256 lotId) {
        if (EarnCore(address(core)).cumulativeDeposited(receiver) + assets <= TEST_KYC_DEPOSIT_THRESHOLD) {
            vm.prank(caller);
            return core.deposit(assets, receiver);
        }

        bytes memory authorization = _kycAuthorizationForCore(receiver);
        vm.prank(caller);
        return EarnCore(address(core)).deposit(assets, receiver, authorization);
    }

    function _kycAuthorizationForCore(address user) internal view returns (bytes memory) {
        uint64 expiresAt = uint64(block.timestamp + 1 hours);
        uint256 nonce = EarnCore(address(core)).kycNonce(user);
        bytes32 structHash =
            keccak256(abi.encode(TEST_KYC_AUTHORIZATION_TYPEHASH, user, TEST_KYC_SCOPE_DEPOSIT, expiresAt, nonce));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(address(core)), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(TEST_KYC_SIGNER_PK, digest);

        return abi.encode(expiresAt, nonce, abi.encodePacked(r, s, v));
    }

    function _domainSeparator(address verifyingContract) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                TEST_EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes("PAiT Earn KYC")),
                keccak256(bytes("1")),
                block.chainid,
                verifyingContract
            )
        );
    }

    function _singleWithdrawal(uint256 lotId, uint256 shareAmount)
        internal
        pure
        returns (WithdrawalLotInputView[] memory withdrawals)
    {
        withdrawals = new WithdrawalLotInputView[](1);
        withdrawals[0] = WithdrawalLotInputView({lotId: lotId, shareAmount: shareAmount});
    }
}
