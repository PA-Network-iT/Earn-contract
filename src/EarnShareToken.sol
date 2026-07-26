// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @dev Reverts on any user-to-user transfer attempt.
error TransfersDisabled();
/// @dev Reverts when an operation needs more unlocked balance than the account holds.
error InsufficientUnlockedBalance(address account, uint256 requested, uint256 available);
/// @dev Reverts when an operation needs more locked balance than the account holds.
error InsufficientLockedBalance(address account, uint256 requested, uint256 lockedAmount);
/// @dev Reverts when a caller other than the owning core invokes a controlled operation.
error UnauthorizedCore(address caller);

/// @title EarnShareToken
/// @notice Non-transferable accounting token that represents a user's claim on the EARN product.
/// @dev Deliberately not upgradeable through UUPS: the token has no admin surface beyond the
///      owning core, and its whole behavior is mint / burn / lock / unlock driven by `EarnCore`.
///
///      Lock semantics: shares backing a pending withdrawal request are locked so the same shares
///      cannot be spent twice. Settlement burns locked shares (`burnLocked`), cancellation returns
///      them (`unlock`), and compliance force-closures burn unlocked shares (`burn`).
contract EarnShareToken is Initializable, ERC20Upgradeable, OwnableUpgradeable {
    /// @dev Share balance reserved by a pending withdrawal request.
    mapping(address account => uint256 amount) private _lockedBalances;

    event Locked(address indexed account, uint256 amount);
    event Unlocked(address indexed account, uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @dev Restricts an operation to the owning core contract.
    modifier onlyCore() {
        if (msg.sender != owner()) {
            revert UnauthorizedCore(msg.sender);
        }
        _;
    }

    /// @notice Initializes the token metadata and controller.
    /// @param name_ Token name.
    /// @param symbol_ Token symbol.
    /// @param coreController Core contract that owns token operations.
    function initialize(string memory name_, string memory symbol_, address coreController) external initializer {
        __ERC20_init(name_, symbol_);
        __Ownable_init(coreController);
    }

    /// @notice Returns the token decimals, matched to USDC.
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Returns the locked share balance for an account.
    function lockedBalanceOf(address account) external view returns (uint256) {
        return _lockedBalances[account];
    }

    /// @notice Returns the freely usable share balance for an account.
    function availableBalanceOf(address account) public view returns (uint256) {
        return balanceOf(account) - _lockedBalances[account];
    }

    /// @notice Mints shares to an account.
    /// @param to Receiver of newly minted shares.
    /// @param amount Amount to mint.
    function mint(address to, uint256 amount) external onlyCore {
        _mint(to, amount);
    }

    /// @notice Burns unlocked shares from an account.
    /// @param from Account whose shares are burned.
    /// @param amount Amount to burn.
    function burn(address from, uint256 amount) external onlyCore {
        uint256 available = availableBalanceOf(from);
        if (amount > available) {
            revert InsufficientUnlockedBalance(from, amount, available);
        }

        _burn(from, amount);
    }

    /// @notice Burns locked shares during withdrawal settlement.
    /// @param from Account whose locked shares are burned.
    /// @param amount Amount to burn.
    function burnLocked(address from, uint256 amount) external onlyCore {
        uint256 lockedAmount = _lockedBalances[from];
        if (amount > lockedAmount) {
            revert InsufficientLockedBalance(from, amount, lockedAmount);
        }

        _lockedBalances[from] = lockedAmount - amount;
        _burn(from, amount);
    }

    /// @notice Locks shares on an account while a withdrawal request is pending.
    /// @param account Account to lock.
    /// @param amount Amount to lock.
    function lock(address account, uint256 amount) external onlyCore {
        uint256 available = availableBalanceOf(account);
        if (amount > available) {
            revert InsufficientUnlockedBalance(account, amount, available);
        }

        _lockedBalances[account] += amount;
        emit Locked(account, amount);
    }

    /// @notice Unlocks shares on an account after a withdrawal request is cancelled.
    /// @param account Account to unlock.
    /// @param amount Amount to unlock.
    function unlock(address account, uint256 amount) external onlyCore {
        uint256 lockedAmount = _lockedBalances[account];
        if (amount > lockedAmount) {
            revert InsufficientLockedBalance(account, amount, lockedAmount);
        }

        _lockedBalances[account] = lockedAmount - amount;
        emit Unlocked(account, amount);
    }

    /// @dev Allows mint (`from == 0`) and burn (`to == 0`) but blocks every transfer in between.
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            revert TransfersDisabled();
        }

        super._update(from, to, value);
    }
}
