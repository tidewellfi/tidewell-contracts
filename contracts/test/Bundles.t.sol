// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";
import {TidewellFactory} from "../src/TidewellFactory.sol";
import {TidewellSwapper} from "../src/TidewellSwapper.sol";
import {TidewellShapedBase} from "../src/TidewellShapedBase.sol";
import {TidewellVaultV3} from "../src/TidewellVaultV3.sol";
import {TidewellShapedVaultV4} from "../src/TidewellShapedVaultV4.sol";
import {TidewellBundleFactory} from "../src/bundles/TidewellBundleFactory.sol";
import {TidewellBundleVault} from "../src/bundles/TidewellBundleVault.sol";
import {TidewellBundler} from "../src/bundles/TidewellBundler.sol";
import {IPositionManagerV4S} from "../src/libraries/ShapesV4.sol";
import {MockERC20, MockSink, MockRouter, MockWETH, MockDiscount} from "./mocks/Mocks.t.sol";
import {V4TraderS} from "./ShapedV4.t.sol";

interface IPermit2Domain {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

/// LP Bundles against the real Uniswap v4 PoolManager, PositionManager and Permit2.
contract BundlesTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    IPoolManager pm;
    address posm;
    address permit2;
    MockWETH weth;
    MockERC20 usdg; // 6 decimals
    MockERC20 tsla; // 18
    MockERC20 tide; // 18
    MockSink sink;
    V4TraderS trader;
    MockRouter mockRouter;

    TidewellBundleFactory factory;
    TidewellBundler bundler;

    PoolKey ethKey; // ETH / USDG 0.05%
    PoolKey tslaKey; // TSLA / USDG 0.3%
    PoolKey tideKey; // ETH / TIDE 1%

    address user = makeAddr("user");
    address maker = makeAddr("maker");
    address whale = makeAddr("whale");
    address keeper = makeAddr("keeper");
    address guardian = makeAddr("guardian");
    address stranger = makeAddr("stranger");

    uint256 plainId; // ETH 50 / TSLA 50, by Tidewell
    uint256 tideId; // ETH 45 / TSLA 45 / TIDE 10, by `maker`

