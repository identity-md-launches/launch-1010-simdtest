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

contract LaunchHandler is Test {
    SIMDTESTHook public immutable hook;
    PoolSwapTest public immutable router;
    PoolKey internal key;
    bool internal pairIs0;
    uint256 public totalFees;
    uint256 public successfulTrades;

    constructor(SIMDTESTHook hook_, PoolSwapTest router_, PoolKey memory key_) {
        hook = hook_;
        router = router_;
        key = key_;
        pairIs0 = hook_.IMD() < hook_.token();
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
        uint256 expectedFee = buy
            ? (imdBefore - IERC20(hook.IMD()).balanceOf(address(this))) * hook.antiSnipeFeeBps() / 10000
            : 0;
        assertEq(fee, expectedFee, "fee must use gross IMD spent in either mode");
        totalFees += fee;
        ++successfulTrades;
    }

    function advance(uint8 blocksForward, uint16 secondsForward) public {
        vm.roll(block.number + bound(blocksForward, 0, 2));
        vm.warp(block.timestamp + bound(secondsForward, 0, 120));
    }

    function sweep() public {
        hook.sweep();
    }
}

contract LaunchInvariantTest is LaunchFixture {
    LaunchHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new LaunchHandler(hook, router, key);
        token.transfer(address(handler), 50_000_000 ether);
        IERC20(IMD).transfer(address(handler), 50_000_000 ether);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = LaunchHandler.trade.selector;
        selectors[1] = LaunchHandler.advance.selector;
        selectors[2] = LaunchHandler.sweep.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_feesConservedAndAllDeltasSettled() public view {
        assertEq(hook.accruedFees() + IERC20(IMD).balanceOf(hook.SWEEP_TREASURY()), handler.totalFees());
        assertEq(IERC20(IMD).balanceOf(address(hook)), 0);
        assertGe(IERC20(IMD).balanceOf(address(manager)), hook.accruedFees());
        assertEq(
            token.balanceOf(address(this)) + token.balanceOf(address(manager))
                + token.balanceOf(address(handler)),
            1e27
        );
        assertEq(
            IERC20(IMD).balanceOf(address(this)) + IERC20(IMD).balanceOf(address(manager))
                + IERC20(IMD).balanceOf(address(handler)) + IERC20(IMD).balanceOf(hook.SWEEP_TREASURY()),
            2e27
        );
        assertSettled();
    }
}
