// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TidewellShapedBase} from "../TidewellShapedBase.sol";
import {Shapes} from "../libraries/Shapes.sol";
import {ShapesV4, IPositionManagerV4S} from "../libraries/ShapesV4.sol";

interface IBundleFactoryView {
    function bundler() external view returns (address);
}

/// The bundler tells for which wallet it is acting in the current call (the sender of the transaction, or for a keeper
/// rebalance the owner of the vault it rebalances). Kept in transient storage: it only exists during that call.
interface IBundlerActing {
    function actingFor() external view returns (address);
}

interface ITidewellSwapperV4 {
    function swap(PoolKey calldata key, bool zeroForOne, uint256 amountIn, uint160 limit, bytes calldata route)
        external
        payable;
}

/// @title TidewellBundleVault
/// @notice One vault per user for LP Bundles: the positions of every bundle the user holds, in Uniswap v4 pools, with
///         liquidity shapes. It is the shaped v4 vault (TidewellShapedVaultV4) with three differences:
///          - deposits and withdrawals of a bundle go through the bundler (TidewellBundler), which swaps the user's ETH
///            or USDG into the pools' tokens and back in the same transaction. The bundler can only act for the wallet
///            that sends the transaction (or, for the keeper's weekly rebalance, move value between this vault's own
///            positions under the bundler's limits); what it takes out goes back to this vault or to the owner.
///          - every position has its own protocol fee (2%, 1.5% in a bundle with a TIDE pool, 1% for its maker); the
///            staking discount comes on top, never below 1%.
///          - the owner can always take everything out himself, without the bundler (remove, close, rescue, claim).
///         Everything else (keeper limits, price checks, gas refunds) is the same as in the shaped v4 vault.
contract TidewellBundleVault is TidewellShapedBase {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint8 internal constant DECREASE_LIQUIDITY = 0x01;
    uint8 internal constant BURN_POSITION = 0x03;
    /// remove(): share of the position taken out, 1e18 = all of it.
    uint256 public constant SHARE_ALL = 1e18;

    uint32 public constant POKE_MIN_AGE = 1 minutes;
    uint32 public constant POKE_MAX_AGE = 30 minutes;
    /// The lowest protocol fee on earned fees, whatever the discounts: 1%.
    uint256 public constant FEE_FLOOR_BPS = 100;

    struct Position {
        uint256 tokenId; // NFT of the first band; the bands are tokenId .. tokenId + bands - 1. Changes on every range move
        PoolKey key;
        int24 tickLower; // the whole range, all bands together
        int24 tickUpper;
        uint32 lastMove;
        uint32 lastCompound; // last reinvest by the keeper
        uint8 shape; // Shapes.EVEN, CENTERED or EDGES
        uint16 feeBps; // protocol fee on this position's earned fees, before the staking discount
        Settings settings;
    }

    struct Poke {
        int24 tick;
        uint32 at;
    }

    struct OpenParams {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0;
        uint256 amount1;
        uint160 sqrtPriceMin; // the owner's price protection: the pool price must lie between these
        uint160 sqrtPriceMax;
        uint8 shape;
        Settings settings;
    }

    mapping(uint256 id => Position) internal _positions;
    mapping(uint256 id => Poke) public pokes;

    event Opened(uint256 indexed id, uint256 tokenId, int24 tickLower, int24 tickUpper, uint256 amount0, uint256 amount1);
    event Added(uint256 indexed id, uint256 amount0, uint256 amount1);
    event Removed(uint256 indexed id, uint128 liquidity, uint256 amount0, uint256 amount1);
    event Poked(uint256 indexed id, int24 tick);
    event ShapeSet(uint256 indexed id, uint8 shape, uint256 bands);

    error HookNotAllowed();
    error PriceOutOfBounds();
    error BadValue();
    error NoPriceCheck();
    error PriceMoved(int24 tick, int24 pokedTick);
    error NotBundler();

    // ---------------------------------------------------------------- views

    function getPosition(uint256 id) external view returns (Position memory) {
        return _positions[id];
    }

    /// @notice Number of bands of a position (1 for Even, 3 to 15 for the other shapes; see Shapes).
    function bandsOf(uint256 id) public view returns (uint256) {
        return Shapes.bands(_positions[id].shape);
    }

    /// @notice Total liquidity of all bands of a position.
    function positionLiquidity(uint256 id) external view returns (uint256) {
        Position storage pos = _get(id);
        return ShapesV4.liquidity(pos.tokenId, Shapes.bands(pos.shape), address(_posm()));
    }

    // ---------------------------------------------------------------- bundler: deposits

    /// The bundler, acting for this vault's owner (see IBundlerActing).
    modifier onlyBundler() {
        address b = IBundleFactoryView(address(factory)).bundler();
        if (msg.sender != b || IBundlerActing(b).actingFor() != owner) revert NotBundler();
        _;
    }

    /// The owner, or the bundler acting for him.
    modifier onlyOwnerOrBundler() {
        if (msg.sender != owner) {
            address b = IBundleFactoryView(address(factory)).bundler();
            if (msg.sender != b || IBundlerActing(b).actingFor() != owner) revert NotBundler();
        }
        _;
    }

    /// @notice Opens a position with tokens the bundler has just put in this vault (native ETH comes as msg.value).
    ///         `feeBps` is the bundle's protocol fee, never above the factory's fee nor below 1%.
    function openFor(OpenParams calldata p, uint16 feeBps)
        external
        payable
        onlyBundler
        whenNotPaused
        nonReentrant
        returns (uint256 id)
    {
        (address c0, address c1, uint160 sqrtP) = _checkOpen(p);
        id = _open(p, sqrtP, _fromBalance(c0, p.amount0), _fromBalance(c1, p.amount1), feeBps);
    }

    function _checkOpen(OpenParams calldata p) internal view returns (address c0, address c1, uint160 sqrtP) {
        PoolKey calldata key = p.key;
        c0 = Currency.unwrap(key.currency0);
        c1 = Currency.unwrap(key.currency1);
        if (c0 >= c1) revert UnknownPool();
        if (address(key.hooks) != address(0) && !factory.allowedHook(address(key.hooks))) revert HookNotAllowed();
        (sqrtP,,,) = _pm().getSlot0(key.toId());
        if (sqrtP == 0) revert UnknownPool();
        if (sqrtP < p.sqrtPriceMin || sqrtP > p.sqrtPriceMax) revert PriceOutOfBounds();
        uint256 n = Shapes.bands(p.shape);
        _checkSettings(p.settings, key.tickSpacing, n);
        _checkRange(p.tickLower, p.tickUpper, key.tickSpacing, p.settings, n);
        if (msg.value != (c0 == address(0) ? p.amount0 : 0)) revert BadValue();
    }

    function _open(OpenParams calldata p, uint160 sqrtP, uint256 in0, uint256 in1, uint16 feeBps)
        internal
        returns (uint256 id)
    {
        PoolKey memory key = p.key;
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        (uint256 tokenId, uint256 used0, uint256 used1) =
            ShapesV4.mint(key, p.tickLower, p.tickUpper, p.shape, in0, in1, sqrtP, address(_posm()), factory.permit2());

        id = ++nextPositionId;
        _positions[id] = Position({
            tokenId: tokenId,
            key: key,
            tickLower: p.tickLower,
            tickUpper: p.tickUpper,
            lastMove: uint32(block.timestamp),
            lastCompound: 0,
            shape: p.shape,
            feeBps: _clampFee(feeBps),
            settings: p.settings
        });
        _addId(id);

        _send(c0, in0 - used0);
        _send(c1, in1 - used1);
        emit Opened(id, tokenId, p.tickLower, p.tickUpper, used0, used1);
        emit ShapeSet(id, p.shape, Shapes.bands(p.shape));
    }

    /// @notice Adds tokens the bundler has just put in this vault to a position (native ETH comes as msg.value).
    ///         What does not fit goes to the owner.
    function addFor(uint256 id, uint256 amount0, uint256 amount1, uint160 sqrtPriceMin, uint160 sqrtPriceMax)
        external
        payable
        onlyBundler
        whenNotPaused
        nonReentrant
    {
        Position storage pos = _get(id);
        address c0 = Currency.unwrap(pos.key.currency0);
        address c1 = Currency.unwrap(pos.key.currency1);
        if (msg.value != (c0 == address(0) ? amount0 : 0)) revert BadValue();
        (uint160 sqrtP,,,) = _pm().getSlot0(pos.key.toId());
        if (sqrtP < sqrtPriceMin || sqrtP > sqrtPriceMax) revert PriceOutOfBounds();
        _collectFees(id, pos, false);
        uint256 in0 = _fromBalance(c0, amount0);
        uint256 in1 = _fromBalance(c1, amount1);
        (bool ok, uint256 used0, uint256 used1) = _increase(pos, in0, in1, sqrtP);
        if (!ok) revert BadRange();
        _send(c0, in0 - used0);
        _send(c1, in1 - used1);
        emit Added(id, used0, used1);
    }

    function setSettings(uint256 id, Settings calldata s) external onlyOwner {
        Position storage pos = _get(id);
        _checkSettings(s, pos.key.tickSpacing, Shapes.bands(pos.shape));
        pos.settings = s;
        emit SettingsChanged(id, s);
    }

    // ---------------------------------------------------------------- owner: withdrawals (never paused)

    /// @notice Takes `share` of a position out of every band (1e18 = all) and sends it to the owner; 0 only collects
    ///         the fees. Earned fees stay ready to claim. The minimums are for the whole position.
    function remove(uint256 id, uint128 share, uint128 amount0Min, uint128 amount1Min) external onlyOwner nonReentrant {
        Position storage pos = _get(id);
        if (share > SHARE_ALL) revert BadValue();
        _collectFees(id, pos, false);
        (uint256 a0, uint256 a1) = _modify(pos, DECREASE_LIQUIDITY, share);
        if (a0 < amount0Min || a1 < amount1Min) revert PriceOutOfBounds();
        _send(Currency.unwrap(pos.key.currency0), a0);
        _send(Currency.unwrap(pos.key.currency1), a1);
        emit Removed(id, share, a0, a1);
    }

    /// @notice Closes a position and sends everything in both tokens to the owner, including unclaimed fees.
    function close(uint256 id, uint128 amount0Min, uint128 amount1Min) external onlyOwner nonReentrant {
        Position storage pos = _get(id);
        address c0 = Currency.unwrap(pos.key.currency0);
        address c1 = Currency.unwrap(pos.key.currency1);
        _collectFees(id, pos, false);
        (uint256 a0, uint256 a1) = _modify(pos, BURN_POSITION, 0);
        if (a0 < amount0Min || a1 < amount1Min) revert PriceOutOfBounds();
        _delete(id);
        // Everything of the pair, except what waits to go back into other positions of this vault.
        _send(c0, _balance(c0) - _reserved(c0));
        _send(c1, _balance(c1) - _reserved(c1));
        emit Closed(id);
    }

    /// @notice Last-resort exit: hands the Uniswap NFT itself to the owner. Fees are settled first if that works.
    function rescue(uint256 id) external onlyOwner nonReentrant {
        Position storage pos = _get(id);
        uint256 tokenId = pos.tokenId;
        uint256 n = Shapes.bands(pos.shape);
        try this.settleFees(id) {} catch {}
        _delete(id);
        ShapesV4.transferAll(tokenId, n, owner, address(_posm()));
        emit Closed(id);
    }

    /// @dev Only callable by this vault itself, so rescue() can try it without being blocked by a failure.
    function settleFees(uint256 id) external {
        if (msg.sender != address(this)) revert NotAllowed();
        _collectFees(id, _positions[id], false);
    }

    // ---------------------------------------------------------------- bundler: withdrawals and moves (never paused)

    /// @notice Takes `share` of a position out (1e18 = all of it: the position is closed) and hands it to the bundler,
    ///         which swaps it for the owner or, in a rebalance, puts it into another position of this vault. Fees are
    ///         collected first and stay here, ready to claim.
    function takeOut(uint256 id, uint256 share) external onlyBundler nonReentrant returns (uint256 a0, uint256 a1) {
        Position storage pos = _get(id);
        if (share == 0 || share > SHARE_ALL) revert BadValue();
        address c0 = Currency.unwrap(pos.key.currency0);
        address c1 = Currency.unwrap(pos.key.currency1);
        _collectFees(id, pos, false);
        if (share == SHARE_ALL) {
            (a0, a1) = _modify(pos, BURN_POSITION, 0);
            // What waited to go back into this position comes along.
            (uint256 u0, uint256 u1) = _takeUnplaced(id);
            (a0, a1) = (a0 + u0, a1 + u1);
            _delete(id);
            emit Closed(id);
        } else {
            (a0, a1) = _modify(pos, DECREASE_LIQUIDITY, share);
            emit Removed(id, uint128(share), a0, a1);
        }
        _sendTo(c0, msg.sender, a0);
        _sendTo(c1, msg.sender, a1);
    }

    /// @notice Collects a position's earned fees into this vault (ready to claim), taking the protocol fee.
    function collect(uint256 id) external onlyOwnerOrBundler nonReentrant {
        _collectFees(id, _get(id), false);
    }

    /// @notice Hands `amount` of a ready-to-claim token (zero: all of it) to the bundler, to swap or send to the owner.
    function takeReady(address token, uint256 amount) external onlyBundler nonReentrant returns (uint256) {
        uint256 ready = _balance(token) - _reserved(token);
        if (amount == 0 || amount > ready) amount = ready;
        _sendTo(token, msg.sender, amount);
        emit Claimed(token, amount);
        return amount;
    }

    /// @notice The checked pool price of a position (Chainlink, or the keeper's recorded price): the bundler's keeper
    ///         rebalance swaps against it. Uses up the recorded price, like the keeper's own actions.
    function checkedPrice(uint256 id) external onlyBundler returns (uint160) {
        return _checkPrice(id, _get(id));
    }

    // ---------------------------------------------------------------- keeper (or owner)

    /// @notice Records the current pool price, the first step of the price check for pools without Chainlink feeds.
    function poke(uint256 id) external onlyOwnerOrKeeper whenNotPaused nonReentrant refundGas {
        Position storage pos = _get(id);
        (, int24 tick,,) = _pm().getSlot0(pos.key.toId());
        pokes[id] = Poke(tick, uint32(block.timestamp));
        emit Poked(id, tick);
    }

    /// @notice Collects fees, takes the protocol fee and reinvests the chosen share, with a swap in the position's own
    ///         pool so that share fits the range's ratio. The rest stays ready to claim.
    function compound(uint256 id, bool zeroForOne, uint256 amountIn, bytes memory route)
        external
        onlyOwnerOrKeeper
        whenNotPaused
        nonReentrant
        refundGas
    {
        Position storage pos = _get(id);
        if (msg.sender != owner) {
            if (block.timestamp < uint256(pos.lastCompound) + KEEPER_COMPOUND_COOLDOWN) revert TooSoon();
            pos.lastCompound = uint32(block.timestamp);
        }
        _compound(id, pos.settings.compoundBps, zeroForOne, amountIn, route);
    }

    /// @notice The owner's instant compound. No recorded price is needed: the owner signs the price range the pool
    ///         must be in (as with add). Collects the fees and reinvests everything of the pair the vault holds (these
    ///         fees and those already ready to claim), with a swap in the pool itself for the range's ratio, whatever
    ///         the reinvest setting. What still does not fit stays ready to claim.
    function compoundNow(
        uint256 id,
        uint160 sqrtPriceMin,
        uint160 sqrtPriceMax,
        bool zeroForOne,
        uint256 amountIn,
        bytes memory route
    ) external
        onlyOwnerOrBundler
        whenNotPaused
        nonReentrant
    {
        Position storage pos = _get(id);
        uint160 sqrtP = _ownerPrice(pos, sqrtPriceMin, sqrtPriceMax);
        _collectFees(id, pos, true);
        // Everything ready to claim and what waits to go back into this position goes in (not what other positions
        // of this vault wait for).
        (uint256 u0, uint256 u1) = _takeUnplaced(id);
        address c0 = Currency.unwrap(pos.key.currency0);
        address c1 = Currency.unwrap(pos.key.currency1);
        _reinvest(id, pos, _balance(c0) - _reserved(c0), _balance(c1) - _reserved(c1), zeroForOne, amountIn, sqrtP, route);
        // What still does not fit: this position's leftover keeps waiting, the rest is ready to claim again.
        uint256[2] storage w = _unplaced[id];
        (w[0], w[1]) = (Math.min(w[0], u0), Math.min(w[1], u1));
    }

    /// Swaps part of (a0, a1) in the position's own pool so it fits the range's ratio; returns the new amounts.
    function _swapToRatio(
        uint256 id,
        Position storage pos,
        bool zeroForOne,
        uint256 amountIn,
        uint256 a0,
        uint256 a1,
        bytes memory route
    )
        internal
        returns (uint256, uint256)
    {
        if (amountIn == 0) return (a0, a1);
        if (amountIn > (zeroForOne ? a0 : a1)) revert SwapTooLarge();
        _countKeeperSwap(id);
        (uint256 spent, uint256 got) = _swap(pos, zeroForOne, amountIn, route);
        emit Swapped(id, zeroForOne, spent, got);
        return zeroForOne ? (a0 - spent, a1 + got) : (a0 + got, a1 - spent);
    }

    function _ownerPrice(Position storage pos, uint160 lo, uint160 hi) internal view returns (uint160 sqrtP) {
        (sqrtP,,,) = _pm().getSlot0(pos.key.toId());
        if (sqrtP < lo || sqrtP > hi) revert PriceOutOfBounds();
    }

    function _compound(uint256 id, uint256 bps, bool zeroForOne, uint256 amountIn, bytes memory route) internal {
        Position storage pos = _get(id);
        uint160 sqrtP = _checkPrice(id, pos);
        (uint256 f0, uint256 f1) = _collectFees(id, pos, true);
        (uint256 u0, uint256 u1) = _takeUnplaced(id);
        if (bps == 10_000) {
            // Everything goes back in (not what other positions of this vault wait for).
            address c0 = Currency.unwrap(pos.key.currency0);
            address c1 = Currency.unwrap(pos.key.currency1);
            (f0, f1) = (_balance(c0) - _reserved(c0), _balance(c1) - _reserved(c1));
        } else {
            // The chosen share of the fees, plus what belongs in the position but is not in it yet.
            (f0, f1) = ((f0 * bps) / 10_000 + u0, (f1 * bps) / 10_000 + u1);
        }
        _reinvest(id, pos, f0, f1, zeroForOne, amountIn, sqrtP, route);
    }

    /// @dev Swaps a0/a1 to the range's ratio in the position's own pool (when amountIn > 0) and adds them to the
    ///      position. What does not fit waits in the vault to go in with the next compound (unplaced).
    function _reinvest(
        uint256 id,
        Position storage pos,
        uint256 a0,
        uint256 a1,
        bool zeroForOne,
        uint256 amountIn,
        uint160 sqrtP,
        bytes memory route
    ) internal {
        if (a0 == 0 && a1 == 0) return;
        if (amountIn > 0) {
            (a0, a1) = _swapToRatio(id, pos, zeroForOne, amountIn, a0, a1, route);
            (sqrtP,,,) = _pm().getSlot0(pos.key.toId());
        }
        (, uint256 used0, uint256 used1) = _increase(pos, a0, a1, sqrtP);
        _setUnplaced(id, a0 - used0, a1 - used1);
        emit Compounded(id, used0, used1);
    }

    /// @notice Moves a position to a new range around the current price, with an optional swap in its own pool.
    function rebalance(
        uint256 id,
        int24 tickLower,
        int24 tickUpper,
        bool zeroForOne,
        uint256 amountIn,
        bytes memory route
    )
        external
        onlyOwnerOrKeeper
        whenNotPaused
        nonReentrant
        refundGas
    {
        Position storage pos = _get(id);
        if (block.timestamp < uint256(pos.lastMove) + pos.settings.cooldown) revert TooSoon();
        _checkPrice(id, pos);
        _checkRange(tickLower, tickUpper, pos.key.tickSpacing, pos.settings, Shapes.bands(pos.shape));
        (, int24 tick,,) = _pm().getSlot0(pos.key.toId());
        if (tick < tickLower || tick >= tickUpper) revert BadRange();

        (uint256 f0, uint256 f1) = _collectFees(id, pos, true);
        uint256 oldTokenId = pos.tokenId;
        (uint256 a0, uint256 a1) = _modify(pos, BURN_POSITION, 0);
        // The position, the reinvested share of its fees, and what an earlier move could not place.
        (uint256 u0, uint256 u1) = _takeUnplaced(id);
        a0 += (f0 * pos.settings.compoundBps) / 10_000 + u0;
        a1 += (f1 * pos.settings.compoundBps) / 10_000 + u1;

        (a0, a1) = _swapToRatio(id, pos, zeroForOne, amountIn, a0, a1, route);

        (uint160 sqrtP,,,) = _pm().getSlot0(pos.key.toId());
        (uint256 newTokenId, uint256 used0, uint256 used1) =
            ShapesV4.mint(pos.key, tickLower, tickUpper, pos.shape, a0, a1, sqrtP, address(_posm()), factory.permit2());
        _setUnplaced(id, a0 - used0, a1 - used1);
        pos.tokenId = newTokenId;
        pos.tickLower = tickLower;
        pos.tickUpper = tickUpper;
        pos.lastMove = uint32(block.timestamp);
        emit Rebalanced(id, oldTokenId, newTokenId, tickLower, tickUpper);
    }

    // ---------------------------------------------------------------- internals: fees

    /// A bundle fee: never above the factory's protocol fee, never below the floor (unless the factory's fee is lower).
    function _clampFee(uint16 feeBps) internal view returns (uint16) {
        uint256 max = factory.protocolFeeBps();
        uint256 f = feeBps > max ? max : feeBps;
        if (f < FEE_FLOOR_BPS) f = FEE_FLOOR_BPS < max ? FEE_FLOOR_BPS : max;
        return uint16(f);
    }

    /// The protocol fee as in TidewellShapedBase._takeFees, at the position's own rate: the staking discount comes off
    /// it, but the result never goes below FEE_FLOOR_BPS. A factory fee of zero switches it off for every position.
    function _takeFeesAt(uint16 feeBps, address t0, address t1, uint256 c0, uint256 c1, uint160 sqrtP, bool strict)
        internal
        returns (uint256 p0, uint256 p1)
    {
        if (c0 == 0 && c1 == 0) return (0, 0);
        uint256 max = factory.protocolFeeBps();
        if (max == 0) return (0, 0);
        uint256 bps = feeBps > max ? max : feeBps;
        uint256 rate = bps * (10_000 - _discount(strict)); // fee per 1e8
        uint256 floor = (bps < FEE_FLOOR_BPS ? bps : FEE_FLOOR_BPS) * 10_000;
        if (rate < floor) rate = floor;
        p0 = (c0 * rate) / 1e8;
        p1 = (c1 * rate) / 1e8;
        if (strict && sqrtP != 0) (p0, p1) = _feeToRank(t0, t1, c0, c1, p0, p1, sqrtP);
        p0 = _sendFee(t0, p0, strict);
        p1 = _sendFee(t1, p1, strict);
    }

    /// Moves the whole fee to the higher-ranked token (ETH above dollars above the rest) at the pool price, as in
    /// TidewellShapedBase._takeFees.
    function _feeToRank(address t0, address t1, uint256 c0, uint256 c1, uint256 p0, uint256 p1, uint160 sqrtP)
        internal
        view
        returns (uint256, uint256)
    {
        uint8 r0 = factory.feeRank(t0);
        uint8 r1 = factory.feeRank(t1);
        if (r1 > r0 && p0 > 0) {
            uint256 want = p1 + Math.mulDiv(Math.mulDiv(p0, sqrtP, 1 << 96), sqrtP, 1 << 96);
            if (want <= c1) return (0, want);
            uint256 q0 = Math.mulDiv(Math.mulDiv(want - c1, 1 << 96, sqrtP), 1 << 96, sqrtP);
            return (q0 > c0 ? c0 : q0, c1);
        } else if (r0 > r1 && p1 > 0) {
            uint256 want = p0 + Math.mulDiv(Math.mulDiv(p1, 1 << 96, sqrtP), 1 << 96, sqrtP);
            if (want <= c0) return (want, 0);
            uint256 q1 = Math.mulDiv(Math.mulDiv(want - c0, sqrtP, 1 << 96), sqrtP, 1 << 96);
            return (c0, q1 > c1 ? c1 : q1);
        }
        return (p0, p1);
    }

    function _sendTo(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (!_trySend(token, to, amount)) revert TransferFailed();
    }

    // ---------------------------------------------------------------- internals: price

    /// Chainlink when both tokens have a fresh feed, otherwise the two-step poke check. Returns the pool price.
    function _checkPrice(uint256 id, Position storage pos) internal returns (uint160 sqrtP) {
        int24 tick;
        (sqrtP, tick,,) = _pm().getSlot0(pos.key.toId());
        if (factory.checkOracle(Currency.unwrap(pos.key.currency0), Currency.unwrap(pos.key.currency1), sqrtP)) {
            return sqrtP;
        }
        Poke memory k = pokes[id];
        if (k.at == 0 || block.timestamp < uint256(k.at) + POKE_MIN_AGE || block.timestamp > uint256(k.at) + POKE_MAX_AGE)
        {
            revert NoPriceCheck();
        }
        int24 d = tick > k.tick ? tick - k.tick : k.tick - tick;
        if (d > factory.maxTickDeviation()) revert PriceMoved(tick, k.tick);
        delete pokes[id]; // one recorded price per action
    }

    // ---------------------------------------------------------------- internals: Uniswap

    function _pm() internal view returns (IPoolManager) {
        return IPoolManager(factory.poolManager());
    }

    function _posm() internal view returns (IPositionManagerV4S) {
        return IPositionManagerV4S(factory.positionManagerV4());
    }

    /// Adds (a0, a1) to all bands; returns ok = false instead of reverting when it cannot be done.
    function _increase(Position storage pos, uint256 a0, uint256 a1, uint160 sqrtP)
        internal
        returns (bool ok, uint256 used0, uint256 used1)
    {
        return ShapesV4.increase(
            pos.tokenId, pos.key, pos.tickLower, pos.tickUpper, pos.shape, a0, a1, sqrtP, address(_posm()), factory.permit2()
        );
    }

    /// Decreases every band by `share` (DECREASE_LIQUIDITY) or burns them all (BURN_POSITION), and takes what comes
    /// out into this vault. Returns the amounts.
    function _modify(Position storage pos, uint8 action, uint256 share) internal returns (uint256 a0, uint256 a1) {
        return ShapesV4.modify(pos.tokenId, Shapes.bands(pos.shape), pos.key, action, share, address(_posm()));
    }

    /// Collects earned fees into this vault and takes the protocol fee. Returns the fees after the protocol fee.
    function _collectFees(uint256 id, Position storage pos, bool strict) internal returns (uint256 f0, uint256 f1) {
        if (ShapesV4.liquidity(pos.tokenId, Shapes.bands(pos.shape), address(_posm())) == 0) return (0, 0);
        (uint256 c0, uint256 c1) = _modify(pos, DECREASE_LIQUIDITY, 0);
        (uint160 sqrtP,,,) = _pm().getSlot0(pos.key.toId());
        (uint256 p0, uint256 p1) = _takeFeesAt(
            pos.feeBps, Currency.unwrap(pos.key.currency0), Currency.unwrap(pos.key.currency1), c0, c1, sqrtP, strict
        );
        f0 = c0 - p0;
        f1 = c1 - p1;
        if (c0 > 0 || c1 > 0) emit FeesCollected(id, c0, c1, p0, p1);
    }

    /// The swap runs in the swapper: along `route` through Uniswap's Universal Router when there is one (the best
    /// path Uniswap's routing found), else in one pool of the pair. Either way it is checked here against the
    /// position's own pool price (which passed the price check): at most the slippage setting plus the pool fee worse.
    function _swap(Position storage pos, bool zeroForOne, uint256 amountIn, bytes memory route)
        internal
        returns (uint256 spent, uint256 got)
    {
        (uint160 sqrtP, uint160 limit, uint256 minBps) = _swapLimits(pos, zeroForOne);
        address c0 = Currency.unwrap(pos.key.currency0);
        address c1 = Currency.unwrap(pos.key.currency1);
        uint256 b0 = _balance(c0);
        uint256 b1 = _balance(c1);
        // The swapper does the swap and sends the output (and anything not swapped) straight back.
        address sw = factory.swapper();
        address cin = zeroForOne ? c0 : c1;
        if (cin != address(0)) IERC20(cin).safeTransfer(sw, amountIn);
        ITidewellSwapperV4(sw).swap{value: cin == address(0) ? amountIn : 0}(pos.key, zeroForOne, amountIn, limit, route);
        if (zeroForOne) {
            spent = b0 - _balance(c0);
            got = _balance(c1) - b1;
        } else {
            spent = b1 - _balance(c1);
            got = _balance(c0) - b0;
        }
        // Never more than asked (a hook cannot make the vault pay extra).
        if (spent == 0 || spent > amountIn) revert BadSwap();
        // The average price must be within slippage plus the pool fee of the position pool's price.
        uint256 expected = zeroForOne
            ? Math.mulDiv(Math.mulDiv(spent, sqrtP, 1 << 96), sqrtP, 1 << 96)
            : Math.mulDiv(Math.mulDiv(spent, 1 << 96, sqrtP), 1 << 96, sqrtP);
        if (got * 10_000 < expected * minBps) revert BadSwap();
    }

    /// The pool price, the price limit for the swap (slippage setting) and the least it must return, in bps of the
    /// pool price (slippage plus the pool fee).
    function _swapLimits(Position storage pos, bool zeroForOne)
        internal
        view
        returns (uint160 sqrtP, uint160 limit, uint256 minBps)
    {
        uint256 slip = _slippage(pos.settings);
        uint24 lpFee;
        (sqrtP,,, lpFee) = _pm().getSlot0(pos.key.toId());
        uint256 factor = Math.sqrt((zeroForOne ? 10_000 - slip : 10_000 + slip) * 1e14); // sqrt(1 -/+ s) * 1e9
        uint256 l = Math.mulDiv(sqrtP, factor, 1e9);
        if (zeroForOne && l <= TickMath.MIN_SQRT_PRICE) l = TickMath.MIN_SQRT_PRICE + 1;
        if (!zeroForOne && l >= TickMath.MAX_SQRT_PRICE) l = TickMath.MAX_SQRT_PRICE - 1;
        limit = uint160(l);
        minBps = 10_000 - slip - lpFee / 100;
    }

    // ---------------------------------------------------------------- internals: bookkeeping

    function _get(uint256 id) internal view returns (Position storage pos) {
        pos = _positions[id];
        if (pos.tokenId == 0) revert UnknownPosition();
    }

    function _delete(uint256 id) internal {
        _removeId(id);
        delete _positions[id];
        delete pokes[id];
        delete _unplaced[id];
        delete keeperSwaps[id];
    }

    function _pairOf(uint256 id) internal view override returns (address, address) {
        PoolKey storage k = _positions[id].key;
        return (Currency.unwrap(k.currency0), Currency.unwrap(k.currency1));
    }
}