    function setUp() public {
        vm.warp(1_800_000_000);
        pm = IPoolManager(deployCode("out/PoolManager.sol/PoolManager.json", abi.encode(address(this))));
        permit2 = deployCode("out/Permit2.sol/Permit2.json");
        weth = new MockWETH();
        vm.deal(address(weth), 100_000 ether);
        usdg = new MockERC20("USDG", 6);
        tsla = new MockERC20("TSLA", 18);
        tide = new MockERC20("TIDE", 18);
        posm = deployCode(
            "out/PositionManager.sol/PositionManager.json",
            abi.encode(address(pm), permit2, uint256(300_000), address(0), address(weth))
        );
        sink = new MockSink();
        mockRouter = new MockRouter(permit2);

        address impl = address(new TidewellBundleVault());
        factory = new TidewellBundleFactory(
            address(this),
            TidewellBundleFactory.Addresses({
                implementationV3: impl,
                implementationV4: impl,
                positionManager: address(0xdead),
                uniswapFactory: address(0xdead),
                poolManager: address(pm),
                positionManagerV4: posm,
                permit2: permit2,
                weth: address(weth)
            }),
            keeper,
            guardian,
            address(sink)
        );
        factory.setOpenMode(true);
        factory.setSwapper(address(new TidewellSwapper(address(factory), address(pm), permit2, address(mockRouter))));
        bundler = new TidewellBundler(address(this), address(factory), address(usdg), address(tide));
        factory.setBundler(address(bundler));

        ethKey = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(usdg)), 500, 10, IHooks(address(0)));
        pm.initialize(ethKey, _sqrt(2500e6, 1e18));
        (address a, address b) = address(tsla) < address(usdg) ? (address(tsla), address(usdg)) : (address(usdg), address(tsla));
        tslaKey = PoolKey(Currency.wrap(a), Currency.wrap(b), 3000, 60, IHooks(address(0)));
        pm.initialize(tslaKey, a == address(tsla) ? _sqrt(400e6, 1e18) : _sqrt(1e18, 400e6));
        tideKey = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(tide)), 10_000, 200, IHooks(address(0)));
        pm.initialize(tideKey, _sqrt(10_000e18, 1e18)); // 1 TIDE = 0.0001 ETH

        trader = new V4TraderS(pm);
        vm.deal(address(trader), 10_000 ether);
        usdg.mint(address(trader), 50_000_000e6);
        tsla.mint(address(trader), 100_000 ether);
        tide.mint(address(trader), 1e30);

        _background();

        // Bundles: Tidewell's ETH/TSLA, and a maker's bundle with 10% TIDE.
        TidewellBundler.Leg[] memory legs = new TidewellBundler.Leg[](2);
        legs[0] = _leg(ethKey, 5000);
        legs[1] = _leg(tslaKey, 5000);
        plainId = bundler.create(legs, _rules(), true);

        TidewellBundler.Leg[] memory t = new TidewellBundler.Leg[](3);
        t[0] = _leg(ethKey, 4500);
        t[1] = _leg(tslaKey, 4500);
        t[2] = _leg(tideKey, 1000);
        vm.prank(maker);
        tideId = bundler.create(t, _rules(), false);

        _fundUser(user);
        _fundUser(maker);
    }

    // ------------------------------------------------------------ helpers

    function _sqrt(uint256 num, uint256 den) internal pure returns (uint160) {
        return uint160(Math.sqrt(Math.mulDiv(num, 1 << 192, den)));
    }

    function _fundUser(address who) internal {
        vm.deal(who, 100 ether);
        usdg.mint(who, 1_000_000e6);
        vm.startPrank(who);
        usdg.approve(address(bundler), type(uint256).max);
        usdg.approve(permit2, type(uint256).max);
        vm.stopPrank();
    }

    /// Wide background liquidity in every pool, through a normal Tidewell vault.
    function _background() internal {
        TidewellFactory f = new TidewellFactory(
            address(this),
            TidewellFactory.Addresses({
                implementationV3: address(new TidewellVaultV3()),
                implementationV4: address(new TidewellShapedVaultV4()),
                positionManager: address(0xdead),
                uniswapFactory: address(0xdead),
                poolManager: address(pm),
                positionManagerV4: posm,
                permit2: permit2,
                weth: address(weth)
            }),
            keeper,
            guardian,
            address(sink)
        );
        f.setOpenMode(true);
        vm.deal(whale, 10_000 ether);
        usdg.mint(whale, 100_000_000e6);
        tsla.mint(whale, 1_000_000 ether);
        tide.mint(whale, 1e30);
        vm.startPrank(whale);
        TidewellShapedVaultV4 bg = TidewellShapedVaultV4(payable(f.createVault(1)));
        usdg.approve(address(bg), type(uint256).max);
        tsla.approve(address(bg), type(uint256).max);
        tide.approve(address(bg), type(uint256).max);
        bg.open{value: 1000 ether}(_full(ethKey, 887_270, 1000 ether, 2_500_000e6));
        (uint256 t0, uint256 t1) = Currency.unwrap(tslaKey.currency0) == address(tsla)
            ? (uint256(10_000 ether), uint256(4_000_000e6))
            : (uint256(4_000_000e6), uint256(10_000 ether));
        bg.open(_full(tslaKey, 887_220, t0, t1));
        bg.open{value: 100 ether}(_full(tideKey, 887_200, 100 ether, 1_000_000 ether));
        vm.stopPrank();
    }

    function _full(PoolKey memory key, int24 edge, uint256 a0, uint256 a1)
        internal
        pure
        returns (TidewellShapedVaultV4.OpenParams memory)
    {
        return TidewellShapedVaultV4.OpenParams({
            key: key,
            tickLower: -edge,
            tickUpper: edge,
            amount0: a0,
            amount1: a1,
            sqrtPriceMin: TickMath.MIN_SQRT_PRICE,
            sqrtPriceMax: TickMath.MAX_SQRT_PRICE,
            shape: 0,
            settings: TidewellShapedBase.Settings({
                minWidth: key.tickSpacing,
                maxWidth: edge * 2,
                cooldown: 30 minutes,
                compoundBps: 0,
                slippageBps: 100,
                rule: 0,
                outDelay: 0
            })
        });
    }

    function _settings(int24 spacing) internal pure returns (TidewellShapedBase.Settings memory) {
        return TidewellShapedBase.Settings({
            minWidth: spacing * 10,
            maxWidth: spacing * 1000,
            cooldown: 30 minutes,
            compoundBps: 10_000,
            slippageBps: 150,
            rule: 0,
            outDelay: 14_400
        });
    }

    function _leg(PoolKey memory key, uint16 w) internal pure returns (TidewellBundler.Leg memory) {
        return TidewellBundler.Leg({key: key, weightBps: w, shape: 0, settings: _settings(key.tickSpacing)});
    }

    function _rules() internal pure returns (TidewellBundler.Rules memory) {
        return TidewellBundler.Rules({rebalance: true, driftPts: 5, everyDays: 7});
    }

    function _tick(PoolKey memory key) internal view returns (int24 tick) {
        (, tick,,) = pm.getSlot0(key.toId());
    }

    function _floor(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 c = tick / spacing;
        if (tick < 0 && tick % spacing != 0) c--;
        return c * spacing;
    }

    /// A range of about ±20% around the price (1,820 ticks each side), on the spacing.
    function _range(PoolKey memory key) internal view returns (int24 lo, int24 hi) {
        int24 s = key.tickSpacing;
        int24 base = _floor(_tick(key), s);
        lo = base - (1820 / s) * s;
        hi = base + (1820 / s + 1) * s;
    }

    function _noPermit() internal pure returns (TidewellBundler.PermitIn memory p) {}

    function _swap(PoolKey memory key, address tokenIn, uint256 amountIn)
        internal
        pure
        returns (TidewellBundler.Swap memory)
    {
        return TidewellBundler.Swap({
            key: key,
            zeroForOne: Currency.unwrap(key.currency0) == tokenIn,
            amountIn: amountIn,
            minOut: 0,
            route: ""
        });
    }

    /// The user's plan for depositing `amount` of USDG: per leg, half of its part is swapped into the other token.
    function _plan(uint256 id, uint256 amount) internal view returns (TidewellBundler.LegIn[] memory li) {
        TidewellBundler.Leg[] memory L = bundler.legsOf(id);
        li = new TidewellBundler.LegIn[](L.length);
        for (uint256 i; i < L.length; ++i) {
            uint256 part = (amount * L[i].weightBps) / 10_000;
            (int24 lo, int24 hi) = _range(L[i].key);
            address c0 = Currency.unwrap(L[i].key.currency0);
            address c1 = Currency.unwrap(L[i].key.currency1);
            TidewellBundler.Swap[] memory s;
            // forge-lint: disable-next-line
            uint256 fee = (part / 2) * 15 / 10_000;
            uint256 half = part / 2 - fee - 1;
            if (c0 == address(usdg) || c1 == address(usdg)) {
                s = new TidewellBundler.Swap[](1);
                s[0] = _swap(L[i].key, address(usdg), half);
            } else {
                // ETH/TIDE: USDG -> ETH in the ETH pool, then half of that ETH -> TIDE.
                s = new TidewellBundler.Swap[](2);
                s[0] = _swap(ethKey, address(usdg), part - (part * 15) / 10_000 - 1);
                s[1] = _swap(L[i].key, address(0), _ethFor(part) / 2);
            }
            li[i] = TidewellBundler.LegIn({
                tickLower: lo,
                tickUpper: hi,
                sqrtPriceMin: TickMath.MIN_SQRT_PRICE,
                sqrtPriceMax: TickMath.MAX_SQRT_PRICE,
                swaps: s
            });
        }
    }

    /// About how much ETH `usd` of USDG buys (a little less, to be safe).
    function _ethFor(uint256 usd) internal pure returns (uint256) {
        return (usd * 1e12 * 98) / 100 / 2500;
    }

    function _openUsdg(address who, uint256 id, uint256 amount) internal {
        TidewellBundler.LegIn[] memory li = _plan(id, amount);
        vm.prank(who);
        bundler.open(id, amount, li, _noPermit());
    }

    function _vault(address who) internal view returns (TidewellBundleVault) {
        return TidewellBundleVault(payable(factory.vaultOf(who, 1)));
    }

    function _liq(TidewellBundleVault v, uint256 id) internal view returns (uint256) {
        return v.positionLiquidity(id);
    }

    function _assertEmpty() internal view {
        assertEq(address(bundler).balance, 0, "bundler keeps no ETH");
        assertEq(weth.balanceOf(address(bundler)), 0, "no WETH");
        assertEq(usdg.balanceOf(address(bundler)), 0, "no USDG");
        assertEq(tsla.balanceOf(address(bundler)), 0, "no TSLA");
        assertEq(tide.balanceOf(address(bundler)), 0, "no TIDE");
    }

    function _trade(uint256 rounds) internal {
        for (uint256 i; i < rounds; ++i) {
            trader.swap(ethKey, true, 20 ether);
            trader.swap(ethKey, false, 50_000e6);
            trader.swap(tslaKey, Currency.unwrap(tslaKey.currency0) == address(usdg), 40_000e6);
            trader.swap(tslaKey, Currency.unwrap(tslaKey.currency0) == address(tsla), 100 ether);
            trader.swap(tideKey, true, 2 ether);
            trader.swap(tideKey, false, 20_000 ether);
            vm.warp(block.timestamp + 60);
        }
    }

    // ------------------------------------------------------------ registry

    function test_create_rules() public {
        TidewellBundler.Leg[] memory legs = new TidewellBundler.Leg[](2);
        legs[0] = _leg(ethKey, 5000);
        legs[1] = _leg(tslaKey, 4000);
        vm.expectRevert(TidewellBundler.BadBundle.selector); // weights must add up to 100%
        bundler.create(legs, _rules(), false);
        legs[1] = _leg(ethKey, 5000);
        vm.expectRevert(TidewellBundler.BadBundle.selector); // the same pool twice
        bundler.create(legs, _rules(), false);
        legs[0] = _leg(ethKey, 9600);
        legs[1] = _leg(tslaKey, 400);
        vm.expectRevert(TidewellBundler.BadBundle.selector); // under 5%
        bundler.create(legs, _rules(), false);
        legs[0] = _leg(ethKey, 5000);
        legs[1] = _leg(tslaKey, 5000);
        vm.prank(stranger);
        vm.expectRevert(TidewellBundler.NotAllowed.selector); // only the owner makes Tidewell bundles
        bundler.create(legs, _rules(), true);
        PoolKey memory missing = PoolKey(ethKey.currency0, ethKey.currency1, 100, 1, IHooks(address(0)));
        legs[1] = _leg(missing, 5000);
        vm.expectRevert(TidewellBundler.BadBundle.selector); // a pool that does not exist
        bundler.create(legs, _rules(), false);
    }

    function test_create_tideFlag_needsTenPercent() public view {
        (,,,,, bool isTide,) = bundler.bundles(tideId);
        assertTrue(isTide, "10% TIDE counts");
        (,,,,, bool plain,) = bundler.bundles(plainId);
        assertFalse(plain);
    }

    function test_create_smallTideSliceDoesNotCount() public {
        TidewellBundler.Leg[] memory t = new TidewellBundler.Leg[](3);
        t[0] = _leg(ethKey, 4600);
        t[1] = _leg(tslaKey, 4600);
        t[2] = _leg(tideKey, 800);
        uint256 id = bundler.create(t, _rules(), false);
        (,,,,, bool isTide,) = bundler.bundles(id);
        assertFalse(isTide, "8% TIDE is not enough for the lower fee");
    }

    // ------------------------------------------------------------ deposits

    function test_open_usdg_oneTransaction() public {
        uint256 balBefore = usdg.balanceOf(user);
        _openUsdg(user, plainId, 10_000e6);
        TidewellBundleVault v = _vault(user);
        assertTrue(address(v) != address(0), "vault made");
        (, uint256[] memory ids) = bundler.holdingOf(address(v), plainId);
        assertEq(ids.length, 2);
        assertGt(_liq(v, ids[0]), 0);
        assertGt(_liq(v, ids[1]), 0);
        assertEq(v.owner(), user);
        _assertEmpty();
        // The swap fee: 0.15% of what was swapped, in USDG.
        assertApproxEqAbs(usdg.balanceOf(address(sink)), (5_000e6 * 15) / 10_000, 2e6);
        // Spent at most the amount; the rest came back.
        assertLe(balBefore - usdg.balanceOf(user), 10_000e6);
        (,, uint32 holders,,,,) = bundler.bundles(plainId);
        assertEq(holders, 1);
        uint256[] memory held = bundler.heldBy(address(v));
        assertEq(held.length, 1);
        assertEq(held[0], plainId);
    }

    function test_open_eth_oneTransaction() public {
        TidewellBundler.Leg[] memory L = bundler.legsOf(plainId);
        TidewellBundler.LegIn[] memory li = new TidewellBundler.LegIn[](2);
        uint256 amount = 4 ether;
        // ETH/USDG: half the 2 ETH to USDG. TSLA/USDG: 2 ETH to USDG, then half the USDG to TSLA.
        TidewellBundler.Swap[] memory s0 = new TidewellBundler.Swap[](1);
        s0[0] = _swap(ethKey, address(0), 0.99 ether);
        TidewellBundler.Swap[] memory s1 = new TidewellBundler.Swap[](2);
        s1[0] = _swap(ethKey, address(0), 1.99 ether);
        s1[1] = _swap(tslaKey, address(usdg), 2_400e6);
        (int24 lo0, int24 hi0) = _range(L[0].key);
        (int24 lo1, int24 hi1) = _range(L[1].key);
        li[0] = TidewellBundler.LegIn(lo0, hi0, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE, s0);
        li[1] = TidewellBundler.LegIn(lo1, hi1, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE, s1);
        uint256 ethBefore = user.balance;
        vm.prank(user);
        bundler.open{value: amount}(plainId, amount, li, _noPermit());
        TidewellBundleVault v = _vault(user);
        (, uint256[] memory ids) = bundler.holdingOf(address(v), plainId);
        assertGt(_liq(v, ids[0]), 0);
        assertGt(_liq(v, ids[1]), 0);
        assertLe(ethBefore - user.balance, amount);
        _assertEmpty();
        assertGt(address(sink).balance, 0, "swap fee in ETH");
    }

    function test_open_permit2Signature() public {
        (address who, uint256 key) = makeAddrAndKey("permitUser");
        usdg.mint(who, 100_000e6);
        vm.prank(who);
        usdg.approve(permit2, type(uint256).max); // the one-time Permit2 approval, no approval of the bundler
        uint256 amount = 2_000e6;
        TidewellBundler.PermitIn memory p = TidewellBundler.PermitIn({nonce: 7, deadline: block.timestamp + 1 hours, signature: ""});
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "PermitTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline)TokenPermissions(address token,uint256 amount)"
                ),
                keccak256(abi.encode(keccak256("TokenPermissions(address token,uint256 amount)"), address(usdg), amount)),
                address(bundler),
                p.nonce,
                p.deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", IPermit2Domain(permit2).DOMAIN_SEPARATOR(), structHash));
        (uint8 v_, bytes32 r, bytes32 s) = vm.sign(key, digest);
        p.signature = abi.encodePacked(r, s, v_);
        TidewellBundler.LegIn[] memory li = _plan(plainId, amount);
        vm.prank(who);
        bundler.open(plainId, amount, li, p);
        (, uint256[] memory ids) = bundler.holdingOf(address(_vault(who)), plainId);
        assertEq(ids.length, 2);
        _assertEmpty();
    }

    function test_open_again_addsToSamePositions() public {
        _openUsdg(user, plainId, 10_000e6);
        TidewellBundleVault v = _vault(user);
        (, uint256[] memory ids) = bundler.holdingOf(address(v), plainId);
        uint256 l0 = _liq(v, ids[0]);
        uint256 l1 = _liq(v, ids[1]);
        _openUsdg(user, plainId, 10_000e6);
        (, uint256[] memory again) = bundler.holdingOf(address(v), plainId);
        assertEq(again[0], ids[0]);
        assertEq(again[1], ids[1]);
        assertGt(_liq(v, ids[0]), l0);
        assertGt(_liq(v, ids[1]), l1);
        (,, uint32 holders,,,,) = bundler.bundles(plainId);
        assertEq(holders, 1, "still one wallet");
        _assertEmpty();
    }

    function test_open_cannotTakeMoreThanItsPart() public {
        TidewellBundler.LegIn[] memory li = _plan(plainId, 10_000e6);
        li[0].swaps[0].amountIn = 6_000e6; // more than the leg's 5,000
        vm.prank(user);
        vm.expectRevert(TidewellBundler.BadAmount.selector);
        bundler.open(plainId, 10_000e6, li, _noPermit());
    }

    function test_open_minOutProtects() public {
        TidewellBundler.LegIn[] memory li = _plan(plainId, 10_000e6);
        li[0].swaps[0].minOut = 100 ether; // far more ETH than 2,500 USDG buys
        vm.prank(user);
        vm.expectRevert(TidewellBundler.BadSwap.selector);
        bundler.open(plainId, 10_000e6, li, _noPermit());
    }

    function test_open_priceProtects() public {
        TidewellBundler.LegIn[] memory li = _plan(plainId, 10_000e6);
        (uint160 p,,,) = pm.getSlot0(ethKey.toId());
        li[0].sqrtPriceMax = p / 2; // the user only accepts a much lower price
        vm.prank(user);
        vm.expectRevert(TidewellBundleVault.PriceOutOfBounds.selector);
        bundler.open(plainId, 10_000e6, li, _noPermit());
    }

    // ------------------------------------------------------------ fees

    function test_fees_perBundleAndMaker() public {
        _openUsdg(user, plainId, 10_000e6);
        _openUsdg(user, tideId, 10_000e6);
        _openUsdg(maker, tideId, 10_000e6);
        TidewellBundleVault v = _vault(user);
        (, uint256[] memory plainIds) = bundler.holdingOf(address(v), plainId);
        (, uint256[] memory tideIds) = bundler.holdingOf(address(v), tideId);
        assertEq(v.getPosition(plainIds[0]).feeBps, 200, "normal bundle 2%");
        assertEq(v.getPosition(tideIds[0]).feeBps, 150, "TIDE bundle 1.5%");
        TidewellBundleVault mv = _vault(maker);
        (, uint256[] memory makerIds) = bundler.holdingOf(address(mv), tideId);
        assertEq(mv.getPosition(makerIds[0]).feeBps, 100, "maker of a TIDE bundle 1%");
        (,, uint32 holders,,,,) = bundler.bundles(tideId);
        assertEq(holders, 1, "the maker is not counted as joined");
    }

    function test_fees_takenAtTheRate_floorWithDiscount() public {
        _openUsdg(user, tideId, 20_000e6);
        TidewellBundleVault v = _vault(user);
        (, uint256[] memory ids) = bundler.holdingOf(address(v), tideId);
        MockDiscount d = new MockDiscount();
        d.set(5000); // 50% staking discount: 1.5% would become 0.75%, the floor keeps it at 1%
        factory.setFee(address(sink), 200, address(d));
        _trade(20);
        vm.recordLogs();
        vm.prank(user);
        v.collect(ids[0]);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == keccak256("FeesCollected(uint256,uint256,uint256,uint256,uint256)")) {
                (uint256 c0, uint256 c1, uint256 p0, uint256 p1) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
                if (c0 > 1e9) assertApproxEqRel(p0, c0 / 100, 0.01e18, "1% of token0");
                if (c1 > 1e3) assertApproxEqRel(p1, c1 / 100, 0.01e18, "1% of token1");
                found = c0 > 0 || c1 > 0;
            }
        }
        assertTrue(found, "fees were collected");
    }

    // ------------------------------------------------------------ withdraw, claim, compound

    function test_withdraw_half_thenAll_toUsdg() public {
        _openUsdg(user, plainId, 10_000e6);
        TidewellBundleVault v = _vault(user);
        (, uint256[] memory ids) = bundler.holdingOf(address(v), plainId);
        uint256 l0 = _liq(v, ids[0]);
        uint256 before = usdg.balanceOf(user);
        TidewellBundler.Swap[] memory s = new TidewellBundler.Swap[](2);
        s[0] = _swap(ethKey, address(0), 0.4 ether); // most of the ETH that comes out
        s[1] = _swap(tslaKey, address(tsla), 2.9 ether);
        vm.prank(user);
        bundler.withdraw(plainId, 0.5e18, s, false, 3_000e6);
        assertApproxEqRel(_liq(v, ids[0]), l0 / 2, 0.001e18, "half left");
        assertGt(usdg.balanceOf(user) - before, 3_000e6);
        _assertEmpty();

        TidewellBundler.Swap[] memory none;
        vm.prank(user);
        bundler.withdraw(plainId, 1e18, none, false, 0);
        (, uint256[] memory gone) = bundler.holdingOf(address(v), plainId);
        assertEq(gone.length, 0, "holding closed");
        assertEq(v.positionIds().length, 0, "positions closed");
        (,, uint32 holders,,,,) = bundler.bundles(plainId);
        assertEq(holders, 0);
        assertEq(bundler.heldBy(address(v)).length, 0);
        assertGt(tsla.balanceOf(user), 0, "tokens not swapped come as they are");
        _assertEmpty();
    }

    function test_withdraw_toEth() public {
        _openUsdg(user, plainId, 10_000e6);
        TidewellBundler.Swap[] memory s = new TidewellBundler.Swap[](2);
        s[0] = _swap(tslaKey, address(tsla), 6 ether);
        s[1] = _swap(ethKey, address(usdg), 7_000e6);
        uint256 before = user.balance;
        vm.prank(user);
        bundler.withdraw(plainId, 1e18, s, true, 3 ether);
        assertGt(user.balance - before, 3 ether);
        _assertEmpty();
    }

    function test_withdraw_minOutProtects() public {
        _openUsdg(user, plainId, 10_000e6);
        TidewellBundler.Swap[] memory none;
        vm.prank(user);
        vm.expectRevert();
        bundler.withdraw(plainId, 1e18, none, false, 20_000e6);
    }

    function test_claim_asEth_keepsGasMoney() public {
        _openUsdg(user, plainId, 20_000e6);
        _trade(30);
        TidewellBundleVault v = _vault(user);
        vm.prank(user);
        bundler.claim(plainId, new TidewellBundler.Swap[](0), false, 0, 0);
        assertGt(usdg.balanceOf(user), 0);
        // Again after more trading, all as ETH (USDG and TSLA swapped), 0.001 ETH stays for the keeper.
        _trade(30);
        vm.deal(address(v), 0.01 ether); // ETH in the vault (the keeper's gas money)
        uint256 before = user.balance;
        // Swap what will be ready: collect first to see it.
        vm.startPrank(user);
        (, uint256[] memory ids) = bundler.holdingOf(address(v), plainId);
        v.collect(ids[0]);
        v.collect(ids[1]);
        vm.stopPrank();
        uint256 readyUsd = usdg.balanceOf(address(v));
        uint256 readyTsla = tsla.balanceOf(address(v));
        TidewellBundler.Swap[] memory s = new TidewellBundler.Swap[](2);
        s[0] = _swap(tslaKey, address(tsla), readyTsla);
        s[1] = _swap(ethKey, address(usdg), readyUsd + (readyTsla * 380) / 1e12);
        s[1].amountIn = readyUsd; // only the USDG that is there before the TSLA swap is known; the rest comes as USDG
        vm.prank(user);
        bundler.claim(plainId, s, true, 0, 0.001 ether);
        assertGt(user.balance, before, "fees as ETH");
        assertEq(address(v).balance, 0.001 ether, "gas money stays");
        _assertEmpty();
    }

    function test_compound_reinvests() public {
        _openUsdg(user, plainId, 20_000e6);
        _trade(30);
        TidewellBundleVault v = _vault(user);
        (, uint256[] memory ids) = bundler.holdingOf(address(v), plainId);
        uint256 l0 = _liq(v, ids[0]);
        TidewellBundler.CompoundIn[] memory c = new TidewellBundler.CompoundIn[](2);
        c[0] = TidewellBundler.CompoundIn(TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE, false, 0, "");
        c[1] = TidewellBundler.CompoundIn(TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE, false, 0, "");
        vm.prank(user);
        bundler.compound(plainId, c);
        assertGt(_liq(v, ids[0]), l0, "fees went back in");
    }

    // ------------------------------------------------------------ keeper rebalance

    function _pokeAll(TidewellBundleVault v, uint256[] memory ids) internal {
        vm.startPrank(keeper);
        for (uint256 i; i < ids.length; ++i) {
            v.poke(ids[i]);
        }
        vm.stopPrank();
        vm.warp(block.timestamp + 61);
    }

    function _moveEthToTsla(uint256 share, uint256 ethIn) internal pure returns (TidewellBundler.Move[] memory m) {
        m = new TidewellBundler.Move[](1);
        TidewellBundler.Swap[] memory s = new TidewellBundler.Swap[](1);
        s[0] = TidewellBundler.Swap({key: PoolKey(Currency.wrap(address(0)), Currency.wrap(address(0)), 0, 0, IHooks(address(0))), zeroForOne: true, amountIn: ethIn, minOut: 0, route: ""});
        m[0] = TidewellBundler.Move({from: 0, to: 1, share: share, swaps: s});
    }

    function test_rebalance_keeperMovesValue_withinLimits() public {
        _openUsdg(user, plainId, 20_000e6);
        TidewellBundleVault v = _vault(user);
        (, uint256[] memory ids) = bundler.holdingOf(address(v), plainId);
        vm.warp(block.timestamp + 7 days);
        _pokeAll(v, ids);
        uint256 l0 = _liq(v, ids[0]);
        uint256 l1 = _liq(v, ids[1]);
        TidewellBundler.Move[] memory m = _moveEthToTsla(0.2e18, 0);
        // 20% of the ETH position: its ETH to USDG in the ETH pool, then USDG to TSLA in the TSLA pool.
        TidewellBundler.Swap[] memory s = new TidewellBundler.Swap[](2);
        s[0] = _swap(ethKey, address(0), 0.35 ether);
        s[1] = _swap(tslaKey, address(usdg), 900e6);
        m[0].swaps = s;
        vm.prank(keeper);
        bundler.rebalance(address(v), plainId, m);
        assertApproxEqRel(_liq(v, ids[0]), (l0 * 8) / 10, 0.001e18, "20% out");
        assertGt(_liq(v, ids[1]), l1, "into the other position");
        _assertEmpty();

        // Not again within the period.
        _pokeAll(v, ids);
        vm.prank(keeper);
        vm.expectRevert(TidewellBundler.TooSoon.selector);
        bundler.rebalance(address(v), plainId, m);
    }

    function test_rebalance_throughAThirdPoolOfTheBundle() public {
        _openUsdg(user, tideId, 20_000e6);
        TidewellBundleVault v = _vault(user);
        (, uint256[] memory ids) = bundler.holdingOf(address(v), tideId);
        vm.warp(block.timestamp + 7 days);
        _pokeAll(v, ids);
        uint256 lT = _liq(v, ids[2]);
        uint256 lS = _liq(v, ids[1]);
        // 30% of the TIDE position into TSLA: TIDE -> ETH (TIDE pool), ETH -> USDG (ETH pool), USDG -> TSLA (TSLA pool).
        TidewellBundler.Swap[] memory s = new TidewellBundler.Swap[](3);
        s[0] = _swap(tideKey, address(tide), 1_000 ether);
        s[1] = _swap(ethKey, address(0), 0.15 ether);
        s[2] = _swap(tslaKey, address(usdg), 300e6);
        TidewellBundler.Move[] memory m = new TidewellBundler.Move[](1);
        m[0] = TidewellBundler.Move({from: 2, to: 1, share: 0.3e18, swaps: s});
        vm.prank(keeper);
        bundler.rebalance(address(v), tideId, m);
        assertApproxEqRel(_liq(v, ids[2]), (lT * 7) / 10, 0.001e18, "30% out of TIDE");
        assertGt(_liq(v, ids[1]), lS, "into TSLA");
        _assertEmpty();
    }

    function test_rebalance_limits() public {
        _openUsdg(user, plainId, 20_000e6);
        TidewellBundleVault v = _vault(user);
        (, uint256[] memory ids) = bundler.holdingOf(address(v), plainId);
        vm.warp(block.timestamp + 7 days);
        _pokeAll(v, ids);
        TidewellBundler.Move[] memory m = _moveEthToTsla(0.6e18, 0);
        m[0].swaps[0] = _swap(ethKey, address(0), 0.1 ether);
        vm.prank(keeper);
        vm.expectRevert(TidewellBundler.BadAmount.selector); // more than half a position
        bundler.rebalance(address(v), plainId, m);

        m = _moveEthToTsla(0.2e18, 0);
        m[0].swaps[0] = _swap(tideKey, address(0), 0.1 ether);
        vm.prank(keeper);
        vm.expectRevert(TidewellBundler.BadSwap.selector); // a pool outside the move
        bundler.rebalance(address(v), plainId, m);

        m[0].swaps[0] = _swap(ethKey, address(0), 0.1 ether);
        m[0].swaps[0].route = hex"01";
        vm.prank(keeper);
        vm.expectRevert(TidewellBundler.BadSwap.selector); // no routes for the keeper
        bundler.rebalance(address(v), plainId, m);

        m[0].swaps[0].route = "";
        // Back and forth in one rebalance: refused.
        TidewellBundler.Move[] memory two = new TidewellBundler.Move[](2);
        two[0] = m[0];
        two[1] = TidewellBundler.Move({from: 1, to: 0, share: 0.2e18, swaps: new TidewellBundler.Swap[](0)});
        vm.prank(keeper);
        vm.expectRevert(TidewellBundler.BadAmount.selector);
        bundler.rebalance(address(v), plainId, two);

        vm.prank(stranger);
        vm.expectRevert(TidewellBundler.NotKeeper.selector);
        bundler.rebalance(address(v), plainId, m);
    }

    function test_rebalance_needsCheckedPrice() public {
        _openUsdg(user, plainId, 20_000e6);
        TidewellBundleVault v = _vault(user);
        vm.warp(block.timestamp + 7 days);
        TidewellBundler.Move[] memory m = _moveEthToTsla(0.2e18, 0);
        m[0].swaps[0] = _swap(ethKey, address(0), 0.1 ether);
        vm.prank(keeper);
        vm.expectRevert(TidewellBundleVault.NoPriceCheck.selector); // no Chainlink and no recorded price
        bundler.rebalance(address(v), plainId, m);
    }

    function test_rebalance_badSwapPriceRefused() public {
        _openUsdg(user, plainId, 20_000e6);
        TidewellBundleVault v = _vault(user);
        (, uint256[] memory ids) = bundler.holdingOf(address(v), plainId);
        vm.warp(block.timestamp + 7 days);
        _pokeAll(v, ids);
        TidewellBundler.Move[] memory m = _moveEthToTsla(0.5e18, 0);
        // A swap far bigger than the pool can take within the slippage setting stops at the limit; the price check
        // then refuses what it got for what it spent only if it is worse than allowed, so it reverts or swaps less.
        m[0].swaps[0] = _swap(ethKey, address(0), 0.8 ether);
        m[0].swaps[0].minOut = 10_000_000e6; // and demands more than possible
        vm.prank(keeper);
        vm.expectRevert(TidewellBundler.BadSwap.selector);
        bundler.rebalance(address(v), plainId, m);
    }

    // ------------------------------------------------------------ access and safety

    function test_vault_onlyBundlerForOwner() public {
        _openUsdg(user, plainId, 10_000e6);
        TidewellBundleVault v = _vault(user);
        (, uint256[] memory ids) = bundler.holdingOf(address(v), plainId);
        vm.prank(stranger);
        vm.expectRevert(TidewellBundleVault.NotBundler.selector);
        v.takeOut(ids[0], 1e18);
        vm.prank(stranger);
        vm.expectRevert(TidewellBundleVault.NotBundler.selector);
        v.takeReady(address(usdg), 0);
        // The bundler itself outside a user's call acts for nobody.
        vm.prank(address(bundler));
        vm.expectRevert(TidewellBundleVault.NotBundler.selector);
        v.takeOut(ids[0], 1e18);
    }

    function test_otherWallet_cannotTouchHolding() public {
        _openUsdg(user, plainId, 10_000e6);
        TidewellBundler.Swap[] memory none;
        vm.prank(stranger);
        vm.expectRevert(TidewellBundler.NotHeld.selector);
        bundler.withdraw(plainId, 1e18, none, false, 0);
        vm.prank(stranger);
        vm.expectRevert(TidewellBundler.NotHeld.selector);
        bundler.claim(plainId, none, false, 0, 0);
    }

    function test_newImplementation_onlyForNewVaults() public {
        _openUsdg(user, plainId, 10_000e6);
        address first = address(_vault(user));
        address impl2 = address(new TidewellBundleVault());
        vm.prank(stranger);
        vm.expectRevert();
        factory.setImplementation(impl2);
        factory.setImplementation(impl2);
        _openUsdg(maker, plainId, 10_000e6);
        assertEq(address(_vault(user)), first, "existing vault unchanged");
        assertTrue(factory.isVault(address(_vault(maker))));
    }

    function test_onlyBundlerMakesVaults() public {
        vm.prank(stranger);
        vm.expectRevert(TidewellBundleFactory.NotBundler.selector);
        factory.vaultFor(stranger);
    }

    function test_owner_canExitWithoutBundler() public {
        _openUsdg(user, plainId, 10_000e6);
        TidewellBundleVault v = _vault(user);
        (, uint256[] memory ids) = bundler.holdingOf(address(v), plainId);
        uint256 before = usdg.balanceOf(user);
        vm.prank(user);
        v.close(ids[1], 0, 0);
        assertGt(usdg.balanceOf(user) + tsla.balanceOf(user), before);
    }

    function test_paused_blocksDeposits_notWithdrawals() public {
        _openUsdg(user, plainId, 10_000e6);
        factory.setPaused(true);
        TidewellBundler.LegIn[] memory li = _plan(plainId, 1_000e6);
        vm.prank(user);
        vm.expectRevert();
        bundler.open(plainId, 1_000e6, li, _noPermit());
        TidewellBundler.Swap[] memory none;
        vm.prank(user);
        bundler.withdraw(plainId, 1e18, none, false, 0);
        _assertEmpty();
    }

    function test_delisted_noNewDeposits_holdersCanLeave() public {
        _openUsdg(user, tideId, 10_000e6);
        vm.prank(stranger);
        vm.expectRevert(TidewellBundler.NotAllowed.selector);
        bundler.setListed(tideId, false);
        bundler.setListed(tideId, false); // the owner
        TidewellBundler.LegIn[] memory li = _plan(tideId, 1_000e6);
        vm.prank(user);
        vm.expectRevert(TidewellBundler.NotListed.selector);
        bundler.open(tideId, 1_000e6, li, _noPermit());
        TidewellBundler.Swap[] memory none;
        vm.prank(user);
        bundler.withdraw(tideId, 1e18, none, false, 0);
    }

    function test_tideBundle_openAndClose_eth() public {
        _openUsdg(user, tideId, 10_000e6);
        TidewellBundleVault v = _vault(user);
        (, uint256[] memory ids) = bundler.holdingOf(address(v), tideId);
        assertEq(ids.length, 3);
        assertGt(_liq(v, ids[2]), 0, "TIDE position");
        _assertEmpty();
        TidewellBundler.Swap[] memory none;
        vm.prank(user);
        bundler.withdraw(tideId, 1e18, none, true, 0);
        assertGt(tide.balanceOf(user), 0);
        _assertEmpty();
    }
}
