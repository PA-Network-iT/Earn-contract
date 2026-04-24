// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {MockUSDC} from "test/shared/mocks/MockUSDC.sol";
import {SubscriptionNFT} from "src/subscription/SubscriptionNFT.sol";
import {PackagePassNFT} from "src/subscription/PackagePassNFT.sol";
import {SubscriptionManager} from "src/subscription/SubscriptionManager.sol";

/// @notice Minimal stand-in for EarnCore exposing the surface SubscriptionManager integrates with.
/// @dev Records calls so tests can assert that the manager fires setSponsor / setSponsorRate
///      and forwards USDC to the treasury wallet.
contract MockEarnCoreStub {
    address internal _treasuryWallet;

    mapping(address user => address sponsor) public userSponsor;
    mapping(address sponsor => uint256 rateBps) public sponsorRateBps;

    uint256 public setSponsorCalls;
    uint256 public setSponsorRateCalls;

    bool public revertOnSetSponsor;

    constructor(address treasuryWallet_) {
        _treasuryWallet = treasuryWallet_;
    }

    function treasuryWallet() external view returns (address) {
        return _treasuryWallet;
    }

    function setRevertOnSetSponsor(bool flag) external {
        revertOnSetSponsor = flag;
    }

    function setSponsor(address user, address sponsor) external {
        require(!revertOnSetSponsor, "stub: sponsor-reverted");
        userSponsor[user] = sponsor;
        setSponsorCalls += 1;
    }

    function setSponsorRate(address sponsor, uint256 newRateBps) external {
        sponsorRateBps[sponsor] = newRateBps;
        setSponsorRateCalls += 1;
    }
}

/// @notice Shared fixture wiring USDC + mock EarnCore + subscription stack.
abstract contract SubscriptionTestBase is Test {
    uint64 internal constant SUBSCRIPTION_DURATION = 365 days;
    uint256 internal constant SUBSCRIPTION_PRICE = 100e6; // 100 USDC
    uint256 internal constant INITIAL_TIMESTAMP = 1_743_465_600;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal treasury = makeAddr("treasury");

    MockUSDC internal usdc;
    MockEarnCoreStub internal earnCoreStub;
    SubscriptionNFT internal subNft;
    PackagePassNFT internal passNft;
    SubscriptionManager internal manager;

    function setUp() public virtual {
        vm.warp(INITIAL_TIMESTAMP);
        usdc = new MockUSDC();
        earnCoreStub = new MockEarnCoreStub(treasury);

        SubscriptionNFT subImpl = new SubscriptionNFT();
        ERC1967Proxy subProxy = new ERC1967Proxy(
            address(subImpl), abi.encodeCall(SubscriptionNFT.initialize, (admin))
        );
        subNft = SubscriptionNFT(address(subProxy));

        PackagePassNFT passImpl = new PackagePassNFT();
        ERC1967Proxy passProxy = new ERC1967Proxy(
            address(passImpl), abi.encodeCall(PackagePassNFT.initialize, (admin))
        );
        passNft = PackagePassNFT(address(passProxy));

        SubscriptionManager mImpl = new SubscriptionManager();
        ERC1967Proxy mProxy = new ERC1967Proxy(
            address(mImpl),
            abi.encodeCall(
                SubscriptionManager.initialize,
                (
                    admin,
                    address(earnCoreStub),
                    address(subNft),
                    address(passNft),
                    address(usdc),
                    SUBSCRIPTION_PRICE
                )
            )
        );
        manager = SubscriptionManager(address(mProxy));

        vm.startPrank(admin);
        subNft.setManager(address(manager));
        passNft.setManager(address(manager));
        vm.stopPrank();

        _fundAndApprove(alice, 1_000_000e6);
        _fundAndApprove(bob, 1_000_000e6);
        _fundAndApprove(carol, 1_000_000e6);
        _fundAndApprove(admin, 1_000_000e6);
    }

    function _fundAndApprove(address account, uint256 amount) internal {
        usdc.mint(account, amount);
        vm.prank(account);
        usdc.approve(address(manager), type(uint256).max);
    }

    function _grantGenesisSubscription(address user) internal {
        vm.prank(admin);
        manager.adminMintGenesisSubscription(user);
    }

    function _addTier(uint256 price, uint32 seats, uint256 rateBps) internal returns (uint16 tierId) {
        vm.prank(admin);
        tierId = manager.addTier(price, seats, rateBps, "ipfs://tier");
    }

    /// @notice Helper: grants `addr` a genesis subscription (if needed), creates a tier and
    ///         lets `addr` buy it so that `addr` carries `seats` on their `PackagePassNFT` and
    ///         can sponsor that many first-time `buySubscription` calls before the resolver
    ///         falls back to a null sponsor.
    /// @dev Uses a dedicated tier with `price = 1 USDC` and `sponsorRateBps = 500` (5%). Returns
    ///      the created tier id so callers that need to inspect tier data can do so.
    function _bootstrapPartnerPass(address addr, uint32 seats) internal returns (uint16 tierId) {
        if (!manager.hasActiveSubscription(addr)) {
            _grantGenesisSubscription(addr);
        }
        tierId = _addTier(1e6, seats, 500);
        vm.prank(addr);
        // `address(0)` — the bootstrap partner is typically `admin`, who has a genesis sub and
        // therefore no referrer; preserves the no-op path on `buyPackagePass(tier, partner)`.
        manager.buyPackagePass(tierId, address(0));
    }
}
