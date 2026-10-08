// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SIMDTEST} from "../../src/SIMDTEST.sol";
import {SIMDTESTHook} from "../../src/SIMDTESTHook.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

contract PairMock is ERC20 {
    constructor() ERC20("Offline IMD", "IMD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

abstract contract LaunchFixture is Test {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal constant MAINNET_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    uint160 internal constant PRICE = 79228162514264337593543950336;
    uint256 internal constant LIMIT = 10_000_000 ether;
    IPoolManager internal manager;
    SIMDTEST internal token;
    SIMDTESTHook internal hook;
    PoolKey internal key;
    PoolSwapTest internal router;
    PoolModifyLiquidityTest internal liquidity;
    bool internal pairIs0;
    uint256 internal startBlock;
    uint256 internal startTime;

    function tokenBelowPair() internal pure virtual returns (bool) {
        return true;
    }

    function setUp() public virtual {
        manager = IPoolManager(address(new PoolManager(address(this))));
        vm.etch(IMD, address(new PairMock()).code);
        PairMock(IMD).mint(address(this), 2_000_000_000 ether);
        _launch();
    }

    function _launch() internal {
        uint256 currentBlock = vm.getBlockNumber();
        vm.roll(currentBlock < 100 ? 100 : currentBlock);
        uint256 currentTime = vm.getBlockTimestamp();
        vm.warp(currentTime < 1000 ? 1000 : currentTime);
        bytes32 tokenHash = keccak256(type(SIMDTEST).creationCode);
        for (uint256 i;; ++i) {
            bytes32 salt = bytes32(i);
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(hex"ff", address(this), salt, tokenHash))))
            );
            if ((predicted < IMD) == tokenBelowPair()) {
                token = new SIMDTEST{salt: salt}();
                break;
            }
        }
        hook = _deployHook();
        pairIs0 = IMD < address(token);
        key = PoolKey(
            Currency.wrap(pairIs0 ? IMD : address(token)),
            Currency.wrap(pairIs0 ? address(token) : IMD),
            12500,
            60,
            IHooks(address(hook))
        );
        assertFalse(hook.limitActive());
        manager.initialize(key, PRICE);
        startBlock = block.number;
        startTime = block.timestamp;
        router = new PoolSwapTest(manager);
        liquidity = new PoolModifyLiquidityTest(manager);
        IERC20(IMD).approve(address(router), type(uint256).max);
        IERC20(IMD).approve(address(liquidity), type(uint256).max);
        token.approve(address(router), type(uint256).max);
        token.approve(address(liquidity), type(uint256).max);
        liquidity.modifyLiquidity(key, ModifyLiquidityParams(-887220, 887220, 900_000_000 ether, 0), "");
    }

    function _mineHook() internal view returns (address predicted, bytes32 salt) {
        bytes memory code =
            abi.encodePacked(type(SIMDTESTHook).creationCode, abi.encode(manager, address(token)));
        bytes32 hash = keccak256(code);
        for (uint256 i;; ++i) {
            salt = bytes32(i);
            predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", address(this), salt, hash)))));
            if ((uint160(predicted) & 0x3fff) == 0x20c8 && predicted.code.length == 0) {
                return (predicted, salt);
            }
        }
    }

    function _deployHook() internal returns (SIMDTESTHook deployed) {
        (address predicted, bytes32 salt) = _mineHook();
        deployed = new SIMDTESTHook{salt: salt}(manager, address(token));
        assertEq(address(deployed), predicted);
    }

    function swap(bool buy, int256 amount) internal returns (BalanceDelta) {
        bool zeroForOne = buy == pairIs0;
        return swapAt(buy, amount, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
    }

    function swapAt(bool buy, int256 amount, uint160 priceLimit) internal returns (BalanceDelta) {
        return router.swap(
            key, SwapParams(buy == pairIs0, amount, priceLimit), PoolSwapTest.TestSettings(false, false), ""
        );
    }

    function pairDelta(BalanceDelta d) internal view returns (int128) {
        return pairIs0 ? d.amount0() : d.amount1();
    }

    function tokenDelta(BalanceDelta d) internal view returns (int128) {
        return pairIs0 ? d.amount1() : d.amount0();
    }

    function assertSettled() internal view {
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertEq(manager.currencyDelta(address(hook), Currency.wrap(IMD)), 0);
        assertEq(manager.currencyDelta(address(hook), Currency.wrap(address(token))), 0);
        assertFalse(manager.isUnlocked());
    }
}
