// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @title CooldownHook
/// @notice A Uniswap v4 hook that lets each address swap at most once per pool every `cooldownBlocks` blocks.
///
/// The rule, precisely: if an address last swapped in pool P at block B, its next swap in P is accepted at block
/// `B + cooldownBlocks` or later and rejected at any block in `[B, B + cooldownBlocks)`. Direction, size, and the
/// pool's fee tier do not matter — a swap is a swap. Pools are independent: a swap in one pool never consumes the
/// allowance in another, even for the same address and the same hook instance. Liquidity and donations are not
/// touched at all, so LPs can always enter and, more importantly, always exit.
///
/// @dev Whose cooldown is it? The `sender` that `PoolManager` passes to `beforeSwap` is the address that called
/// `PoolManager.swap` — the router (or whichever contract took the unlock), never the end user. That is the only
/// identity the manager attests, so it is the only one this hook uses. The consequence is deliberate and must be
/// understood before deployment: every user of a shared router shares one cooldown, and a user who wants their
/// own cooldown must swap through a contract they alone control. `hookData` is ignored entirely; an address inside
/// it is a claim by the router, not a fact, and this hook does not trust claims. See the README for the full
/// router discussion.
///
/// Every callback is authenticated as coming from the one `PoolManager` fixed at construction. There is no owner,
/// no pause, no parameter setter, no upgrade path: the cooldown is an immutable and the behaviour reviewed is the
/// behaviour deployed.
///
/// The hook does not require a dynamic-fee pool and never overrides the LP fee; it works with static-fee and
/// dynamic-fee pools alike. It therefore declares no initialize callbacks — there is nothing about the pool it
/// needs to validate.
contract CooldownHook is IHooks {
    /// @notice Smallest accepted cooldown. One block means "once per block".
    uint256 public constant MIN_COOLDOWN_BLOCKS = 1;
    /// @notice Largest accepted cooldown.
    uint256 public constant MAX_COOLDOWN_BLOCKS = 1000;

    /// @notice The only address allowed to drive a callback.
    IPoolManager public immutable poolManager;
    /// @notice The window, in blocks, fixed at construction.
    uint256 public immutable cooldownBlocks;

    /// @notice The block in which `swapper` last swapped in `poolId`; zero if it never has.
    /// @dev Keyed by `PoolId` first so state for one pool can never alias state for another. A last-swap block of
    /// zero is read as "never swapped"; block zero itself carries no user transactions on any chain this could be
    /// deployed to, so the sentinel costs nothing.
    mapping(PoolId poolId => mapping(address swapper => uint256 blockNumber)) public lastSwapBlock;

    /// @notice A swap passed the cooldown check and the window was restarted.
    event SwapRecorded(PoolId indexed poolId, address indexed swapper, uint256 blockNumber, uint256 nextAllowedBlock);

    /// @notice A callback was driven by something other than the pool manager.
    error NotPoolManager();
    /// @notice A callback this hook does not declare was called anyway.
    error HookNotImplemented();
    /// @notice The constructor was given the zero address for the pool manager.
    error InvalidPoolManager();
    /// @notice The constructor was given a cooldown outside `[MIN_COOLDOWN_BLOCKS, MAX_COOLDOWN_BLOCKS]`.
    error InvalidCooldown(uint256 cooldownBlocks);
    /// @notice `swapper` tried to swap in `poolId` before its window closed.
    error SwapCooldownActive(PoolId poolId, address swapper, uint256 lastSwapBlock, uint256 nextAllowedBlock);

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @param _poolManager The canonical `PoolManager` this hook serves. Baked in; cannot change.
    /// @param _cooldownBlocks The window N, in blocks, in `[1, 1000]`.
    /// @dev Reverts unless the address this is deployed to carries exactly the `beforeSwap` flag, so a mis-mined
    /// deployment fails at deployment rather than at the first swap.
    constructor(IPoolManager _poolManager, uint256 _cooldownBlocks) {
        if (address(_poolManager) == address(0)) revert InvalidPoolManager();
        if (_cooldownBlocks < MIN_COOLDOWN_BLOCKS || _cooldownBlocks > MAX_COOLDOWN_BLOCKS) {
            revert InvalidCooldown(_cooldownBlocks);
        }
        poolManager = _poolManager;
        cooldownBlocks = _cooldownBlocks;
        Hooks.validateHookPermissions(this, getHookPermissions());
    }

    /// @notice The callbacks this hook implements. `PoolManager` must find exactly these bits in the address.
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice The first block in which `swapper` may swap in `poolId` again. Zero if it never has swapped there.
    function nextAllowedBlock(PoolId poolId, address swapper) public view returns (uint256) {
        uint256 last = lastSwapBlock[poolId][swapper];
        return last == 0 ? 0 : last + cooldownBlocks;
    }

    /// @notice Whether a swap by `swapper` in `poolId` would pass the cooldown check right now.
    function canSwap(PoolId poolId, address swapper) external view returns (bool) {
        return block.number >= nextAllowedBlock(poolId, swapper);
    }

    // ---------------------------------------------------------------------------------------------------------
    // The one callback this hook declares.
    // ---------------------------------------------------------------------------------------------------------

    /// @inheritdoc IHooks
    /// @dev `sender` is whoever called `PoolManager.swap`, as attested by the manager itself. `hookData` is
    /// deliberately unused: nothing in it can be verified, so nothing in it may influence identity.
    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        uint256 last = lastSwapBlock[poolId][sender];
        if (last != 0) {
            uint256 nextAllowed = last + cooldownBlocks;
            if (block.number < nextAllowed) revert SwapCooldownActive(poolId, sender, last, nextAllowed);
        }

        lastSwapBlock[poolId][sender] = block.number;
        emit SwapRecorded(poolId, sender, block.number, block.number + cooldownBlocks);

        // No delta, no fee override. The hook gates the swap; it never reshapes it.
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Everything else on IHooks. The address does not advertise these, so PoolManager never calls them; they
    // exist to satisfy the interface and they refuse every caller, manager included.
    // ---------------------------------------------------------------------------------------------------------

    /// @inheritdoc IHooks
    function beforeInitialize(address, PoolKey calldata, uint160) external pure override returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure override returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        pure
        override
        returns (bytes4, int128)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }
}
