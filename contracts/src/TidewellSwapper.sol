// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {ITidewellFactory} from "./interfaces/ITidewell.sol";

/// @title TidewellSwapper
/// @notice Does the swaps of the vaults. Normally through Uniswap's Universal Router along the route Uniswap's own
///         routing found (several pools and hops, as on the app's swap page); without a route, in one pool of the
///         pair (the one set in the factory, usually the deepest). Only vaults of the factory may call it. A vault
///         first hands over the input; the output and anything not swapped go straight back to that vault in the
///         same transaction, so this contract never keeps tokens. The vault itself checks the price it got, so a bad
///         route can only make the swap revert.
contract TidewellSwapper is IUnlockCallback {
    using SafeERC20 for IERC20;
    using BalanceDeltaLibrary for BalanceDelta;

    ITidewellFactory public immutable factory;
    IPoolManager public immutable poolManager;
    address public immutable permit2;
    /// Uniswap's Universal Router: the only contract a route is ever sent to.
    address public immutable router;

    error NotAllowed();
    error TransferFailed();

    constructor(address factory_, address poolManager_, address permit2_, address router_) {
        factory = ITidewellFactory(factory_);
        poolManager = IPoolManager(poolManager_);
        permit2 = permit2_;
        router = router_;
    }

    /// @notice A v4 vault's swap of `amountIn` (already sent here). With a route: through the Universal Router.
    ///         Without: in the pair's swap pool from the factory (else pool `key` itself), stopping at price `limit`.
    ///         Output and any unused input go back to the calling vault.
    function swap(PoolKey calldata key, bool zeroForOne, uint256 amountIn, uint160 limit, bytes calldata route)
        external
        payable
    {
        if (!factory.isVault(msg.sender)) revert NotAllowed();
        if (route.length > 0) {
            _route(Currency.unwrap(zeroForOne ? key.currency0 : key.currency1), amountIn, route);
        } else {
            PoolKey memory k = key;
            (uint24 f, int24 sp, address h) =
                factory.swapPool(1, Currency.unwrap(k.currency0), Currency.unwrap(k.currency1));
            if (sp != 0) (k.fee, k.tickSpacing, k.hooks) = (f, sp, IHooks(h));
            poolManager.unlock(abi.encode(msg.sender, k, zeroForOne, amountIn, limit));
        }
        _sendAll(key.currency0, msg.sender);
        _sendAll(key.currency1, msg.sender);
    }

    /// @notice A v3 vault's swap of `amountIn` of `tokenIn` (already sent here) through the Universal Router.
    function swapToken(address tokenIn, address tokenOut, uint256 amountIn, bytes calldata route) external {
        if (!factory.isVault(msg.sender)) revert NotAllowed();
        _route(tokenIn, amountIn, route);
        _sendAll(Currency.wrap(tokenIn), msg.sender);
        _sendAll(Currency.wrap(tokenOut), msg.sender);
    }

    /// @notice Gives the Universal Router a standing Permit2 allowance for `token`, as Uniswap's routing expects of a
    ///         swapper. Anyone may call it: this contract holds no tokens between swaps, so there is nothing to take.
    function prepare(address token) public {
        if (IERC20(token).allowance(address(this), permit2) < type(uint160).max) {
            IERC20(token).forceApprove(permit2, type(uint256).max);
        }
        (uint160 amount, uint48 expiration,) = IAllowanceTransfer(permit2).allowance(address(this), token, router);
        if (amount < type(uint128).max || expiration < block.timestamp + 365 days) {
            IAllowanceTransfer(permit2).approve(token, router, type(uint160).max, type(uint48).max);
        }
    }

    function _route(address tokenIn, uint256 amountIn, bytes calldata route) internal {
        if (tokenIn != address(0)) prepare(tokenIn);
        (bool ok, bytes memory ret) = router.call{value: tokenIn == address(0) ? amountIn : 0}(route);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    receive() external payable {}

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotAllowed();
        (address vault, PoolKey memory key, bool zeroForOne, uint256 amountIn, uint160 limit) =
            abi.decode(data, (address, PoolKey, bool, uint256, uint160));
        BalanceDelta delta = poolManager.swap(
            key, SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: limit}), ""
        );
        (Currency payC, Currency getC) = zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        int128 pay = zeroForOne ? delta.amount0() : delta.amount1();
        int128 get = zeroForOne ? delta.amount1() : delta.amount0();
        if (pay < 0) {
            uint256 amount = uint256(uint128(-pay));
            if (Currency.unwrap(payC) == address(0)) {
                poolManager.settle{value: amount}();
            } else {
                poolManager.sync(payC);
                IERC20(Currency.unwrap(payC)).safeTransfer(address(poolManager), amount);
                poolManager.settle();
            }
        }
        if (get > 0) poolManager.take(getC, vault, uint256(uint128(get)));
        return "";
    }

    function _sendAll(Currency c, address to) internal {
        address t = Currency.unwrap(c);
        if (t == address(0)) {
            uint256 b = address(this).balance;
            if (b > 0) {
                (bool ok,) = to.call{value: b}("");
                if (!ok) revert TransferFailed();
            }
        } else {
            uint256 b = IERC20(t).balanceOf(address(this));
            if (b > 0) IERC20(t).safeTransfer(to, b);
        }
    }
}
