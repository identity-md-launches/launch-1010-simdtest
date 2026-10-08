// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Immutable, single-pool launch rules. No token transfer hooks or administrator.
contract SIMDTESTHook is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant ANTI_SNIPE_MAX_FEE_BPS = 3000;
    uint256 public constant ANTI_SNIPE_DURATION_BLOCKS = 10;
    uint256 public constant MAX_BUY_BPS = 100;
    uint256 public constant MAX_BUY_DURATION_SECONDS = 3600;
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;
    address public constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address public constant SWEEP_TREASURY = 0x3dD5F73dD1A4E62630fAd3909673F130aD429985;
    uint160 public constant HOOK_FLAGS = (1 << 13) | (1 << 7) | (1 << 6) | (1 << 3);

    IPoolManager public immutable POOL_MANAGER;
    address public immutable token;
    bool public initialized;
    uint256 public openedAt;
    uint256 public openedBlock;

    error OnlyPoolManager();
    error OnlySelf();
    error InvalidDeployment();
    error InvalidPool();
    error AlreadyInitialized();
    error MaxBuyExceeded();
    error UnrepresentableFee();
    error QuoteResult(int128 pairedDelta);
    error UnexpectedQuoteReturn();

    event PoolOpened(uint256 blockNumber, uint256 timestamp);
    event FeeAccrued(uint256 amount);
    event Swept(uint256 amount);

    constructor(IPoolManager poolManager_, address token_) {
        if (address(poolManager_).code.length == 0 || token_.code.length == 0 || token_ == IMD) {
            revert InvalidDeployment();
        }
        POOL_MANAGER = poolManager_;
        token = token_;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(POOL_MANAGER)) revert OnlyPoolManager();
        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
    }

    function beforeInitialize(address, PoolKey calldata key, uint160)
        external
        onlyPoolManager
        returns (bytes4)
    {
        if (initialized) revert AlreadyInitialized();
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        if (
            address(key.hooks) != address(this) || key.fee != 12500 || key.tickSpacing != 60
                || !((c0 == token && c1 == IMD) || (c0 == IMD && c1 == token))
        ) revert InvalidPool();
        initialized = true;
        openedAt = block.timestamp;
        openedBlock = block.number;
        emit PoolOpened(block.number, block.timestamp);
        return IHooks.beforeInitialize.selector;
    }

    function maxBuy() public pure returns (uint256) {
        return TOTAL_SUPPLY * MAX_BUY_BPS / 10_000;
    }

    function limitActive() public view returns (bool) {
        return initialized && block.timestamp - openedAt < MAX_BUY_DURATION_SECONDS;
    }

    function antiSnipeFeeBps() public view returns (uint256) {
        if (!initialized) return 0;
        uint256 elapsed = block.number - openedBlock;
        if (elapsed >= ANTI_SNIPE_DURATION_BLOCKS) return 0;
        return ANTI_SNIPE_MAX_FEE_BPS * (ANTI_SNIPE_DURATION_BLOCKS - elapsed) / ANTI_SNIPE_DURATION_BLOCKS;
    }

    /// @dev Quotes are rolled back, including pool state, events and transient currency deltas.
    /// Core skips callbacks when the hook itself is the swap caller. No funds leave the manager.
    function quoteSwap(PoolKey calldata key, SwapParams calldata params) external {
        if (msg.sender != address(this)) revert OnlySelf();
        BalanceDelta delta = POOL_MANAGER.swap(key, params, "");
        revert QuoteResult(Currency.unwrap(key.currency0) == IMD ? delta.amount0() : delta.amount1());
    }

    function _quote(PoolKey calldata key, SwapParams memory params) private returns (uint256) {
        try this.quoteSwap(key, params) {
            revert UnexpectedQuoteReturn();
        } catch (bytes memory reason) {
            if (reason.length != 36 || bytes4(reason) != QuoteResult.selector) {
                assembly ("memory-safe") {
                    revert(add(reason, 32), mload(reason))
                }
            }
            int256 pairedDelta;
            assembly ("memory-safe") {
                pairedDelta := mload(add(reason, 36))
            }
            return pairedDelta < 0 ? uint256(-pairedDelta) : 0;
        }
    }

    /// @notice Fees always use IMD. LP fee override is always zero.
    /// @dev Both modes charge the rate on gross IMD spent, including the hook fee.
    /// A reverted quote handles partial fills and requests wider than v4's int128 return deltas.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint256 rate = antiSnipeFeeBps();
        bool buying = params.zeroForOne == (Currency.unwrap(key.currency0) == IMD);
        if (!buying || rate == 0 || params.amountSpecified == 0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
        }

        bool exactInput = params.amountSpecified < 0;
        uint256 fee =
            exactInput ? _exactInputFee(key, params, rate) : _quote(key, params) * rate / (10_000 - rate);
        if (!exactInput && uint256(params.amountSpecified) > uint256(type(int256).max) - fee) {
            revert UnrepresentableFee();
        }
        // used is an int128 core delta; with rate <= 3000 both fee formulas fit int128.
        int128 feeDelta = int128(int256(fee));
        if (fee != 0) {
            POOL_MANAGER.mint(address(this), uint256(uint160(IMD)), fee);
            emit FeeAccrued(fee);
        }
        return (
            IHooks.beforeSwap.selector,
            exactInput ? toBeforeSwapDelta(feeDelta, 0) : toBeforeSwapDelta(0, feeDelta),
            0
        );
    }

    function _exactInputFee(PoolKey calldata key, SwapParams memory params, uint256 rate)
        private
        returns (uint256)
    {
        uint256 budget;
        unchecked {
            budget = uint256(-params.amountSpecified);
        }
        // Exact floor without overflowing even for the magnitude of int256.min.
        uint256 budgetFee = budget / 10_000 * rate + budget % 10_000 * rate / 10_000;
        uint256 netBudget = budget - budgetFee;
        params.amountSpecified = -int256(netBudget);
        uint256 used = _quote(key, params);
        return used == netBudget ? budgetFee : used * rate / (10_000 - rate);
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta delta, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, int128)
    {
        int128 delivered = Currency.unwrap(key.currency0) == token ? delta.amount0() : delta.amount1();
        if (limitActive() && delivered > 0 && uint128(delivered) > maxBuy()) revert MaxBuyExceeded();
        return (IHooks.afterSwap.selector, 0);
    }

    function accruedFees() public view returns (uint256) {
        return POOL_MANAGER.balanceOf(address(this), uint256(uint160(IMD)));
    }

    /// @notice Anyone may redeem the hook's IMD claims and sweep donated IMD to the fixed vault.
    function sweep() external nonReentrant {
        if (accruedFees() != 0) POOL_MANAGER.unlock("");
        uint256 balance = IERC20(IMD).balanceOf(address(this));
        if (balance != 0) {
            IERC20(IMD).safeTransfer(SWEEP_TREASURY, balance);
            emit Swept(balance);
        }
    }

    function unlockCallback(bytes calldata) external onlyPoolManager returns (bytes memory) {
        uint256 amount = accruedFees();
        if (amount != 0) {
            POOL_MANAGER.burn(address(this), uint256(uint160(IMD)), amount);
            POOL_MANAGER.take(Currency.wrap(IMD), SWEEP_TREASURY, amount);
            emit Swept(amount);
        }
        return "";
    }
}
