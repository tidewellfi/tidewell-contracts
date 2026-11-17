// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {Shapes} from "./Shapes.sol";

/// Minimal view of the Uniswap v4 PositionManager.
interface IPositionManagerV4S {
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
    function nextTokenId() external view returns (uint256);
    function getPositionLiquidity(uint256 tokenId) external view returns (uint128);
    function transferFrom(address from, address to, uint256 tokenId) external;
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @title ShapesV4
/// @notice The Uniswap v4 side of a shaped position: all its bands are minted, topped up, collected and burned
///         together, in one call to the PositionManager each time. The bands of a position are NFTs with consecutive
///         ids (they are minted in one go), so a position only stores the first id and the shape.
/// @dev Linked library: runs inside the vault (delegatecall), so balances, approvals and NFTs are the vault's own.
library ShapesV4 {
    using SafeERC20 for IERC20;

    uint8 internal constant INCREASE_LIQUIDITY = 0x00;
    uint8 internal constant DECREASE_LIQUIDITY = 0x01;
    uint8 internal constant MINT_POSITION = 0x02;
    uint8 internal constant BURN_POSITION = 0x03;
    uint8 internal constant TAKE_PAIR = 0x11;
    uint8 internal constant CLOSE_CURRENCY = 0x12;
    uint8 internal constant SWEEP = 0x14;

    /// share = SHARE_ALL takes a band out completely.
    uint256 internal constant SHARE_ALL = 1e18;

    error NothingFits();
    error NotConsecutive();

    /// Mints all bands of a new position in [lower, upper]. Returns the first NFT id and what was used.
    function mint(
        PoolKey memory key,
        int24 lower,
        int24 upper,
        uint8 shape,
        uint256 a0,
        uint256 a1,
        uint160 sqrtP,
        address posm,
        address permit2
    ) external returns (uint256 firstId, uint256 used0, uint256 used1) {
        uint128[] memory liq = Shapes.plan(lower, upper, shape, a0, a1, sqrtP);
        if (!Shapes.fits(liq)) revert NothingFits();
        uint256 n = liq.length;
        bytes memory actions = new bytes(n + 3);
        bytes[] memory params = new bytes[](n + 3);
        for (uint256 i; i < n; ++i) {
            (int24 lo, int24 hi) = Shapes.band(lower, upper, n, i);
            actions[i] = bytes1(MINT_POSITION);
            params[i] = abi.encode(key, lo, hi, uint256(liq[i]), uint128(a0), uint128(a1), address(this), bytes(""));
        }
        _settle(key, actions, params, n);
        firstId = IPositionManagerV4S(posm).nextTokenId();
        (used0, used1) = _run(key, actions, params, a0, a1, posm, permit2);
        // The bands were minted one after the other; make sure nothing else was minted in between.
        for (uint256 i; i < n; ++i) {
            if (IPositionManagerV4S(posm).ownerOf(firstId + i) != address(this)) revert NotConsecutive();
        }
    }

    /// Adds (a0, a1) to all bands in the shape's proportions. ok = false instead of a revert when it cannot be done.
    function increase(
        uint256 firstId,
        PoolKey memory key,
        int24 lower,
        int24 upper,
        uint8 shape,
        uint256 a0,
        uint256 a1,
        uint160 sqrtP,
        address posm,
        address permit2
    ) external returns (bool ok, uint256 used0, uint256 used1) {
        uint128[] memory liq = Shapes.plan(lower, upper, shape, a0, a1, sqrtP);
        if (!Shapes.fits(liq)) return (false, 0, 0);
        uint256 n = liq.length;
        bytes memory actions = new bytes(n + 3);
        bytes[] memory params = new bytes[](n + 3);
        for (uint256 i; i < n; ++i) {
            actions[i] = bytes1(INCREASE_LIQUIDITY);
            params[i] = abi.encode(firstId + i, uint256(liq[i]), uint128(a0), uint128(a1), bytes(""));
        }
        _settle(key, actions, params, n);
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        uint256 b0 = _balance(c0);
        uint256 b1 = _balance(c1);
        _approve(c0, a0, posm, permit2);
        _approve(c1, a1, posm, permit2);
        try IPositionManagerV4S(posm).modifyLiquidities{value: c0 == address(0) ? a0 : 0}(
            abi.encode(actions, params), block.timestamp
        ) {
            ok = true;
            used0 = b0 - _balance(c0);
            used1 = b1 - _balance(c1);
        } catch {}
        _approve(c0, 0, posm, permit2);
        _approve(c1, 0, posm, permit2);
    }

    /// DECREASE_LIQUIDITY (share of each band, 0 = only collect the fees; bands without liquidity are skipped) or
    /// BURN_POSITION (every band, everything), then everything that comes out into the vault. Returns the amounts.
    function modify(uint256 firstId, uint256 n, PoolKey memory key, uint8 action, uint256 share, address posm)
        external
        returns (uint256 a0, uint256 a1)
    {
        bytes memory actions = new bytes(n + 1);
        bytes[] memory params = new bytes[](n + 1);
        uint256 k;
        for (uint256 i; i < n; ++i) {
            uint256 id = firstId + i;
            if (action == BURN_POSITION) {
                actions[k] = bytes1(BURN_POSITION);
                params[k++] = abi.encode(id, uint128(0), uint128(0), bytes(""));
            } else {
                uint256 l = IPositionManagerV4S(posm).getPositionLiquidity(id);
                if (l == 0) continue;
                actions[k] = bytes1(DECREASE_LIQUIDITY);
                params[k++] = abi.encode(id, (l * share) / SHARE_ALL, uint128(0), uint128(0), bytes(""));
            }
        }
        if (k == 0) return (0, 0);
        actions[k] = bytes1(TAKE_PAIR);
        params[k++] = abi.encode(key.currency0, key.currency1, address(this));
        // Shorten to the actions actually used.
        assembly {
            mstore(actions, k)
            mstore(params, k)
        }
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        uint256 b0 = _balance(c0);
        uint256 b1 = _balance(c1);
        IPositionManagerV4S(posm).modifyLiquidities(abi.encode(actions, params), block.timestamp);
        a0 = _balance(c0) - b0;
        a1 = _balance(c1) - b1;
    }

    /// Total liquidity of all bands (0 when the position holds nothing any more).
    function liquidity(uint256 firstId, uint256 n, address posm) external view returns (uint256 total) {
        for (uint256 i; i < n; ++i) {
            total += IPositionManagerV4S(posm).getPositionLiquidity(firstId + i);
        }
    }

    /// Hands every band NFT to `to` (the owner's last-resort exit).
    function transferAll(uint256 firstId, uint256 n, address to, address posm) external {
        for (uint256 i; i < n; ++i) {
            IPositionManagerV4S(posm).transferFrom(address(this), to, firstId + i);
        }
    }

    // ---------------------------------------------------------------- internals

    function _settle(PoolKey memory key, bytes memory actions, bytes[] memory params, uint256 n) private view {
        actions[n] = bytes1(CLOSE_CURRENCY);
        actions[n + 1] = bytes1(CLOSE_CURRENCY);
        actions[n + 2] = bytes1(SWEEP);
        params[n] = abi.encode(key.currency0);
        params[n + 1] = abi.encode(key.currency1);
        params[n + 2] = abi.encode(key.currency0, address(this));
    }

    function _run(
        PoolKey memory key,
        bytes memory actions,
        bytes[] memory params,
        uint256 a0,
        uint256 a1,
        address posm,
        address permit2
    ) private returns (uint256 used0, uint256 used1) {
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        uint256 b0 = _balance(c0);
        uint256 b1 = _balance(c1);
        _approve(c0, a0, posm, permit2);
        _approve(c1, a1, posm, permit2);
        IPositionManagerV4S(posm).modifyLiquidities{value: c0 == address(0) ? a0 : 0}(
            abi.encode(actions, params), block.timestamp
        );
        used0 = b0 - _balance(c0);
        used1 = b1 - _balance(c1);
        _approve(c0, 0, posm, permit2);
        _approve(c1, 0, posm, permit2);
    }

    function _approve(address token, uint256 amount, address posm, address permit2) private {
        if (token == address(0)) return;
        if (IERC20(token).allowance(address(this), permit2) < amount) {
            IERC20(token).forceApprove(permit2, type(uint256).max);
        }
        IAllowanceTransfer(permit2).approve(token, posm, uint160(amount), uint48(block.timestamp));
    }

    function _balance(address token) private view returns (uint256) {
        return token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
    }
}
