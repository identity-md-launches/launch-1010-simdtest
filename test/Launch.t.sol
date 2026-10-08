// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    LaunchFixture,
    SIMDTESTHook,
    BalanceDelta,
    IERC20,
    IPoolManager,
    PoolKey,
    SwapParams,
    IHooks,
    Currency
} from "./helpers/LaunchFixture.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

abstract contract LaunchBehavior is LaunchFixture {
    using StateLibrary for IPoolManager;

    function test_permissionsInitializationAndCodeLimits() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        Hooks.validateHookPermissions(IHooks(address(hook)), p);
        assertEq(uint160(address(hook)) & 0x3fff, hook.HOOK_FLAGS());
        assertEq(hook.openedBlock(), startBlock);
        assertEq(hook.openedAt(), startTime);
        assertEq(hook.maxBuy(), LIMIT);
        assertTrue(hook.limitActive());
        (,,, uint24 lpFee) = manager.getSlot0(key.toId());
        assertEq(lpFee, 12500);
        assertLe(type(SIMDTESTHook).creationCode.length + 64, 49152);
        assertLe(address(hook).code.length, 24576);
    }

    function test_allCallbacksRejectUnauthorizedCalls() public {
        vm.expectRevert(SIMDTESTHook.OnlyPoolManager.selector);
        hook.beforeInitialize(address(this), key, PRICE);
        vm.expectRevert(SIMDTESTHook.OnlyPoolManager.selector);
        hook.beforeSwap(address(this), key, SwapParams(pairIs0, -1 ether, PRICE / 2), "");
        vm.expectRevert(SIMDTESTHook.OnlyPoolManager.selector);
        hook.afterSwap(address(this), key, SwapParams(pairIs0, -1 ether, PRICE / 2), BalanceDelta.wrap(0), "");
        vm.expectRevert(SIMDTESTHook.OnlyPoolManager.selector);
        hook.unlockCallback("");
        vm.expectRevert(SIMDTESTHook.OnlySelf.selector);
        hook.quoteSwap(key, SwapParams(pairIs0, -1 ether, PRICE / 2));
        vm.prank(address(manager));
        vm.expectRevert(SIMDTESTHook.AlreadyInitialized.selector);
        hook.beforeInitialize(address(this), key, PRICE);
    }

    function test_linearDecayEveryBlockAndSweep() public {
        uint256 treasuryBefore = IERC20(IMD).balanceOf(hook.SWEEP_TREASURY());
        uint256 accumulated;
        for (uint256 i; i <= 11; ++i) {
            vm.roll(startBlock + i);
            uint256 bps = i < 10 ? 3000 - 300 * i : 0;
            assertEq(hook.antiSnipeFeeBps(), bps);
            uint256 old = hook.accruedFees();
            BalanceDelta d = swap(true, -1000 ether);
            assertEq(pairDelta(d), -1000 ether);
            assertGt(tokenDelta(d), 0);
            assertEq(hook.accruedFees() - old, 1000 ether * bps / 10000);
            accumulated += 1000 ether * bps / 10000;
            assertSettled();
        }
        assertEq(hook.accruedFees(), accumulated);
        vm.prank(makeAddr("anyone"));
        hook.sweep();
        assertEq(hook.accruedFees(), 0);
        assertEq(IERC20(IMD).balanceOf(hook.SWEEP_TREASURY()) - treasuryBefore, accumulated);
        assertEq(IERC20(IMD).balanceOf(address(hook)), 0);
        hook.sweep();
        assertEq(IERC20(IMD).balanceOf(hook.SWEEP_TREASURY()) - treasuryBefore, accumulated);
        assertSettled();
    }

    function test_exactOutputFeeAndBothSells() public {
        BalanceDelta d = swap(true, 1000 ether);
        uint256 cost = uint256(-int256(pairDelta(d)));
        uint256 fee = hook.accruedFees();
        assertEq(tokenDelta(d), 1000 ether);
        assertEq(fee, cost * 3000 / 10000);
        d = swap(false, -1000 ether);
        assertEq(tokenDelta(d), -1000 ether);
        assertGt(pairDelta(d), 0);
        assertEq(hook.accruedFees(), fee);
        d = swap(false, 1000 ether);
        assertEq(pairDelta(d), 1000 ether);
        assertLt(tokenDelta(d), 0);
        assertEq(hook.accruedFees(), fee);
        assertSettled();
    }

    function test_sameTradeChargesSameFeeInBothModes() public {
        for (uint256 elapsed; elapsed <= 10; ++elapsed) {
            vm.roll(startBlock + elapsed);
            uint256 snapshot = vm.snapshotState();
            BalanceDelta input = swap(true, -1000 ether);
            uint256 inputFee = hook.accruedFees();
            assertSettled();
            assertTrue(vm.revertToState(snapshot));

            BalanceDelta output = swap(true, int256(tokenDelta(input)));
            assertEq(tokenDelta(output), tokenDelta(input), "same token output");
            assertEq(hook.accruedFees(), inputFee, "fee must not depend on request mode");
            assertEq(pairDelta(output), pairDelta(input), "same gross IMD spent");
            assertSettled();
            assertTrue(vm.revertToState(snapshot));
            vm.deleteStateSnapshot(snapshot);
        }
    }

    function test_partialExactOutputUsesGrossIMDAtEveryRate() public {
        for (uint256 elapsed; elapsed <= 10; ++elapsed) {
            vm.roll(startBlock + elapsed);
            uint256 snapshot = vm.snapshotState();
            uint160 tight = TickMath.getSqrtPriceAtTick(pairIs0 ? int24(-1) : int24(1));
            BalanceDelta d = swapAt(true, int256(LIMIT), tight);
            assertGt(tokenDelta(d), 0);
            assertLt(uint256(uint128(tokenDelta(d))), LIMIT);
            uint256 spent = uint256(-int256(pairDelta(d)));
            assertEq(hook.accruedFees(), spent * (3000 - 300 * elapsed) / 10000);
            assertSettled();
            assertTrue(vm.revertToState(snapshot));
            vm.deleteStateSnapshot(snapshot);
        }
    }

    function expectMaxBuy() internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterSwap.selector,
                abi.encodeWithSelector(SIMDTESTHook.MaxBuyExceeded.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    function test_exactlyOnePercentSucceedsAndOneWeiMoreReverts() public {
        assertEq(tokenDelta(swap(true, int256(LIMIT))), int256(LIMIT));
        uint256 previousFees = hook.accruedFees();
        expectMaxBuy();
        swap(true, int256(LIMIT + 1));
        assertEq(hook.accruedFees(), previousFees);
        // Per swap: the same buyer can buy the maximum again.
        assertEq(tokenDelta(swap(true, int256(LIMIT))), int256(LIMIT));
        assertSettled();
    }

    function test_exactInputOverLimitReverts() public {
        expectMaxBuy();
        swap(true, -30_000_000 ether);
        assertEq(hook.accruedFees(), 0);
        assertSettled();
    }

    function test_boundariesIndependentTimers() public {
        vm.roll(startBlock + 10);
        assertEq(hook.antiSnipeFeeBps(), 0);
        vm.warp(startTime + 3599);
        assertTrue(hook.limitActive());
        expectMaxBuy();
        swap(true, int256(LIMIT + 1));
        vm.warp(startTime + 3600);
        assertFalse(hook.limitActive());
        assertEq(tokenDelta(swap(true, int256(LIMIT + 1))), int256(LIMIT + 1));
        swap(true, -30_000_000 ether);
        swap(false, -30_000_000 ether);
        swap(false, 1000 ether);
        assertEq(hook.accruedFees(), 0);
        assertSettled();
    }

    function test_partialFillUsesDeliveredAmountAndConsumedIMD() public {
        uint160 tight = TickMath.getSqrtPriceAtTick(pairIs0 ? int24(-1) : int24(1));
        BalanceDelta d = swapAt(true, -int256(1e30), tight);
        assertLt(uint256(uint128(tokenDelta(d))), LIMIT);
        uint256 fee = hook.accruedFees();
        uint256 used = uint256(-int256(pairDelta(d))) - fee;
        assertGt(fee, 0);
        assertEq(fee, used * 3000 / 7000);
        (uint160 price,,,) = manager.getSlot0(key.toId());
        assertEq(price, tight);
        assertSettled();
    }

    function test_hugeExactInputAndOutputPartialFill() public {
        uint160 tight = TickMath.getSqrtPriceAtTick(pairIs0 ? int24(-1) : int24(1));
        BalanceDelta d = swapAt(true, type(int256).min, tight);
        assertGt(tokenDelta(d), 0);
        assertLt(uint256(uint128(tokenDelta(d))), LIMIT);
        tight = TickMath.getSqrtPriceAtTick(pairIs0 ? int24(-2) : int24(2));
        d = swapAt(true, int256(1) << 200, tight);
        assertGt(tokenDelta(d), 0);
        assertLt(uint256(uint128(tokenDelta(d))), LIMIT);
        assertSettled();
    }

    function testFuzz_hugeRequestsRemainExecutable(uint256 raw, bool buy, bool exactInput) public {
        uint256 magnitude = bound(raw, uint256(1) << 128, uint256(1) << 240);
        uint160 tight = TickMath.getSqrtPriceAtTick((buy == pairIs0) ? int24(-1) : int24(1));
        BalanceDelta d = swapAt(buy, exactInput ? -int256(magnitude) : int256(magnitude), tight);
        if (buy) {
            assertGt(tokenDelta(d), 0);
            assertLt(uint256(uint128(tokenDelta(d))), LIMIT);
            assertGt(hook.accruedFees(), 0);
        } else {
            assertLt(tokenDelta(d), 0);
            assertEq(hook.accruedFees(), 0);
        }
        assertSettled();
    }

    function test_int256MaxOutputRejectsUnrepresentableFee() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(SIMDTESTHook.UnrepresentableFee.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swapAt(true, type(int256).max, TickMath.getSqrtPriceAtTick(pairIs0 ? int24(-1) : int24(1)));
    }

    function test_rawIMDDonationsSweptOnlyToTreasury() public {
        uint256 before = IERC20(IMD).balanceOf(hook.SWEEP_TREASURY());
        IERC20(IMD).transfer(address(hook), 12 ether);
        vm.prank(makeAddr("outsider"));
        hook.sweep();
        assertEq(IERC20(IMD).balanceOf(hook.SWEEP_TREASURY()), before + 12 ether);
    }

    function test_noOwnerOrAdminSelectors() public {
        string[6] memory signatures = [
            "owner()",
            "setFee(uint256)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "pause()",
            "setTreasury(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            (bool ok,) = address(hook).call(abi.encodeWithSignature(signatures[i], address(this)));
            assertFalse(ok);
        }
        bytes memory code = address(hook).code;
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xff && op != 0xf4 && op != 0xf2);
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_swapAccounting(uint96 raw, uint8 elapsed, bool exactInput, bool buy) public {
        uint256 amount = bound(raw, 100, 100_000 ether);
        uint256 blocksElapsed = bound(elapsed, 0, 12);
        vm.roll(startBlock + blocksElapsed);
        uint256 imdBefore = IERC20(IMD).balanceOf(address(this));
        uint256 tokenBefore = token.balanceOf(address(this));
        uint256 managerBefore = IERC20(IMD).balanceOf(address(manager));
        BalanceDelta d = swap(buy, exactInput ? -int256(amount) : int256(amount));
        assertEq(int256(IERC20(IMD).balanceOf(address(this))) - int256(imdBefore), pairDelta(d));
        assertEq(int256(token.balanceOf(address(this))) - int256(tokenBefore), tokenDelta(d));
        assertEq(
            int256(IERC20(IMD).balanceOf(address(manager))) - int256(managerBefore), -int256(pairDelta(d))
        );
        uint256 rate = blocksElapsed < 10 ? 3000 - blocksElapsed * 300 : 0;
        uint256 fee = hook.accruedFees();
        if (!buy || rate == 0) assertEq(fee, 0);
        else assertEq(fee, (imdBefore - IERC20(IMD).balanceOf(address(this))) * rate / 10000);
        assertSettled();
    }
}

contract TokenIsCurrency0Test is LaunchBehavior {}

contract TokenIsCurrency1Test is LaunchBehavior {
    function tokenBelowPair() internal pure override returns (bool) {
        return false;
    }
}
