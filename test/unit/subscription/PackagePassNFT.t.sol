// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {PackagePassNFT} from "src/subscription/PackagePassNFT.sol";
import {
    SoulboundTransferDisabled,
    UnauthorizedManager,
    TokenNotMinted,
    TokenAlreadyMinted,
    InvalidManager,
    NoSeatsAvailable,
    ZeroAddress
} from "test/shared/subscription/SubscriptionErrors.sol";

/// @notice Unit tests for the soulbound `PackagePassNFT` contract.
contract PackagePassNFTTest is Test {
    address internal admin = makeAddr("admin");
    address internal manager = makeAddr("manager");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    PackagePassNFT internal nft;

    function setUp() public {
        PackagePassNFT impl = new PackagePassNFT();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(PackagePassNFT.initialize, (admin)));
        nft = PackagePassNFT(address(proxy));

        vm.prank(admin);
        nft.setManager(manager);
    }

    function test_initializeSetsMetadata() public view {
        assertEq(nft.name(), "PAiT Package Pass");
        assertEq(nft.symbol(), "PAIT-PASS");
    }

    function test_tokenIdIsDeterministic() public view {
        assertEq(nft.tokenIdOf(alice), uint256(uint160(alice)));
    }

    function test_managerCanMintWithTierAndSeats() public {
        vm.prank(manager);
        nft.mint(alice, 2, 10);

        assertEq(nft.ownerOf(nft.tokenIdOf(alice)), alice);
        assertEq(nft.tierOf(alice), 2);
        assertEq(nft.seatsOf(alice), 10);
    }

    function test_mintRejectsNonManager() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(UnauthorizedManager.selector, alice));
        nft.mint(alice, 1, 1);
    }

    function test_mintRejectsZeroOwner() public {
        vm.prank(manager);
        vm.expectRevert(ZeroAddress.selector);
        nft.mint(address(0), 1, 1);
    }

    function test_mintRejectsDoubleMint() public {
        vm.startPrank(manager);
        nft.mint(alice, 1, 1);
        vm.expectRevert(abi.encodeWithSelector(TokenAlreadyMinted.selector, alice));
        nft.mint(alice, 1, 1);
        vm.stopPrank();
    }

    function test_setTierUpdatesInPlace() public {
        vm.startPrank(manager);
        nft.mint(alice, 1, 5);
        nft.setTier(alice, 3, 15);
        vm.stopPrank();

        assertEq(nft.tierOf(alice), 3);
        assertEq(nft.seatsOf(alice), 15);
        // Token not re-minted: owner still holds single token.
        assertEq(nft.balanceOf(alice), 1);
        assertEq(nft.ownerOf(nft.tokenIdOf(alice)), alice);
    }

    function test_setTierRevertsIfNotMinted() public {
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(TokenNotMinted.selector, alice));
        nft.setTier(alice, 2, 10);
    }

    function test_setTierRejectsNonManager() public {
        vm.prank(manager);
        nft.mint(alice, 1, 5);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(UnauthorizedManager.selector, alice));
        nft.setTier(alice, 2, 10);
    }

    function test_burnClearsStorage() public {
        vm.startPrank(manager);
        nft.mint(alice, 2, 10);
        nft.burn(alice);
        vm.stopPrank();

        assertEq(nft.balanceOf(alice), 0);
        assertEq(nft.tierOf(alice), 0);
        assertEq(nft.seatsOf(alice), 0);
    }

    function test_transferRevertsWithSoulbound() public {
        vm.prank(manager);
        nft.mint(alice, 1, 1);
        uint256 tokenId = nft.tokenIdOf(alice);

        vm.prank(alice);
        vm.expectRevert(SoulboundTransferDisabled.selector);
        nft.transferFrom(alice, bob, tokenId);
    }

    function test_approveRevertsForSoulbound() public {
        vm.prank(manager);
        nft.mint(alice, 1, 1);
        uint256 tokenId = nft.tokenIdOf(alice);

        vm.prank(alice);
        vm.expectRevert(SoulboundTransferDisabled.selector);
        nft.approve(bob, tokenId);
    }

    function test_onlyAdminCanSetManager() public {
        bytes32 adminRole = nft.DEFAULT_ADMIN_ROLE();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, adminRole)
        );
        nft.setManager(alice);
    }

    function test_setManagerRejectsZero() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(InvalidManager.selector, address(0)));
        nft.setManager(address(0));
    }

    // ===== decrementSeats =====

    function test_decrementSeatsHappyPath() public {
        vm.startPrank(manager);
        nft.mint(alice, 1, 3);
        uint32 remaining = nft.decrementSeats(alice);
        vm.stopPrank();

        assertEq(remaining, 2);
        assertEq(nft.seatsOf(alice), 2);
    }

    function test_decrementSeatsToZero() public {
        vm.startPrank(manager);
        nft.mint(alice, 1, 1);
        uint32 remaining = nft.decrementSeats(alice);
        vm.stopPrank();

        assertEq(remaining, 0);
        assertEq(nft.seatsOf(alice), 0);
    }

    function test_decrementSeatsRejectsNonManager() public {
        vm.prank(manager);
        nft.mint(alice, 1, 5);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(UnauthorizedManager.selector, alice));
        nft.decrementSeats(alice);
    }

    function test_decrementSeatsRevertsWhenZero() public {
        vm.startPrank(manager);
        nft.mint(alice, 1, 1);
        nft.decrementSeats(alice);
        vm.expectRevert(abi.encodeWithSelector(NoSeatsAvailable.selector, alice));
        nft.decrementSeats(alice);
        vm.stopPrank();
    }

    function test_decrementSeatsRevertsWhenNoPass() public {
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(NoSeatsAvailable.selector, alice));
        nft.decrementSeats(alice);
    }

    function test_decrementSeatsKeepsTierIntact() public {
        vm.startPrank(manager);
        nft.mint(alice, 3, 5);
        nft.decrementSeats(alice);
        vm.stopPrank();

        assertEq(nft.tierOf(alice), 3);
    }
}
