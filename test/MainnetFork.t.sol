// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    LaunchFixture,
    IERC20,
    IERC20Metadata,
    IPoolManager,
    BalanceDelta,
    SIMDTESTHook,
    IHooks
} from "./helpers/LaunchFixture.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";

/// @notice Run with --fork-url and --fork-block-number. No environment reads; explicitly skipped offline.
contract MainnetForkTest is LaunchFixture {
    function setUp() public override {
        try vm.activeFork() returns (uint256) {}
        catch {
            vm.skip(true);
            return;
        }
        assertEq(block.chainid, 1, "Ethereum mainnet required");
        assertGt(MAINNET_MANAGER.code.length, 0, "PoolManager missing at fork block");
        assertGt(IMD.code.length, 0, "IMD missing at fork block");
        assertEq(IERC20Metadata(IMD).symbol(), "IMD");
        assertEq(IERC20Metadata(IMD).decimals(), 18);
        manager = IPoolManager(MAINNET_MANAGER);
        // Test funding only: the live IMD implementation and transfer behavior remain intact.
        deal(IMD, address(this), 2_000_000_000 ether);
        _launch();
    }

    function testFork_realIMDBothBuyAndSellModesAndSweep() public {
        uint256 beforeTreasury = IERC20(IMD).balanceOf(hook.SWEEP_TREASURY());
        assertGt(tokenDelta(swap(true, -1000 ether)), 0);
        assertEq(hook.accruedFees(), 300 ether);
        BalanceDelta d = swap(true, 1000 ether);
        assertEq(tokenDelta(d), 1000 ether);
        uint256 outputFee = hook.accruedFees() - 300 ether;
        assertEq(outputFee, (uint256(-int256(pairDelta(d))) - outputFee) * 3000 / 10000);
        uint256 fees = hook.accruedFees();
        swap(false, -1000 ether);
        swap(false, 1000 ether);
        assertEq(hook.accruedFees(), fees);
        hook.sweep();
        assertEq(hook.accruedFees(), 0);
        assertEq(IERC20(IMD).balanceOf(hook.SWEEP_TREASURY()) - beforeTreasury, fees);
        assertSettled();
    }

    function testFork_realManagerBuyLimitAndExpiry() public {
        assertEq(tokenDelta(swap(true, int256(LIMIT))), int256(LIMIT));
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterSwap.selector,
                abi.encodeWithSelector(SIMDTESTHook.MaxBuyExceeded.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swap(true, int256(LIMIT + 1));
        vm.roll(startBlock + 10);
        vm.warp(startTime + 3600);
        uint256 fees = hook.accruedFees();
        assertEq(tokenDelta(swap(true, int256(LIMIT + 1))), int256(LIMIT + 1));
        swap(true, -30_000_000 ether);
        swap(false, -30_000_000 ether);
        swap(false, 1000 ether);
        assertEq(hook.accruedFees(), fees);
        assertFalse(hook.limitActive());
        assertSettled();
    }

    function testFork_realManagerLinearDecay() public {
        for (uint256 i; i <= 10; ++i) {
            vm.roll(startBlock + i);
            uint256 old = hook.accruedFees();
            swap(true, -1000 ether);
            assertEq(hook.accruedFees() - old, 1000 ether * (3000 - 300 * i) / 10000);
        }
        assertSettled();
    }
}
