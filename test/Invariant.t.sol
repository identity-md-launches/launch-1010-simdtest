// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    LaunchFixture,
    SIMDTESTHook,
    IERC20,
    PoolKey,
    SwapParams,
    IPoolManager
} from "./helpers/LaunchFixture.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Test} from "forge-std/Test.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";

contract LaunchHandler is Test {
    SIMDTESTHook public immutable hook;
    PoolSwapTest public immutable router;
    PoolKey internal key;
    bool internal pairIs0;
    uint256 public totalFees;
    uint256 public totalDonations;
    uint256 public totalClaimDonations;
    uint256 public successfulTrades;
    uint256 public rejectedBuys;
    uint256 public immutable openingBlock;
    uint256 public immutable openingTime;

    constructor(SIMDTESTHook hook_, PoolSwapTest router_, PoolKey memory key_) {
        hook = hook_;
        router = router_;
        key = key_;
        pairIs0 = hook_.IMD() < hook_.token();
        openingBlock = hook_.openedBlock();
        openingTime = hook_.openedAt();
        IERC20(hook_.IMD()).approve(address(router_), type(uint256).max);
        IERC20(hook_.token()).approve(address(router_), type(uint256).max);
    }

    function trade(uint96 raw, bool buy, bool exactInput) public {
        uint256 amount = bound(raw, 10, 1000 ether);
        bool zeroForOne = buy == pairIs0;
        uint256 beforeFees = hook.accruedFees();
        uint256 imdBefore = IERC20(hook.IMD()).balanceOf(address(this));
        router.swap(
            key,
            SwapParams(
                zeroForOne,
                exactInput ? -int256(amount) : int256(amount),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        uint256 fee = hook.accruedFees() - beforeFees;
        uint256 elapsed = block.number - openingBlock;
        uint256 rate = elapsed < 10 ? (10 - elapsed) * 300 : 0;
        uint256 expectedFee =
            buy ? (imdBefore - IERC20(hook.IMD()).balanceOf(address(this))) * rate / 10000 : 0;
        assertEq(fee, expectedFee, "fee must use gross IMD spent in either mode");
        // Ghost accounting uses the specification and observed payer cost, not accruedFees().
        totalFees += expectedFee;
        ++successfulTrades;
    }

    function advance(uint8 blocksForward, uint16 secondsForward) public {
        vm.roll(block.number + bound(blocksForward, 0, 2));
        vm.warp(block.timestamp + bound(secondsForward, 0, 1800));
    }

    function donate(uint96 raw) public {
        uint256 amount = bound(raw, 0, 1 ether);
        IERC20(hook.IMD()).transfer(address(hook), amount);
        totalDonations += amount;
    }

    /// @dev Sell into ERC-6909 claims, then donate those claims to the hook. No token deal/mint
    /// cheats occur in the handler; these claims are backed by settled trades.
    function donateClaims(uint96 raw) public {
        uint256 amount = bound(raw, 100, 100 ether);
        bool zeroForOne = !pairIs0;
        BalanceDelta delta = router.swap(
            key,
            SwapParams(
                zeroForOne,
                -int256(amount),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            PoolSwapTest.TestSettings(true, false),
            ""
        );
        uint256 output = uint256(uint128(pairIs0 ? delta.amount0() : delta.amount1()));
        assertGt(output, 0);
        IPoolManager manager = hook.POOL_MANAGER();
        uint256 id = uint160(hook.IMD());
        assertEq(manager.balanceOf(address(this), id), output);
        assertTrue(manager.transfer(address(hook), id, output));
        assertEq(manager.balanceOf(address(this), id), 0);
        totalClaimDonations += output;
    }

    function rejectOversizedBuy(uint96 raw) public {
        if (block.timestamp - openingTime >= 3600) return;
        uint256 output = 10_000_000 ether + bound(raw, 1, 1_000_000 ether);
        SwapParams memory params = SwapParams(
            pairIs0, int256(output), pairIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterSwap.selector,
                abi.encodeWithSelector(SIMDTESTHook.MaxBuyExceeded.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        router.swap(key, params, PoolSwapTest.TestSettings(false, false), "");
        ++rejectedBuys;
    }

    function sweep() public {
        hook.sweep();
    }
}

contract LaunchInvariantTest is LaunchFixture {
    using StateLibrary for IPoolManager;
    LaunchHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new LaunchHandler(hook, router, key);
        token.transfer(address(handler), 50_000_000 ether);
        IERC20(IMD).transfer(address(handler), 50_000_000 ether);
        targetContract(address(handler));
        // Seed every run with both fee modes, both donation forms, and a real rejected buy.
        // Random sequences then explore their interleavings, including empty/repeated sweeps.
        handler.trade(1000 ether, true, true);
        handler.trade(1000 ether, true, false);
        handler.donate(1 ether);
        handler.donateClaims(1 ether);
        handler.rejectOversizedBuy(1);
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = LaunchHandler.trade.selector;
        selectors[1] = LaunchHandler.advance.selector;
        selectors[2] = LaunchHandler.sweep.selector;
        selectors[3] = LaunchHandler.donate.selector;
        selectors[4] = LaunchHandler.donateClaims.selector;
        selectors[5] = LaunchHandler.rejectOversizedBuy.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_feesConservedAndAllDeltasSettled() public view virtual {
        assertEq(
            hook.accruedFees() + IERC20(IMD).balanceOf(hook.SWEEP_TREASURY())
                + IERC20(IMD).balanceOf(address(hook)),
            handler.totalFees() + handler.totalDonations() + handler.totalClaimDonations()
        );
        assertGe(IERC20(IMD).balanceOf(address(manager)), hook.accruedFees());
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(hook)), 0, "hook collected launch tokens");
        assertEq(hook.openedBlock(), startBlock);
        assertEq(hook.openedAt(), startTime);
        assertEq(hook.limitActive(), block.timestamp - startTime < 3600);
        uint256 elapsed = block.number - startBlock;
        assertEq(hook.antiSnipeFeeBps(), elapsed < 10 ? (10 - elapsed) * 300 : 0);
        (,,, uint24 lpFee) = manager.getSlot0(key.toId());
        assertEq(lpFee, 12500);
        assertEq(
            token.balanceOf(address(this)) + token.balanceOf(address(manager))
                + token.balanceOf(address(handler)),
            1e27
        );
        assertEq(
            IERC20(IMD).balanceOf(address(this)) + IERC20(IMD).balanceOf(address(manager))
                + IERC20(IMD).balanceOf(address(handler)) + IERC20(IMD).balanceOf(hook.SWEEP_TREASURY())
                + IERC20(IMD).balanceOf(address(hook)),
            2e27
        );
        assertSettled();
    }
}

contract LaunchInvariantToken1Test is LaunchInvariantTest {
    function tokenBelowPair() internal pure override returns (bool) {
        return false;
    }

    // Foundry does not inherit function-level inline configuration with inherited tests.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_feesConservedAndAllDeltasSettled() public view override {
        super.invariant_feesConservedAndAllDeltasSettled();
    }
}
