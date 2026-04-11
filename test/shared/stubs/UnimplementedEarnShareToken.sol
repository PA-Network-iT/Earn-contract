// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IEarnShareTokenSpec, NotImplemented} from "test/shared/interfaces/EarnSpecInterfaces.sol";

/// @notice EN: Minimal share-token stub that returns defaults or reverts for unimplemented mutating behavior.
/// @custom:fa stub حداقلی share token که برای رفتارهای تغییر‌دهنده پیاده‌نشده revert می‌کند و بقیه موارد را پیش‌فرض برمی‌گرداند.
contract UnimplementedEarnShareToken is IEarnShareTokenSpec {
    function name() external pure returns (string memory) {
        return "";
    }

    function symbol() external pure returns (string memory) {
        return "";
    }

    function decimals() external pure returns (uint8) {
        return 0;
    }

    function totalSupply() external pure returns (uint256) {
        return 0;
    }

    function transfer(address, uint256) external pure returns (bool) {
        revert NotImplemented(this.transfer.selector);
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        revert NotImplemented(this.transferFrom.selector);
    }

    function approve(address, uint256) external pure returns (bool) {
        revert NotImplemented(this.approve.selector);
    }

    function allowance(address, address) external pure returns (uint256) {
        return 0;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function lockedBalanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function availableBalanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function mint(address, uint256) external pure {
        revert NotImplemented(this.mint.selector);
    }

    function burn(address, uint256) external pure {
        revert NotImplemented(this.burn.selector);
    }

    function burnLocked(address, uint256) external pure {
        revert NotImplemented(this.burnLocked.selector);
    }

    function lock(address, uint256) external pure {
        revert NotImplemented(this.lock.selector);
    }

    function unlock(address, uint256) external pure {
        revert NotImplemented(this.unlock.selector);
    }
}
