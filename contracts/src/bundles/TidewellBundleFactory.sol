// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IUniswapV3Pool} from "../interfaces/IUniswapV3.sol";
import {AggregatorV3Interface} from "../interfaces/ITidewell.sol";

interface IBundleVaultInit {
    function initialize(address owner_) external;
}


/// @title TidewellBundleFactory
/// @notice The factory of the LP Bundles vaults: one bundle vault per user (Uniswap v4 only), created by the bundler
///         (TidewellBundler) the first time a wallet opens a bundle, plus the shared rules: keeper, fees, limits and
///         price checks. The same rules and hard limits as TidewellFactory; the bundles get their own factory because
///         vaults cannot be upgraded and bundle positions need their own vault (fee per position, the bundler).
/// @dev The owner is meant to be a 48-hour TimelockController controlled by the admin Safe. The guardian (the admin
///      Safe itself) can only pause and unpause. Every setting has a hard limit in this contract, so even the owner
///      cannot set abusive values. Vaults are not upgradeable: a new version is a new factory.
contract TidewellBundleFactory is Ownable2Step {
    // ---------------------------------------------------------------- hard limits
    uint256 public constant MAX_PROTOCOL_FEE_BPS = 1000; // 10% of earned fees
    uint256 public constant MAX_DISCOUNT_BPS = 5000; // 50% off the protocol fee
    uint256 public constant MAX_SLIPPAGE_CAP_BPS = 500; // 5%
    uint256 public constant MAX_PRICE_DEVIATION_BPS = 500; // 5%
    int24 public constant MAX_TICK_DEVIATION_CAP = 500; // about 5%
    uint256 public constant MAX_REFUND_CAP = 0.002 ether;
    uint32 public constant MIN_COOLDOWN_FLOOR = 5 minutes;

    // ---------------------------------------------------------------- immutables
    uint8 public constant KIND_V3 = 0;
    uint8 public constant KIND_V4 = 1;

    address public immutable implementationV3;
    /// The bundle vault code for new vaults. The owner can set a new version for vaults made after that (until LP
    /// Bundles launch: the deploy wallet; then the 48-hour timelock). Existing vaults never change.
    address public implementationV4;
    address public immutable positionManager; // Uniswap v3 NonfungiblePositionManager
    address public immutable uniswapFactory; // Uniswap v3 factory
    address public immutable poolManager; // Uniswap v4 PoolManager
    address public immutable positionManagerV4; // Uniswap v4 PositionManager
    address public immutable permit2;
    address public immutable weth;

    // ---------------------------------------------------------------- settings
    address public keeper;
    address public guardian;
    bool public paused;

    address public feeRecipient;
    uint256 public protocolFeeBps = 200; // 2% of earned fees
    address public feeDiscount;

    uint256 public maxSlippageBps = 500; // 5%: memecoins cost a few percent to trade (pool fees, hook fees)
    uint256 public maxPriceDeviationBps = 150; // pool vs Chainlink
    int24 public maxTickDeviation = 150; // pool vs its own average, about 1.5%
    uint32 public minCooldown = 30 minutes;
    uint16 public cardinalityTarget = 100;

    uint256 public maxGasPrice = 1 gwei;
    uint256 public maxRefundWei = 0.0005 ether;
    uint256 public refundOverheadGas = 60_000;

    /// While false, only tokens with a cap may be deposited (guarded launch).
    bool public openMode;

    /// TidewellBundler: opens, adds to and takes out of bundle vaults for their owner, and may use the swapper.
    address public bundler;
    /// Maximum raw amount of a token per deposit. Zero means: no cap in open mode, not allowed in guarded mode.
    mapping(address token => uint256) public tokenCap;

    struct Feed {
        address feed;
        uint32 maxAge;
    }

    mapping(address token => Feed) public feeds;

    /// Uniswap v4 hooks that have been reviewed. Pools without a hook are always allowed.
    mapping(address hook => bool) public allowedHook;

    /// The pool vaults swap in for a pair (kind 0 = Uniswap v3: fee only; 1 = v4: fee, spacing, hook), usually the
    /// deepest one. Unset (spacing 0, or fee 0 for v3): a position swaps in its own pool. Every swap must still give
    /// the position pool's price minus the slippage setting, so a bad choice can only make swaps revert.
    struct SwapPool {
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    mapping(uint8 kind => mapping(address t0 => mapping(address t1 => SwapPool))) public swapPool;
    /// Does the Uniswap v4 swaps of the vaults (TidewellSwapper).
    address public swapper;

    /// Which token the protocol fee is taken in: the side with the higher rank. ETH = 2, dollar stablecoins = 1.
    mapping(address token => uint8) public feeRank;

    mapping(address user => mapping(uint8 kind => address)) public vaultOf;
    mapping(address vault => bool) internal _isVault;

    // ---------------------------------------------------------------- events
    event VaultCreated(address indexed user, uint8 kind, address vault);
    event HookAllowed(address indexed hook, bool allowed);
    event SwapperSet(address swapper);
    event SwapPoolSet(uint8 kind, address indexed t0, address indexed t1, uint24 fee, int24 tickSpacing, address hooks);
    event FeeRankSet(address indexed token, uint8 rank);
    event KeeperSet(address keeper);
    event GuardianSet(address guardian);
    event Paused(bool paused);
    event FeeSet(address recipient, uint256 bps, address discount);
    event LimitsSet(uint256 maxSlippageBps, uint256 maxPriceDeviationBps, int24 maxTickDeviation, uint32 minCooldown);
    event GasRefundSet(uint256 maxGasPrice, uint256 maxRefundWei, uint256 overheadGas);
    event CardinalityTargetSet(uint16 target);
    event OpenModeSet(bool open);
    event TokenCapSet(address indexed token, uint256 cap);
    event FeedSet(address indexed token, address feed, uint32 maxAge);
    event BundlerSet(address bundler);
    event ImplementationSet(address implementation);

    error NotGuardian();
    error NotKeeper();
    error ZeroAddress();
    error OutOfBounds();
    error TokenNotAllowed(address token);
    error AboveCap(address token, uint256 amount, uint256 cap);
    error PriceDeviation(uint256 poolPrice, uint256 oraclePrice);
    error TickDeviation(int24 tick, int24 averageTick);
    error NoPriceCheck();
    error BadKind();
    error NotBundler();

    struct Addresses {
        address implementationV3;
        address implementationV4;
        address positionManager;
        address uniswapFactory;
        address poolManager;
        address positionManagerV4;
        address permit2;
        address weth;
    }

    constructor(address owner_, Addresses memory a, address keeper_, address guardian_, address feeRecipient_)
        Ownable(owner_)
    {
        if (
            a.implementationV3 == address(0) || a.implementationV4 == address(0) || a.positionManager == address(0)
                || a.uniswapFactory == address(0) || a.poolManager == address(0) || a.positionManagerV4 == address(0)
                || a.permit2 == address(0) || a.weth == address(0) || keeper_ == address(0) || guardian_ == address(0)
                || feeRecipient_ == address(0)
        ) revert ZeroAddress();
        implementationV3 = a.implementationV3;
        implementationV4 = a.implementationV4;
        positionManager = a.positionManager;
        uniswapFactory = a.uniswapFactory;
        poolManager = a.poolManager;
        positionManagerV4 = a.positionManagerV4;
        permit2 = a.permit2;
        weth = a.weth;
        keeper = keeper_;
        guardian = guardian_;
        feeRecipient = feeRecipient_;
        feeRank[address(0)] = 2; // native ETH
        feeRank[a.weth] = 2;
    }

    // ---------------------------------------------------------------- vaults

    /// @notice The bundle vault of `user`, created when it does not exist yet. Only the bundler, which only ever
    ///         asks for the vault of the wallet that sends the transaction.
    function vaultFor(address user) external returns (address vault) {
        if (msg.sender != bundler || bundler == address(0)) revert NotBundler();
        vault = vaultOf[user][KIND_V4];
        if (vault != address(0)) return vault;
        vault = Clones.cloneDeterministic(implementationV4, _salt(user, KIND_V4));
        IBundleVaultInit(vault).initialize(user);
        vaultOf[user][KIND_V4] = vault;
        _isVault[vault] = true;
        emit VaultCreated(user, KIND_V4, vault);
    }

    /// @notice Vaults of this factory, and the bundler: both may use the swapper. The RevenueRouter also uses this to
    ///         accept fee reports, which only vaults send.
    function isVault(address a) external view returns (bool) {
        return _isVault[a] || (a == bundler && a != address(0));
    }

    function predictVault(address user, uint8 kind) external view returns (address) {
        return Clones.predictDeterministicAddress(_impl(kind), _salt(user, kind));
    }

    function _impl(uint8 kind) internal view returns (address) {
        if (kind == KIND_V4) return implementationV4;
        revert BadKind();
    }

    function _salt(address user, uint8 kind) internal pure returns (bytes32) {
        return keccak256(abi.encode(user, kind));
    }

    // ---------------------------------------------------------------- checks used by vaults

    function checkDeposit(address token, uint256 amount) external view {
        uint256 cap = tokenCap[token];
        if (cap == 0) {
            if (!openMode) revert TokenNotAllowed(token);
            return;
        }
        if (amount > cap) revert AboveCap(token, amount, cap);
    }

    /// @notice Reverts unless the pool price looks right. Uses Chainlink when both tokens have a fresh feed, and the
    ///         pool's own time-weighted average otherwise.
    function checkPrice(address pool) external view {
        IUniswapV3Pool p = IUniswapV3Pool(pool);
        (uint160 sqrtPriceX96, int24 tick,,,,,) = p.slot0();
        address t0 = p.token0();
        address t1 = p.token1();

        if (checkOracle(t0, t1, sqrtPriceX96)) return;
        int24 avg = _averageTick(p);
        int24 d = tick > avg ? tick - avg : avg - tick;
        if (d > maxTickDeviation) revert TickDeviation(tick, avg);
    }

    /// @notice Compares a pool price with Chainlink. Returns false when there is no usable feed for both tokens, and
    ///         reverts when the feeds disagree with the pool. Address zero (native ETH) uses the WETH feed.
    function checkOracle(address t0, address t1, uint160 sqrtPriceX96) public view returns (bool) {
        (bool ok, uint256 oraclePrice) = _oraclePrice(t0, t1);
        if (!ok) return false;
        // Pool price of token0 in token1, raw units, 1e18 fixed point.
        uint256 poolPrice = Math.mulDiv(Math.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 96), 1e18, 1 << 96);
        if (poolPrice == 0) return false;
        uint256 diff = poolPrice > oraclePrice ? poolPrice - oraclePrice : oraclePrice - poolPrice;
        if (diff * 10_000 > oraclePrice * maxPriceDeviationBps) revert PriceDeviation(poolPrice, oraclePrice);
        return true;
    }

    function _oraclePrice(address t0, address t1) internal view returns (bool, uint256) {
        if (t0 == address(0)) t0 = weth;
        if (t1 == address(0)) t1 = weth;
        (bool ok0, uint256 p0) = _feedPrice(t0);
        if (!ok0) return (false, 0);
        (bool ok1, uint256 p1) = _feedPrice(t1);
        if (!ok1) return (false, 0);
        uint256 d0 = 10 ** IERC20Metadata(t0).decimals();
        uint256 d1 = 10 ** IERC20Metadata(t1).decimals();
        // token1 per token0 in raw units = p0 * 10^dec1 / (p1 * 10^dec0), as 1e18 fixed point.
        return (true, Math.mulDiv(p0 * d1, 1e18, p1 * d0));
    }

    /// Price in USD with 18 decimals, or (false, 0) when there is no feed or it is stale or broken.
    function _feedPrice(address token) internal view returns (bool, uint256) {
        Feed memory f = feeds[token];
        if (f.feed == address(0)) return (false, 0);
        try AggregatorV3Interface(f.feed).latestRoundData() returns (
            uint80, int256 answer, uint256, uint256 updatedAt, uint80
        ) {
            if (answer <= 0 || updatedAt + f.maxAge < block.timestamp) return (false, 0);
            uint8 dec = AggregatorV3Interface(f.feed).decimals();
            return (true, uint256(answer) * 10 ** (18 - dec));
        } catch {
            return (false, 0);
        }
    }

    /// Average tick over the longest of 10, 2 or 0.5 minutes that the pool has history for.
    function _averageTick(IUniswapV3Pool p) internal view returns (int24) {
        uint32[3] memory windows = [uint32(600), 120, 30];
        for (uint256 i; i < 3; ++i) {
            uint32[] memory ago = new uint32[](2);
            ago[0] = windows[i];
            try p.observe(ago) returns (int56[] memory cum, uint160[] memory) {
                int56 delta = cum[1] - cum[0];
                int24 avg = int24(delta / int56(uint56(windows[i])));
                if (delta < 0 && (delta % int56(uint56(windows[i])) != 0)) avg--;
                return avg;
            } catch {}
        }
        revert NoPriceCheck();
    }

    // ---------------------------------------------------------------- guardian

    function setPaused(bool paused_) external {
        if (msg.sender != guardian && msg.sender != owner()) revert NotGuardian();
        paused = paused_;
        emit Paused(paused_);
    }

    // ---------------------------------------------------------------- owner (timelocked)

    function setKeeper(address keeper_) external onlyOwner {
        if (keeper_ == address(0)) revert ZeroAddress();
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    function setGuardian(address guardian_) external onlyOwner {
        if (guardian_ == address(0)) revert ZeroAddress();
        guardian = guardian_;
        emit GuardianSet(guardian_);
    }

    function setImplementation(address implementation_) external onlyOwner {
        if (implementation_ == address(0)) revert ZeroAddress();
        implementationV4 = implementation_;
        emit ImplementationSet(implementation_);
    }

    function setBundler(address bundler_) external onlyOwner {
        if (bundler_ == address(0)) revert ZeroAddress();
        bundler = bundler_;
        emit BundlerSet(bundler_);
    }

    function setFee(address recipient, uint256 bps, address discount) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        if (bps > MAX_PROTOCOL_FEE_BPS) revert OutOfBounds();
        feeRecipient = recipient;
        protocolFeeBps = bps;
        feeDiscount = discount;
        emit FeeSet(recipient, bps, discount);
    }

    function setLimits(uint256 slippageBps, uint256 priceDeviationBps, int24 tickDeviation, uint32 cooldown)
        external
        onlyOwner
    {
        if (
            slippageBps == 0 || slippageBps > MAX_SLIPPAGE_CAP_BPS || priceDeviationBps == 0
                || priceDeviationBps > MAX_PRICE_DEVIATION_BPS || tickDeviation <= 0
                || tickDeviation > MAX_TICK_DEVIATION_CAP || cooldown < MIN_COOLDOWN_FLOOR
        ) revert OutOfBounds();
        maxSlippageBps = slippageBps;
        maxPriceDeviationBps = priceDeviationBps;
        maxTickDeviation = tickDeviation;
        minCooldown = cooldown;
        emit LimitsSet(slippageBps, priceDeviationBps, tickDeviation, cooldown);
    }

    function setGasRefund(uint256 gasPrice, uint256 refundWei, uint256 overheadGas) external onlyOwner {
        if (refundWei > MAX_REFUND_CAP || overheadGas > 200_000) revert OutOfBounds();
        maxGasPrice = gasPrice;
        maxRefundWei = refundWei;
        refundOverheadGas = overheadGas;
        emit GasRefundSet(gasPrice, refundWei, overheadGas);
    }

    function setCardinalityTarget(uint16 target) external onlyOwner {
        if (target > 1000) revert OutOfBounds();
        cardinalityTarget = target;
        emit CardinalityTargetSet(target);
    }

    function setOpenMode(bool open) external onlyOwner {
        openMode = open;
        emit OpenModeSet(open);
    }

    function setTokenCap(address token, uint256 cap) external onlyOwner {
        tokenCap[token] = cap;
        emit TokenCapSet(token, cap);
    }

    function setFeeRank(address token, uint8 rank) external onlyOwner {
        if (rank > 2) revert OutOfBounds();
        feeRank[token] = rank;
        emit FeeRankSet(token, rank);
    }

    function setSwapper(address swapper_) external onlyOwner {
        if (swapper_ == address(0)) revert ZeroAddress();
        swapper = swapper_;
        emit SwapperSet(swapper_);
    }

    /// @notice Sets the pool vaults swap in for a pair. The keeper picks the deepest pool; the owner can too.
    function setSwapPool(uint8 kind, address t0, address t1, uint24 fee, int24 tickSpacing, address hooks) external {
        if (msg.sender != keeper && msg.sender != owner()) revert NotKeeper();
        swapPool[kind][t0][t1] = SwapPool(fee, tickSpacing, hooks);
        emit SwapPoolSet(kind, t0, t1, fee, tickSpacing, hooks);
    }

    function setHookAllowed(address hook, bool allowed) external onlyOwner {
        allowedHook[hook] = allowed;
        emit HookAllowed(hook, allowed);
    }

    function setFeed(address token, address feed, uint32 maxAge) external onlyOwner {
        feeds[token] = Feed(feed, maxAge);
        emit FeedSet(token, feed, maxAge);
    }
}
