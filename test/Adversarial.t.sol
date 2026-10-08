// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    LaunchFixture,
    PairMock,
    SIMDTESTHook,
    IERC20,
    IPoolManager,
    IHooks,
    PoolKey,
    BalanceDelta,
    Currency
} from "./helpers/LaunchFixture.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Local fault injection only. Retains PairMock's storage layout and balances.
contract RefusingPair is PairMock {
    address public refusedSender;

    function refuse(address sender) external {
        refusedSender = sender;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (msg.sender == refusedSender) return false;
        return super.transfer(to, amount);
    }
}

abstract contract AdversarialBehavior is LaunchFixture {
    using StateLibrary for IPoolManager;

    function poolState() internal view returns (bytes32) {
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
                manager.getLiquidity(key.toId()),
                manager.protocolFeesAccrued(key.currency0),
                manager.protocolFeesAccrued(key.currency1)
            )
        );
    }

    function fundsState() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                IERC20(IMD).balanceOf(address(this)),
                IERC20(IMD).balanceOf(address(manager)),
                IERC20(IMD).balanceOf(address(hook)),
                IERC20(IMD).balanceOf(hook.SWEEP_TREASURY()),
                token.balanceOf(address(this)),
                token.balanceOf(address(manager)),
                hook.accruedFees()
            )
        );
    }

    function wrapped(bytes4 callback, bytes4 reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            callback,
            abi.encodeWithSelector(reason),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    /// @dev A taxed swap must leave exactly the state of ONE underlying swap with its net input.
    /// Includes protocol fees and LP fee growth, which a quote that persisted would double-charge.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_quoteCannotPersistPoolOrProtocolFees(
        uint96 raw,
        uint8 elapsed,
        bool exactInput,
        bool partialFill
    ) public {
        manager.setProtocolFeeController(address(this));
        manager.setProtocolFee(key, uint24(500 | (500 << 12)));
        vm.roll(startBlock + bound(elapsed, 0, 9));
        uint256 amount = bound(raw, 100, 100_000 ether);
        uint160 priceLimit = partialFill
            ? TickMath.getSqrtPriceAtTick(pairIs0 ? int24(-1) : int24(1))
            : (pairIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
        int256 specified = exactInput ? -int256(amount) : int256(amount);
        uint256 snapshot = vm.snapshotState();

        BalanceDelta taxed = swapAt(true, specified, priceLimit);
        uint256 fee = hook.accruedFees();
        uint256 gross = uint256(-int256(pairDelta(taxed)));
        assertEq(fee, gross * (3000 - 300 * (block.number - startBlock)) / 10_000);
        bytes32 taxedPool = poolState();
        assertSettled();

        assertTrue(vm.revertToStateAndDelete(snapshot));
        vm.roll(startBlock + 10);
        BalanceDelta referenceSwap = swapAt(true, exactInput ? -int256(gross - fee) : specified, priceLimit);
        assertEq(tokenDelta(taxed), tokenDelta(referenceSwap), "quote changed delivered tokens");
        assertEq(uint256(-int256(pairDelta(referenceSwap))), gross - fee, "quote changed pool input");
        assertEq(poolState(), taxedPool, "quote persisted pool state, LP fees or protocol fees");
        assertEq(hook.accruedFees(), 0);
        assertSettled();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_rejectedBuyRollsBackAllValue(uint96 excess, uint8 elapsed) public {
        swap(true, -1000 ether); // Existing claims must survive the rejected swap too.
        vm.roll(startBlock + bound(elapsed, 0, 10));
        vm.warp(startTime + 3599);
        bytes32 poolBefore = poolState();
        bytes32 fundsBefore = fundsState();
        uint256 requested = LIMIT + bound(excess, 1, LIMIT);
        vm.expectRevert(wrapped(IHooks.afterSwap.selector, SIMDTESTHook.MaxBuyExceeded.selector));
        swap(true, int256(requested));
        assertEq(poolState(), poolBefore, "rejected swap changed pool accounting");
        assertEq(fundsState(), fundsBefore, "rejected swap retained fee claims or moved tokens");
        assertSettled();
        assertEq(tokenDelta(swap(true, int256(LIMIT))), int256(LIMIT), "failed swap poisoned next buy");
    }

    function test_quoteErrorRollsBackFeesAndDoesNotPoisonNextSwap() public {
        swap(true, -1000 ether);
        bytes32 poolBefore = poolState();
        bytes32 fundsBefore = fundsState();
        // A price limit equal to the current price is outside v4's accepted swap domain.
        (uint160 currentPrice,,,) = manager.getSlot0(key.toId());
        bytes memory reason =
            abi.encodeWithSignature("PriceLimitAlreadyExceeded(uint160,uint160)", currentPrice, currentPrice);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                reason,
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swapAt(true, -1000 ether, currentPrice);
        assertEq(poolState(), poolBefore);
        assertEq(fundsState(), fundsBefore);
        assertSettled();
        assertGt(tokenDelta(swap(true, 1000 ether)), 0);
    }

    function test_expiredBuyLimitDoesNotPrematurelyDisableBlockFee() public {
        vm.warp(startTime + 3600);
        assertFalse(hook.limitActive());
        assertEq(hook.antiSnipeFeeBps(), 3000);
        BalanceDelta delta = swap(true, int256(LIMIT + 1));
        assertEq(tokenDelta(delta), int256(LIMIT + 1));
        assertEq(hook.accruedFees(), uint256(-int256(pairDelta(delta))) * 3000 / 10_000);
        assertSettled();
    }

    function test_largeSellsAreUnrestrictedDuringBothWindows() public {
        BalanceDelta delta = swap(false, -int256(LIMIT + 1));
        assertEq(tokenDelta(delta), -int256(LIMIT + 1));
        delta = swap(false, int256(LIMIT + 1));
        assertGt(uint256(-int256(tokenDelta(delta))), LIMIT);
        assertEq(pairDelta(delta), int256(LIMIT + 1));
        assertTrue(hook.limitActive());
        assertEq(hook.accruedFees(), 0);
        assertSettled();
    }

    function test_failedClaimPayoutRetainsClaimAndCanBeRetried() public {
        swap(true, -1000 ether);
        IERC20(IMD).transfer(address(hook), 7 ether);
        vm.etch(IMD, address(new RefusingPair()).code);
        RefusingPair(IMD).refuse(address(manager));
        bytes32 fundsBefore = fundsState();
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                IMD,
                IERC20.transfer.selector,
                abi.encode(false),
                abi.encodeWithSelector(CurrencyLibrary.ERC20TransferFailed.selector)
            )
        );
        hook.sweep();
        assertEq(fundsState(), fundsBefore, "failed redemption burned claims");
        assertSettled();

        // Claim collection must continue without requiring an immediate treasury transfer.
        swap(true, -1000 ether);
        assertEq(hook.accruedFees(), 600 ether);
        vm.etch(IMD, address(new PairMock()).code);
        hook.sweep();
        assertEq(IERC20(IMD).balanceOf(hook.SWEEP_TREASURY()), 607 ether);
        assertEq(hook.accruedFees(), 0);
        assertSettled();
    }

    function test_failedDonationPayoutAlsoRollsBackEarlierClaimRedemption() public {
        swap(true, -1000 ether);
        IERC20(IMD).transfer(address(hook), 7 ether);
        vm.etch(IMD, address(new RefusingPair()).code);
        RefusingPair(IMD).refuse(address(hook));
        bytes32 fundsBefore = fundsState();
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, IMD));
        hook.sweep();
        assertEq(fundsState(), fundsBefore, "late failure failed to restore earlier treasury payout");
        assertSettled();
        vm.etch(IMD, address(new PairMock()).code);
        hook.sweep();
        assertEq(IERC20(IMD).balanceOf(hook.SWEEP_TREASURY()), 307 ether);
        assertEq(hook.accruedFees(), 0);
        assertEq(IERC20(IMD).balanceOf(address(hook)), 0);
        assertSettled();
    }

    function test_failedPoolInitializationDoesNotStartClocks() public {
        SIMDTESTHook fresh = _deployHook();
        PoolKey memory pending = key;
        pending.hooks = IHooks(address(fresh));
        // beforeInitialize runs before core rejects an out-of-range opening price.
        vm.expectRevert(abi.encodeWithSelector(TickMath.InvalidSqrtPrice.selector, uint160(0)));
        manager.initialize(pending, 0);
        assertFalse(fresh.initialized());
        assertFalse(fresh.limitActive());
        assertEq(fresh.openedAt(), 0);
        assertEq(fresh.openedBlock(), 0);
        vm.roll(startBlock + 25);
        vm.warp(startTime + 5000);
        manager.initialize(pending, PRICE);
        assertEq(fresh.openedBlock(), startBlock + 25);
        assertEq(fresh.openedAt(), startTime + 5000);
        assertEq(fresh.antiSnipeFeeBps(), 3000);
        assertTrue(fresh.limitActive());
    }
}

contract AdversarialToken0Test is AdversarialBehavior {}

contract AdversarialToken1Test is AdversarialBehavior {
    function tokenBelowPair() internal pure override returns (bool) {
        return false;
    }
}
