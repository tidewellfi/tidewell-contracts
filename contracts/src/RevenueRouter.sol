// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IRevenueSink} from "./interfaces/ITidewell.sol";
import {IUniswapV3Factory, IUniswapV3Pool} from "./interfaces/IUniswapV3.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

interface IReferrals {
    function referrerOf(address user) external view returns (address);
}

interface IVaultCheck {
    function isVault(address vault) external view returns (bool);
}

interface ITidewellChecks {
    function keeper() external view returns (address);
    function uniswapFactory() external view returns (address);
    function weth() external view returns (address);
    function checkOracle(address t0, address t1, uint160 sqrtPriceX96) external view returns (bool);
    function checkPrice(address pool) external view;
    function poolManager() external view returns (address);
    function allowedHook(address hook) external view returns (bool);
}

interface IWETH9 {
    function withdraw(uint256 amount) external;
}

/// Pons v2 contracts, as deployed on Robinhood Chain.
interface IPonsFeeEscrow {
    function claim() external returns (uint256);
    function claimToken(address token) external returns (uint256);
    function balanceOf(address recipient) external view returns (uint256);
    function balanceOfToken(address recipient, address token) external view returns (uint256);
}

interface IPonsHook {
    function sweepPoolFees(bytes32 poolId, uint256 minConversionQuoteOut, uint256 minBuybackTokensOut) external;
}

interface IPonsLaunchFactory {
    function transferCreatorFeeRecipient(address token, address newRecipient) external;
}

