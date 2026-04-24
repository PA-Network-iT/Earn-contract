// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {SubscriptionNFT} from "src/subscription/SubscriptionNFT.sol";
import {
    SoulboundTransferDisabled,
    UnauthorizedManager,
    TokenNotMinted,
    TokenAlreadyMinted,
    InvalidManager,
    ZeroAddress
} from "test/shared/subscription/SubscriptionErrors.sol";

/// @notice Unit tests for the soulbound `SubscriptionNFT` contract.
contract SubscriptionNFTTest is Test {
    address internal admin = makeAddr("admin");
    address internal manager = makeAddr("manager");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    SubscriptionNFT internal nft;

    function setUp() public {
        SubscriptionNFT impl = new SubscriptionNFT();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(SubscriptionNFT.initialize, (admin)));
        nft = SubscriptionNFT(address(proxy));

        vm.prank(admin);
        nft.setManager(manager);
    }

    function test_initializeSetsMetadata() public view {
        assertEq(nft.name(), "PAiT Subscription");
        assertEq(nft.symbol(), "PAIT-SUB");
    }

    function test_adminHasDefaultAdminRole() public view {
        assertTrue(nft.hasRole(nft.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(nft.hasRole(nft.UPGRADER_ROLE(), admin));
    }

    function test_setManagerRejectsZero() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(InvalidManager.selector, address(0)));
        nft.setManager(address(0));
    }

    function test_onlyAdminCanSetManager() public {
        bytes32 adminRole = nft.DEFAULT_ADMIN_ROLE();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, adminRole)
        );
        nft.setManager(alice);
    }

    function test_tokenIdIsDeterministicFromOwner() public view {
        assertEq(nft.tokenIdOf(alice), uint256(uint160(alice)));
        assertEq(nft.tokenIdOf(bob), uint256(uint160(bob)));
    }

    function test_managerCanMint() public {
        vm.prank(manager);
        nft.mint(alice);

        assertEq(nft.ownerOf(nft.tokenIdOf(alice)), alice);
        assertEq(nft.balanceOf(alice), 1);
    }

    function test_mintRejectsNonManager() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(UnauthorizedManager.selector, alice));
        nft.mint(alice);
    }

    function test_mintRejectsZeroOwner() public {
        vm.prank(manager);
        vm.expectRevert(ZeroAddress.selector);
        nft.mint(address(0));
    }

    function test_mintRejectsDoubleMint() public {
        vm.startPrank(manager);
        nft.mint(alice);
        vm.expectRevert(abi.encodeWithSelector(TokenAlreadyMinted.selector, alice));
        nft.mint(alice);
        vm.stopPrank();
    }

    function test_managerCanBurn() public {
        vm.startPrank(manager);
        nft.mint(alice);
        nft.burn(alice);
        vm.stopPrank();

        assertEq(nft.balanceOf(alice), 0);
    }

    function test_burnRejectsNonManager() public {
        vm.prank(manager);
        nft.mint(alice);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(UnauthorizedManager.selector, alice));
        nft.burn(alice);
    }

    function test_burnRevertsIfNotMinted() public {
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(TokenNotMinted.selector, alice));
        nft.burn(alice);
    }

    function test_transferRevertsWithSoulbound() public {
        vm.prank(manager);
        nft.mint(alice);

        uint256 tokenId = nft.tokenIdOf(alice);

        vm.prank(alice);
        vm.expectRevert(SoulboundTransferDisabled.selector);
        nft.transferFrom(alice, bob, tokenId);
    }

    function test_safeTransferRevertsWithSoulbound() public {
        vm.prank(manager);
        nft.mint(alice);

        uint256 tokenId = nft.tokenIdOf(alice);

        vm.prank(alice);
        vm.expectRevert(SoulboundTransferDisabled.selector);
        nft.safeTransferFrom(alice, bob, tokenId);
    }

    function test_approveAlwaysRevertsForSoulbound() public {
        vm.prank(manager);
        nft.mint(alice);

        uint256 tokenId = nft.tokenIdOf(alice);

        vm.prank(alice);
        vm.expectRevert(SoulboundTransferDisabled.selector);
        nft.approve(bob, tokenId);
    }

    function test_setApprovalForAllAlwaysRevertsForSoulbound() public {
        vm.prank(alice);
        vm.expectRevert(SoulboundTransferDisabled.selector);
        nft.setApprovalForAll(bob, true);
    }
}
