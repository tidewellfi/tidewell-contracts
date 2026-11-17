// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {INonfungiblePositionManager, IUniswapV3Factory, IUniswapV3Pool} from "./interfaces/IUniswapV3.sol";
import {TidewellShapedBase} from "./TidewellShapedBase.sol";
import {Shapes} from "./libraries/Shapes.sol";
import {ShapesV3} from "./libraries/ShapesV3.sol";

interface IWETHWithdrawS {
    function withdraw(uint256 amount) external;
}

interface ITidewellSwapperV3S {
    function swapToken(address tokenIn, address tokenOut, uint256 amountIn, bytes calldata route) external;
}

/// @title TidewellShapedVaultV3
/// @notice One vault per user, with liquidity shapes: a position is one band (Even) or 3 to 15 bands with more
///         liquidity in the middle (Centered) or at the ends (Edges); see Shapes. The keeper is also bound by the
///         keeper limits of TidewellShapedBase.
///         Holds that user's Uniswap v3 positions and their fees. Only the owner can take
///         anything out. The keeper can only collect fees, reinvest and move a range, within the owner's settings and
///         the factory's limits, and everything it touches stays in this vault.
/// @dev Every token in this vault that is not inside a Uniswap position belongs to the owner and is "ready to claim".
///      There is no shared accounting between users, so one user's tokens can never affect another user.
contract TidewellShapedVaultV3 is TidewellShapedBase {
    using SafeERC20 for IERC20;

    uint160 internal constant MIN_SQRT_RATIO = 4295128739;
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    /// remove(): share of the position taken out, 1e18 = all of it.
    uint256 public constant SHARE_ALL = 1e18;

    struct Position {
        uint256 tokenId; // NFT of the first band; the bands are tokenId .. tokenId + bands - 1. Changes on every move
        address pool;
        address token0;
        address token1;
        uint24 fee;
        int24 tickSpacing;
        int24 tickLower; // the whole range, all bands together
        int24 tickUpper;
        uint32 lastMove;
        uint32 lastCompound; // last reinvest by the keeper
        uint8 shape; // Shapes.EVEN, CENTERED or EDGES
        Settings settings;
    }

    struct OpenParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0;
        uint256 amount1;
        uint256 amount0Min;
        uint256 amount1Min;
        uint8 shape;
        Settings settings;
    }

    mapping(uint256 id => Position) internal _positions;

    address internal transient _swapPool;

    event Opened(
        uint256 indexed id, uint256 tokenId, address pool, int24 tickLower, int24 tickUpper, uint256 amount0, uint256 amount1
    );
    event Added(uint256 indexed id, uint256 amount0, uint256 amount1);
    event Removed(uint256 indexed id, uint128 liquidity, uint256 amount0, uint256 amount1);
    event ShapeSet(uint256 indexed id, uint8 shape, uint256 bands);

    error PriceOutOfBounds();
    error BadValue();

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
        return ShapesV3.liquidity(pos.tokenId, Shapes.bands(pos.shape), factory.positionManager());
    }

    // ---------------------------------------------------------------- owner: deposits

    /// @notice Opens a new position. The owner must have approved this vault for both tokens.
    function open(OpenParams calldata p) external onlyOwner whenNotPaused nonReentrant returns (uint256 id) {
        (address pool, int24 spacing) = _checkOpen(p);
        id = _open(p, pool, spacing, _pull(p.token0, p.amount0), _pull(p.token1, p.amount1));
    }

    /// @notice Same as open, with the deposit already in the vault: used by factory.openWithPermit, which moves the
    ///         tokens from the owner's wallet into this vault through Permit2 in the same transaction.
    function openFromBalance(OpenParams calldata p) external onlyOwnerOrFactory whenNotPaused nonReentrant returns (uint256 id) {
        (address pool, int24 spacing) = _checkOpen(p);
        id = _open(p, pool, spacing, _fromBalance(p.token0, p.amount0), _fromBalance(p.token1, p.amount1));
    }

    function _checkOpen(OpenParams calldata p) internal view returns (address pool, int24 spacing) {
        if (p.token0 >= p.token1) revert BadRange();
        pool = IUniswapV3Factory(factory.uniswapFactory()).getPool(p.token0, p.token1, p.fee);
        if (pool == address(0)) revert UnknownPool();
        spacing = IUniswapV3Pool(pool).tickSpacing();
        uint256 n = Shapes.bands(p.shape);
        _checkSettings(p.settings, spacing, n);
        _checkRange(p.tickLower, p.tickUpper, spacing, p.settings, n);
    }

    function _open(OpenParams calldata p, address pool, int24 spacing, uint256 in0, uint256 in1)
        internal
        returns (uint256 id)
    {

        // Make sure the pool keeps enough price history for the keeper's price check.
        (,,,, uint16 cardinalityNext,,) = IUniswapV3Pool(pool).slot0();
        uint16 target = factory.cardinalityTarget();
        if (cardinalityNext < target) IUniswapV3Pool(pool).increaseObservationCardinalityNext(target);

        (uint160 sqrtP,,,,,,) = IUniswapV3Pool(pool).slot0();
        (uint256 tokenId, uint256 used0, uint256 used1) = ShapesV3.mint(
            ShapesV3.Pair(p.token0, p.token1, p.fee), p.tickLower, p.tickUpper, p.shape, in0, in1, sqrtP,
            factory.positionManager()
        );
        if (used0 < p.amount0Min || used1 < p.amount1Min) revert PriceOutOfBounds();

        id = ++nextPositionId;
        _positions[id] = Position({
            tokenId: tokenId,
            pool: pool,
            token0: p.token0,
            token1: p.token1,
            fee: p.fee,
            tickSpacing: spacing,
            tickLower: p.tickLower,
            tickUpper: p.tickUpper,
            lastMove: uint32(block.timestamp),
            lastCompound: 0,
            shape: p.shape,
            settings: p.settings
        });
        _addId(id);

        _send(p.token0, in0 - used0);
        _send(p.token1, in1 - used1);
        emit Opened(id, tokenId, pool, p.tickLower, p.tickUpper, used0, used1);
        emit ShapeSet(id, p.shape, Shapes.bands(p.shape));
    }

    function add(uint256 id, uint256 amount0, uint256 amount1, uint256 amount0Min, uint256 amount1Min)
        external
        onlyOwner
        whenNotPaused
        nonReentrant
    {
        Position storage pos = _get(id);
        uint256 in0 = _pull(pos.token0, amount0);
        uint256 in1 = _pull(pos.token1, amount1);
        (bool ok, uint256 used0, uint256 used1) = _increase(pos, in0, in1, amount0Min, amount1Min);
        if (!ok) revert BadRange();
        _send(pos.token0, in0 - used0);
        _send(pos.token1, in1 - used1);
        emit Added(id, used0, used1);
    }

    function setSettings(uint256 id, Settings calldata s) external onlyOwner {
        Position storage pos = _get(id);
        _checkSettings(s, pos.tickSpacing, Shapes.bands(pos.shape));
        pos.settings = s;
        emit SettingsChanged(id, s);
    }

    // ---------------------------------------------------------------- owner: withdrawals (never paused)

    /// @notice Takes `share` of a position out of every band (1e18 = all) and sends it to the owner; 0 only collects
    ///         the fees. Earned fees stay ready to claim. The minimums are for the whole position.
    function remove(uint256 id, uint128 share, uint256 amount0Min, uint256 amount1Min) external onlyOwner nonReentrant {
        Position storage pos = _get(id);
        if (share > SHARE_ALL) revert BadValue();
        _collectFees(id, pos, false);
        (uint256 a0, uint256 a1) = ShapesV3.decrease(pos.tokenId, Shapes.bands(pos.shape), share, factory.positionManager());
        if (a0 < amount0Min || a1 < amount1Min) revert PriceOutOfBounds();
        _send(pos.token0, a0);
        _send(pos.token1, a1);
        emit Removed(id, share, a0, a1);
    }

    /// @notice Closes a position and sends everything in both tokens to the owner, including unclaimed fees.
    function close(uint256 id, uint256 amount0Min, uint256 amount1Min) external onlyOwner nonReentrant {
        Position storage pos = _get(id);
        address t0 = pos.token0;
        address t1 = pos.token1;
        _collectFees(id, pos, false);
        address npm = factory.positionManager();
        uint256 n = Shapes.bands(pos.shape);
        (uint256 a0, uint256 a1) = ShapesV3.decrease(pos.tokenId, n, SHARE_ALL, npm);
        if (a0 < amount0Min || a1 < amount1Min) revert PriceOutOfBounds();
        ShapesV3.burn(pos.tokenId, n, npm);
        _delete(id);
        // Everything of the pair, except what waits to go back into other positions of this vault.
        _send(t0, IERC20(t0).balanceOf(address(this)) - _reserved(t0));
        _send(t1, IERC20(t1).balanceOf(address(this)) - _reserved(t1));
        emit Closed(id);
    }

    /// @notice Last-resort exit: hands the Uniswap NFT itself to the owner. Fees are settled first if that works.
    function rescue(uint256 id) external onlyOwner nonReentrant {
        Position storage pos = _get(id);
        uint256 tokenId = pos.tokenId;
        uint256 n = Shapes.bands(pos.shape);
        try this.settleFees(id) {} catch {}
        _delete(id);
        ShapesV3.transferAll(tokenId, n, owner, factory.positionManager());
        emit Closed(id);
    }

    /// @dev Only callable by this vault itself, so rescue() can try it without being blocked by a failure.
    function settleFees(uint256 id) external {
        if (msg.sender != address(this)) revert NotAllowed();
        _collectFees(id, _positions[id], false);
    }

    // ---------------------------------------------------------------- keeper (or owner)

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

    /// @notice The owner's instant compound. No price history is needed: the owner signs the price range the pool
    ///         must be in. Collects the fees and reinvests everything of the pair the vault holds (these fees and those
    ///         already ready to claim), with a swap in the pool itself for the range's ratio, whatever the reinvest
    ///         setting. What still does not fit stays ready to claim.
    function compoundNow(
        uint256 id,
        uint160 sqrtPriceMin,
        uint160 sqrtPriceMax,
        bool zeroForOne,
        uint256 amountIn,
        bytes memory route
    )
        external
        onlyOwner
        whenNotPaused
        nonReentrant
    {
        Position storage pos = _get(id);
        _ownerPrice(pos, sqrtPriceMin, sqrtPriceMax);
        _collectFees(id, pos, true);
        // Everything ready to claim and what waits to go back into this position goes in (not what other positions
        // of this vault wait for).
        (uint256 u0, uint256 u1) = _takeUnplaced(id);
        address t0 = pos.token0;
        address t1 = pos.token1;
        _reinvest(id, pos, _balance(t0) - _reserved(t0), _balance(t1) - _reserved(t1), zeroForOne, amountIn, route);
        // What still does not fit: this position's leftover keeps waiting, the rest is ready to claim again.
        uint256[2] storage w = _unplaced[id];
        (w[0], w[1]) = (Math.min(w[0], u0), Math.min(w[1], u1));
    }

    /// @notice Claims this position's fees as ETH in one transaction: collects them, swaps everything of the pool's
    ///         other token that is ready to claim to WETH in the pool itself, unwraps all WETH and sends the ETH to
    ///         the owner. Only for pools with WETH. `keepWei` of ETH stays in the vault for the keeper's gas.
    function claimAsEth(uint256 id, uint160 sqrtPriceMin, uint160 sqrtPriceMax, uint256 keepWei, bytes memory route)
        external
        onlyOwner
        whenNotPaused
        nonReentrant
    {
        Position storage pos = _get(id);
        address weth = factory.weth();
        if (pos.token0 != weth && pos.token1 != weth) revert UnknownPool();
        _ownerPrice(pos, sqrtPriceMin, sqrtPriceMax);
        _collectFees(id, pos, true);
        // What waits to go back into positions is not ready to claim: it stays.
        bool zeroForOne = pos.token1 == weth; // the other token is token0: swap 0 -> 1
        address other = zeroForOne ? pos.token0 : pos.token1;
        uint256 amount = IERC20(other).balanceOf(address(this)) - _reserved(other);
        if (amount > 0) {
            (uint256 spent, uint256 got) = _swap(pos, zeroForOne, amount, route);
            emit Swapped(id, zeroForOne, spent, got);
        }
        uint256 w = IERC20(weth).balanceOf(address(this)) - _reserved(weth);
        if (w > 0) IWETHWithdrawS(weth).withdraw(w);
        uint256 bal = address(this).balance;
        uint256 out = bal > keepWei ? bal - keepWei : 0;
        if (out > 0) {
            _send(address(0), out);
            emit Claimed(address(0), out);
        }
    }

    function _ownerPrice(Position storage pos, uint160 lo, uint160 hi) internal view {
        (uint160 sqrtP,,,,,,) = IUniswapV3Pool(pos.pool).slot0();
        if (sqrtP < lo || sqrtP > hi) revert PriceOutOfBounds();
    }

    /// @dev Swaps `amountIn` of one token of a0/a1 for the other in the position's own pool; returns the new amounts.
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

    function _compound(uint256 id, uint256 bps, bool zeroForOne, uint256 amountIn, bytes memory route) internal {
        Position storage pos = _get(id);
        factory.checkPrice(pos.pool);
        (uint256 f0, uint256 f1) = _collectFees(id, pos, true);
        (uint256 u0, uint256 u1) = _takeUnplaced(id);
        // The chosen share of the fees, plus what belongs in the position but is not in it yet.
        uint256 r0 = (f0 * bps) / 10_000 + u0;
        uint256 r1 = (f1 * bps) / 10_000 + u1;
        if (bps == 10_000) {
            // Everything goes back in (not what other positions of this vault wait for).
            (r0, r1) = (_balance(pos.token0) - _reserved(pos.token0), _balance(pos.token1) - _reserved(pos.token1));
        }
        _reinvest(id, pos, r0, r1, zeroForOne, amountIn, route);
    }

    /// @dev Swaps r0/r1 to the range's ratio in the position's own pool (when amountIn > 0) and adds them to the
    ///      position. Adding can fail when they do not fit the range (for example only one token while the price is
    ///      inside it); what is not added waits in the vault for the next compound (unplaced).
    function _reinvest(
        uint256 id,
        Position storage pos,
        uint256 r0,
        uint256 r1,
        bool zeroForOne,
        uint256 amountIn,
        bytes memory route
    ) internal {
        if (r0 == 0 && r1 == 0) return;
        (r0, r1) = _swapToRatio(id, pos, zeroForOne, amountIn, r0, r1, route);
        (, uint256 used0, uint256 used1) = _increase(pos, r0, r1, 0, 0);
        _setUnplaced(id, r0 - used0, r1 - used1);
        emit Compounded(id, used0, used1);
    }

    /// @notice Moves a position to a new range around the current price.
    /// @param zeroForOne direction of the optional swap that brings the tokens to the new range's ratio
    /// @param amountIn amount to swap; zero for no swap
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
        factory.checkPrice(pos.pool);
        _checkRange(tickLower, tickUpper, pos.tickSpacing, pos.settings, Shapes.bands(pos.shape));
        (, int24 tick,,,,,) = IUniswapV3Pool(pos.pool).slot0();
        if (tick < tickLower || tick >= tickUpper) revert BadRange();

        (uint256 f0, uint256 f1) = _collectFees(id, pos, true);
        uint256 oldTokenId = pos.tokenId;
        address npm = factory.positionManager();
        uint256 n = Shapes.bands(pos.shape);
        (uint256 a0, uint256 a1) = ShapesV3.decrease(oldTokenId, n, SHARE_ALL, npm);
        ShapesV3.burn(oldTokenId, n, npm);
        // The position, the reinvested share of its fees, and what an earlier move could not place.
        (uint256 u0, uint256 u1) = _takeUnplaced(id);
        a0 += (f0 * pos.settings.compoundBps) / 10_000 + u0;
        a1 += (f1 * pos.settings.compoundBps) / 10_000 + u1;

        (a0, a1) = _swapToRatio(id, pos, zeroForOne, amountIn, a0, a1, route);

        (uint160 sqrtP,,,,,,) = IUniswapV3Pool(pos.pool).slot0();
        (uint256 newTokenId, uint256 used0, uint256 used1) = ShapesV3.mint(
            ShapesV3.Pair(pos.token0, pos.token1, pos.fee), tickLower, tickUpper, pos.shape, a0, a1, sqrtP, npm
        );
        _setUnplaced(id, a0 - used0, a1 - used1);
        pos.tokenId = newTokenId;
        pos.tickLower = tickLower;
        pos.tickUpper = tickUpper;
        pos.lastMove = uint32(block.timestamp);
        emit Rebalanced(id, oldTokenId, newTokenId, tickLower, tickUpper);
    }

    // ---------------------------------------------------------------- Uniswap callbacks

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        if (msg.sender != _swapPool || _swapPool == address(0)) revert NotAllowed();
        (address t0, address t1) = abi.decode(data, (address, address));
        if (amount0Delta > 0) IERC20(t0).safeTransfer(msg.sender, uint256(amount0Delta));
        if (amount1Delta > 0) IERC20(t1).safeTransfer(msg.sender, uint256(amount1Delta));
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != factory.positionManager()) revert NotAllowed();
        return this.onERC721Received.selector;
    }

    // ---------------------------------------------------------------- internals: Uniswap

    /// Adds (a0, a1) to all bands; ok = false when nothing fits.
    function _increase(Position storage pos, uint256 a0, uint256 a1, uint256 min0, uint256 min1)
        internal
        returns (bool ok, uint256 used0, uint256 used1)
    {
        (uint160 sqrtP,,,,,,) = IUniswapV3Pool(pos.pool).slot0();
        return ShapesV3.increase(
            pos.tokenId,
            ShapesV3.Pair(pos.token0, pos.token1, pos.fee),
            pos.tickLower,
            pos.tickUpper,
            pos.shape,
            a0,
            a1,
            sqrtP,
            min0,
            min1,
            factory.positionManager()
        );
    }

    /// Collects earned fees into this vault and takes the protocol fee. Returns the fees after the protocol fee.
    /// @dev Must never be called while removed principal is still owed by the position manager: every _decrease()
    ///      collects its own amounts straight away, so what is owed here is always fees.
    function _collectFees(uint256 id, Position storage pos, bool strict) internal returns (uint256 f0, uint256 f1) {
        (uint256 c0, uint256 c1) = ShapesV3.collect(pos.tokenId, Shapes.bands(pos.shape), factory.positionManager());
        (uint160 sqrtP,,,,,,) = IUniswapV3Pool(pos.pool).slot0();
        (uint256 p0, uint256 p1) = _takeFees(pos.token0, pos.token1, c0, c1, sqrtP, strict);
        f0 = c0 - p0;
        f1 = c1 - p1;
        if (c0 > 0 || c1 > 0) emit FeesCollected(id, c0, c1, p0, p1);
    }

    /// Swaps directly against the position's own pool, bounded by the owner's slippage setting.
    /// The swap runs along `route` through Uniswap's Universal Router (via the swapper) when there is one (the best
    /// path Uniswap's routing found), else in the position's own pool. Either way it is checked against the
    /// position's own pool price (which passed the price check): at most the slippage setting plus the pool fee worse.
    function _swap(Position storage pos, bool zeroForOne, uint256 amountIn, bytes memory route)
        internal
        returns (uint256 spent, uint256 got)
    {
        uint256 slip = _slippage(pos.settings);
        (uint160 sqrtP,,,,,,) = IUniswapV3Pool(pos.pool).slot0();
        if (route.length > 0) {
            (address tIn, address tOut) = zeroForOne ? (pos.token0, pos.token1) : (pos.token1, pos.token0);
            uint256 bIn = IERC20(tIn).balanceOf(address(this));
            uint256 bOut = IERC20(tOut).balanceOf(address(this));
            address sw = factory.swapper();
            IERC20(tIn).safeTransfer(sw, amountIn);
            ITidewellSwapperV3S(sw).swapToken(tIn, tOut, amountIn, route);
            spent = bIn - IERC20(tIn).balanceOf(address(this));
            got = IERC20(tOut).balanceOf(address(this)) - bOut;
        } else {
            // Price limit: the pool price may move at most `slip` against us.
            uint256 factor = Math.sqrt((zeroForOne ? 10_000 - slip : 10_000 + slip) * 1e14); // sqrt(1 -/+ s) * 1e9
            uint256 limit = Math.mulDiv(sqrtP, factor, 1e9);
            if (zeroForOne && limit <= MIN_SQRT_RATIO) limit = MIN_SQRT_RATIO + 1;
            if (!zeroForOne && limit >= MAX_SQRT_RATIO) limit = MAX_SQRT_RATIO - 1;
            _swapPool = pos.pool;
            (int256 d0, int256 d1) = IUniswapV3Pool(pos.pool).swap(
                address(this), zeroForOne, int256(amountIn), uint160(limit), abi.encode(pos.token0, pos.token1)
            );
            _swapPool = address(0);
            (spent, got) = zeroForOne ? (uint256(d0), uint256(-d1)) : (uint256(d1), uint256(-d0));
        }
        if (spent == 0 || spent > amountIn) revert BadSwap();

        // The average price must be within slippage plus the pool fee of the position pool's price.
        uint256 expected = zeroForOne
            ? Math.mulDiv(Math.mulDiv(spent, sqrtP, 1 << 96), sqrtP, 1 << 96)
            : Math.mulDiv(Math.mulDiv(spent, 1 << 96, sqrtP), 1 << 96, sqrtP);
        if (got * 10_000 < expected * (10_000 - slip - pos.fee / 100)) revert BadSwap();
    }

    // ---------------------------------------------------------------- internals: bookkeeping

    function _get(uint256 id) internal view returns (Position storage pos) {
        pos = _positions[id];
        if (pos.pool == address(0)) revert UnknownPosition();
    }

    function _delete(uint256 id) internal {
        _removeId(id);
        delete _positions[id];
        delete _unplaced[id];
        delete keeperSwaps[id];
    }

    function _pairOf(uint256 id) internal view override returns (address, address) {
        return (_positions[id].token0, _positions[id].token1);
    }
}
