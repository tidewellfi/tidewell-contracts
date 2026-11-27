// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";
import {TidewellShapedBase} from "../TidewellShapedBase.sol";
import {TidewellBundleVault, ITidewellSwapperV4} from "./TidewellBundleVault.sol";

interface IBundleFactory {
    function vaultFor(address user) external returns (address);
    function vaultOf(address user, uint8 kind) external view returns (address);
    function swapper() external view returns (address);
    function feeRecipient() external view returns (address);
    function protocolFeeBps() external view returns (uint256);
    function keeper() external view returns (address);
    function paused() external view returns (bool);
    function poolManager() external view returns (address);
    function allowedHook(address hook) external view returns (bool);
    function maxSlippageBps() external view returns (uint256);
    function permit2() external view returns (address);
    function weth() external view returns (address);
}

interface IWETH9 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/// @title TidewellBundler
/// @notice LP Bundles: packages of 2 to 8 Tidewell positions in Uniswap v4 pools, opened, topped up, withdrawn and
///         claimed with one transaction in ETH or USDG.
///          - The registry: Tidewell's own bundles and those made by users. A bundle never changes after it is made:
///            its pools, weights, settings and balance rules are fixed (a maker who wants other settings makes a new
///            one). The owner and the maker can stop new deposits into a bundle; holders can always withdraw.
///          - Each wallet's positions sit in its own bundle vault (TidewellBundleVault), never with anyone else's.
///            This contract only passes through: the user's ETH or USDG comes in, is swapped through Tidewell's
///            swapper, put into the vault, and anything left over goes back to the user, all in the same
///            transaction. It never keeps tokens between transactions.
///          - Swaps for a deposit, withdrawal or claim pay 0.15%, always in ETH or USDG.
///          - The keeper may put a bundle back to its weights, at most once per the bundle's period, moving at most
///            half of a position per move, with swaps only in the bundle's own pools and at their checked prices (the
///            same price checks as for range moves). Value only ever moves between the vault's own positions.
/// @dev The owner is meant to be the 48-hour timelock of the admin Safe; it only marks bundles as Tidewell's own and
///      stops new deposits into a bundle that breaks the rules.
contract TidewellBundler is Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint8 internal constant KIND_V4 = 1;
    uint256 public constant MAX_LEGS = 8;
    uint256 public constant MIN_WEIGHT_BPS = 500; // every pool at least 5%
    /// A bundle counts as a TIDE bundle (lower fee) only with at least this much in a pool with TIDE.
    uint256 public constant MIN_TIDE_WEIGHT_BPS = 1000;
    uint16 public constant FEE_TIDE_BPS = 150; // 1.5% on earned fees in a bundle with a TIDE pool
    uint16 public constant FEE_TIDE_MAKER_BPS = 100; // 1% for its maker
    uint256 public constant SWAP_FEE_BPS = 15; // 0.15% of what is swapped into or out of ETH or USDG
    uint256 public constant SHARE_ALL = 1e18;
    /// The keeper moves at most this share of a position per move.
    uint256 public constant MAX_MOVE_SHARE = 0.5e18;
    uint16 public constant MAX_PERIOD_DAYS = 90;

    IBundleFactory public immutable factory;
    address public immutable usdg;
    address public immutable tide;
    address public immutable weth;

    struct Leg {
        PoolKey key;
        uint16 weightBps;
        uint8 shape;
        TidewellShapedBase.Settings settings;
    }

    /// Bundle balance: every `everyDays` days the keeper may put the bundle back to its weights when a pool is more
    /// than `driftPts` percentage points off (the drift is worked out by the keeper; this contract limits what it may do).
    struct Rules {
        bool rebalance;
        uint8 driftPts;
        uint16 everyDays;
    }

    struct Bundle {
        address maker;
        uint32 created;
        uint32 holders; // wallets other than the maker that hold it
        bool official; // a Tidewell bundle
        bool listed; // open for new deposits
        bool tide; // has a TIDE pool of at least MIN_TIDE_WEIGHT_BPS
        Rules rules;
    }

    struct Holding {
        uint32 lastRebalance;
        uint256[] ids; // position ids in the vault, in the order of the bundle's legs
    }

    /// One swap through Tidewell's swapper: in pool `key` (or along `route` through Uniswap's Universal Router),
    /// `amountIn` of the key's token0 (zeroForOne) or token1, for at least `minOut` of the other.
    struct Swap {
        PoolKey key;
        bool zeroForOne;
        uint256 amountIn;
        uint256 minOut;
        bytes route;
    }

    /// The user's part of a deposit into one leg: the range to open (ignored when adding to a position), the price the
    /// pool must be at, and the swaps from ETH or USDG into the pool's tokens.
    struct LegIn {
        int24 tickLower;
        int24 tickUpper;
        uint160 sqrtPriceMin;
        uint160 sqrtPriceMax;
        Swap[] swaps;
    }

    /// USDG through Permit2 (signature transfer, this contract as spender). An empty signature: a plain approval.
    struct PermitIn {
        uint256 nonce;
        uint256 deadline;
        bytes signature;
    }

    struct CompoundIn {
        uint160 sqrtPriceMin;
        uint160 sqrtPriceMax;
        bool zeroForOne;
        uint256 amountIn;
        bytes route;
    }

    /// A keeper move: `share` of the position of leg `from` goes to the position of leg `to`, with swaps in the
    /// bundle's own pools only (no routes), each at that pool's checked price.
    struct Move {
        uint8 from;
        uint8 to;
        uint256 share;
        Swap[] swaps;
    }

    uint256 public bundleCount;
    mapping(uint256 id => Bundle) public bundles;
    mapping(uint256 id => Leg[]) internal _legs;
    mapping(address vault => mapping(uint256 id => Holding)) internal _holdings;
    mapping(address vault => uint256[]) internal _held;

    /// The wallet this contract acts for in the current call; read by the vaults (IBundlerActing).
    address private transient _acting;

    event BundleCreated(uint256 indexed id, address indexed maker, bool official, bool tide);
    event Listed(uint256 indexed id, bool listed);
    event Opened(address indexed user, uint256 indexed id, address payToken, uint256 amount, uint256 swapFee);
    event Withdrawn(address indexed user, uint256 indexed id, uint256 share, address payToken, uint256 amountOut);
    event FeesClaimed(address indexed user, uint256 indexed id, bool asEth);
    event Rebalanced(address indexed vault, uint256 indexed id, uint256 moves);

    error BadBundle();
    error NotListed();
    error NotHeld();
    error BadAmount();
    error BadSwap();
    error TooLittle(uint256 out, uint256 min);
    error NotKeeper();
    error TooSoon();
    error Paused();
    error NotAllowed();
    error TransferFailed();

    constructor(address owner_, address factory_, address usdg_, address tide_) Ownable(owner_) {
        if (factory_ == address(0) || usdg_ == address(0)) revert BadBundle();
        factory = IBundleFactory(factory_);
        usdg = usdg_;
        tide = tide_;
        weth = IBundleFactory(factory_).weth();
    }

    receive() external payable {}

    // ---------------------------------------------------------------- views

    function actingFor() external view returns (address) {
        return _acting;
    }

    function legsOf(uint256 id) external view returns (Leg[] memory) {
        return _legs[id];
    }

    function holdingOf(address vault, uint256 id) external view returns (uint32 lastRebalance, uint256[] memory ids) {
        Holding storage h = _holdings[vault][id];
        return (h.lastRebalance, h.ids);
    }

    /// Bundles a vault holds (for the dashboard).
    function heldBy(address vault) external view returns (uint256[] memory) {
        return _held[vault];
    }

    /// The protocol fee a wallet's positions in a bundle pay on earned fees, before the staking discount.
    function feeFor(uint256 id, address user) public view returns (uint16) {
        Bundle storage b = bundles[id];
        if (!b.tide) return uint16(factory.protocolFeeBps());
        return user == b.maker ? FEE_TIDE_MAKER_BPS : FEE_TIDE_BPS;
    }

    // ---------------------------------------------------------------- registry

    /// @notice Makes a bundle. Anyone may; `official` (a Tidewell bundle) only the owner. It can never be changed.
    function create(Leg[] calldata legs, Rules calldata rules, bool official) external returns (uint256 id) {
        if (official && msg.sender != owner()) revert NotAllowed();
        uint256 n = legs.length;
        if (n < 2 || n > MAX_LEGS) revert BadBundle();
        if (rules.rebalance && (rules.everyDays == 0 || rules.everyDays > MAX_PERIOD_DAYS || rules.driftPts == 0 || rules.driftPts > 50)) {
            revert BadBundle();
        }
        IPoolManager pm = IPoolManager(factory.poolManager());
        uint256 total;
        uint256 tideW;
        id = ++bundleCount;
        for (uint256 i; i < n; ++i) {
            Leg calldata l = legs[i];
            if (l.weightBps < MIN_WEIGHT_BPS) revert BadBundle();
            total += l.weightBps;
            address c0 = Currency.unwrap(l.key.currency0);
            address c1 = Currency.unwrap(l.key.currency1);
            if (c0 >= c1) revert BadBundle();
            address h = address(l.key.hooks);
            if (h != address(0) && !factory.allowedHook(h)) revert BadBundle();
            (uint160 sqrtP,,,) = pm.getSlot0(l.key.toId());
            if (sqrtP == 0) revert BadBundle();
            if (l.settings.slippageBps == 0 || l.settings.slippageBps > factory.maxSlippageBps()) revert BadBundle();
            if (l.settings.compoundBps > 10_000 || l.settings.minWidth <= 0 || l.settings.maxWidth < l.settings.minWidth) {
                revert BadBundle();
            }
            PoolId pid = l.key.toId();
            for (uint256 j; j < i; ++j) {
                if (PoolId.unwrap(legs[j].key.toId()) == PoolId.unwrap(pid)) revert BadBundle();
            }
            if (tide != address(0) && (c0 == tide || c1 == tide)) tideW += l.weightBps;
            _legs[id].push(l);
        }
        if (total != 10_000) revert BadBundle();
        bool isTide = tideW >= MIN_TIDE_WEIGHT_BPS;
        bundles[id] = Bundle({
            maker: msg.sender,
            created: uint32(block.timestamp),
            holders: 0,
            official: official,
            listed: true,
            tide: isTide,
            rules: rules
        });
        emit BundleCreated(id, msg.sender, official, isTide);
    }

    /// @notice Opens or closes a bundle for new deposits. The maker for his own bundle, the owner for any.
    ///         Holders keep their positions and can always withdraw.
    function setListed(uint256 id, bool listed) external {
        Bundle storage b = bundles[id];
        if (b.maker == address(0)) revert BadBundle();
        if (msg.sender != owner() && msg.sender != b.maker) revert NotAllowed();
        b.listed = listed;
        emit Listed(id, listed);
    }

    // ---------------------------------------------------------------- user: deposit

    /// @notice Opens a bundle, or adds to it when the wallet already holds it, with ETH (sent along) or USDG (through
    ///         Permit2 or an approval). The amount is split by the bundle's weights; per leg the user's swaps turn
    ///         the leg's part into the pool's tokens, which go into the wallet's bundle vault. What is left over comes
    ///         back.
    function open(uint256 id, uint256 amount, LegIn[] calldata legs, PermitIn calldata permit)
        external
        payable
        nonReentrant
    {
        Bundle storage b = bundles[id];
        if (b.maker == address(0)) revert BadBundle();
        if (!b.listed) revert NotListed();
        Leg[] storage L = _legs[id];
        if (legs.length != L.length || amount == 0) revert BadAmount();
        bool payEth = msg.value > 0;
        if (payEth) {
            if (msg.value != amount) revert BadAmount();
        } else {
            _pullUsdg(amount, permit);
        }
        _acting = msg.sender;
        address vault = factory.vaultFor(msg.sender);
        Holding storage h = _holdings[vault][id];
        bool fresh = h.ids.length == 0;
        if (fresh) {
            _held[vault].push(id);
            if (msg.sender != b.maker) ++b.holders;
        }
        uint16 fee = feeFor(id, msg.sender);
        uint256 left = amount;
        uint256 swapFee;
        for (uint256 i; i < L.length; ++i) {
            uint256 budget = i + 1 == L.length ? left : (amount * L[i].weightBps) / 10_000;
            left -= budget;
            uint256 paid;
            (paid,) = _fundLeg(vault, h, L[i], legs[i], i, budget, payEth, fresh, fee);
            swapFee += paid;
        }
        _sweep(id, msg.sender, payEth);
        _acting = address(0);
        emit Opened(msg.sender, id, payEth ? address(0) : usdg, amount, swapFee);
    }

    /// Turns `budget` of the pay token into one leg's tokens and puts them into the vault. Returns the swap fee paid.
    function _fundLeg(
        address vault,
        Holding storage h,
        Leg storage leg,
        LegIn calldata li,
        uint256 i,
        uint256 budget,
        bool payEth,
        bool fresh,
        uint16 fee
    ) internal returns (uint256 swapFee, uint256 spent) {
        address c0 = Currency.unwrap(leg.key.currency0);
        address c1 = Currency.unwrap(leg.key.currency1);
        bool pay0 = _isPay(c0, payEth);
        bool pay1 = _isPay(c1, payEth);
        uint256 payBefore = _payBalance(payEth);
        uint256 b0 = pay0 ? 0 : _bal(c0);
        uint256 b1 = pay1 ? 0 : _bal(c1);
        for (uint256 k; k < li.swaps.length; ++k) {
            Swap calldata s = li.swaps[k];
            address tin = Currency.unwrap(s.zeroForOne ? s.key.currency0 : s.key.currency1);
            if (_isPay(tin, payEth)) swapFee += _takeSwapFee(payEth, s.amountIn);
            _swap(s, 0);
        }
        spent = payBefore - _payBalance(payEth);
        if (spent > budget) revert BadAmount();
        uint256 rest = budget - spent;
        uint256 a0 = pay0 ? rest : _bal(c0) - b0;
        uint256 a1 = pay1 ? rest : _bal(c1) - b1;
        if (pay0 && pay1) revert BadBundle();
        if (a0 == 0 && a1 == 0) revert BadAmount();
        // The pay token's part is its native or wrapped form, whichever the pool uses.
        if (a0 > 0) _need(c0, a0);
        if (a1 > 0) _need(c1, a1);
        uint256 value = c0 == address(0) ? a0 : 0;
        if (c0 != address(0) && a0 > 0) IERC20(c0).safeTransfer(vault, a0);
        if (a1 > 0) IERC20(c1).safeTransfer(vault, a1);
        if (fresh) {
            TidewellBundleVault.OpenParams memory p = TidewellBundleVault.OpenParams({
                key: leg.key,
                tickLower: li.tickLower,
                tickUpper: li.tickUpper,
                amount0: a0,
                amount1: a1,
                sqrtPriceMin: li.sqrtPriceMin,
                sqrtPriceMax: li.sqrtPriceMax,
                shape: leg.shape,
                settings: leg.settings
            });
            h.ids.push(TidewellBundleVault(payable(vault)).openFor{value: value}(p, fee));
        } else {
            TidewellBundleVault(payable(vault)).addFor{value: value}(h.ids[i], a0, a1, li.sqrtPriceMin, li.sqrtPriceMax);
        }
    }

    // ---------------------------------------------------------------- user: withdraw, claim, compound

    /// @notice Takes `share` of every position of a bundle out (1e18 = all: the bundle is closed), swaps it with
    ///         `swaps` to ETH (toEth) or USDG and sends that to the wallet, at least `minOut`. Anything the swaps did not
    ///         turn into it is sent as it is. Never paused. Earned fees stay ready to claim.
    function withdraw(uint256 id, uint256 share, Swap[] calldata swaps, bool toEth, uint256 minOut)
        external
        nonReentrant
    {
        if (share == 0 || share > SHARE_ALL) revert BadAmount();
        address vault = factory.vaultOf(msg.sender, KIND_V4);
        Holding storage h = _holdings[vault][id];
        uint256 n = h.ids.length;
        if (n == 0) revert NotHeld();
        _acting = msg.sender;
        for (uint256 i; i < n; ++i) {
            TidewellBundleVault(payable(vault)).takeOut(h.ids[i], share);
        }
        if (share == SHARE_ALL) _drop(vault, id, msg.sender);
        uint256 out = _swapOut(swaps, toEth);
        if (out < minOut) revert TooLittle(out, minOut);
        _sweep(id, msg.sender, toEth);
        _acting = address(0);
        emit Withdrawn(msg.sender, id, share, toEth ? address(0) : usdg, out);
    }

    /// @notice Collects the earned fees of a bundle's positions and sends everything ready to claim in its pools'
    ///         tokens to the wallet; with toEth, first swapped to ETH with `swaps` (at least `minOut`). `keepWei` of
    ///         ETH stays in the vault for the keeper's gas. Never paused.
    function claim(uint256 id, Swap[] calldata swaps, bool toEth, uint256 minOut, uint256 keepWei)
        external
        nonReentrant
    {
        address vault = factory.vaultOf(msg.sender, KIND_V4);
        Holding storage h = _holdings[vault][id];
        uint256 n = h.ids.length;
        if (n == 0) revert NotHeld();
        _acting = msg.sender;
        TidewellBundleVault v = TidewellBundleVault(payable(vault));
        Leg[] storage L = _legs[id];
        for (uint256 i; i < n; ++i) {
            v.collect(h.ids[i]);
        }
        for (uint256 i; i < L.length; ++i) {
            _takeReady(v, Currency.unwrap(L[i].key.currency0), keepWei);
            _takeReady(v, Currency.unwrap(L[i].key.currency1), keepWei);
        }
        uint256 out = _swapOut(swaps, toEth);
        if (out < minOut) revert TooLittle(out, minOut);
        _sweep(id, msg.sender, toEth);
        _acting = address(0);
        emit FeesClaimed(msg.sender, id, toEth);
    }

    /// @notice Reinvests every position's fees now (the vault's compoundNow for each position, in leg order).
    function compound(uint256 id, CompoundIn[] calldata c) external nonReentrant {
        address vault = factory.vaultOf(msg.sender, KIND_V4);
        Holding storage h = _holdings[vault][id];
        uint256 n = h.ids.length;
        if (n == 0 || c.length != n) revert NotHeld();
        _acting = msg.sender;
        for (uint256 i; i < n; ++i) {
            TidewellBundleVault(payable(vault)).compoundNow(
                h.ids[i], c[i].sqrtPriceMin, c[i].sqrtPriceMax, c[i].zeroForOne, c[i].amountIn, c[i].route
            );
        }
        _acting = address(0);
    }

    // ---------------------------------------------------------------- keeper: bundle balance

    /// @notice Puts a bundle back towards its weights by moving value between the vault's own positions. The keeper
    ///         works out the drift; this contract only allows it once per the bundle's period, at most half of a
    ///         position per move, with swaps only in the bundle's own pools and at their checked prices.
    function rebalance(address vault, uint256 id, Move[] calldata moves) external nonReentrant {
        if (msg.sender != factory.keeper()) revert NotKeeper();
        if (factory.paused()) revert Paused();
        Bundle storage b = bundles[id];
        if (!b.rules.rebalance) revert NotAllowed();
        Holding storage h = _holdings[vault][id];
        uint256 n = h.ids.length;
        if (n == 0) revert NotHeld();
        if (block.timestamp < uint256(h.lastRebalance) + uint256(b.rules.everyDays) * 1 days) revert TooSoon();
        if (moves.length == 0 || moves.length > n) revert BadAmount();
        h.lastRebalance = uint32(block.timestamp);
        address user = TidewellBundleVault(payable(vault)).owner();
        _acting = user;
        Leg[] storage L = _legs[id];
        // Checked prices, once per position (Chainlink, or the keeper's recorded price).
        uint160[] memory price = new uint160[](n);
        // A position either gives or receives in one rebalance, never both: value cannot go back and forth.
        uint8[] memory role = new uint8[](n); // 1 gives, 2 receives
        for (uint256 m; m < moves.length; ++m) {
            Move calldata mv = moves[m];
            if (mv.from >= n || mv.to >= n || mv.from == mv.to) revert BadAmount();
            if (mv.share == 0 || mv.share > MAX_MOVE_SHARE) revert BadAmount();
            if (role[mv.from] == 2 || role[mv.to] == 1) revert BadAmount();
            (role[mv.from], role[mv.to]) = (1, 2);
        }
        for (uint256 m; m < moves.length; ++m) {
            _move(vault, h, L, moves[m], price);
        }
        // Anything left over goes back to the vault (ready to claim).
        for (uint256 i; i < n; ++i) {
            _back(vault, Currency.unwrap(L[i].key.currency0));
            _back(vault, Currency.unwrap(L[i].key.currency1));
        }
        _acting = address(0);
        emit Rebalanced(vault, id, moves.length);
    }

    function _move(address vault, Holding storage h, Leg[] storage L, Move calldata mv, uint160[] memory price)
        internal
    {
        TidewellBundleVault v = TidewellBundleVault(payable(vault));
        v.takeOut(h.ids[mv.from], mv.share);
        for (uint256 k; k < mv.swaps.length; ++k) {
            Swap calldata s = mv.swaps[k];
            if (s.route.length > 0) revert BadSwap();
            uint256 leg = _legOf(L, s.key);
            _checkedSwap(s, _price(v, h, price, leg), L[leg].settings.slippageBps);
        }
        PoolKey storage kt = L[mv.to].key;
        address c0 = Currency.unwrap(kt.currency0);
        address c1 = Currency.unwrap(kt.currency1);
        uint256 a0 = _bal(c0);
        uint256 a1 = _bal(c1);
        if (a0 == 0 && a1 == 0) return;
        if (c0 != address(0) && a0 > 0) IERC20(c0).safeTransfer(vault, a0);
        if (a1 > 0) IERC20(c1).safeTransfer(vault, a1);
        // The price may have moved by the move's own swap in that pool, within its slippage setting.
        uint256 slipTo = L[mv.to].settings.slippageBps;
        uint160 p = _price(v, h, price, mv.to);
        uint160 lo = uint160(Math.mulDiv(p, Math.sqrt((10_000 - slipTo) * 1e14), 1e9));
        uint160 hi = uint160(Math.mulDiv(p, Math.sqrt((10_000 + slipTo) * 1e14), 1e9));
        v.addFor{value: c0 == address(0) ? a0 : 0}(h.ids[mv.to], a0, a1, lo, hi);
    }

    /// The checked price of a leg's pool, read once per rebalance (it uses up the keeper's recorded price).
    function _price(TidewellBundleVault v, Holding storage h, uint160[] memory price, uint256 leg)
        internal
        returns (uint160)
    {
        if (price[leg] == 0) price[leg] = v.checkedPrice(h.ids[leg]);
        return price[leg];
    }

    /// The leg whose pool `key` is; reverts for a pool outside the bundle.
    function _legOf(Leg[] storage L, PoolKey calldata key) internal view returns (uint256) {
        bytes32 id = PoolId.unwrap(key.toId());
        for (uint256 i; i < L.length; ++i) {
            if (PoolId.unwrap(L[i].key.toId()) == id) return i;
        }
        revert BadSwap();
    }

    /// A keeper swap in one of the bundle's pools, at most the slippage setting plus the pool fee worse than the
    /// checked price (as the vaults check their own swaps).
    function _checkedSwap(Swap calldata s, uint160 sqrtP, uint256 slip) internal {
        uint256 cap = factory.maxSlippageBps();
        if (slip > cap) slip = cap;
        (,,, uint24 lpFee) = IPoolManager(factory.poolManager()).getSlot0(s.key.toId());
        uint256 factor = Math.sqrt((s.zeroForOne ? 10_000 - slip : 10_000 + slip) * 1e14);
        uint256 l = Math.mulDiv(sqrtP, factor, 1e9);
        if (s.zeroForOne && l <= TickMath.MIN_SQRT_PRICE) l = TickMath.MIN_SQRT_PRICE + 1;
        if (!s.zeroForOne && l >= TickMath.MAX_SQRT_PRICE) l = TickMath.MAX_SQRT_PRICE - 1;
        (uint256 spent, uint256 got) = _swap(s, uint160(l));
        uint256 expected = s.zeroForOne
            ? Math.mulDiv(Math.mulDiv(spent, sqrtP, 1 << 96), sqrtP, 1 << 96)
            : Math.mulDiv(Math.mulDiv(spent, 1 << 96, sqrtP), 1 << 96, sqrtP);
        if (got * 10_000 < expected * (10_000 - slip - lpFee / 100)) revert BadSwap();
    }

    // ---------------------------------------------------------------- owner

    /// @notice Recovers tokens sent to this contract by mistake (it never keeps any of its own between transactions).
    function rescueTokens(address token, address to) external onlyOwner {
        uint256 amount = _bal(token);
        if (token == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    // ---------------------------------------------------------------- internals

    function _pullUsdg(uint256 amount, PermitIn calldata permit) internal {
        if (permit.signature.length == 0) {
            IERC20(usdg).safeTransferFrom(msg.sender, address(this), amount);
            return;
        }
        ISignatureTransfer(factory.permit2()).permitTransferFrom(
            ISignatureTransfer.PermitTransferFrom({
                permitted: ISignatureTransfer.TokenPermissions({token: usdg, amount: amount}),
                nonce: permit.nonce,
                deadline: permit.deadline
            }),
            ISignatureTransfer.SignatureTransferDetails({to: address(this), requestedAmount: amount}),
            msg.sender,
            permit.signature
        );
    }

    /// A swap through the swapper; `limit` zero means no price limit (the caller checks minOut or the price).
    function _swap(Swap calldata s, uint160 limit) internal returns (uint256 spent, uint256 got) {
        address tin = Currency.unwrap(s.zeroForOne ? s.key.currency0 : s.key.currency1);
        address tout = Currency.unwrap(s.zeroForOne ? s.key.currency1 : s.key.currency0);
        if (s.amountIn == 0) revert BadSwap();
        _need(tin, s.amountIn);
        if (limit == 0) limit = s.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        uint256 inBefore = _bal(tin);
        uint256 outBefore = _bal(tout);
        address sw = factory.swapper();
        if (tin != address(0)) IERC20(tin).safeTransfer(sw, s.amountIn);
        ITidewellSwapperV4(sw).swap{value: tin == address(0) ? s.amountIn : 0}(
            s.key, s.zeroForOne, s.amountIn, limit, s.route
        );
        spent = inBefore - _bal(tin);
        got = _bal(tout) - outBefore;
        if (spent == 0 || spent > s.amountIn || got < s.minOut) revert BadSwap();
    }

    /// Runs the swaps of a withdrawal or claim and takes the 0.15% swap fee from what they turned into the pay token.
    /// Returns everything of the pay token there is now (to be sent to the user).
    function _swapOut(Swap[] calldata swaps, bool toEth) internal returns (uint256) {
        uint256 before = _payBalance(toEth);
        for (uint256 k; k < swaps.length; ++k) {
            _swap(swaps[k], 0);
        }
        uint256 after_ = _payBalance(toEth);
        if (after_ > before) _takeSwapFee(toEth, after_ - before);
        return _payBalance(toEth);
    }

    function _takeSwapFee(bool payEth, uint256 swapped) internal returns (uint256 fee) {
        fee = (swapped * SWAP_FEE_BPS) / 10_000;
        if (fee == 0) return 0;
        address to = factory.feeRecipient();
        if (payEth) {
            _need(address(0), fee);
            (bool ok,) = to.call{value: fee}("");
            if (!ok) revert TransferFailed();
        } else {
            IERC20(usdg).safeTransfer(to, fee);
        }
    }

    function _takeReady(TidewellBundleVault v, address token, uint256 keepWei) internal {
        if (token == address(0) || token == weth) {
            uint256 ready = v.takeReady(token, 0);
            // Gas money for the keeper stays in the vault (in ETH or WETH, whichever this was).
            uint256 keep = keepWei < ready ? keepWei : ready;
            if (keep > 0) _sendTo(token, address(v), keep);
        } else {
            v.takeReady(token, 0);
        }
    }

    /// Sends everything this contract holds of the bundle's tokens and the pay token to `to`. ETH and WETH go as ETH
    /// when paying in ETH. Called at the end of every user action, so nothing stays here.
    function _sweep(uint256 id, address to, bool payEth) internal {
        Leg[] storage L = _legs[id];
        if (payEth) {
            uint256 w = _bal(weth);
            if (w > 0) IWETH9(weth).withdraw(w);
        }
        _sendTo(address(0), to, address(this).balance);
        _sendTo(weth, to, _bal(weth));
        _sendTo(usdg, to, _bal(usdg));
        for (uint256 i; i < L.length; ++i) {
            _sendTo(Currency.unwrap(L[i].key.currency0), to, _bal(Currency.unwrap(L[i].key.currency0)));
            _sendTo(Currency.unwrap(L[i].key.currency1), to, _bal(Currency.unwrap(L[i].key.currency1)));
        }
    }

    function _back(address vault, address token) internal {
        _sendTo(token, vault, _bal(token));
    }

    function _drop(address vault, uint256 id, address user) internal {
        delete _holdings[vault][id];
        uint256[] storage list = _held[vault];
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == id) {
                list[i] = list[list.length - 1];
                list.pop();
                break;
            }
        }
        Bundle storage b = bundles[id];
        if (user != b.maker && b.holders > 0) --b.holders;
    }

    function _isPay(address t, bool payEth) internal view returns (bool) {
        return payEth ? (t == address(0) || t == weth) : t == usdg;
    }

    function _payBalance(bool payEth) internal view returns (uint256) {
        return payEth ? address(this).balance + _bal(weth) : _bal(usdg);
    }

    /// Makes sure `amount` of `token` is here in the form asked: ETH and WETH are wrapped or unwrapped as needed.
    function _need(address token, uint256 amount) internal {
        if (token == weth) {
            uint256 have = _bal(weth);
            if (have < amount) IWETH9(weth).deposit{value: amount - have}();
        } else if (token == address(0)) {
            uint256 have = address(this).balance;
            if (have < amount) IWETH9(weth).withdraw(amount - have);
        }
    }

    function _bal(address token) internal view returns (uint256) {
        return token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
    }

    function _sendTo(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (token == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }
}
