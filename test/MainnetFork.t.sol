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
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @notice Run with --fork-url (optional archive block pin). No environment reads; skipped offline.
contract MainnetForkTest is LaunchFixture {
    using StateLibrary for IPoolManager;

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
        assertEq(outputFee, uint256(-int256(pairDelta(d))) * 3000 / 10000);
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

    function testFork_partialFillTaxesConsumedIMDAndSweepsMixedFunds() public {
        uint160 tight = TickMath.getSqrtPriceAtTick(pairIs0 ? int24(-1) : int24(1));
        uint256 treasuryBefore = IERC20(IMD).balanceOf(hook.SWEEP_TREASURY());
        uint256 traderBefore = IERC20(IMD).balanceOf(address(this));
        // Requested output is above the limit; actual delivery below it must succeed.
        BalanceDelta delta = swapAt(true, int256(LIMIT + 1), tight);
        uint256 spent = traderBefore - IERC20(IMD).balanceOf(address(this));
        assertGt(tokenDelta(delta), 0);
        assertLt(uint256(uint128(tokenDelta(delta))), LIMIT);
        assertEq(uint256(-int256(pairDelta(delta))), spent);
        uint256 fees = hook.accruedFees();
        assertEq(fees, spent * 3000 / 10_000);
        assertGt(fees, 0);
        assertEq(IERC20(IMD).balanceOf(address(hook)), 0, "fees must be manager claims");
        (uint160 price,,, uint24 lpFee) = manager.getSlot0(key.toId());
        assertEq(price, tight);
        assertEq(lpFee, 12500);
        IERC20(IMD).transfer(address(hook), 7 ether);
        address keeper = makeAddr("fork sweep keeper");
        uint256 keeperBefore = IERC20(IMD).balanceOf(keeper);
        vm.prank(keeper);
        hook.sweep();
        assertEq(IERC20(IMD).balanceOf(keeper), keeperBefore);
        assertEq(IERC20(IMD).balanceOf(hook.SWEEP_TREASURY()) - treasuryBefore, fees + 7 ether);
        assertEq(IERC20(IMD).balanceOf(address(hook)), 0);
        assertEq(hook.accruedFees(), 0);
        hook.sweep();
        assertEq(IERC20(IMD).balanceOf(hook.SWEEP_TREASURY()) - treasuryBefore, fees + 7 ether);
        assertSettled();
    }

    function testFork_rejectedBuyPreservesRealBalancesAndPool() public {
        swap(true, -1000 ether);
        bytes32 beforeState = forkAccountingState();
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterSwap.selector,
                abi.encodeWithSelector(SIMDTESTHook.MaxBuyExceeded.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swap(true, -30_000_000 ether);
        assertEq(forkAccountingState(), beforeState);
        assertSettled();
        assertEq(tokenDelta(swap(true, int256(LIMIT))), int256(LIMIT));
        assertSettled();
    }

    function forkAccountingState() internal view returns (bytes32) {
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(key.toId());
        (uint256 growth0, uint256 growth1) = manager.getFeeGrowthGlobals(key.toId());
        return keccak256(
            abi.encode(
                price,
                tick,
                protocolFee,
                lpFee,
                growth0,
                growth1,
                hook.accruedFees(),
                IERC20(IMD).balanceOf(address(this)),
                IERC20(IMD).balanceOf(address(manager)),
                token.balanceOf(address(this)),
                token.balanceOf(address(manager))
            )
        );
    }
}

contract MainnetForkCurrency1Test is MainnetForkTest {
    function tokenBelowPair() internal pure override returns (bool) {
        return false;
    }
}
