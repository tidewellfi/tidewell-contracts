// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

interface IKeeperSource {
    function keeper() external view returns (address);
}

/// Pons v2 launch factory, as deployed on Robinhood Chain.
interface IPonsLaunches {
    struct Launched {
        address token;
        address curve;
        address deployer;
        address creatorFeeRecipient;
        address pairToken;
        uint256 graduationThreshold;
        uint24 poolFee;
        int24 tickSpacing;
        uint16 creatorTaxBps;
        bool buybackEnabled;
        uint8 phase;
        uint256 sweptQuote;
        uint256 sweptTokens;
        uint256 sweptAt;
        bool exists;
    }

    function getLaunchedToken(address token) external view returns (Launched memory);
    function memeHook() external view returns (address);
}

/// Pons v2 bonding curve of one launch (TIDE trades here until it graduates).
interface IPonsCurve {
    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient) external payable returns (uint256 tokensOut);
    function getReserves() external view returns (uint256 quoteReserve, uint256 tokenReserve);
    function feeBps() external view returns (uint256);
    function creatorTaxBps() external view returns (uint256);
    function currentSnipeTaxBps(address recipient) external view returns (uint256);
    function graduated() external view returns (bool);
}

/// @title BuybackBurner
/// @notice Receives the buyback share of protocol revenue (35%) in ETH, buys TIDE with it and burns every TIDE it
///         buys. From the TIDE launch on: while TIDE trades on its Pons bonding curve, it buys on the curve (one buy
///         per `curveInterval`, 8 hours by default: three a day); the moment TIDE graduates it switches by itself to
///         the Uniswap v4 pool Pons created (one buy per `minInterval`). No owner action and no waiting period: the
///         keeper's regular call picks the right market. At most `maxPerBuy` ETH per buy, so the burn is steady.
/// @dev Same two-step price check as the vaults, on both markets: the keeper first records the price (poke), and
///      buys between 1 and 30 minutes later only if the price is still nearly the same, with a minimum amount of
///      TIDE worked out from that price. On the curve it never buys while the launch's anti-snipe tax applies. The
///      owner (the 48-hour timelock of the admin Safe) sets the limits; it cannot take the ETH out.
contract BuybackBurner is IUnlockCallback, Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint32 public constant POKE_MIN_AGE = 1 minutes;
    uint32 public constant POKE_MAX_AGE = 30 minutes;
    uint256 public constant MAX_SLIPPAGE_BPS = 500;
    int24 public constant MAX_TICK_DEVIATION = 300;

    IPoolManager public immutable poolManager;
    IKeeperSource public immutable keeperSource;

    PoolKey public poolKey;
    bool public poolSet;
    uint256 public maxPerBuy = 0.5 ether;
    uint32 public minInterval = 20 hours;
    uint256 public slippageBps = 200; // the pool's own fee comes on top
    int24 public maxTickDeviation = 100;

    uint32 public lastBuy;
    int24 public pokedTick;
    uint32 public pokedAt;
    /// Curve: one buy per this many seconds (at least two a day), and the most the price may move between the poke
    /// and the buy, in basis points.
    uint32 public curveInterval = 8 hours;
    uint256 public curveMaxMoveBps = 100;
    /// Curve price at the poke (quote reserve per token reserve, 1e18-scaled); 0 = the poke was on the pool.
    uint256 public pokedCurvePrice;

    /// Where TIDE's pool comes from: the Pons launch factory and the TIDE token, set once by the deployer.
    IPonsLaunches public ponsFactory;
    address public tide;

    uint256 public totalEthSpent;
    uint256 public totalBurned;

    bool internal transient _unlocking;

    event Poked(int24 tick);
    event PokedCurve(uint256 price);
    event BoughtAndBurnedOnCurve(uint256 ethIn, uint256 tideBurned);
    event CurveLimitsSet(uint32 curveInterval, uint256 curveMaxMoveBps);
    event BoughtAndBurned(uint256 ethIn, uint256 tideBurned);
    event PoolSet(PoolKey key);
    event PonsSourceSet(address ponsFactory, address tide);
    event LimitsSet(uint256 maxPerBuy, uint32 minInterval, uint256 slippageBps, int24 maxTickDeviation);

    error NotKeeper();
    error NoPool();
    error TooSoon();
    error NoPriceCheck();
    error PriceMoved(int24 tick, int24 pokedTick);
    error BadPool();
    error OutOfBounds();
    error BadSwap();
    error SnipeTax();
    error CurvePriceMoved(uint256 price, uint256 pokedPrice);

    constructor(address owner_, address poolManager_, address keeperSource_) Ownable(owner_) {
        poolManager = IPoolManager(poolManager_);
        keeperSource = IKeeperSource(keeperSource_);
    }

    receive() external payable {}

    modifier onlyKeeper() {
        if (msg.sender != keeperSource.keeper()) revert NotKeeper();
        _;
    }

    // ---------------------------------------------------------------- keeper

    /// @notice Where the next buy happens: 0 = nowhere yet, 1 = the Pons bonding curve, 2 = the Uniswap v4 pool.
    function market() public view returns (uint8) {
        if (poolSet) return 2;
        if (address(ponsFactory) == address(0)) return 0;
        IPonsLaunches.Launched memory l = ponsFactory.getLaunchedToken(tide);
        if (!l.exists || l.pairToken != address(0)) return 0;
        if (l.phase == 2) return 2; // PoolCreated: switched to by the next poke or buy
        if (l.phase == 0 && l.curve != address(0) && !IPonsCurve(l.curve).graduated()) return 1;
        return 0; // swept but no pool yet, or rescued: the ETH waits
    }

    /// @notice Seconds between buys on the market buys happen on now.
    function interval() public view returns (uint32) {
        return market() == 1 ? curveInterval : minInterval;
    }

    /// @notice Records the current TIDE price: step one of a buy.
    function poke() external onlyKeeper {
        uint8 m = _market();
        if (m == 0) revert NoPool();
        if (m == 1) {
            uint256 p = _curvePrice(_curve());
            pokedCurvePrice = p;
            pokedAt = uint32(block.timestamp);
            emit PokedCurve(p);
            return;
        }
        (, int24 tick,,) = poolManager.getSlot0(poolKey.toId());
        pokedTick = tick;
        pokedCurvePrice = 0;
        pokedAt = uint32(block.timestamp);
        emit Poked(tick);
    }

    /// @notice Buys TIDE with up to `maxPerBuy` ETH and burns all of it, on the curve or in the pool.
    function buyAndBurn() external onlyKeeper nonReentrant returns (uint256 ethIn, uint256 burned) {
        uint8 m = _market();
        if (m == 0) revert NoPool();
        if (block.timestamp < uint256(lastBuy) + (m == 1 ? curveInterval : minInterval)) revert TooSoon();
        if (
            pokedAt == 0 || block.timestamp < uint256(pokedAt) + POKE_MIN_AGE
                || block.timestamp > uint256(pokedAt) + POKE_MAX_AGE
        ) revert NoPriceCheck();
        // A poke on the other market (the switch happened in between) does not count.
        if ((m == 1) != (pokedCurvePrice != 0)) revert NoPriceCheck();
        pokedAt = 0;
        (ethIn, burned) = m == 1 ? _buyOnCurve() : _buyInPool();
        if (ethIn == 0) return (0, 0);
        IERC20(tide != address(0) ? tide : Currency.unwrap(poolKey.currency1)).safeTransfer(DEAD, burned);
        lastBuy = uint32(block.timestamp);
        totalEthSpent += ethIn;
        totalBurned += burned;
        if (m == 1) emit BoughtAndBurnedOnCurve(ethIn, burned);
        else emit BoughtAndBurned(ethIn, burned);
    }

    /// @dev market(), and when TIDE has just graduated: take the pool from Pons (once; no owner needed).
    function _market() internal returns (uint8 m) {
        m = market();
        if (m == 2 && !poolSet) {
            // The first buy in the new pool may follow right away, whenever the last curve buy was.
            lastBuy = 0;
            IPonsLaunches.Launched memory l = ponsFactory.getLaunchedToken(tide);
            _setPool(
                PoolKey(Currency.wrap(address(0)), Currency.wrap(tide), l.poolFee, l.tickSpacing, IHooks(ponsFactory.memeHook()))
            );
        }
    }

    function _curve() internal view returns (IPonsCurve) {
        return IPonsCurve(ponsFactory.getLaunchedToken(tide).curve);
    }

    function _curvePrice(IPonsCurve curve) internal view returns (uint256) {
        (uint256 q, uint256 t) = curve.getReserves();
        if (q == 0 || t == 0) revert BadPool();
        return Math.mulDiv(q, 1e18, t);
    }

    function _buyOnCurve() internal returns (uint256 ethIn, uint256 burned) {
        IPonsCurve curve = _curve();
        if (curve.currentSnipeTaxBps(address(this)) != 0) revert SnipeTax();
        uint256 p = _curvePrice(curve);
        uint256 p0 = pokedCurvePrice;
        uint256 moved = p > p0 ? p - p0 : p0 - p;
        if (moved * 10_000 > p0 * curveMaxMoveBps) revert CurvePriceMoved(p, p0);

        ethIn = address(this).balance;
        if (ethIn > maxPerBuy) ethIn = maxPerBuy;
        if (ethIn == 0) return (0, 0);

        // The least TIDE to accept: the curve's own formula at the poked price, after its fee and creator tax,
        // minus `slippageBps`.
        (uint256 q, uint256 t) = curve.getReserves();
        uint256 net = (ethIn * (10_000 - curve.feeBps() - curve.creatorTaxBps())) / 10_000;
        uint256 expected = Math.mulDiv(net, t, q + net);
        uint256 minOut = (expected * (10_000 - slippageBps)) / 10_000;

        IERC20 tideToken = IERC20(tide);
        uint256 ethBefore = address(this).balance;
        uint256 tideBefore = tideToken.balanceOf(address(this));
        curve.buy{value: ethIn}(ethIn, minOut, address(this));
        // A buy that completes the curve is filled only up to its end; the rest comes back to this contract.
        ethIn = ethBefore - address(this).balance;
        burned = tideToken.balanceOf(address(this)) - tideBefore;
        if (ethIn == 0 || burned == 0) revert BadSwap();
    }

    function _buyInPool() internal returns (uint256 ethIn, uint256 burned) {
        PoolKey memory key = poolKey;
        (uint160 sqrtP, int24 tick,, uint24 lpFee) = poolManager.getSlot0(key.toId());
        int24 d = tick > pokedTick ? tick - pokedTick : pokedTick - tick;
        if (d > maxTickDeviation) revert PriceMoved(tick, pokedTick);

        ethIn = address(this).balance;
        if (ethIn > maxPerBuy) ethIn = maxPerBuy;
        if (ethIn == 0) return (0, 0);

        // ETH is currency0, so buying TIDE moves the price down: limit it to `slippageBps`.
        uint256 factor = Math.sqrt((10_000 - slippageBps) * 1e14);
        uint256 limit = Math.mulDiv(sqrtP, factor, 1e9);
        if (limit <= TickMath.MIN_SQRT_PRICE) limit = TickMath.MIN_SQRT_PRICE + 1;

        IERC20 tideToken = IERC20(Currency.unwrap(key.currency1));
        uint256 ethBefore = address(this).balance;
        uint256 tideBefore = tideToken.balanceOf(address(this));
        _unlocking = true;
        poolManager.unlock(abi.encode(key, ethIn, uint160(limit)));
        _unlocking = false;
        ethIn = ethBefore - address(this).balance;
        burned = tideToken.balanceOf(address(this)) - tideBefore;
        if (ethIn == 0 || burned == 0) revert BadSwap();

        // Average price no worse than slippage plus the pool fee (and up to 2% for a hook's own fee).
        uint256 expected = Math.mulDiv(Math.mulDiv(ethIn, sqrtP, 1 << 96), sqrtP, 1 << 96);
        uint256 cost = slippageBps + lpFee / 100 + 200;
        if (burned * 10_000 < expected * (10_000 - cost)) revert BadSwap();
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager) || !_unlocking) revert NotKeeper();
        (PoolKey memory key, uint256 amountIn, uint160 limit) = abi.decode(data, (PoolKey, uint256, uint160));
        BalanceDelta delta = poolManager.swap(
            key, SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: limit}), ""
        );
        int128 pay = delta.amount0();
        int128 get = delta.amount1();
        if (pay < 0) poolManager.settle{value: uint256(uint128(-pay))}();
        if (get > 0) poolManager.take(key.currency1, address(this), uint256(uint128(get)));
        return "";
    }

    // ---------------------------------------------------------------- owner

    /// @notice TIDE's Pons launch, so the burner can buy on its curve and later find its pool (see market()). Once only,
    ///         and only before a pool is set: the deployer sets it right after the TIDE launch, before ownership goes
    ///         to the timelock.
    function setPonsSource(address ponsFactory_, address tide_) external onlyOwner {
        if (address(ponsFactory) != address(0) || poolSet) revert BadPool();
        if (ponsFactory_ == address(0) || tide_ == address(0)) revert BadPool();
        ponsFactory = IPonsLaunches(ponsFactory_);
        tide = tide_;
        emit PonsSourceSet(ponsFactory_, tide_);
    }

    /// @notice Sets the TIDE pool by hand (timelocked): native ETH against TIDE on Uniswap v4.
    function setPool(PoolKey calldata key) external onlyOwner {
        _setPool(key);
    }

    function _setPool(PoolKey memory key) internal {
        if (Currency.unwrap(key.currency0) != address(0) || Currency.unwrap(key.currency1) == address(0)) revert BadPool();
        (uint160 sqrtP,,,) = poolManager.getSlot0(key.toId());
        if (sqrtP == 0) revert BadPool();
        poolKey = key;
        poolSet = true;
        emit PoolSet(key);
    }

    function setCurveLimits(uint32 curveInterval_, uint256 curveMaxMoveBps_) external onlyOwner {
        // At least two buys a day; the price may move between 0.1% and 5% between poke and buy.
        if (curveInterval_ < 1 hours || curveInterval_ > 12 hours || curveMaxMoveBps_ < 10 || curveMaxMoveBps_ > 500) {
            revert OutOfBounds();
        }
        curveInterval = curveInterval_;
        curveMaxMoveBps = curveMaxMoveBps_;
        emit CurveLimitsSet(curveInterval_, curveMaxMoveBps_);
    }

    function setLimits(uint256 maxPerBuy_, uint32 minInterval_, uint256 slippageBps_, int24 maxTickDeviation_)
        external
        onlyOwner
    {
        if (
            maxPerBuy_ == 0 || minInterval_ < 1 hours || slippageBps_ == 0 || slippageBps_ > MAX_SLIPPAGE_BPS
                || maxTickDeviation_ <= 0 || maxTickDeviation_ > MAX_TICK_DEVIATION
        ) revert OutOfBounds();
        maxPerBuy = maxPerBuy_;
        minInterval = minInterval_;
        slippageBps = slippageBps_;
        maxTickDeviation = maxTickDeviation_;
        emit LimitsSet(maxPerBuy_, minInterval_, slippageBps_, maxTickDeviation_);
    }
}
