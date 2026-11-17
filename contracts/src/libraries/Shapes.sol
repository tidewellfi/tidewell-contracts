// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";

/// @title Shapes
/// @notice How the liquidity of a position is spread over its range. The range is split into equal bands, each its
///         own Uniswap position; a band's liquidity is its weight times one common unit, so the shape stays the same
///         whatever the amounts.
///         - Even: one band over the whole range (the classic Uniswap position).
///         - Centered: an odd number of bands, the most liquidity in the middle (7 bands: weights 1 2 3 4 3 2 1).
///         - Edges: the same bands, the most liquidity at both ends (7 bands: weights 4 3 2 1 2 3 4).
///         The shape byte holds the kind in its lowest two bits and the number of bands above them: n = shape >> 2,
///         odd, from 3 to 15; 0 means the default of 7. More bands give a smoother shape and cost more gas.
library Shapes {
    uint8 internal constant EVEN = 0;
    uint8 internal constant CENTERED = 1;
    uint8 internal constant EDGES = 2;
    uint256 internal constant DEFAULT_BANDS = 7;
    uint256 internal constant MIN_BANDS = 3;
    uint256 internal constant MAX_BANDS = 15;

    /// One unit of liquidity used to measure what a band needs; real liquidity is (weight × unit) scaled.
    uint256 internal constant UNIT = 1e18;

    error BadShape();

    /// Number of bands of a shape byte; reverts on anything that is not a valid shape.
    function bands(uint8 shape) internal pure returns (uint256 n) {
        uint8 kind = shape & 3;
        n = shape >> 2;
        if (kind == EVEN) {
            if (n != 0) revert BadShape();
            return 1;
        }
        if (kind != CENTERED && kind != EDGES) revert BadShape();
        if (n == 0) return DEFAULT_BANDS;
        if (n < MIN_BANDS || n > MAX_BANDS || n % 2 == 0) revert BadShape();
    }

    /// Weight of band `i` (0 = lowest prices): a triangle that rises (Centered) or falls (Edges) by one per band
    /// towards the middle.
    function weight(uint8 shape, uint256 i) internal pure returns (uint256) {
        uint256 n = bands(shape);
        if (n == 1) return 1;
        uint256 h = (n - 1) / 2;
        uint256 d = i > h ? i - h : h - i; // distance from the middle band: 0..h
        return (shape & 3) == CENTERED ? h + 1 - d : 1 + d;
    }

    /// Lower and upper tick of band `i` of `n` in [lower, upper]. The width must be a multiple of n × tick spacing.
    function band(int24 lower, int24 upper, uint256 n, uint256 i) internal pure returns (int24 lo, int24 hi) {
        int24 step = (upper - lower) / int24(int256(n));
        lo = lower + step * int24(int256(i));
        hi = lo + step;
    }

    /// Liquidity per band for the most of (a0, a1) that fits the shape at price sqrtP. A small margin is kept back so
    /// Uniswap's rounding up never asks for more than there is. Zero when nothing fits.
    function plan(int24 lower, int24 upper, uint8 shape, uint256 a0, uint256 a1, uint160 sqrtP)
        internal
        pure
        returns (uint128[] memory liq)
    {
        uint256 n = bands(shape);
        liq = new uint128[](n);
        uint256 x;
        uint256 y;
        for (uint256 i; i < n; ++i) {
            (int24 lo, int24 hi) = band(lower, upper, n, i);
            (uint256 bx, uint256 by) = amounts(
                sqrtP, TickMath.getSqrtPriceAtTick(lo), TickMath.getSqrtPriceAtTick(hi), uint128(weight(shape, i) * UNIT)
            );
            x += bx;
            y += by;
        }
        // Keep back a few wei per band for rounding.
        a0 = a0 > n * 2 ? a0 - n * 2 : 0;
        a1 = a1 > n * 2 ? a1 - n * 2 : 0;
        uint256 m = type(uint256).max;
        if (x > 0) m = Math.mulDiv(a0, UNIT, x);
        if (y > 0) m = Math.min(m, Math.mulDiv(a1, UNIT, y));
        if (x == 0 && y == 0) m = 0;
        m -= m / 1e6; // and a millionth, for the rounding inside Uniswap
        if (m == 0) return liq;
        for (uint256 i; i < n; ++i) {
            liq[i] = SafeCast.toUint128(weight(shape, i) * m);
        }
    }

    /// Tokens needed for liquidity `l` in [sa, sb] at price sqrtP, rounded up (never less than Uniswap asks).
    function amounts(uint160 sqrtP, uint160 sa, uint160 sb, uint128 l) internal pure returns (uint256 x, uint256 y) {
        if (sqrtP <= sa) {
            x = SqrtPriceMath.getAmount0Delta(sa, sb, l, true);
        } else if (sqrtP < sb) {
            x = SqrtPriceMath.getAmount0Delta(sqrtP, sb, l, true);
            y = SqrtPriceMath.getAmount1Delta(sa, sqrtP, l, true);
        } else {
            y = SqrtPriceMath.getAmount1Delta(sa, sb, l, true);
        }
    }

    /// True when every band would get liquidity.
    function fits(uint128[] memory liq) internal pure returns (bool) {
        for (uint256 i; i < liq.length; ++i) {
            if (liq[i] == 0) return false;
        }
        return liq.length > 0;
    }
}