/// @title RevenueRouter
/// @notice Receives all protocol revenue: the protocol fee from every vault and the creator fees of the TIDE pool on
///         Pons. Pays the referral share first, then splits the rest: rewards reserve for staking (30%) and boosted
///         pools (5%), buyback and burn (35%), safety fund (15%) and team and development (15%). TIDE that arrives
///         here is burned directly.
///         Everything is paid out in ETH: the keeper converts other tokens (mostly USDG) to ETH first, through the
///         token's Uniswap v3 pool with WETH, checked against Chainlink or the pool's own average price.
/// @dev The owner is the 48-hour timelock of the admin Safe. It can change the destinations and the split within hard
///      limits, never take money out for itself. Revenue is kept per token; address zero is ETH.
contract RevenueRouter is IRevenueSink, IUnlockCallback, Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant MAX_REF_SHARE_BPS = 3000;
    uint256 public constant MAX_TEAM_BPS = 2000;

    IReferrals public immutable referrals;
    ITidewellChecks public immutable checks; // the vault factory: keeper, price checks, Uniswap v3, WETH
    uint256 public constant MAX_CONVERT_SLIPPAGE_BPS = 300;
    uint256 public convertSlippageBps = 100;

    // ---------------------------------------------------------------- settings
    uint256 public refShareBps = 2000; // 20% of the protocol fee of invited users

    struct Split {
        uint16 staking;
        uint16 boosts;
        uint16 burn;
        uint16 safety;
        uint16 team;
    }

    Split public split = Split({staking: 3000, boosts: 500, burn: 3500, safety: 1500, team: 1500});

    address public stakingReserve; // The Well
    address public boostReserve;
    address public burner;
    address public safetyFund;
    address public team; // Team Safe

    mapping(address factory => bool) public isFactory;

    // Pons
    address public ponsEscrow;
    address public ponsHook;
    address public ponsFactory;
    address public tide;
    /// Locked reserve for expanding to other chains: pays out only through the 48-hour timelock, never by a swap.
    address public expansionReserve;
    /// TIDE that arrives as revenue (creator fees): the same 35% is burned as from ETH revenue, half is kept for
    /// expansion to other chains, and the rest goes to the rewards pot of the boosted pools.
    uint16 public constant TIDE_BURN_BPS = 3500;
    uint16 public constant TIDE_EXPANSION_BPS = 5000;

    /// The dollar stablecoin used as stepping stone: token -> USDG (Uniswap v4) -> ETH (Uniswap v3).
    address public usdg;
    uint24 public usdgWethFee = 500;

    // ---------------------------------------------------------------- accounting
    /// Revenue per token waiting to be split.
    mapping(address token => uint256) public pending;
    /// Referral rewards per referrer and token, ready to claim.
    mapping(address referrer => mapping(address token => uint256)) public referralOwed;
    /// Referral rewards not yet converted to ETH, per token.
    mapping(address token => uint256) public referralTotal;
    /// Referral amounts already converted, and the ETH they became, per original token.
    mapping(address token => uint256) public referralConverted;
    mapping(address token => uint256) public referralEth;

    uint256 public referralEthTotal;
    address internal transient _swapPool;
    bool internal transient _unlocking;

    event ProtocolFee(address indexed user, address indexed token, uint256 amount, address referrer, uint256 referral);
    event OtherRevenue(address indexed token, uint256 amount);
    event Distributed(address indexed token, uint256 amount, Split split);
    event Burned(address indexed token, uint256 amount);
    event TideSplit(uint256 burned, uint256 toExpansion, uint256 toBoosts);
    event ExpansionReserveSet(address reserve);
    event ReferralClaimed(address indexed referrer, address indexed token, uint256 amount);
    event DestinationsSet(address stakingReserve, address boostReserve, address burner, address safetyFund, address team);
    event SplitSet(Split split);
    event RefShareSet(uint256 bps);
    event FactorySet(address factory, bool allowed);
    event PonsSet(address escrow, address hook, address factory, address tide);
    event Converted(address indexed token, uint256 amountIn, uint256 ethOut);
    event ConvertSlippageSet(uint256 bps);

    error NotVault();
    error ZeroAddress();
    error OutOfBounds();
    error Unbacked();
    error TransferFailed();
    error NotKeeper();
    error UnknownPool();
    error BadSwap();
    error NoPriceCheck();

    constructor(
        address owner_,
        address referrals_,
        address factory_,
        address stakingReserve_,
        address boostReserve_,
        address burner_,
        address safetyFund_,
        address team_
    ) Ownable(owner_) {
        if (referrals_ == address(0) || factory_ == address(0)) revert ZeroAddress();
        referrals = IReferrals(referrals_);
        checks = ITidewellChecks(factory_);
        _addFactory(factory_);
        _setDestinations(stakingReserve_, boostReserve_, burner_, safetyFund_, team_);
    }

    receive() external payable {}

    // ---------------------------------------------------------------- income

    /// @inheritdoc IRevenueSink
    function onProtocolFee(address user, address token, uint256 amount) external nonReentrant {
        if (!_isVault(msg.sender)) revert NotVault();
        address ref = referrals.referrerOf(user);
        uint256 r;
        if (ref != address(0)) {
            r = (amount * refShareBps) / 10_000;
            referralOwed[ref][token] += r;
            referralTotal[token] += r;
        }
        pending[token] += amount - r;
        // The vault sends the fee before calling, so the balance must cover everything booked.
        if (_balance(token) < _booked(token)) revert Unbacked();
        emit ProtocolFee(user, token, amount, ref, r);
    }

    /// @notice Books anything that arrived without a vault call (Pons fees, direct payments) as revenue to split.
    function sync(address token) public nonReentrant returns (uint256 extra) {
        extra = _balance(token) - _booked(token);
        if (extra > 0) {
            pending[token] += extra;
            emit OtherRevenue(token, extra);
        }
    }

    // ---------------------------------------------------------------- Pons (TIDE creator fees)

    /// @notice Claims the TIDE pool's creator fees from Pons into this contract. Anyone may call it.
    function claimPons(address token) external returns (uint256 extra) {
        IPonsFeeEscrow escrow = IPonsFeeEscrow(ponsEscrow);
        // The escrow reverts when there is nothing to claim, so check first.
        if (token == address(0)) {
            if (escrow.balanceOf(address(this)) > 0) escrow.claim();
        } else {
            if (escrow.balanceOfToken(address(this), token) > 0) escrow.claimToken(token);
        }
        extra = sync(token);
    }

    /// @notice Moves pending fees of the graduated TIDE pool into the Pons escrow, so they can be claimed.
    /// @dev Pons only lets the fee recipient do this when no internal swap is needed.
    function sweepPons(bytes32 poolId) external {
        IPonsHook(ponsHook).sweepPoolFees(poolId, 0, 0);
    }

    /// @notice Hands the TIDE creator fees to a new recipient, for example a new version of this contract.
    function transferPonsRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert ZeroAddress();
        IPonsLaunchFactory(ponsFactory).transferCreatorFeeRecipient(tide, newRecipient);
    }

    // ---------------------------------------------------------------- outgoing

    /// @notice Splits the pending revenue of one token over the destinations. Anyone may call it. TIDE is split
    ///         35% burned, 50% to the expansion reserve and 15% to the boosted-pools reserve; ETH by `split`.
    function distribute(address token) external nonReentrant {
        uint256 amount = pending[token];
        if (amount == 0) return;
        if (token != address(0) && token == tide) {
            if (expansionReserve == address(0)) revert ZeroAddress();
            pending[token] = 0;
            uint256 toBurn = (amount * TIDE_BURN_BPS) / 10_000;
            uint256 toExpansion = (amount * TIDE_EXPANSION_BPS) / 10_000;
            uint256 toBoosts = amount - toBurn - toExpansion;
            _send(token, DEAD, toBurn);
            _send(token, expansionReserve, toExpansion);
            _send(token, boostReserve, toBoosts);
            emit Burned(token, toBurn);
            emit TideSplit(toBurn, toExpansion, toBoosts);
            return;
        }
        pending[token] = 0;
        if (token != address(0)) revert UnknownPool(); // convert to ETH first
        Split memory s = split;
        uint256 toStaking = (amount * s.staking) / 10_000;
        uint256 toBoosts = (amount * s.boosts) / 10_000;
        uint256 toBurn = (amount * s.burn) / 10_000;
        uint256 toSafety = (amount * s.safety) / 10_000;
        uint256 toTeam = amount - toStaking - toBoosts - toBurn - toSafety;
        _send(token, stakingReserve, toStaking);
        _send(token, boostReserve, toBoosts);
        _send(token, burner, toBurn);
        _send(token, safetyFund, toSafety);
        _send(token, team, toTeam);
        emit Distributed(token, amount, s);
    }

    /// @notice Sends the caller's referral rewards in ETH. `tokens` lists the tokens the rewards were earned in
    ///         (address zero for ETH); rewards earned in other tokens become claimable once they are converted.
    function claimReferral(address[] calldata tokens) external nonReentrant returns (uint256 eth) {
        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i];
            uint256 owed = referralOwed[msg.sender][token];
            if (owed == 0) continue;
            if (token == address(0)) {
                referralOwed[msg.sender][token] = 0;
                referralTotal[token] -= owed;
                eth += owed;
                emit ReferralClaimed(msg.sender, token, owed);
                continue;
            }
            uint256 units = owed < referralConverted[token] ? owed : referralConverted[token];
            if (units == 0) continue;
            uint256 out = Math.mulDiv(units, referralEth[token], referralConverted[token]);
            referralOwed[msg.sender][token] = owed - units;
            referralConverted[token] -= units;
            referralEth[token] -= out;
            referralEthTotal -= out;
            eth += out;
            emit ReferralClaimed(msg.sender, token, units);
        }
        _send(address(0), msg.sender, eth);
    }

    /// @notice Referral rewards of `referrer` in ETH that can be claimed now, for one source token.
    function claimableReferral(address referrer, address token) external view returns (uint256) {
        uint256 owed = referralOwed[referrer][token];
        if (token == address(0)) return owed;
        uint256 units = owed < referralConverted[token] ? owed : referralConverted[token];
        return units == 0 ? 0 : Math.mulDiv(units, referralEth[token], referralConverted[token]);
    }

    // ---------------------------------------------------------------- conversion to ETH (keeper)

    /// @notice Converts everything booked in `token` (revenue and referral rewards) to ETH. WETH is unwrapped;
    ///         other tokens are swapped in their Uniswap v3 pool with WETH of the given fee tier.
    function convert(address token, uint24 poolFee) external nonReentrant returns (uint256 ethOut) {
        if (msg.sender != checks.keeper()) revert NotKeeper();
        if (token == address(0) || token == tide) revert UnknownPool();
        uint256 amountIn = pending[token] + referralTotal[token];
        if (amountIn == 0) return 0;
        address weth = checks.weth();
        uint256 used = amountIn;
        if (token == weth) {
            ethOut = amountIn;
        } else {
            (used, ethOut) = _swapToWeth(token, weth, poolFee, amountIn);
        }
        IWETH9(weth).withdraw(ethOut);
        _bookConversion(token, amountIn, used, ethOut);
    }

    /// @notice Converts a token whose market is on Uniswap v4 (for example a Stock Token paired with USDG) to ETH.
    ///         `key` is the token's pool with native ETH or with USDG; from USDG the route continues through USDG's
    ///         Uniswap v3 pool with WETH. The v4 price must match Chainlink, so this only runs while the token's
    ///         feed is fresh (for Stock Tokens: on trading days).
    function convertV4(address token, PoolKey calldata key) external nonReentrant returns (uint256 ethOut) {
        if (msg.sender != checks.keeper()) revert NotKeeper();
        if (token == address(0) || token == tide || token == checks.weth()) revert UnknownPool();
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        address other = c0 == token ? c1 : c0;
        if ((c0 != token && c1 != token) || (other != address(0) && other != usdg)) revert UnknownPool();
        if (address(key.hooks) != address(0) && !checks.allowedHook(address(key.hooks))) revert UnknownPool();
        IPoolManager pm = IPoolManager(checks.poolManager());
        (uint160 sqrtP,,, uint24 lpFee) = pm.getSlot0(key.toId());
        if (sqrtP == 0) revert UnknownPool();
        if (!checks.checkOracle(c0, c1, sqrtP)) revert NoPriceCheck();

        uint256 amountIn = pending[token] + referralTotal[token];
        if (amountIn == 0) return 0;
        bool zeroForOne = c0 == token;
        uint256 slip = convertSlippageBps;
        uint256 factor = Math.sqrt((zeroForOne ? 10_000 - slip : 10_000 + slip) * 1e14);
        uint256 limit = Math.mulDiv(sqrtP, factor, 1e9);
        if (zeroForOne && limit <= TickMath.MIN_SQRT_PRICE) limit = TickMath.MIN_SQRT_PRICE + 1;
        if (!zeroForOne && limit >= TickMath.MAX_SQRT_PRICE) limit = TickMath.MAX_SQRT_PRICE - 1;

        uint256 tokenBefore = _balance(token);
        uint256 otherBefore = _balance(other);
        _unlocking = true;
        pm.unlock(abi.encode(key, zeroForOne, amountIn, uint160(limit)));
        _unlocking = false;
        uint256 used = tokenBefore - _balance(token);
        uint256 got = _balance(other) - otherBefore;
        uint256 expected = zeroForOne
            ? Math.mulDiv(Math.mulDiv(used, sqrtP, 1 << 96), sqrtP, 1 << 96)
            : Math.mulDiv(Math.mulDiv(used, 1 << 96, sqrtP), 1 << 96, sqrtP);
        if (used == 0 || got * 10_000 < expected * (10_000 - slip - lpFee / 100 - 200)) revert BadSwap();

        if (other == address(0)) {
            ethOut = got;
        } else {
            // Second hop: USDG to WETH on Uniswap v3, then unwrap.
            address weth = checks.weth();
            (uint256 usdgUsed, uint256 wethOut) = _swapToWeth(usdg, weth, usdgWethFee, got);
            if (usdgUsed != got) revert BadSwap();
            IWETH9(weth).withdraw(wethOut);
            ethOut = wethOut;
        }
        _bookConversion(token, amountIn, used, ethOut);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        IPoolManager pm = IPoolManager(checks.poolManager());
        if (msg.sender != address(pm) || !_unlocking) revert BadSwap();
        (PoolKey memory key, bool zeroForOne, uint256 amountIn, uint160 limit) =
            abi.decode(data, (PoolKey, bool, uint256, uint160));
        BalanceDelta delta = pm.swap(
            key, SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: limit}), ""
        );
        (Currency payC, Currency getC) = zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        int128 pay = zeroForOne ? delta.amount0() : delta.amount1();
        int128 get = zeroForOne ? delta.amount1() : delta.amount0();
        if (pay < 0) {
            pm.sync(payC);
            IERC20(Currency.unwrap(payC)).safeTransfer(address(pm), uint256(uint128(-pay)));
            pm.settle();
        }
        if (get > 0) pm.take(getC, address(this), uint256(uint128(get)));
        return "";
    }

    /// Splits converted ETH between revenue and referral rewards in proportion to what was converted.
    function _bookConversion(address token, uint256 amountIn, uint256 used, uint256 ethOut) internal {
        uint256 refUnits = Math.mulDiv(referralTotal[token], used, amountIn);
        uint256 refEth = used == 0 ? 0 : Math.mulDiv(ethOut, refUnits, used);
        uint256 revUnits = used - refUnits;
        pending[token] -= revUnits;
        referralTotal[token] -= refUnits;
        referralConverted[token] += refUnits;
        referralEth[token] += refEth;
        referralEthTotal += refEth;
        pending[address(0)] += ethOut - refEth;
        emit Converted(token, used, ethOut);
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        if (msg.sender != _swapPool || _swapPool == address(0)) revert BadSwap();
        address tokenIn = abi.decode(data, (address));
        uint256 owed = uint256(amount0Delta > 0 ? amount0Delta : amount1Delta);
        IERC20(tokenIn).safeTransfer(msg.sender, owed);
    }

    function _swapToWeth(address token, address weth, uint24 poolFee, uint256 amountIn)
        internal
        returns (uint256 spent, uint256 got)
    {
        address pool = IUniswapV3Factory(checks.uniswapFactory()).getPool(token, weth, poolFee);
        if (pool == address(0)) revert UnknownPool();
        (uint160 sqrtP,,,,,,) = IUniswapV3Pool(pool).slot0();
        bool zeroForOne = token < weth;
        (address t0, address t1) = zeroForOne ? (token, weth) : (weth, token);
        if (!checks.checkOracle(t0, t1, sqrtP)) checks.checkPrice(pool); // reverts on a bad price

        uint256 slip = convertSlippageBps;
        uint256 factor = Math.sqrt((zeroForOne ? 10_000 - slip : 10_000 + slip) * 1e14);
        uint160 limit = uint160(Math.mulDiv(sqrtP, factor, 1e9));
        _swapPool = pool;
        (int256 d0, int256 d1) = IUniswapV3Pool(pool).swap(address(this), zeroForOne, int256(amountIn), limit, abi.encode(token));
        _swapPool = address(0);
        spent = uint256(zeroForOne ? d0 : d1);
        got = uint256(-(zeroForOne ? d1 : d0));
        uint256 expected = zeroForOne
            ? Math.mulDiv(Math.mulDiv(spent, sqrtP, 1 << 96), sqrtP, 1 << 96)
            : Math.mulDiv(Math.mulDiv(spent, 1 << 96, sqrtP), 1 << 96, sqrtP);
        if (spent == 0 || got * 10_000 < expected * (10_000 - slip - poolFee / 100)) revert BadSwap();
    }

    // ---------------------------------------------------------------- owner (timelocked)

    function setDestinations(address staking_, address boosts_, address burner_, address safety_, address team_)
        external
        onlyOwner
    {
        _setDestinations(staking_, boosts_, burner_, safety_, team_);
    }

    function setSplit(Split calldata s) external onlyOwner {
        if (uint256(s.staking) + s.boosts + s.burn + s.safety + s.team != 10_000 || s.team > MAX_TEAM_BPS) {
            revert OutOfBounds();
        }
        split = s;
        emit SplitSet(s);
    }

    function setUsdg(address usdg_, uint24 usdgWethFee_) external onlyOwner {
        usdg = usdg_;
        usdgWethFee = usdgWethFee_;
    }

    function setConvertSlippage(uint256 bps) external onlyOwner {
        if (bps == 0 || bps > MAX_CONVERT_SLIPPAGE_BPS) revert OutOfBounds();
        convertSlippageBps = bps;
        emit ConvertSlippageSet(bps);
    }

    function setRefShare(uint256 bps) external onlyOwner {
        if (bps > MAX_REF_SHARE_BPS) revert OutOfBounds();
        refShareBps = bps;
        emit RefShareSet(bps);
    }

    /// A new factory version must be added here before its vaults can report fees.
    function setFactory(address factory_, bool allowed) external onlyOwner {
        if (allowed) _addFactory(factory_);
        else isFactory[factory_] = false;
        emit FactorySet(factory_, allowed);
    }

    function setExpansionReserve(address reserve) external onlyOwner {
        if (reserve == address(0)) revert ZeroAddress();
        expansionReserve = reserve;
        emit ExpansionReserveSet(reserve);
    }

    function setPons(address escrow, address hook, address launchFactory, address tide_) external onlyOwner {
        ponsEscrow = escrow;
        ponsHook = hook;
        ponsFactory = launchFactory;
        tide = tide_;
        emit PonsSet(escrow, hook, launchFactory, tide_);
    }

    // ---------------------------------------------------------------- internals

    address[] private _factories;

    function _addFactory(address f) internal {
        if (f == address(0)) revert ZeroAddress();
        if (!isFactory[f]) {
            bool listed;
            for (uint256 i; i < _factories.length; ++i) {
                if (_factories[i] == f) listed = true;
            }
            if (!listed) _factories.push(f);
            isFactory[f] = true;
        }
    }

    function _isVault(address v) internal view returns (bool) {
        // Every factory that was ever added is asked; there will only be a few.
        for (uint256 i; i < _factories.length; ++i) {
            address f = _factories[i];
            if (isFactory[f] && IVaultCheck(f).isVault(v)) return true;
        }
        return false;
    }

    function _setDestinations(address a, address b, address c, address d, address e) internal {
        if (a == address(0) || b == address(0) || c == address(0) || d == address(0) || e == address(0)) {
            revert ZeroAddress();
        }
        stakingReserve = a;
        boostReserve = b;
        burner = c;
        safetyFund = d;
        team = e;
        emit DestinationsSet(a, b, c, d, e);
    }

    /// Everything this contract owes, in one token: revenue to split, unconverted referral rewards, and (for ETH)
    /// the ETH that converted referral rewards became.
    function _booked(address token) internal view returns (uint256 total) {
        total = pending[token] + referralTotal[token];
        if (token == address(0)) {
            // Converted referral ETH is tracked per source token; add it up through the running total.
            total += referralEthTotal;
        }
    }

    function _balance(address token) internal view returns (uint256) {
        return token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
    }

    function _send(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (token == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }
}
