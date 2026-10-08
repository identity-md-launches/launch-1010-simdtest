// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    LaunchFixture,
    PairMock,
    IERC20,
    SIMDTESTHook,
    PoolKey,
    Currency,
    IHooks
} from "./helpers/LaunchFixture.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {HookAddressMiner} from "../script/HookAddressMiner.s.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

contract ReenteringPair is PairMock {
    SIMDTESTHook internal target;
    bool internal armed;
    bool public attempted;
    bool public entered;

    function arm(SIMDTESTHook hook) external {
        target = hook;
        armed = true;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool success = super.transfer(to, amount);
        if (armed && to == target.SWEEP_TREASURY()) {
            armed = false;
            attempted = true;
            (entered,) = address(target).call(abi.encodeCall(SIMDTESTHook.sweep, ()));
        }
        return success;
    }
}

contract SecurityTest is LaunchFixture {
    function test_sweepReentrancyCannotRedeemTwice() public {
        swap(true, -1000 ether);
        IERC20(IMD).transfer(address(hook), 7 ether);
        vm.etch(IMD, address(new ReenteringPair()).code);
        ReenteringPair(IMD).arm(hook);
        hook.sweep();
        assertTrue(ReenteringPair(IMD).attempted());
        assertFalse(ReenteringPair(IMD).entered());
        assertEq(hook.accruedFees(), 0);
        assertEq(IERC20(IMD).balanceOf(address(hook)), 0);
        assertEq(IERC20(IMD).balanceOf(hook.SWEEP_TREASURY()), 307 ether);
        assertSettled();
    }

    function test_donationOnlySweepAlsoRejectsReentrancy() public {
        IERC20(IMD).transfer(address(hook), 7 ether);
        vm.etch(IMD, address(new ReenteringPair()).code);
        ReenteringPair(IMD).arm(hook);
        hook.sweep();
        assertTrue(ReenteringPair(IMD).attempted());
        assertFalse(ReenteringPair(IMD).entered());
        assertEq(IERC20(IMD).balanceOf(hook.SWEEP_TREASURY()), 7 ether);
    }

    function test_wrongPoolCannotCaptureInitialization() public {
        SIMDTESTHook fresh = _deployHook();
        PoolKey memory valid = key;
        valid.hooks = IHooks(address(fresh));
        assertFalse(fresh.initialized());
        PoolKey memory bad = key;
        bad.hooks = IHooks(address(fresh));
        bad.fee = 0x800000;
        vm.prank(address(manager));
        vm.expectRevert(SIMDTESTHook.InvalidPool.selector);
        fresh.beforeInitialize(address(this), bad, PRICE);
        bad = key;
        bad.hooks = IHooks(address(fresh));
        bad.tickSpacing = 10;
        vm.prank(address(manager));
        vm.expectRevert(SIMDTESTHook.InvalidPool.selector);
        fresh.beforeInitialize(address(this), bad, PRICE);
        bad = key;
        bad.hooks = IHooks(address(fresh));
        bad.currency0 = Currency.wrap(address(new PairMock()));
        vm.prank(address(manager));
        vm.expectRevert(SIMDTESTHook.InvalidPool.selector);
        fresh.beforeInitialize(address(this), bad, PRICE);
        vm.prank(address(manager));
        fresh.beforeInitialize(address(this), valid, PRICE);
        assertTrue(fresh.initialized());
    }

    function test_poolCannotInitializeBeforeHookCodeExists() public {
        (address predicted, bytes32 salt) = _mineHook();
        PoolKey memory pending = key;
        pending.hooks = IHooks(predicted);
        vm.expectRevert(Hooks.InvalidHookResponse.selector);
        manager.initialize(pending, PRICE);
        SIMDTESTHook fresh = new SIMDTESTHook{salt: salt}(manager, address(token));
        assertEq(address(fresh), predicted);
        manager.initialize(pending, PRICE);
        assertTrue(fresh.initialized());
    }

    function test_feeAccruesWhenManagerStartsWithNoIMDOrETH() public {
        liquidity.modifyLiquidity(key, _removeLiquidity(), "");
        deal(IMD, address(manager), 0);
        int24 lower = pairIs0 ? int24(-600) : int24(60);
        int24 upper = pairIs0 ? int24(-60) : int24(600);
        liquidity.modifyLiquidity(key, ModifyLiquidityParams(lower, upper, 900_000_000 ether, 0), "");
        assertEq(IERC20(IMD).balanceOf(address(manager)), 0);
        assertEq(address(manager).balance, 0);
        swap(true, -1000 ether);
        assertEq(hook.accruedFees(), 300 ether);
        hook.sweep();
        assertEq(IERC20(IMD).balanceOf(hook.SWEEP_TREASURY()), 300 ether);
        assertSettled();
    }

    function test_emptyPoolHasNoPhantomFee() public {
        liquidity.modifyLiquidity(key, _removeLiquidity(), "");
        uint256 imdBefore = IERC20(IMD).balanceOf(address(this));
        swap(true, -1000 ether);
        assertEq(hook.accruedFees(), 0);
        assertEq(IERC20(IMD).balanceOf(address(this)), imdBefore);
        assertSettled();
    }

    function _removeLiquidity() internal pure returns (ModifyLiquidityParams memory) {
        return ModifyLiquidityParams(-887220, 887220, -900_000_000 ether, 0);
    }

    function test_minerPlansDirectHookWithMainnetConstructorArguments() public {
        HookAddressMiner miner = new HookAddressMiner();
        (address at, bytes32 salt, bytes memory code) = miner.run(address(this), address(token), 0, 200000);
        assertEq(uint160(at) & 0x3fff, 0x20c8);
        assertEq(
            at,
            address(
                uint160(uint256(keccak256(abi.encodePacked(hex"ff", address(this), salt, keccak256(code)))))
            )
        );
        assertEq(
            code,
            abi.encodePacked(
                type(SIMDTESTHook).creationCode, abi.encode(IPoolManager(MAINNET_MANAGER), address(token))
            )
        );
    }
}
