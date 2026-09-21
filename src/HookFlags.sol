// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Hooks} from "v4-core/src/libraries/Hooks.sol";

/// @title HookFlags
/// @notice The fourteen permission bits Uniswap v4 reads from a hook's address, plus the two questions a deployer
/// asks about them: which bits does this address carry, and does it carry exactly the ones I asked for?
/// @dev Mirrors `Hooks.sol` bit for bit. It exists so deployment tooling and the admission checks can talk about
/// flags without importing the whole `Hooks` library (which drags `IPoolManager` and friends along). Any drift
/// between these constants and `Hooks` would make a mined address disagree with `PoolManager`, so every constant
/// is defined in terms of the `Hooks` one rather than restated.
library HookFlags {
    uint160 internal constant BEFORE_INITIALIZE = Hooks.BEFORE_INITIALIZE_FLAG;
    uint160 internal constant AFTER_INITIALIZE = Hooks.AFTER_INITIALIZE_FLAG;
    uint160 internal constant BEFORE_ADD_LIQUIDITY = Hooks.BEFORE_ADD_LIQUIDITY_FLAG;
    uint160 internal constant AFTER_ADD_LIQUIDITY = Hooks.AFTER_ADD_LIQUIDITY_FLAG;
    uint160 internal constant BEFORE_REMOVE_LIQUIDITY = Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG;
    uint160 internal constant AFTER_REMOVE_LIQUIDITY = Hooks.AFTER_REMOVE_LIQUIDITY_FLAG;
    uint160 internal constant BEFORE_SWAP = Hooks.BEFORE_SWAP_FLAG;
    uint160 internal constant AFTER_SWAP = Hooks.AFTER_SWAP_FLAG;
    uint160 internal constant BEFORE_DONATE = Hooks.BEFORE_DONATE_FLAG;
    uint160 internal constant AFTER_DONATE = Hooks.AFTER_DONATE_FLAG;
    uint160 internal constant BEFORE_SWAP_RETURN_DELTA = Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;
    uint160 internal constant AFTER_SWAP_RETURN_DELTA = Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    uint160 internal constant AFTER_ADD_LIQUIDITY_RETURN_DELTA = Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG;
    uint160 internal constant AFTER_REMOVE_LIQUIDITY_RETURN_DELTA = Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG;

    /// @notice Every permission bit at once. The address bits above this mask carry no meaning to v4.
    uint160 internal constant ALL = Hooks.ALL_HOOK_MASK;

    /// @notice The flags `CooldownHook` needs: `afterInitialize` and `beforeSwap`.
    /// @dev This is the value to mine a `CooldownHook` address for (decimal 4224, hex 0x1080).
    uint160 internal constant COOLDOWN_HOOK = AFTER_INITIALIZE | BEFORE_SWAP;

    /// @notice The permission bits an address carries.
    function flagsOf(address hook) internal pure returns (uint160) {
        return uint160(hook) & ALL;
    }

    /// @notice Whether an address carries exactly `flags` — no more, no fewer.
    /// @dev Exactness matters. `PoolManager` calls every callback the address advertises, so a surplus bit is a
    /// callback the hook never wrote, and the revert takes the swap with it.
    function matches(address hook, uint160 flags) internal pure returns (bool) {
        return flagsOf(hook) == (flags & ALL);
    }
}
