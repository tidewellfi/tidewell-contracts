// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {INonfungiblePositionManager, IUniswapV3Factory, IUniswapV3Pool} from "./interfaces/IUniswapV3.sol";
import {TidewellVaultBase} from "./TidewellVaultBase.sol";

interface IWETHWithdraw {
    function withdraw(uint256 amount) external;
}

interface ITidewellSwapperV3 {
    function swapToken(address tokenIn, address tokenOut, uint256 amountIn, bytes calldata route) external;
}

/// @title TidewellVaultV3
/// @notice One vault per user. Holds that user's Uniswap v3 positions and their fees. Only the owner can take
///         anything out. The keeper can only collect fees, reinvest and move a range, within the owner's settings and
///         the factory's limits, and everything it touches stays in this vault.
/// @dev Every token in this vault that is not inside a Uniswap position belongs to the owner and is "ready to claim".
///      There is no shared accounting between users, so one user's tokens can never affect another user.
contract TidewellVaultV3 is TidewellVaultBase {
    using SafeERC20 for IERC20;

    uint160 internal constant MIN_SQRT_RATIO = 4295128739;
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    struct Position {
        uint256 tokenId; // current Uniswap NFT; changes on every range move
        address pool;
        address token0;
        address token1;
        uint24 fee;
        int24 tickSpacing;
        uint32 lastMove;
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
        Settings settings;
    }

    mapping(uint256 id => Position) internal _positions;

    address internal transient _swapPool;

    event Opened(
        uint256 indexed id, uint256 tokenId, address pool, int24 tickLower, int24 tickUpper, uint256 amount0, uint256 amount1
    );
    event Added(uint256 indexed id, uint256 amount0, uint256 amount1);
    event Removed(uint256 indexed id, uint128 liquidity, uint256 amount0, uint256 amount1);

    error PriceOutOfBounds();

    // ---------------------------------------------------------------- views

    function getPosition(uint256 id) external view returns (Position memory) {
        return _positions[id];
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
        _checkSettings(p.settings, spacing);
        _checkRange(p.tickLower, p.tickUpper, spacing, p.settings);
    }

    function _open(OpenParams calldata p, address pool, int24 spacing, uint256 in0, uint256 in1)
        internal
        returns (uint256 id)
    {

        // Make sure the pool keeps enough price history for the keeper's price check.
        (,,,, uint16 cardinalityNext,,) = IUniswapV3Pool(pool).slot0();
        uint16 target = factory.cardinalityTarget();
        if (cardinalityNext < target) IUniswapV3Pool(pool).increaseObservationCardinalityNext(target);

        (uint256 tokenId, uint256 used0, uint256 used1) =
            _mint(p.token0, p.token1, p.fee, p.tickLower, p.tickUpper, in0, in1, p.amount0Min, p.amount1Min);

        id = ++nextPositionId;
        _positions[id] = Position({
            tokenId: tokenId,
            pool: pool,
            token0: p.token0,
            token1: p.token1,
            fee: p.fee,
            tickSpacing: spacing,
            lastMove: uint32(block.timestamp),
            settings: p.settings
        });
        _addId(id);

        _send(p.token0, in0 - used0);
        _send(p.token1, in1 - used1);
        emit Opened(id, tokenId, pool, p.tickLower, p.tickUpper, used0, used1);
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
        (uint256 used0, uint256 used1) = _increase(pos, in0, in1, amount0Min, amount1Min);
        _send(pos.token0, in0 - used0);
        _send(pos.token1, in1 - used1);
        emit Added(id, used0, used1);
    }

    function setSettings(uint256 id, Settings calldata s) external onlyOwner {
        Position storage pos = _get(id);
        _checkSettings(s, pos.tickSpacing);
        pos.settings = s;
        emit SettingsChanged(id, s);
    }

    // ---------------------------------------------------------------- owner: withdrawals (never paused)

    /// @notice Takes part of a position out and sends it to the owner. Earned fees stay ready to claim.
    function remove(uint256 id, uint128 liquidity, uint256 amount0Min, uint256 amount1Min) external onlyOwner nonReentrant {
        Position storage pos = _get(id);
        _collectFees(id, pos, false);
        (uint256 a0, uint256 a1) = _decrease(pos.tokenId, liquidity, amount0Min, amount1Min);
        _send(pos.token0, a0);
        _send(pos.token1, a1);
        emit Removed(id, liquidity, a0, a1);
    }

    /// @notice Closes a position and sends everything in both tokens to the owner, including unclaimed fees.
    function close(uint256 id, uint256 amount0Min, uint256 amount1Min) external onlyOwner nonReentrant {
        Position storage pos = _get(id);
        address t0 = pos.token0;
        address t1 = pos.token1;
        _collectFees(id, pos, false);
        uint128 liquidity = _liquidity(pos.tokenId);
        _decrease(pos.tokenId, liquidity, amount0Min, amount1Min);
        INonfungiblePositionManager(factory.positionManager()).burn(pos.tokenId);
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
        try this.settleFees(id) {} catch {}
        _delete(id);
        INonfungiblePositionManager(factory.positionManager()).safeTransferFrom(address(this), owner, tokenId);
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
        _compound(id, _get(id).settings.compoundBps, zeroForOne, amountIn, route);
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
        if (w > 0) IWETHWithdraw(weth).withdraw(w);
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
        address npm = factory.positionManager();
        IERC20(pos.token0).forceApprove(npm, r0);
        IERC20(pos.token1).forceApprove(npm, r1);
        uint256 used0;
        uint256 used1;
        try INonfungiblePositionManager(npm).increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: pos.tokenId,
                amount0Desired: r0,
                amount1Desired: r1,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        ) returns (uint128, uint256 a0, uint256 a1) {
            (used0, used1) = (a0, a1);
        } catch {}
        IERC20(pos.token0).forceApprove(npm, 0);
        IERC20(pos.token1).forceApprove(npm, 0);
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
        _checkRange(tickLower, tickUpper, pos.tickSpacing, pos.settings);
        (, int24 tick,,,,,) = IUniswapV3Pool(pos.pool).slot0();
        if (tick < tickLower || tick >= tickUpper) revert BadRange();

        (uint256 f0, uint256 f1) = _collectFees(id, pos, true);
        uint256 oldTokenId = pos.tokenId;
        (uint256 a0, uint256 a1) = _decrease(oldTokenId, _liquidity(oldTokenId), 0, 0);
        INonfungiblePositionManager(factory.positionManager()).burn(oldTokenId);
        // The position, the reinvested share of its fees, and what an earlier move could not place.
        (uint256 u0, uint256 u1) = _takeUnplaced(id);
        a0 += (f0 * pos.settings.compoundBps) / 10_000 + u0;
        a1 += (f1 * pos.settings.compoundBps) / 10_000 + u1;

        (a0, a1) = _swapToRatio(id, pos, zeroForOne, amountIn, a0, a1, route);

        (uint256 newTokenId, uint256 used0, uint256 used1) =
            _mint(pos.token0, pos.token1, pos.fee, tickLower, tickUpper, a0, a1, 0, 0);
        _setUnplaced(id, a0 - used0, a1 - used1);
        pos.tokenId = newTokenId;
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

    function _mint(
        address t0,
        address t1,
        uint24 fee,
        int24 tickLower,
        int24 tickUpper,
        uint256 a0,
        uint256 a1,
        uint256 min0,
        uint256 min1
    ) internal returns (uint256 tokenId, uint256 used0, uint256 used1) {
        address npm = factory.positionManager();
        IERC20(t0).forceApprove(npm, a0);
        IERC20(t1).forceApprove(npm, a1);
        (tokenId,, used0, used1) = INonfungiblePositionManager(npm).mint(
            INonfungiblePositionManager.MintParams({
                token0: t0,
                token1: t1,
                fee: fee,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: a0,
                amount1Desired: a1,
                amount0Min: min0,
                amount1Min: min1,
                recipient: address(this),
                deadline: block.timestamp
            })
        );
        IERC20(t0).forceApprove(npm, 0);
        IERC20(t1).forceApprove(npm, 0);
    }

    function _increase(Position storage pos, uint256 a0, uint256 a1, uint256 min0, uint256 min1)
        internal
        returns (uint256 used0, uint256 used1)
    {
        address npm = factory.positionManager();
        IERC20(pos.token0).forceApprove(npm, a0);
        IERC20(pos.token1).forceApprove(npm, a1);
        (, used0, used1) = INonfungiblePositionManager(npm).increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: pos.tokenId,
                amount0Desired: a0,
                amount1Desired: a1,
                amount0Min: min0,
                amount1Min: min1,
                deadline: block.timestamp
            })
        );
        IERC20(pos.token0).forceApprove(npm, 0);
        IERC20(pos.token1).forceApprove(npm, 0);
    }

    /// Removes liquidity and collects exactly the removed amounts into this vault.
    function _decrease(uint256 tokenId, uint128 liquidity, uint256 min0, uint256 min1)
        internal
        returns (uint256 a0, uint256 a1)
    {
        if (liquidity == 0) return (0, 0);
        INonfungiblePositionManager npm = INonfungiblePositionManager(factory.positionManager());
        (a0, a1) = npm.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidity,
                amount0Min: min0,
                amount1Min: min1,
                deadline: block.timestamp
            })
        );
        npm.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: uint128(a0),
                amount1Max: uint128(a1)
            })
        );
    }

    /// Collects earned fees into this vault and takes the protocol fee. Returns the fees after the protocol fee.
    /// @dev Must never be called while removed principal is still owed by the position manager: every _decrease()
    ///      collects its own amounts straight away, so what is owed here is always fees.
    function _collectFees(uint256 id, Position storage pos, bool strict) internal returns (uint256 f0, uint256 f1) {
        (uint256 c0, uint256 c1) = INonfungiblePositionManager(factory.positionManager()).collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: pos.tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
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
            ITidewellSwapperV3(sw).swapToken(tIn, tOut, amountIn, route);
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

    function _liquidity(uint256 tokenId) internal view returns (uint128 liquidity) {
        (,,,,,,, liquidity,,,,) = INonfungiblePositionManager(factory.positionManager()).positions(tokenId);
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
    }

    function _pairOf(uint256 id) internal view override returns (address, address) {
        return (_positions[id].token0, _positions[id].token1);
    }
}
