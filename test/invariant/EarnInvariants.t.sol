// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {EarnTestBase} from "test/shared/EarnTestBase.sol";

/// @notice EN: Invariant tests for protocol-wide properties that must hold across state transitions.
/// @custom:fa تست‌های invariant برای ویژگی‌های سراسری پروتکل که باید در همه تغییرات state برقرار بمانند.
contract EarnInvariantsTest is EarnTestBase {
    function invariant_currentIndexNeverDropsBelowOneRay() public view {
        assertGe(core.currentIndex(), ONE_RAY);
    }
}
