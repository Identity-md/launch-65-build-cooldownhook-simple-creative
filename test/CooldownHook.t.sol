// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolDonateTest} from "v4-core/src/test/PoolDonateTest.sol";

import {CooldownHook} from "../src/CooldownHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Exercises `CooldownHook` against a real `PoolManager`: pools are initialised, seeded with liquidity, and
/// swapped through `PoolSwapTest`, the reference router from v4-core.
///
/// Two routers are deployed because the identity the hook rate-limits is the router — the `sender` `PoolManager`
/// reports is whoever called `swap`. Two routers are therefore two independent swappers, and one router used by two
/// EOAs is one swapper. Both facts are tested below.
contract CooldownHookTest is Test {
    using StateLibrary for IPoolManager;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint256 constant SUPPLY = 1_000_000 ether;
    uint256 constant COOLDOWN = 10;
    uint256 constant START_BLOCK = 1_000;
    int24 constant TICK_SPACING = 60;
    // Full range for tickSpacing 60: the widest multiples inside [MIN_TICK, MAX_TICK].
    int24 constant TICK_LOWER = -887_220;
    int24 constant TICK_UPPER = 887_220;
    int256 constant LIQUIDITY = 1_000 ether;
    int256 constant SWAP_AMOUNT = -1 ether; // exact input

    PoolManager manager;
    CooldownHook hook;

    PoolSwapTest routerA;
    PoolSwapTest routerB;
    PoolModifyLiquidityTest lpRouter;
    PoolDonateTest donateRouter;

    MockERC20 token0;
    MockERC20 token1;
    MockERC20 token2;

    PoolKey keyA; // token0 / token1
    PoolKey keyB; // token0 / token2, same hook

    function setUp() public {
        vm.roll(START_BLOCK);

        manager = new PoolManager(address(this));
        hook = deployHook(COOLDOWN);

        routerA = new PoolSwapTest(manager);
        routerB = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);
        donateRouter = new PoolDonateTest(manager);

        (token0, token1, token2) = deploySortedTokens();
        approveAll(token0);
        approveAll(token1);
        approveAll(token2);

        keyA = poolKey(token0, token1, 3_000);
        keyB = poolKey(token0, token2, 3_000);
        manager.initialize(keyA, SQRT_PRICE_1_1);
        manager.initialize(keyB, SQRT_PRICE_1_1);
        addLiquidity(keyA, LIQUIDITY);
        addLiquidity(keyB, LIQUIDITY);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Construction and permissions
    // ------------------------------------------------------------------------------------------------------------

    function test_constructor_storesParameters() public view {
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.cooldownBlocks(), COOLDOWN);
        assertEq(hook.MIN_COOLDOWN_BLOCKS(), 1);
        assertEq(hook.MAX_COOLDOWN_BLOCKS(), 1000);
    }

    function test_constructor_acceptsBothBounds() public {
        assertEq(deployHook(1).cooldownBlocks(), 1);
        assertEq(deployHook(1000).cooldownBlocks(), 1000);
    }

    /// @dev Same manager, same N, same deployer: the miner must step past the salt already used by setUp's hook
    /// instead of colliding with it, and the result is a second, independent instance.
    function test_constructor_identicalParametersYieldASecondInstance() public {
        CooldownHook twin = deployHook(COOLDOWN);
        assertTrue(address(twin) != address(hook));
        assertTrue(HookFlags.matches(address(twin), HookFlags.COOLDOWN_HOOK));
        assertEq(twin.cooldownBlocks(), COOLDOWN);
    }

    function test_constructor_rejectsZeroCooldown() public {
        vm.expectRevert(abi.encodeWithSelector(CooldownHook.InvalidCooldown.selector, 0));
        new CooldownHook(manager, 0);
    }

    function test_constructor_rejectsCooldownAboveMax() public {
        vm.expectRevert(abi.encodeWithSelector(CooldownHook.InvalidCooldown.selector, 1001));
        new CooldownHook(manager, 1001);
    }

    function testFuzz_constructor_rejectsCooldownOutsideRange(uint256 n) public {
        vm.assume(n == 0 || n > 1000);
        vm.expectRevert(abi.encodeWithSelector(CooldownHook.InvalidCooldown.selector, n));
        new CooldownHook(manager, n);
    }

    function test_constructor_rejectsZeroPoolManager() public {
        vm.expectRevert(CooldownHook.InvalidPoolManager.selector);
        new CooldownHook(IPoolManager(address(0)), COOLDOWN);
    }

    /// @dev A plain `new` lands on a nonce-derived address that (almost surely) does not carry exactly the
    /// beforeSwap bit, and the constructor must refuse it rather than leave a hook the manager would never call.
    function test_constructor_rejectsAddressWithoutTheRightFlags() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.skip(HookFlags.matches(predicted, HookFlags.COOLDOWN_HOOK));
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new CooldownHook(manager, COOLDOWN);
    }

    function test_permissions_declareOnlyBeforeSwap() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeSwap);
        assertFalse(p.beforeInitialize);
        assertFalse(p.afterInitialize);
        assertFalse(p.beforeAddLiquidity);
        assertFalse(p.afterAddLiquidity);
        assertFalse(p.beforeRemoveLiquidity);
        assertFalse(p.afterRemoveLiquidity);
        assertFalse(p.afterSwap);
        assertFalse(p.beforeDonate);
        assertFalse(p.afterDonate);
        assertFalse(p.beforeSwapReturnDelta);
        assertFalse(p.afterSwapReturnDelta);
        assertFalse(p.afterAddLiquidityReturnDelta);
        assertFalse(p.afterRemoveLiquidityReturnDelta);
    }

    function test_permissions_addressCarriesExactlyBeforeSwap() public view {
        assertEq(HookFlags.flagsOf(address(hook)), HookFlags.BEFORE_SWAP);
        assertEq(HookFlags.COOLDOWN_HOOK, uint160(0x80));
        assertTrue(HookFlags.matches(address(hook), HookFlags.COOLDOWN_HOOK));
    }

    // ------------------------------------------------------------------------------------------------------------
    // Cooldown: success paths
    // ------------------------------------------------------------------------------------------------------------

    function test_swap_firstSwapSucceedsAndRecordsBlock() public {
        PoolId id = keyA.toId();
        assertEq(hook.lastSwapBlock(id, address(routerA)), 0);
        assertEq(hook.nextAllowedBlock(id, address(routerA)), 0);
        assertTrue(hook.canSwap(id, address(routerA)));

        vm.expectEmit(address(hook));
        emit CooldownHook.SwapRecorded(id, address(routerA), block.number, block.number + COOLDOWN);
        BalanceDelta delta = swap(routerA, keyA, true);

        // A real trade happened: token0 in, token1 out.
        assertEq(delta.amount0(), int128(SWAP_AMOUNT));
        assertGt(delta.amount1(), 0);
        assertEq(hook.lastSwapBlock(id, address(routerA)), block.number);
        assertEq(hook.nextAllowedBlock(id, address(routerA)), block.number + COOLDOWN);
        assertFalse(hook.canSwap(id, address(routerA)));
    }

    function test_swap_allowedExactlyAtTheBoundaryBlock() public {
        uint256 first = vm.getBlockNumber();
        swap(routerA, keyA, true);

        vm.roll(first + COOLDOWN);
        assertTrue(hook.canSwap(keyA.toId(), address(routerA)));
        swap(routerA, keyA, true);
        assertEq(hook.lastSwapBlock(keyA.toId(), address(routerA)), first + COOLDOWN);
    }

    function test_swap_allowedWellAfterTheBoundary() public {
        swap(routerA, keyA, true);
        vm.roll(block.number + COOLDOWN + 12_345);
        swap(routerA, keyA, false);
    }

    /// @dev The window restarts from the new swap, not from the old one: after swapping at B and B+N, the next
    /// swap is allowed at B+2N, and B+N+1 is still blocked.
    function test_swap_windowRestartsFromTheLatestSwap() public {
        uint256 first = vm.getBlockNumber();
        swap(routerA, keyA, true);
        vm.roll(first + COOLDOWN);
        swap(routerA, keyA, true);

        vm.roll(first + COOLDOWN + 1);
        expectCooldownRevert(keyA, address(routerA), first + COOLDOWN);
        swap(routerA, keyA, true);

        vm.roll(first + 2 * COOLDOWN);
        swap(routerA, keyA, true);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Cooldown: failure paths
    // ------------------------------------------------------------------------------------------------------------

    function test_swap_secondSwapInTheSameBlockReverts() public {
        swap(routerA, keyA, true);
        expectCooldownRevert(keyA, address(routerA), block.number);
        swap(routerA, keyA, true);
    }

    function test_swap_oppositeDirectionIsStillASwap() public {
        swap(routerA, keyA, true);
        expectCooldownRevert(keyA, address(routerA), block.number);
        swap(routerA, keyA, false);
    }

    function test_swap_blockedOneBlockBeforeTheBoundary() public {
        uint256 first = vm.getBlockNumber();
        swap(routerA, keyA, true);

        vm.roll(first + COOLDOWN - 1);
        assertFalse(hook.canSwap(keyA.toId(), address(routerA)));
        expectCooldownRevert(keyA, address(routerA), first);
        swap(routerA, keyA, true);
    }

    /// @dev Every block strictly inside the window rejects; the first block at the boundary accepts. This walks the
    /// whole window for the configured cooldown so the off-by-one on either side has nowhere to hide.
    function test_swap_everyBlockInsideTheWindowReverts() public {
        uint256 first = vm.getBlockNumber();
        swap(routerA, keyA, true);

        for (uint256 b = first; b < first + COOLDOWN; b++) {
            vm.roll(b);
            expectCooldownRevert(keyA, address(routerA), first);
            swap(routerA, keyA, true);
            assertEq(hook.lastSwapBlock(keyA.toId(), address(routerA)), first, "a rejected swap must not record");
        }

        vm.roll(first + COOLDOWN);
        swap(routerA, keyA, true);
    }

    /// @dev A rejected swap leaves the pool exactly as it found it.
    function test_swap_rejectedSwapDoesNotMoveThePool() public {
        swap(routerA, keyA, true);
        (uint160 priceBefore,,,) = pm().getSlot0(keyA.toId());
        uint256 bal0 = token0.balanceOf(address(this));
        uint256 bal1 = token1.balanceOf(address(this));

        expectCooldownRevert(keyA, address(routerA), block.number);
        swap(routerA, keyA, true);

        (uint160 priceAfter,,,) = pm().getSlot0(keyA.toId());
        assertEq(priceAfter, priceBefore);
        assertEq(token0.balanceOf(address(this)), bal0);
        assertEq(token1.balanceOf(address(this)), bal1);
    }

    /// @dev The boundary holds for any legal N, not just the one in setUp. A fresh hook is mined and deployed per
    /// run, and a fresh pool is bound to it.
    /// forge-config: default.fuzz.runs = 64
    function testFuzz_swap_boundaryHoldsForAnyCooldown(uint256 n, uint256 elapsed) public {
        n = bound(n, 1, 1000);
        elapsed = bound(elapsed, 0, 2 * n);

        CooldownHook fresh = deployHook(n);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3_000,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(fresh))
        });
        manager.initialize(key, SQRT_PRICE_1_1);
        addLiquidity(key, LIQUIDITY);

        uint256 first = vm.getBlockNumber();
        swap(routerA, key, true);
        vm.roll(first + elapsed);

        if (elapsed < n) {
            assertFalse(fresh.canSwap(key.toId(), address(routerA)));
            vm.expectRevert(cooldownRevertData(fresh, key, address(routerA), first, n));
            swap(routerA, key, true);
            assertEq(fresh.lastSwapBlock(key.toId(), address(routerA)), first);
        } else {
            assertTrue(fresh.canSwap(key.toId(), address(routerA)));
            swap(routerA, key, true);
            assertEq(fresh.lastSwapBlock(key.toId(), address(routerA)), first + elapsed);
        }
    }

    // ------------------------------------------------------------------------------------------------------------
    // Isolation: pools and senders
    // ------------------------------------------------------------------------------------------------------------

    function test_pools_areIndependent() public {
        // Same hook, same router, same block: pool A and pool B each get their own allowance.
        swap(routerA, keyA, true);
        swap(routerA, keyB, true);

        assertEq(hook.lastSwapBlock(keyA.toId(), address(routerA)), block.number);
        assertEq(hook.lastSwapBlock(keyB.toId(), address(routerA)), block.number);

        // And each is now exhausted on its own account.
        expectCooldownRevert(keyA, address(routerA), block.number);
        swap(routerA, keyA, true);
        expectCooldownRevert(keyB, address(routerA), block.number);
        swap(routerA, keyB, true);
    }

    function test_pools_swapInOneDoesNotStartACooldownInTheOther() public {
        swap(routerA, keyA, true);
        assertEq(hook.lastSwapBlock(keyB.toId(), address(routerA)), 0);
        assertTrue(hook.canSwap(keyB.toId(), address(routerA)));

        // Later, pool B is used for the first time while A is still cooling.
        vm.roll(vm.getBlockNumber() + 1);
        swap(routerA, keyB, true);
        expectCooldownRevert(keyA, address(routerA), block.number - 1);
        swap(routerA, keyA, true);
    }

    /// @dev Two pools over the same token pair — different tick spacing — are different `PoolId`s, and the hook
    /// keeps them apart too.
    function test_pools_samePairDifferentSpacingAreIndependent() public {
        PoolKey memory keyA2 = PoolKey({
            currency0: keyA.currency0,
            currency1: keyA.currency1,
            fee: 500,
            tickSpacing: 10,
            hooks: IHooks(address(hook))
        });
        manager.initialize(keyA2, SQRT_PRICE_1_1);
        addLiquidity(keyA2, LIQUIDITY);

        swap(routerA, keyA, true);
        swap(routerA, keyA2, true);
        expectCooldownRevert(keyA, address(routerA), block.number);
        swap(routerA, keyA, true);
    }

    function test_senders_areIndependent() public {
        // Two routers are two `sender`s as far as PoolManager is concerned.
        swap(routerA, keyA, true);
        swap(routerB, keyA, true);

        expectCooldownRevert(keyA, address(routerA), block.number);
        swap(routerA, keyA, true);
        expectCooldownRevert(keyA, address(routerB), block.number);
        swap(routerB, keyA, true);
    }

    /// @dev The documented router assumption, made concrete: two EOAs behind the same router are one swapper.
    /// The cooldown is keyed on what `PoolManager` attests — the router — not on whoever called the router.
    function test_senders_usersOfASharedRouterShareOneCooldown() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        token0.transfer(alice, 10 ether);
        token0.transfer(bob, 10 ether);
        vm.prank(alice);
        token0.approve(address(routerA), type(uint256).max);
        vm.prank(bob);
        token0.approve(address(routerA), type(uint256).max);

        vm.prank(alice);
        swap(routerA, keyA, true);

        // Bob is rate-limited by Alice's swap, because both are `routerA` to the manager.
        vm.prank(bob);
        expectCooldownRevert(keyA, address(routerA), block.number);
        swap(routerA, keyA, true);

        assertEq(hook.lastSwapBlock(keyA.toId(), alice), 0, "EOAs are never the recorded identity");
        assertEq(hook.lastSwapBlock(keyA.toId(), bob), 0, "EOAs are never the recorded identity");
    }

    /// @dev `hookData` cannot be used to claim a different identity: a router that says "this is really Bob" is still
    /// the router, and a router that says nothing afterwards is still rate-limited.
    function test_hookData_isIgnoredForIdentity() public {
        address claimed = makeAddr("claimed");
        swapWithData(routerA, keyA, true, abi.encode(claimed));

        assertEq(hook.lastSwapBlock(keyA.toId(), claimed), 0);
        assertEq(hook.lastSwapBlock(keyA.toId(), address(routerA)), block.number);

        expectCooldownRevert(keyA, address(routerA), block.number);
        swapWithData(routerA, keyA, true, abi.encode(makeAddr("someone-else")));
        expectCooldownRevert(keyA, address(routerA), block.number);
        swap(routerA, keyA, true);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Liquidity and donations are untouched
    // ------------------------------------------------------------------------------------------------------------

    function test_liquidity_canBeAddedAndRemovedWhileACooldownIsActive() public {
        swap(routerA, keyA, true);
        expectCooldownRevert(keyA, address(routerA), block.number);
        swap(routerA, keyA, true);

        // Same block, same pool: LPs are not swappers.
        addLiquidity(keyA, 5 ether);
        removeLiquidity(keyA, 5 ether);
    }

    /// @dev The exit that matters: every unit of liquidity can leave, cooldown or not, and the LP gets tokens back.
    function test_liquidity_fullExitIsAlwaysPossible() public {
        swap(routerA, keyA, true);

        uint128 liquidity = pm().getLiquidity(keyA.toId());
        assertEq(liquidity, uint128(uint256(LIQUIDITY)));

        uint256 bal0 = token0.balanceOf(address(this));
        uint256 bal1 = token1.balanceOf(address(this));
        removeLiquidity(keyA, LIQUIDITY);

        assertEq(pm().getLiquidity(keyA.toId()), 0);
        assertGt(token0.balanceOf(address(this)), bal0);
        assertGt(token1.balanceOf(address(this)), bal1);
    }

    function test_donate_isUnaffected() public {
        swap(routerA, keyA, true);
        donateRouter.donate(keyA, 1 ether, 1 ether, "");
    }

    // ------------------------------------------------------------------------------------------------------------
    // Pool shapes
    // ------------------------------------------------------------------------------------------------------------

    /// @dev The hook needs no dynamic fee and never overrides the fee, but a dynamic-fee pool must work with it too:
    /// returning a zero override from beforeSwap leaves the pool's own LP fee alone.
    function test_dynamicFeePool_isAcceptedAndRateLimited() public {
        PoolKey memory dyn = poolKey(token1, token2, LPFeeLibrary.DYNAMIC_FEE_FLAG);
        manager.initialize(dyn, SQRT_PRICE_1_1);
        addLiquidity(dyn, LIQUIDITY);

        swap(routerA, dyn, true);
        expectCooldownRevert(dyn, address(routerA), block.number);
        swap(routerA, dyn, true);

        (,,, uint24 lpFee) = pm().getSlot0(dyn.toId());
        assertEq(lpFee, 0, "the hook must not override a dynamic pool's fee");
    }

    function test_initialize_doesNotInvolveTheHook() public {
        // No initialize callbacks are declared, so a pool binding this hook opens without the hook ever running.
        PoolKey memory k = poolKey(token1, token2, 100);
        k.tickSpacing = 1;
        vm.expectCall(address(hook), "", 0);
        manager.initialize(k, SQRT_PRICE_1_1);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Callback authentication
    // ------------------------------------------------------------------------------------------------------------

    function test_beforeSwap_refusesCallersOtherThanThePoolManager() public {
        SwapParams memory params = SwapParams(true, SWAP_AMOUNT, TickMath.MIN_SQRT_PRICE + 1);

        vm.expectRevert(CooldownHook.NotPoolManager.selector);
        hook.beforeSwap(address(routerA), keyA, params, "");

        // Not even the router, and not even with a spoofed sender that has no record yet.
        vm.prank(address(routerA));
        vm.expectRevert(CooldownHook.NotPoolManager.selector);
        hook.beforeSwap(makeAddr("nobody"), keyA, params, "");

        assertEq(hook.lastSwapBlock(keyA.toId(), address(routerA)), 0, "a refused call must not record");
    }

    /// @dev Mirrors the admission check: every callback on IHooks, offered from the test's own address, has to fail.
    function test_allCallbacks_refuseCallersOtherThanThePoolManager() public {
        ModifyLiquidityParams memory lp = ModifyLiquidityParams(-60, 60, 1 ether, bytes32(0));
        SwapParams memory sp = SwapParams(true, SWAP_AMOUNT, TickMath.MIN_SQRT_PRICE + 1);
        BalanceDelta zero = BalanceDelta.wrap(0);

        expectRefusal(abi.encodeCall(IHooks.beforeInitialize, (address(this), keyA, SQRT_PRICE_1_1)));
        expectRefusal(abi.encodeCall(IHooks.afterInitialize, (address(this), keyA, SQRT_PRICE_1_1, 0)));
        expectRefusal(abi.encodeCall(IHooks.beforeAddLiquidity, (address(this), keyA, lp, "")));
        expectRefusal(abi.encodeCall(IHooks.afterAddLiquidity, (address(this), keyA, lp, zero, zero, "")));
        expectRefusal(abi.encodeCall(IHooks.beforeRemoveLiquidity, (address(this), keyA, lp, "")));
        expectRefusal(abi.encodeCall(IHooks.afterRemoveLiquidity, (address(this), keyA, lp, zero, zero, "")));
        expectRefusal(abi.encodeCall(IHooks.beforeSwap, (address(this), keyA, sp, "")));
        expectRefusal(abi.encodeCall(IHooks.afterSwap, (address(this), keyA, sp, zero, "")));
        expectRefusal(abi.encodeCall(IHooks.beforeDonate, (address(this), keyA, 1, 1, "")));
        expectRefusal(abi.encodeCall(IHooks.afterDonate, (address(this), keyA, 1, 1, "")));
    }

    /// @dev The undeclared callbacks refuse the manager as well: there is no path by which they do anything.
    function test_undeclaredCallbacks_refuseEvenThePoolManager() public {
        ModifyLiquidityParams memory lp = ModifyLiquidityParams(-60, 60, 1 ether, bytes32(0));
        SwapParams memory sp = SwapParams(true, SWAP_AMOUNT, TickMath.MIN_SQRT_PRICE + 1);
        BalanceDelta zero = BalanceDelta.wrap(0);
        bytes[9] memory calls = [
            abi.encodeCall(IHooks.beforeInitialize, (address(this), keyA, SQRT_PRICE_1_1)),
            abi.encodeCall(IHooks.afterInitialize, (address(this), keyA, SQRT_PRICE_1_1, 0)),
            abi.encodeCall(IHooks.beforeAddLiquidity, (address(this), keyA, lp, "")),
            abi.encodeCall(IHooks.afterAddLiquidity, (address(this), keyA, lp, zero, zero, "")),
            abi.encodeCall(IHooks.beforeRemoveLiquidity, (address(this), keyA, lp, "")),
            abi.encodeCall(IHooks.afterRemoveLiquidity, (address(this), keyA, lp, zero, zero, "")),
            abi.encodeCall(IHooks.afterSwap, (address(this), keyA, sp, zero, "")),
            abi.encodeCall(IHooks.beforeDonate, (address(this), keyA, 1, 1, "")),
            abi.encodeCall(IHooks.afterDonate, (address(this), keyA, 1, 1, ""))
        ];
        for (uint256 i = 0; i < calls.length; i++) {
            vm.prank(address(manager));
            (bool ok, bytes memory ret) = address(hook).call(calls[i]);
            assertFalse(ok);
            assertEq(bytes4(ret), CooldownHook.HookNotImplemented.selector);
        }
    }

    /// @dev The manager itself is the only caller that gets through, and the hook then does its job.
    function test_beforeSwap_acceptsThePoolManager() public {
        SwapParams memory params = SwapParams(true, SWAP_AMOUNT, TickMath.MIN_SQRT_PRICE + 1);
        address who = makeAddr("direct-unlocker");

        vm.prank(address(manager));
        (bytes4 selector,, uint24 fee) = hook.beforeSwap(who, keyA, params, "");
        assertEq(selector, IHooks.beforeSwap.selector);
        assertEq(fee, 0);
        assertEq(hook.lastSwapBlock(keyA.toId(), who), block.number);

        vm.prank(address(manager));
        vm.expectRevert(
            abi.encodeWithSelector(
                CooldownHook.SwapCooldownActive.selector, keyA.toId(), who, block.number, block.number + COOLDOWN
            )
        );
        hook.beforeSwap(who, keyA, params, "");
    }

    // ------------------------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------------------------

    /// @dev Deploys the hook the way a real deployment does: mine a salt so CREATE2 lands on an address that carries
    /// exactly the beforeSwap bit, then deploy there.
    function deployHook(uint256 cooldown) internal returns (CooldownHook deployed) {
        bytes memory args = abi.encode(manager, cooldown);
        (address predicted, bytes32 salt) =
            HookMiner.find(address(this), HookFlags.COOLDOWN_HOOK, type(CooldownHook).creationCode, args);
        deployed = new CooldownHook{salt: salt}(manager, cooldown);
        assertEq(address(deployed), predicted, "CREATE2 landed somewhere other than the mined address");
    }

    function deploySortedTokens() internal returns (MockERC20 t0, MockERC20 t1, MockERC20 t2) {
        MockERC20[3] memory tokens =
            [new MockERC20("A", "A", SUPPLY), new MockERC20("B", "B", SUPPLY), new MockERC20("C", "C", SUPPLY)];
        // Insertion sort by address; PoolKey requires currency0 < currency1.
        for (uint256 i = 1; i < 3; i++) {
            for (uint256 j = i; j > 0 && address(tokens[j - 1]) > address(tokens[j]); j--) {
                (tokens[j - 1], tokens[j]) = (tokens[j], tokens[j - 1]);
            }
        }
        return (tokens[0], tokens[1], tokens[2]);
    }

    function approveAll(MockERC20 token) internal {
        token.approve(address(routerA), type(uint256).max);
        token.approve(address(routerB), type(uint256).max);
        token.approve(address(lpRouter), type(uint256).max);
        token.approve(address(donateRouter), type(uint256).max);
    }

    function poolKey(MockERC20 a, MockERC20 b, uint24 fee) internal view returns (PoolKey memory) {
        require(address(a) < address(b), "unsorted");
        return PoolKey({
            currency0: Currency.wrap(address(a)),
            currency1: Currency.wrap(address(b)),
            fee: fee,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
    }

    function addLiquidity(PoolKey memory key, int256 liquidity) internal {
        lpRouter.modifyLiquidity(key, ModifyLiquidityParams(TICK_LOWER, TICK_UPPER, liquidity, bytes32(0)), "");
    }

    function removeLiquidity(PoolKey memory key, int256 liquidity) internal {
        lpRouter.modifyLiquidity(key, ModifyLiquidityParams(TICK_LOWER, TICK_UPPER, -liquidity, bytes32(0)), "");
    }

    function swap(PoolSwapTest router, PoolKey memory key, bool zeroForOne) internal returns (BalanceDelta) {
        return swapWithData(router, key, zeroForOne, "");
    }

    function swapWithData(PoolSwapTest router, PoolKey memory key, bool zeroForOne, bytes memory hookData)
        internal
        returns (BalanceDelta)
    {
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: SWAP_AMOUNT,
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        return router.swap(key, params, PoolSwapTest.TestSettings(false, false), hookData);
    }

    /// @dev What the whole call stack reverts with when the hook rejects: PoolManager wraps the hook's revert in an
    /// ERC-7751 `WrappedError`, and the router bubbles it up unchanged.
    function cooldownRevertData(CooldownHook h, PoolKey memory key, address sender, uint256 last, uint256 n)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(h),
            IHooks.beforeSwap.selector,
            abi.encodeWithSelector(CooldownHook.SwapCooldownActive.selector, key.toId(), sender, last, last + n),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function expectCooldownRevert(PoolKey memory key, address sender, uint256 last) internal {
        vm.expectRevert(cooldownRevertData(hook, key, sender, last, COOLDOWN));
    }

    function pm() internal view returns (IPoolManager) {
        return IPoolManager(address(manager));
    }

    function expectRefusal(bytes memory call) internal {
        (bool ok,) = address(hook).call(call);
        assertFalse(ok, "a hook callback accepted a caller that was not the pool manager");
    }
}
