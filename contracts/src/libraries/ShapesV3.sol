// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {INonfungiblePositionManager} from "../interfaces/IUniswapV3.sol";
import {Shapes} from "./Shapes.sol";

/// @title ShapesV3
/// @notice The Uniswap v3 side of a shaped position: all its bands are minted, topped up, collected and burned
///         together. Uniswap v3 mints one NFT per call; the bands of a position are minted one after the other in the
///         same transaction, so their ids are consecutive (checked) and a position only stores the first id.
/// @dev Linked library: runs inside the vault (delegatecall), so balances, approvals and NFTs are the vault's own.
///      The v3 position manager takes amounts, not liquidity: each band gets exactly the amounts its share of the
///      shape needs, so its liquidity follows the shape up to Uniswap's rounding.
library ShapesV3 {
    using SafeERC20 for IERC20;

    uint256 internal constant SHARE_ALL = 1e18;

    error NothingFits();
    error NotConsecutive();

    struct Pair {
        address t0;
        address t1;
        uint24 fee;
    }

    /// Mints all bands of a new position in [lower, upper]. Returns the first NFT id and what was used.
    function mint(
        Pair memory p,
        int24 lower,
        int24 upper,
        uint8 shape,
        uint256 a0,
        uint256 a1,
        uint160 sqrtP,
        address npm
    ) external returns (uint256 firstId, uint256 used0, uint256 used1) {
        uint128[] memory liq = Shapes.plan(lower, upper, shape, a0, a1, sqrtP);
        if (!Shapes.fits(liq)) revert NothingFits();
        uint256 n = liq.length;
        IERC20(p.t0).forceApprove(npm, a0);
        IERC20(p.t1).forceApprove(npm, a1);
        for (uint256 i; i < n; ++i) {
            (int24 lo, int24 hi) = Shapes.band(lower, upper, n, i);
            (uint256 x, uint256 y) =
                Shapes.amounts(sqrtP, TickMath.getSqrtPriceAtTick(lo), TickMath.getSqrtPriceAtTick(hi), liq[i]);
            (uint256 tokenId,, uint256 u0, uint256 u1) = INonfungiblePositionManager(npm).mint(
                INonfungiblePositionManager.MintParams({
                    token0: p.t0,
                    token1: p.t1,
                    fee: p.fee,
                    tickLower: lo,
                    tickUpper: hi,
                    amount0Desired: x,
                    amount1Desired: y,
                    amount0Min: 0,
                    amount1Min: 0,
                    recipient: address(this),
                    deadline: block.timestamp
                })
            );
            if (i == 0) firstId = tokenId;
            else if (tokenId != firstId + i) revert NotConsecutive();
            used0 += u0;
            used1 += u1;
        }
        IERC20(p.t0).forceApprove(npm, 0);
        IERC20(p.t1).forceApprove(npm, 0);
    }

    /// Adds (a0, a1) to all bands in the shape's proportions. ok = false when nothing fits; a band that refuses its
    /// part is skipped (its part stays in the vault as unplaced), so this never blocks a reinvest.
    function increase(
        uint256 firstId,
        Pair memory p,
        int24 lower,
        int24 upper,
        uint8 shape,
        uint256 a0,
        uint256 a1,
        uint160 sqrtP,
        uint256 min0,
        uint256 min1,
        address npm
    ) external returns (bool ok, uint256 used0, uint256 used1) {
        uint128[] memory liq = Shapes.plan(lower, upper, shape, a0, a1, sqrtP);
        if (!Shapes.fits(liq)) return (false, 0, 0);
        uint256 n = liq.length;
        IERC20(p.t0).forceApprove(npm, a0);
        IERC20(p.t1).forceApprove(npm, a1);
        for (uint256 i; i < n; ++i) {
            (int24 lo, int24 hi) = Shapes.band(lower, upper, n, i);
            (uint256 x, uint256 y) =
                Shapes.amounts(sqrtP, TickMath.getSqrtPriceAtTick(lo), TickMath.getSqrtPriceAtTick(hi), liq[i]);
            try INonfungiblePositionManager(npm).increaseLiquidity(
                INonfungiblePositionManager.IncreaseLiquidityParams({
                    tokenId: firstId + i,
                    amount0Desired: x,
                    amount1Desired: y,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp
                })
            ) returns (uint128, uint256 u0, uint256 u1) {
                used0 += u0;
                used1 += u1;
                ok = true;
            } catch {}
        }
        IERC20(p.t0).forceApprove(npm, 0);
        IERC20(p.t1).forceApprove(npm, 0);
        // The owner's minimums are for the whole position.
        if (used0 < min0 || used1 < min1) revert NothingFits();
    }

    /// Takes `share` (1e18 = all) of every band out and collects exactly those amounts into the vault.
    function decrease(uint256 firstId, uint256 n, uint256 share, address npm) external returns (uint256 a0, uint256 a1) {
        for (uint256 i; i < n; ++i) {
            uint256 id = firstId + i;
            uint128 l = _liquidity(id, npm);
            uint128 d = share >= SHARE_ALL ? l : uint128((uint256(l) * share) / SHARE_ALL);
            if (d == 0) continue;
            (uint256 x, uint256 y) = INonfungiblePositionManager(npm).decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: id,
                    liquidity: d,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp
                })
            );
            INonfungiblePositionManager(npm).collect(
                INonfungiblePositionManager.CollectParams({
                    tokenId: id,
                    recipient: address(this),
                    amount0Max: uint128(x),
                    amount1Max: uint128(y)
                })
            );
            a0 += x;
            a1 += y;
        }
    }

    /// Collects everything owed to every band (only ever fees: every decrease collects its own amounts).
    function collect(uint256 firstId, uint256 n, address npm) external returns (uint256 c0, uint256 c1) {
        for (uint256 i; i < n; ++i) {
            (uint256 x, uint256 y) = INonfungiblePositionManager(npm).collect(
                INonfungiblePositionManager.CollectParams({
                    tokenId: firstId + i,
                    recipient: address(this),
                    amount0Max: type(uint128).max,
                    amount1Max: type(uint128).max
                })
            );
            c0 += x;
            c1 += y;
        }
    }

    function burn(uint256 firstId, uint256 n, address npm) external {
        for (uint256 i; i < n; ++i) {
            INonfungiblePositionManager(npm).burn(firstId + i);
        }
    }

    function transferAll(uint256 firstId, uint256 n, address to, address npm) external {
        for (uint256 i; i < n; ++i) {
            INonfungiblePositionManager(npm).safeTransferFrom(address(this), to, firstId + i);
        }
    }

    function liquidity(uint256 firstId, uint256 n, address npm) external view returns (uint256 total) {
        for (uint256 i; i < n; ++i) {
            total += _liquidity(firstId + i, npm);
        }
    }

    function _liquidity(uint256 tokenId, address npm) private view returns (uint128 l) {
        (,,,,,,, l,,,,) = INonfungiblePositionManager(npm).positions(tokenId);
    }
}
