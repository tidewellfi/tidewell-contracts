// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm, console} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TidewellFactory} from "../src/TidewellFactory.sol";
import {TidewellSwapper} from "../src/TidewellSwapper.sol";
import {TidewellShapedBase} from "../src/TidewellShapedBase.sol";
import {TidewellVaultV3} from "../src/TidewellVaultV3.sol";
import {TidewellShapedVaultV4} from "../src/TidewellShapedVaultV4.sol";
import {IPositionManagerV4S as IPositionManagerV4} from "../src/libraries/ShapesV4.sol";
import {Shapes} from "../src/libraries/Shapes.sol";
import {MockERC20, MockFeed, MockSink, MockPonsEscrow, MockPonsLaunches, MockPonsCurve, MockRouter} from "./mocks/Mocks.sol";
import {Reserve} from "../src/Reserve.sol";
import {RevenueRouter} from "../src/RevenueRouter.sol";
import {ReferralRegistry} from "../src/ReferralRegistry.sol";
import {BuybackBurner} from "../src/BuybackBurner.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";

interface IPermit2Domain {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

interface IOwnerOf {
    function ownerOf(uint256 id) external view returns (address);
}

/// Swaps against a v4 pool, to create fees and move the price in tests.
contract V4TraderS is IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;

    IPoolManager immutable pm;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    receive() external payable {}

    function swap(PoolKey memory key, bool zeroForOne, uint256 amountIn) external {
        pm.unlock(abi.encode(key, zeroForOne, amountIn));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, bool zeroForOne, uint256 amountIn) = abi.decode(data, (PoolKey, bool, uint256));
        BalanceDelta d = pm.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        int128 a0 = d.amount0();
        int128 a1 = d.amount1();
        if (a0 < 0) _pay(key.currency0, uint256(uint128(-a0)));
        if (a1 < 0) _pay(key.currency1, uint256(uint128(-a1)));
        if (a0 > 0) pm.take(key.currency0, address(this), uint256(uint128(a0)));
        if (a1 > 0) pm.take(key.currency1, address(this), uint256(uint128(a1)));
        return "";
    }

    function _pay(Currency c, uint256 amount) internal {
        if (Currency.unwrap(c) == address(0)) {
            pm.settle{value: amount}();
        } else {
            pm.sync(c);
            IERC20(Currency.unwrap(c)).transfer(address(pm), amount);
            pm.settle();
        }
    }
}

/// Runs against the real Uniswap v4 PoolManager, PositionManager and Permit2, compiled from their sources.
contract ShapedV4Test is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    IPoolManager pm;
    address posm;
    address permit2;
    TidewellFactory factory;
    MockERC20 weth; // 18 decimals, used for the ERC-20 pool and for the ETH price feed
    MockERC20 usdg; // 6 decimals
    MockSink sink;
    V4TraderS trader;
    PoolKey ethKey; // native ETH / USDG, 0.3%
    PoolKey ercKey; // WETH / USDG, 0.05%

    address user = makeAddr("user");
    address whale = makeAddr("whale");
    address keeper = makeAddr("keeper");
    address guardian = makeAddr("guardian");
    address stranger = makeAddr("stranger");
    TidewellShapedVaultV4 vault;

    MockRouter mockRouter;

    function setUp() public {
        vm.warp(1_800_000_000);
        pm = IPoolManager(deployCode("out/PoolManager.sol/PoolManager.json", abi.encode(address(this))));
        permit2 = deployCode("out/Permit2.sol/Permit2.json");
        weth = new MockERC20("WETH", 18);
        usdg = new MockERC20("USDG", 6);
        posm = deployCode(
            "out/PositionManager.sol/PositionManager.json",
            abi.encode(address(pm), permit2, uint256(300_000), address(0), address(weth))
        );
        sink = new MockSink();
        factory = new TidewellFactory(
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
        factory.setTokenCap(address(weth), 10_000 ether);
        factory.setTokenCap(address(usdg), 50_000_000e6);
        mockRouter = new MockRouter(permit2);
        vm.deal(address(mockRouter), 1_000 ether);
        factory.setSwapper(address(new TidewellSwapper(address(factory), address(pm), permit2, address(mockRouter))));

        ethKey = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(usdg)), 3000, 60, IHooks(address(0)));
        pm.initialize(ethKey, _sqrtPrice(2500e6, 1e18));
        (address a, address b) = address(weth) < address(usdg) ? (address(weth), address(usdg)) : (address(usdg), address(weth));
        ercKey = PoolKey(Currency.wrap(a), Currency.wrap(b), 500, 10, IHooks(address(0)));
        pm.initialize(ercKey, a == address(weth) ? _sqrtPrice(2500e6, 1e18) : _sqrtPrice(1e18, 2500e6));

        trader = new V4TraderS(pm);
        vm.deal(address(trader), 10_000 ether);
        usdg.mint(address(trader), 50_000_000e6);
        weth.mint(address(trader), 10_000 ether);

        // Background liquidity, opened through a vault of its own.
        _fund(whale, 1_000 ether, 10_000_000e6);
        vm.prank(whale);
        TidewellShapedVaultV4 bg = TidewellShapedVaultV4(payable(factory.createVault(1)));
        _approve(whale, address(bg));
        vm.prank(whale);
        bg.open{value: 500 ether}(_params(ethKey, -887220, 887220, 500 ether, 1_250_000e6, _wide(1_774_440)));
        uint256 w = 500 ether;
        uint256 u = 1_250_000e6;
        (uint256 e0, uint256 e1) = Currency.unwrap(ercKey.currency0) == address(weth) ? (w, u) : (u, w);
        vm.prank(whale);
        bg.open(_params(ercKey, -887270, 887270, e0, e1, _wide(1_774_540)));

        _fund(user, 100 ether, 1_000_000e6);
        vm.prank(user);
        vault = TidewellShapedVaultV4(payable(factory.createVault(1)));
        _approve(user, address(vault));
        vm.deal(address(vault), 0.01 ether); // gas tank, also part of the user's ETH
    }

    // ------------------------------------------------------------ helpers

    function _sqrtPrice(uint256 num, uint256 den) internal pure returns (uint160) {
        return uint160(Math.sqrt(Math.mulDiv(num, 1 << 192, den)));
    }

    function _fund(address who, uint256 eth, uint256 usd) internal {
        vm.deal(who, eth);
        weth.mint(who, eth);
        usdg.mint(who, usd);
    }

    function _approve(address who, address v) internal {
        vm.startPrank(who);
        weth.approve(v, type(uint256).max);
        usdg.approve(v, type(uint256).max);
        vm.stopPrank();
    }

    function _wide(int24 width) internal pure returns (TidewellShapedBase.Settings memory) {
        return TidewellShapedBase.Settings({
            minWidth: 600,
            maxWidth: width,
            cooldown: 30 minutes,
            compoundBps: 0,
            slippageBps: 100,
            rule: 0,
            outDelay: 0
        });
    }

    function _settings() internal pure returns (TidewellShapedBase.Settings memory) {
        return TidewellShapedBase.Settings({
            minWidth: 600,
            maxWidth: 6000,
            cooldown: 30 minutes,
            compoundBps: 5000,
            slippageBps: 100,
            rule: 0,
            outDelay: 0
        });
    }

    function _params(PoolKey memory key, int24 lo, int24 hi, uint256 a0, uint256 a1, TidewellShapedBase.Settings memory s)
        internal
        pure
        returns (TidewellShapedVaultV4.OpenParams memory)
    {
        return TidewellShapedVaultV4.OpenParams({
            key: key,
            tickLower: lo,
            tickUpper: hi,
            amount0: a0,
            amount1: a1,
            sqrtPriceMin: TickMath.MIN_SQRT_PRICE,
            sqrtPriceMax: TickMath.MAX_SQRT_PRICE,
            shape: 0,
            settings: s
        });
    }

    function _tick(PoolKey memory key) internal view returns (int24 tick) {
        (, tick,,) = pm.getSlot0(key.toId());
    }

    function _floor(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 c = tick / spacing;
        if (tick < 0 && tick % spacing != 0) c--;
        return c * spacing;
    }

    function _openEth() internal returns (uint256 id) {
        int24 base = _floor(_tick(ethKey), 60);
        vm.prank(user);
        id = vault.open{value: 10 ether}(_params(ethKey, base - 600, base + 600, 10 ether, 25_000e6, _settings()));
    }

    function _tradeEth(uint256 rounds) internal {
        for (uint256 i; i < rounds; ++i) {
            trader.swap(ethKey, true, 5 ether);
            vm.warp(block.timestamp + 15);
            trader.swap(ethKey, false, 12_500e6);
            vm.warp(block.timestamp + 15);
        }
    }

    // ------------------------------------------------------------ tests

    function test_open_nativeEth() public {
        uint256 ethBefore = user.balance;
        uint256 id = _openEth();
        TidewellShapedVaultV4.Position memory pos = vault.getPosition(id);
        assertEq(IOwnerOf(posm).ownerOf(pos.tokenId), address(vault));
        assertGt(IPositionManagerV4(posm).getPositionLiquidity(pos.tokenId), 0);
        // Leftovers went back to the user; the vault holds only its gas tank.
        assertGt(user.balance, ethBefore - 10 ether);
        assertEq(address(vault).balance, 0.01 ether);
        assertEq(usdg.balanceOf(address(vault)), 0);
    }

    function test_compoundNow_onlyOwner_noPriceWait() public {
        uint256 id = _openEth();
        _tradeEth(10);
        vm.prank(keeper);
        vm.expectRevert(TidewellShapedBase.NotOwner.selector);
        vault.compoundNow(id, 0, type(uint160).max, false, 0, "");
        // The owner's own price range replaces the recorded price: no poke, no waiting.
        vm.prank(user);
        vm.expectRevert(TidewellShapedVaultV4.PriceOutOfBounds.selector);
        vault.compoundNow(id, 0, 1, false, 0, "");
        uint128 before = IPositionManagerV4(posm).getPositionLiquidity(vault.getPosition(id).tokenId);
        vm.prank(user);
        vault.compoundNow(id, 0, type(uint160).max, false, 0, "");
        assertGt(IPositionManagerV4(posm).getPositionLiquidity(vault.getPosition(id).tokenId), before);
    }

    /// Compound also reinvests what was already ready to claim in the vault, not only the new pool fees.
    function test_compoundNow_includesReadyBalances() public {
        uint256 id = _openEth();
        _tradeEth(10);
        vm.deal(address(vault), address(vault).balance + 0.05 ether); // ready-to-claim ETH from earlier
        deal(address(usdg), address(vault), usdg.balanceOf(address(vault)) + 100e6);
        uint128 before = IPositionManagerV4(posm).getPositionLiquidity(vault.getPosition(id).tokenId);
        vm.prank(user);
        vault.compoundNow(id, 0, type(uint160).max, false, 0, "");
        uint128 mid = IPositionManagerV4(posm).getPositionLiquidity(vault.getPosition(id).tokenId);
        assertGt(mid, before);
        assertTrue(address(vault).balance < 0.05 ether || usdg.balanceOf(address(vault)) < 100e6, "ready funds went in");
    }

    /// Claim as ETH in one transaction: the USDG fees are swapped to ETH in the pool and sent with the ETH fees;
    /// the gas tank stays.
    function test_claimAsEth_oneTransaction() public {
        uint256 id = _openEth();
        _tradeEth(10);
        uint256 ethBefore = user.balance;
        vm.prank(user);
        vault.claimAsEth(id, 0, type(uint160).max, 0.01 ether, "");
        assertGt(user.balance, ethBefore, "fees arrived as ETH");
        assertEq(usdg.balanceOf(address(vault)), 0, "no USDG left");
        assertEq(address(vault).balance, 0.01 ether, "gas tank kept");
    }

    /// The keeper's compound swaps the reinvested fees to the range's ratio in the pool itself, then adds them.
    function test_compound_withSwap() public {
        uint256 id = _openEth();
        _tradeEth(10);
        vm.prank(keeper);
        vault.poke(id);
        vm.warp(block.timestamp + 61);
        vm.prank(keeper);
        vm.expectRevert(TidewellShapedBase.SwapTooLarge.selector);
        vault.compound(id, true, 1e30, "");

        uint128 before = IPositionManagerV4(posm).getPositionLiquidity(vault.getPosition(id).tokenId);
        vm.recordLogs();
        vm.prank(keeper);
        vault.compound(id, true, 1e9, "");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool swapped;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == keccak256("Swapped(uint256,bool,uint256,uint256)")) swapped = true;
        }
        assertTrue(swapped, "fees swapped in the pool");
        assertGt(IPositionManagerV4(posm).getPositionLiquidity(vault.getPosition(id).tokenId), before);
    }

    function test_compound_needsPokeWithoutFeeds() public {
        uint256 id = _openEth();
        _tradeEth(10);

        vm.prank(keeper);
        vm.expectRevert(TidewellShapedVaultV4.NoPriceCheck.selector);
        vault.compound(id, false, 0, "");

        vm.prank(keeper);
        vault.poke(id);
        vm.prank(keeper);
        vm.expectRevert(TidewellShapedVaultV4.NoPriceCheck.selector); // too soon after the poke
        vault.compound(id, false, 0, "");

        vm.warp(block.timestamp + 61);
        uint256 sinkEth = address(sink).balance;
        vm.recordLogs();
        vm.prank(keeper);
        vault.compound(id, false, 0, "");
        // 2% of the ETH fees went to the fee recipient, in ETH.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("FeesCollected(uint256,uint256,uint256,uint256,uint256)");
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != sig || logs[i].emitter != address(vault)) continue;
            (uint256 c0, uint256 c1, uint256 p0, uint256 p1) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
            assertGt(c0, 0);
            assertGt(c1, 0);
            // The whole 2% is taken in ETH, valued at the pool price, so revenue needs no swap.
            (uint160 sqrtP,,,) = pm.getSlot0(ethKey.toId());
            uint256 usdgInEth = Math.mulDiv(Math.mulDiv(c1, 1 << 96, sqrtP), 1 << 96, sqrtP);
            assertEq(p1, 0);
            assertApproxEqRel(p0, ((c0 + usdgInEth) * factory.protocolFeeBps()) / 10_000, 0.001e18);
            assertEq(address(sink).balance - sinkEth, p0);
            found = true;
        }
        assertTrue(found);

        // A poke is used once (and the keeper's next reinvest waits for the cooldown anyway).
        vm.prank(keeper);
        vm.expectRevert(TidewellShapedBase.TooSoon.selector);
        vault.compound(id, false, 0, "");
        vm.warp(block.timestamp + 4 hours);
        vm.prank(keeper);
        vm.expectRevert(TidewellShapedVaultV4.NoPriceCheck.selector);
        vault.compound(id, false, 0, "");
    }

    function test_poke_refusesMovedPrice() public {
        uint256 id = _openEth();
        vm.prank(keeper);
        vault.poke(id);
        vm.warp(block.timestamp + 61);
        trader.swap(ethKey, true, 50 ether); // someone moves the price between poke and action
        vm.prank(keeper);
        vm.expectRevert();
        vault.compound(id, false, 0, "");
    }

    /// The app's full "compound" for the owner: a move to the same range puts the collected fees back in, with no
    /// change to the range.
    function test_ownerCompound_sameRangeRebalance() public {
        uint256 id = _openEth();
        _tradeEth(10);
        vm.warp(vm.getBlockTimestamp() + 31 minutes);
        TidewellShapedVaultV4.Position memory p = vault.getPosition(id);
        uint128 before = IPositionManagerV4(posm).getPositionLiquidity(p.tokenId);
        vm.prank(user);
        vault.poke(id);
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(user);
        vault.rebalance(id, p.tickLower, p.tickUpper, false, 0, "");
        TidewellShapedVaultV4.Position memory q = vault.getPosition(id);
        assertEq(q.tickLower, p.tickLower, "same range");
        assertEq(q.tickUpper, p.tickUpper, "same range");
        assertGt(IPositionManagerV4(posm).getPositionLiquidity(q.tokenId), before, "fees went in");
    }

    function test_rebalance_withSwap_nativeEth() public {
        uint256 id = _openEth();
        uint256 oldToken = vault.getPosition(id).tokenId;
        trader.swap(ethKey, true, 60 ether); // ETH price falls out of the range
        vm.warp(block.timestamp + 31 minutes);
        vm.prank(keeper);
        vault.poke(id);
        vm.warp(block.timestamp + 61);

        int24 base = _floor(_tick(ethKey), 60);
        vm.prank(keeper);
        vault.rebalance(id, base - 600, base + 600, true, 4 ether, "");

        TidewellShapedVaultV4.Position memory pos = vault.getPosition(id);
        assertTrue(pos.tokenId != oldToken);
        assertEq(pos.tickLower, base - 600);
        assertEq(pos.tickUpper, base + 600);
        assertEq(IOwnerOf(posm).ownerOf(pos.tokenId), address(vault));
        assertGt(IPositionManagerV4(posm).getPositionLiquidity(pos.tokenId), 0);
    }

    /// What a range move cannot place belongs to the position, not to the fees: at a 50% reinvest setting the next
    /// compound still puts all of it back, and only the fee share stays ready to claim.
    function test_unplaced_rangeMoveLeftover_goesBackWhateverTheSetting() public {
        uint256 id = _openEth();
        trader.swap(ethKey, true, 60 ether);
        vm.warp(vm.getBlockTimestamp() + 31 minutes);
        vm.prank(keeper);
        vault.poke(id);
        vm.warp(vm.getBlockTimestamp() + 61);
        int24 base = _floor(_tick(ethKey), 60);
        // A swap that is too small leaves part of the position over (ETH).
        vm.prank(keeper);
        vault.rebalance(id, base - 600, base + 600, true, 1 ether, "");
        (uint256 u0, uint256 u1) = vault.unplaced(id);
        assertGt(u0, 0, "leftover recorded");
        assertLe(u0, address(vault).balance);
        assertLe(u1, usdg.balanceOf(address(vault)));

        _tradeEth(3);
        uint128 liqBefore = IPositionManagerV4(posm).getPositionLiquidity(vault.getPosition(id).tokenId);
        vm.prank(keeper);
        vault.poke(id);
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(keeper);
        vault.compound(id, true, u0 / 2, "");
        assertGt(IPositionManagerV4(posm).getPositionLiquidity(vault.getPosition(id).tokenId), liqBefore);
        // The leftover went in (only the part the rough swap could not match is still waiting).
        (uint256 v0,) = vault.unplaced(id);
        assertLt(v0, (u0 * 3) / 4, "leftover went back in");
    }

    function test_unplaced_notClaimable_closeReturnsIt() public {
        uint256 id = _openEth();
        trader.swap(ethKey, true, 60 ether);
        vm.warp(vm.getBlockTimestamp() + 31 minutes);
        vm.prank(keeper);
        vault.poke(id);
        vm.warp(vm.getBlockTimestamp() + 61);
        int24 base = _floor(_tick(ethKey), 60);
        vm.prank(keeper);
        vault.rebalance(id, base - 600, base + 600, true, 1 ether, "");
        (uint256 u0,) = vault.unplaced(id);
        assertGt(u0, 0);
        // Claiming (also as ETH) takes what is ready to claim only: the leftover belongs to the position and stays.
        vm.prank(user);
        vault.claim(address(0), 0);
        assertEq(address(vault).balance, u0);
        _tradeEth(2);
        vm.prank(user);
        vault.claimAsEth(id, 0, type(uint160).max, 0, "");
        (uint256 v0,) = vault.unplaced(id);
        assertEq(v0, u0);
        assertGe(address(vault).balance, u0);
        // Closing returns everything, the leftover included.
        uint256 e = user.balance;
        vm.prank(user);
        vault.close(id, 0, 0);
        assertGe(user.balance - e, u0);
        (uint256 a, uint256 b) = vault.unplaced(id);
        assertEq(a + b, 0);
        assertEq(address(vault).balance, 0);
    }

    /// The owner's compound puts everything in; what still does not fit is never more "waiting" than before: fees
    /// that were ready to claim stay ready to claim.
    function test_unplaced_compoundNow_neverTurnsFeesIntoLeftover() public {
        uint256 id = _openEth();
        trader.swap(ethKey, true, 60 ether);
        vm.warp(vm.getBlockTimestamp() + 31 minutes);
        vm.prank(keeper);
        vault.poke(id);
        vm.warp(vm.getBlockTimestamp() + 61);
        int24 base = _floor(_tick(ethKey), 60);
        vm.prank(keeper);
        vault.rebalance(id, base - 600, base + 600, true, 1 ether, "");
        (uint256 u0, uint256 u1) = vault.unplaced(id);
        _tradeEth(2);
        // Without a swap most of the ETH does not fit.
        vm.prank(user);
        vault.compoundNow(id, 0, type(uint160).max, false, 0, "");
        (uint256 v0, uint256 v1) = vault.unplaced(id);
        assertLe(v0, u0);
        assertLe(v1, u1);
    }

    function test_rebalance_rules() public {
        uint256 id = _openEth();
        int24 base = _floor(_tick(ethKey), 60);
        vm.prank(keeper);
        vm.expectRevert(TidewellShapedBase.TooSoon.selector);
        vault.rebalance(id, base - 600, base + 600, false, 0, "");
        vm.prank(stranger);
        vm.expectRevert(TidewellShapedBase.NotAllowed.selector);
        vault.rebalance(id, base - 600, base + 600, false, 0, "");
    }

    function test_chainlinkPath_erc20Pool() public {
        MockFeed fw = new MockFeed();
        MockFeed fu = new MockFeed();
        fw.set(2500e8, block.timestamp);
        fu.set(1e8, block.timestamp);
        factory.setFeed(address(weth), address(fw), 1 days);
        factory.setFeed(address(usdg), address(fu), 1 days);

        int24 base = _floor(_tick(ercKey), 10);
        (uint256 a0, uint256 a1) =
            Currency.unwrap(ercKey.currency0) == address(weth) ? (uint256(10 ether), uint256(25_000e6)) : (uint256(25_000e6), uint256(10 ether));
        vm.prank(user);
        uint256 id = vault.open(_params(ercKey, base - 600, base + 600, a0, a1, _settings()));
        // With fresh feeds no poke is needed.
        vm.prank(keeper);
        vault.compound(id, false, 0, "");
        // Feeds that disagree with the pool stop the keeper.
        fw.set(2000e8, block.timestamp);
        vm.prank(keeper);
        vm.expectRevert();
        vault.compound(id, false, 0, "");
    }

    function test_close_returnsEverything_evenWhenPaused() public {
        uint256 id = _openEth();
        _tradeEth(5);
        vm.prank(guardian);
        factory.setPaused(true);
        uint256 e = user.balance;
        uint256 u = usdg.balanceOf(user);
        vm.prank(user);
        vault.close(id, 0, 0);
        assertGt(user.balance, e);
        assertGt(usdg.balanceOf(user), u);
        assertEq(address(vault).balance, 0); // the gas tank went back too
        assertEq(usdg.balanceOf(address(vault)), 0);
        assertEq(vault.positionIds().length, 0);
    }

    function test_onlyOwnerWithdraws() public {
        uint256 id = _openEth();
        vm.startPrank(keeper);
        vm.expectRevert(TidewellShapedBase.NotOwner.selector);
        vault.close(id, 0, 0);
        vm.expectRevert(TidewellShapedBase.NotOwner.selector);
        vault.claim(address(0), 0);
        vm.expectRevert(TidewellShapedBase.NotOwner.selector);
        vault.remove(id, 1, 0, 0);
        vm.stopPrank();
    }

    function test_hooksNeedReview() public {
        PoolKey memory k = ethKey;
        k.hooks = IHooks(address(0x1234));
        vm.prank(user);
        vm.expectRevert(TidewellShapedVaultV4.HookNotAllowed.selector);
        vault.open(_params(k, -600, 600, 0, 1e6, _settings()));
    }

    function test_ownerPriceProtection() public {
        int24 base = _floor(_tick(ethKey), 60);
        TidewellShapedVaultV4.OpenParams memory p = _params(ethKey, base - 600, base + 600, 1 ether, 2_500e6, _settings());
        p.sqrtPriceMax = TickMath.MIN_SQRT_PRICE + 1; // the user expected a much lower price
        vm.prank(user);
        vm.expectRevert(TidewellShapedVaultV4.PriceOutOfBounds.selector);
        vault.open{value: 1 ether}(p);
    }

    function test_rescue_handsOverNft() public {
        uint256 id = _openEth();
        uint256 tokenId = vault.getPosition(id).tokenId;
        vm.prank(user);
        vault.rescue(id);
        assertEq(IOwnerOf(posm).ownerOf(tokenId), user);
    }

    function test_swapper_onlyVaultsAndPoolManager() public {
        TidewellSwapper sw = TidewellSwapper(payable(factory.swapper()));
        vm.expectRevert(TidewellSwapper.NotAllowed.selector);
        sw.unlockCallback("");
        vm.expectRevert(TidewellSwapper.NotAllowed.selector);
        sw.swap(ethKey, true, 1, 0, "");
        vm.expectRevert(TidewellSwapper.NotAllowed.selector);
        sw.swapToken(address(usdg), address(0), 1, "");
    }

    /// With a route, the swap runs through Uniswap's Universal Router (here a stand-in): ETH in as value.
    function test_route_ethIn() public {
        uint256 id = _openEth();
        _tradeEth(10);
        vm.prank(keeper);
        vault.poke(id);
        vm.warp(block.timestamp + 61);
        uint256 r0 = address(mockRouter).balance;
        bytes memory route = abi.encode(address(0), address(usdg), uint256(1e15), uint256(2_480_000));
        vm.prank(keeper);
        vault.compound(id, true, 1e15, route);
        assertEq(address(mockRouter).balance, r0 + 1e15, "router got the ETH");
        address sw = factory.swapper();
        assertEq(sw.balance, 0, "swapper keeps nothing");
        assertEq(usdg.balanceOf(sw), 0, "swapper keeps nothing");
    }

    /// A token in goes to the router through the swapper's standing Permit2 allowance, as Uniswap's routes expect.
    function test_route_tokenIn() public {
        uint256 id = _openEth();
        _tradeEth(10);
        vm.prank(keeper);
        vault.poke(id);
        vm.warp(block.timestamp + 61);
        bytes memory route = abi.encode(address(usdg), address(0), uint256(1e6), uint256(0.000396 ether));
        vm.prank(keeper);
        vault.compound(id, false, 1e6, route);
        assertEq(usdg.balanceOf(address(mockRouter)), 1e6, "router pulled the USDG via Permit2");
        assertEq(usdg.balanceOf(factory.swapper()), 0, "swapper keeps nothing");
    }

    /// A route that gives too little is refused by the vault's own price check.
    function test_route_badPriceReverts() public {
        uint256 id = _openEth();
        _tradeEth(10);
        vm.prank(keeper);
        vault.poke(id);
        vm.warp(block.timestamp + 61);
        bytes memory route = abi.encode(address(0), address(usdg), uint256(1e15), uint256(2_000_000)); // 20% short
        vm.prank(keeper);
        vm.expectRevert(TidewellShapedBase.BadSwap.selector);
        vault.compound(id, true, 1e15, route);
    }

    /// Swaps go through the pool set for the pair (the deepest one), not the position's own thin pool.
    function test_swapPool_deepPoolUsed() public {
        // A second, much deeper ETH/USDG pool with another fee tier.
        PoolKey memory deep = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(usdg)), 500, 10, IHooks(address(0)));
        pm.initialize(deep, _sqrtPrice(2500e6, 1e18));
        _fund(whale, 1_000 ether, 10_000_000e6);
        TidewellShapedVaultV4 bg2 = TidewellShapedVaultV4(payable(factory.vaultOf(whale, 1)));
        vm.prank(whale);
        bg2.open{value: 500 ether}(_params(deep, -887_270, 887_270, 500 ether, 1_250_000e6, _wide(1_774_540)));

        // Only the keeper or the owner may pick the swap pool.
        vm.prank(user);
        vm.expectRevert(TidewellFactory.NotKeeper.selector);
        factory.setSwapPool(1, address(0), address(usdg), 500, 10, address(0));
        vm.prank(keeper);
        factory.setSwapPool(1, address(0), address(usdg), 500, 10, address(0));

        uint256 id = _openEth();
        _tradeEth(10);
        vm.prank(keeper);
        vault.poke(id);
        vm.warp(block.timestamp + 61);
        bytes32 deepId = PoolId.unwrap(PoolIdLibrary.toId(deep));
        vm.recordLogs();
        vm.prank(keeper);
        vault.compound(id, true, 1e9, "");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool swappedInDeep;
        for (uint256 i; i < logs.length; ++i) {
            // PoolManager Swap(id indexed, ...)
            if (logs[i].emitter == address(pm) && logs[i].topics.length > 1 && logs[i].topics[1] == deepId) swappedInDeep = true;
        }
        assertTrue(swappedInDeep, "swap went through the deep pool");
        assertEq(address(factory.swapper()).balance, 0, "swapper keeps nothing");
        assertEq(usdg.balanceOf(factory.swapper()), 0, "swapper keeps nothing");
    }

    // ------------------------------------------------------------ revenue and referrals

    address friendInviter = makeAddr("inviter");
    address dWell = makeAddr("well");
    address dBoost = makeAddr("boost");
    address dBurn = makeAddr("burner");
    address dSafety = makeAddr("safety");
    address dTeam = makeAddr("teamSafe");

    function _revenueSetup() internal returns (RevenueRouter router, ReferralRegistry reg) {
        reg = new ReferralRegistry(address(factory));
        router = new RevenueRouter(address(this), address(reg), address(factory), dWell, dBoost, dBurn, dSafety, dTeam);
        factory.setFee(address(router), 200, address(reg));
    }

    function test_referral_andRevenueSplit() public {
        (RevenueRouter router, ReferralRegistry reg) = _revenueSetup();
        address friend = makeAddr("friend");
        _fund(friend, 50 ether, 100_000e6);
        vm.prank(friend);
        reg.setReferrer(friendInviter);
        assertEq(reg.discountBps(friend), 1000);
        vm.prank(friend);
        TidewellShapedVaultV4 fv = TidewellShapedVaultV4(payable(factory.createVault(1)));
        _approve(friend, address(fv));
        int24 base = _floor(_tick(ethKey), 60);
        vm.prank(friend);
        uint256 id = fv.open{value: 10 ether}(_params(ethKey, base - 600, base + 600, 10 ether, 25_000e6, _settings()));
        _tradeEth(10);
        vm.prank(keeper);
        fv.poke(id);
        vm.warp(block.timestamp + 61);

        vm.recordLogs();
        vm.prank(keeper);
        fv.compound(id, false, 0, "");
        uint256 fee;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(fv) && logs[i].topics[0] == keccak256("FeesCollected(uint256,uint256,uint256,uint256,uint256)")) {
                (uint256 c0, uint256 c1, uint256 p0,) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
                (uint160 sqrtP,,,) = pm.getSlot0(ethKey.toId());
                uint256 inEth = Math.mulDiv(Math.mulDiv(c1, 1 << 96, sqrtP), 1 << 96, sqrtP);
                // 2% with the 10% friend discount = 1.8%.
                assertApproxEqRel(p0, ((c0 + inEth) * 180) / 10_000, 0.001e18);
                fee = p0;
            }
        }
        assertGt(fee, 0);
        // 20% of it is the inviter's, the rest waits to be split.
        uint256 ref = (fee * 2000) / 10_000;
        assertEq(router.referralOwed(friendInviter, address(0)), ref);
        assertEq(router.pending(address(0)), fee - ref);

        address[] memory tokens = new address[](1);
        vm.prank(friendInviter);
        router.claimReferral(tokens);
        assertEq(friendInviter.balance, ref);

        uint256 amount = router.pending(address(0));
        router.distribute(address(0));
        assertEq(dWell.balance, (amount * 3000) / 10_000);
        assertEq(dBoost.balance, (amount * 500) / 10_000);
        assertEq(dBurn.balance, (amount * 3500) / 10_000);
        assertEq(dSafety.balance, (amount * 1500) / 10_000);
        assertEq(dWell.balance + dBoost.balance + dBurn.balance + dSafety.balance + dTeam.balance, amount);
        assertEq(address(router).balance, 0);

        // The discount ends after three months.
        vm.warp(block.timestamp + 91 days);
        assertEq(reg.discountBps(friend), 0);
    }

    function test_referral_rules() public {
        (, ReferralRegistry reg) = _revenueSetup();
        vm.prank(user); // already has a vault
        vm.expectRevert(ReferralRegistry.NotNewUser.selector);
        reg.setReferrer(friendInviter);
        address n = makeAddr("newbie");
        vm.prank(n);
        vm.expectRevert(ReferralRegistry.InvalidReferrer.selector);
        reg.setReferrer(n);
        vm.prank(n);
        reg.setReferrer(friendInviter);
        vm.prank(n);
        vm.expectRevert(ReferralRegistry.AlreadyLinked.selector);
        reg.setReferrer(stranger);
        vm.prank(friendInviter); // cannot invite the one who invited you
        vm.expectRevert(ReferralRegistry.InvalidReferrer.selector);
        reg.setReferrer(n);
    }

    function test_router_onlyVaultsReportFees() public {
        (RevenueRouter router,) = _revenueSetup();
        vm.prank(stranger);
        vm.expectRevert(RevenueRouter.NotVault.selector);
        router.onProtocolFee(stranger, address(0), 1 ether);
    }

    function test_router_ponsClaimAndTideBurn() public {
        (RevenueRouter router,) = _revenueSetup();
        MockPonsEscrow escrow = new MockPonsEscrow();
        MockERC20 tide = new MockERC20("TIDE", 18);
        router.setPons(address(escrow), address(0x1), address(0x2), address(tide));
        escrow.credit{value: 2 ether}(address(router));
        assertEq(router.claimPons(address(0)), 2 ether);
        assertEq(router.pending(address(0)), 2 ether);
        router.distribute(address(0));
        assertEq(dTeam.balance, 0.3 ether);

        tide.mint(address(router), 1000 ether);
        router.sync(address(tide));
        // Without an expansion reserve TIDE cannot be split yet.
        vm.expectRevert(RevenueRouter.ZeroAddress.selector);
        router.distribute(address(tide));
        Reserve expansion = new Reserve(address(this), "Expansion to other chains");
        router.setExpansionReserve(address(expansion));
        router.distribute(address(tide));
        // 35% burned (the same share as from ETH revenue), 50% kept for expansion, 15% to the boosted-pools reserve.
        assertEq(tide.balanceOf(router.DEAD()), 350 ether);
        assertEq(tide.balanceOf(address(expansion)), 500 ether);
        assertEq(tide.balanceOf(router.boostReserve()), 150 ether);
        assertEq(router.pending(address(tide)), 0);
        // The reserve pays out only through its owner (the timelock on mainnet), with a reason.
        vm.prank(address(0xBAD));
        vm.expectRevert();
        expansion.payToken(address(tide), address(0xBAD), 1, "");
        expansion.payToken(address(tide), address(0xB21D6E), 100 ether, "bridge to the new chain");
        assertEq(tide.balanceOf(address(0xB21D6E)), 100 ether);
    }

    function test_router_limits() public {
        (RevenueRouter router,) = _revenueSetup();
        vm.expectRevert(RevenueRouter.OutOfBounds.selector);
        router.setSplit(RevenueRouter.Split({staking: 2000, boosts: 500, burn: 3000, safety: 1500, team: 3000}));
        vm.expectRevert(RevenueRouter.OutOfBounds.selector);
        router.setSplit(RevenueRouter.Split({staking: 3000, boosts: 500, burn: 3500, safety: 1500, team: 1000}));
        vm.expectRevert(RevenueRouter.OutOfBounds.selector);
        router.setRefShare(3001);
        vm.prank(stranger);
        vm.expectRevert();
        router.setDestinations(stranger, stranger, stranger, stranger, stranger);
    }

    // ------------------------------------------------------------ buyback and burn

    function _tidePool() internal returns (MockERC20 tide, PoolKey memory key) {
        tide = new MockERC20("TIDE", 18);
        // Make sure TIDE sorts after native ETH (always true: address zero is lowest).
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(tide)), 3000, 60, IHooks(address(0)));
        // 1 ETH = 60,000 TIDE
        pm.initialize(key, _sqrtPrice(60_000e18, 1e18));
        factory.setTokenCap(address(tide), 1e30);
        tide.mint(whale, 1_000_000_000e18);
        TidewellShapedVaultV4 bg = TidewellShapedVaultV4(payable(factory.vaultOf(whale, 1)));
        vm.prank(whale);
        tide.approve(address(bg), type(uint256).max);
        vm.deal(whale, 200 ether);
        vm.prank(whale);
        bg.open{value: 100 ether}(
            _params(key, -887220, 887220, 100 ether, 6_000_000e18, _wide(1_774_440))
        );
    }

    function test_buyback_onCurveFirst_thenPoolByItself() public {
        (MockERC20 tide, PoolKey memory key) = _tidePool();
        BuybackBurner burner = new BuybackBurner(address(this), address(pm), address(factory));
        MockPonsCurve curve = new MockPonsCurve(tide);
        MockPonsLaunches pons = new MockPonsLaunches();
        pons.launch(address(tide), address(curve), key.fee, key.tickSpacing, address(0));
        vm.deal(address(burner), 3 ether);

        // Before the deployer points it at TIDE's launch: nowhere to buy.
        assertEq(burner.market(), 0);
        vm.prank(stranger);
        vm.expectRevert();
        burner.setPonsSource(address(pons), address(tide));
        burner.setPonsSource(address(pons), address(tide));
        vm.expectRevert(BuybackBurner.BadPool.selector); // once only
        burner.setPonsSource(address(pons), address(tide));
        assertEq(burner.market(), 1);
        assertEq(burner.interval(), 8 hours);

        // On the curve: poke, then buy a minute later; never during the anti-snipe tax.
        curve.setSnipe(5000);
        vm.prank(keeper);
        burner.poke();
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(keeper);
        vm.expectRevert(BuybackBurner.SnipeTax.selector);
        burner.buyAndBurn();
        curve.setSnipe(0);
        vm.prank(keeper);
        burner.poke();
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(keeper);
        (uint256 ethIn, uint256 burned) = burner.buyAndBurn();
        assertEq(ethIn, 0.5 ether);
        assertGt(burned, 0);
        assertEq(tide.balanceOf(burner.DEAD()), burned);
        assertEq(tide.balanceOf(address(burner)), 0);

        // Three buys a day on the curve: not again within 8 hours, then again.
        vm.prank(keeper);
        burner.poke();
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(keeper);
        vm.expectRevert(BuybackBurner.TooSoon.selector);
        burner.buyAndBurn();
        vm.warp(vm.getBlockTimestamp() + 8 hours);
        vm.prank(keeper);
        burner.poke();
        // Someone pushes the curve price up between poke and buy: the buy waits.
        vm.deal(whale, 10 ether);
        vm.prank(whale);
        curve.buy{value: 1 ether}(1 ether, 0, whale);
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(keeper);
        vm.expectPartialRevert(BuybackBurner.CurvePriceMoved.selector);
        burner.buyAndBurn();
        vm.prank(keeper);
        burner.poke();
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(keeper);
        (ethIn,) = burner.buyAndBurn();
        assertEq(ethIn, 0.5 ether);

        // TIDE graduates: the next poke switches to the Uniswap pool by itself, no owner and no waiting period.
        curve.setGraduated(true);
        pons.setPhase(1); // swept, pool not created yet: the ETH waits
        assertEq(burner.market(), 0);
        pons.setPhase(2);
        assertEq(burner.market(), 2);
        assertFalse(burner.poolSet());
        vm.prank(keeper);
        burner.poke();
        assertTrue(burner.poolSet());
        (Currency c0, Currency c1, uint24 fee, int24 spacing,) = burner.poolKey();
        assertEq(Currency.unwrap(c0), address(0));
        assertEq(Currency.unwrap(c1), address(tide));
        assertEq(fee, key.fee);
        assertEq(spacing, key.tickSpacing);
        assertEq(burner.interval(), 20 hours);
        assertEq(burner.lastBuy(), 0); // the first pool buy may follow right away
        vm.warp(vm.getBlockTimestamp() + 61);
        uint256 deadBefore = tide.balanceOf(burner.DEAD());
        vm.prank(keeper);
        (ethIn, burned) = burner.buyAndBurn();
        assertEq(ethIn, 0.5 ether);
        assertEq(tide.balanceOf(burner.DEAD()), deadBefore + burned);
    }

    function test_buyback_curveLimits_onlyOwner_andBounds() public {
        BuybackBurner burner = new BuybackBurner(address(this), address(pm), address(factory));
        vm.prank(stranger);
        vm.expectRevert();
        burner.setCurveLimits(6 hours, 200);
        vm.expectRevert(BuybackBurner.OutOfBounds.selector);
        burner.setCurveLimits(13 hours, 200); // fewer than two buys a day
        burner.setCurveLimits(6 hours, 200);
        assertEq(burner.curveInterval(), 6 hours);
    }

    function test_buyback_buysAndBurnsTide() public {
        (MockERC20 tide, PoolKey memory key) = _tidePool();
        BuybackBurner burner = new BuybackBurner(address(this), address(pm), address(factory));
        vm.deal(address(burner), 3 ether);

        vm.prank(keeper);
        vm.expectRevert(BuybackBurner.NoPool.selector);
        burner.poke();
        burner.setPool(key);

        vm.prank(keeper);
        vm.expectRevert(BuybackBurner.NoPriceCheck.selector);
        burner.buyAndBurn();

        vm.prank(keeper);
        burner.poke();
        vm.warp(block.timestamp + 61);
        vm.prank(keeper);
        (uint256 ethIn, uint256 burned) = burner.buyAndBurn();
        assertEq(ethIn, 0.5 ether); // capped per buy
        assertApproxEqRel(burned, 30_000e18, 0.02e18); // about 60,000 TIDE per ETH, minus fee and impact
        assertEq(tide.balanceOf(burner.DEAD()), burned);
        assertEq(tide.balanceOf(address(burner)), 0);
        assertEq(address(burner).balance, 2.5 ether);

        // One buy per interval.
        vm.prank(keeper);
        burner.poke();
        vm.warp(block.timestamp + 61);
        vm.prank(keeper);
        vm.expectRevert(BuybackBurner.TooSoon.selector);
        burner.buyAndBurn();
    }

    function test_buyback_refusesMovedPrice_andStrangers() public {
        (, PoolKey memory key) = _tidePool();
        BuybackBurner burner = new BuybackBurner(address(this), address(pm), address(factory));
        burner.setPool(key);
        vm.deal(address(burner), 1 ether);
        vm.prank(stranger);
        vm.expectRevert(BuybackBurner.NotKeeper.selector);
        burner.buyAndBurn();
        vm.prank(keeper);
        burner.poke();
        vm.warp(block.timestamp + 61);
        trader.swap(key, true, 20 ether); // someone moves the TIDE price between poke and buy
        vm.prank(keeper);
        vm.expectRevert();
        burner.buyAndBurn();
        vm.expectRevert(BuybackBurner.OutOfBounds.selector);
        burner.setLimits(1 ether, 1 hours, 600, 100);
    }

    function test_router_convertV4_stockTokenToEth() public {
        (RevenueRouter router,) = _revenueSetup();
        MockERC20 stock = new MockERC20("NVDA", 18);
        PoolKey memory key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(stock)), 3000, 60, IHooks(address(0)));
        // 1 ETH = 14 NVDA (ETH 2,500, NVDA ~178.57)
        pm.initialize(key, _sqrtPrice(14e18, 1e18));
        factory.setTokenCap(address(stock), 1e30);
        stock.mint(whale, 1_000_000e18);
        TidewellShapedVaultV4 bg = TidewellShapedVaultV4(payable(factory.vaultOf(whale, 1)));
        vm.prank(whale);
        stock.approve(address(bg), type(uint256).max);
        vm.deal(whale, 2_000 ether);
        vm.prank(whale);
        bg.open{value: 1_000 ether}(_params(key, -887220, 887220, 1_000 ether, 14_000e18, _wide(1_774_440)));

        MockFeed fe = new MockFeed();
        MockFeed fs = new MockFeed();
        fe.set(2500e8, block.timestamp);
        fs.set(178_57142857, block.timestamp);
        factory.setFeed(address(weth), address(fe), 1 days);
        factory.setFeed(address(stock), address(fs), 1 days);

        stock.mint(address(router), 14e18); // fees that arrived in NVDA
        router.sync(address(stock));
        vm.prank(keeper);
        uint256 out = router.convertV4(address(stock), key);
        assertApproxEqRel(out, 1 ether, 0.01e18);
        assertEq(router.pending(address(stock)), 0);
        assertEq(router.pending(address(0)), out);

        // A stale feed (weekend) stops it.
        stock.mint(address(router), 1e18);
        router.sync(address(stock));
        vm.warp(block.timestamp + 2 days);
        vm.prank(keeper);
        vm.expectRevert(RevenueRouter.NoPriceCheck.selector);
        router.convertV4(address(stock), key);
    }

    // ------------------------------------------------------------ one-transaction open (Permit2)

    bytes32 constant TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");
    bytes32 constant PERMIT_BATCH_TYPEHASH = keccak256(
        "PermitBatchTransferFrom(TokenPermissions[] permitted,address spender,uint256 nonce,uint256 deadline)TokenPermissions(address token,uint256 amount)"
    );

    function _permit(address[] memory tokens, uint256[] memory amounts, uint256 nonce)
        internal
        view
        returns (ISignatureTransfer.PermitBatchTransferFrom memory p)
    {
        p.permitted = new ISignatureTransfer.TokenPermissions[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            p.permitted[i] = ISignatureTransfer.TokenPermissions(tokens[i], amounts[i]);
        }
        p.nonce = nonce;
        p.deadline = block.timestamp + 30 minutes;
    }

    function _sign(ISignatureTransfer.PermitBatchTransferFrom memory p, uint256 key, address spender)
        internal
        view
        returns (bytes memory)
    {
        bytes32[] memory hashes = new bytes32[](p.permitted.length);
        for (uint256 i; i < p.permitted.length; ++i) {
            hashes[i] = keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, p.permitted[i]));
        }
        bytes32 structHash = keccak256(
            abi.encode(PERMIT_BATCH_TYPEHASH, keccak256(abi.encodePacked(hashes)), spender, p.nonce, p.deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", IPermit2Domain(permit2).DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _newcomer(string memory name) internal returns (address who, uint256 key) {
        (who, key) = makeAddrAndKey(name);
        _fund(who, 50 ether, 100_000e6);
        vm.startPrank(who);
        weth.approve(permit2, type(uint256).max); // the one-time approval of Permit2 (shared with Uniswap)
        usdg.approve(permit2, type(uint256).max);
        vm.stopPrank();
    }

    function test_openWithPermit_ethPool_withInvite_oneTransaction() public {
        (, ReferralRegistry reg) = _revenueSetup();
        factory.setReferrals(address(reg));
        vm.prank(friendInviter);
        reg.registerCode(bytes8("tidewell"));
        (address n, uint256 key) = _newcomer("newcomer");

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdg);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 25_000e6;
        ISignatureTransfer.PermitBatchTransferFrom memory p = _permit(tokens, amounts, 0);
        bytes memory sig = _sign(p, key, address(factory));
        int24 base = _floor(_tick(ethKey), 60);
        bytes memory call = abi.encodeCall(
            TidewellShapedVaultV4.openFromBalance, (_params(ethKey, base - 600, base + 600, 10 ether, 25_000e6, _settings()))
        );
        uint256 ethBefore = n.balance;
        vm.prank(n);
        address v = factory.openWithPermit{value: 10 ether}(1, bytes8("tidewell"), p, sig, call);

        assertEq(v, factory.vaultOf(n, 1));
        assertEq(TidewellShapedBase(payable(v)).owner(), n);
        assertEq(reg.referrerOf(n), friendInviter);
        TidewellShapedVaultV4.Position memory pos = TidewellShapedVaultV4(payable(v)).getPosition(1);
        assertEq(IOwnerOf(posm).ownerOf(pos.tokenId), v);
        assertGt(IPositionManagerV4(posm).getPositionLiquidity(pos.tokenId), 0);
        // Leftovers went back to the newcomer; nothing stays behind in the vault or the factory.
        assertGt(n.balance, ethBefore - 10 ether);
        assertEq(usdg.balanceOf(v), 0);
        assertEq(address(v).balance, 0);
        assertEq(usdg.balanceOf(address(factory)), 0);
        assertEq(address(factory).balance, 0);
    }

    function test_openWithPermit_erc20Pool_twoTokens_existingVault() public {
        (address n, uint256 key) = _newcomer("second");
        vm.prank(n);
        address existing = factory.createVault(1);
        (address a, address b) = (Currency.unwrap(ercKey.currency0), Currency.unwrap(ercKey.currency1));
        (uint256 e0, uint256 e1) = a == address(weth) ? (uint256(1 ether), uint256(2_500e6)) : (uint256(2_500e6), uint256(1 ether));
        address[] memory tokens = new address[](2);
        tokens[0] = a;
        tokens[1] = b;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = e0;
        amounts[1] = e1;
        ISignatureTransfer.PermitBatchTransferFrom memory p = _permit(tokens, amounts, 7);
        bytes memory sig = _sign(p, key, address(factory));
        int24 base = _floor(_tick(ercKey), 10);
        bytes memory call =
            abi.encodeCall(TidewellShapedVaultV4.openFromBalance, (_params(ercKey, base - 600, base + 600, e0, e1, _settings())));
        vm.prank(n);
        address v = factory.openWithPermit(1, bytes8(0), p, sig, call);
        assertEq(v, existing);
        assertGt(IPositionManagerV4(posm).getPositionLiquidity(TidewellShapedVaultV4(payable(v)).getPosition(1).tokenId), 0);

        // The same signature cannot be used twice.
        vm.prank(n);
        vm.expectRevert();
        factory.openWithPermit(1, bytes8(0), p, sig, call);
    }

    function test_openWithPermit_refusesOthersSignature_andStrangers() public {
        (, uint256 key) = _newcomer("victim");
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdg);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 25_000e6;
        ISignatureTransfer.PermitBatchTransferFrom memory p = _permit(tokens, amounts, 0);
        bytes memory sig = _sign(p, key, address(factory));
        int24 base = _floor(_tick(ethKey), 60);
        bytes memory call = abi.encodeCall(
            TidewellShapedVaultV4.openFromBalance, (_params(ethKey, base - 600, base + 600, 10 ether, 25_000e6, _settings()))
        );
        // Someone else cannot use the victim's signature: Permit2 checks it against the caller.
        vm.deal(stranger, 20 ether);
        vm.prank(stranger);
        vm.expectRevert();
        factory.openWithPermit{value: 10 ether}(1, bytes8(0), p, sig, call);
        // Nobody but the owner and the factory may open from the vault's balance.
        vm.deal(stranger, 20 ether);
        vm.prank(stranger);
        vm.expectRevert(TidewellShapedBase.NotOwner.selector);
        vault.openFromBalance{value: 10 ether}(_params(ethKey, base - 600, base + 600, 10 ether, 25_000e6, _settings()));
        // An invite code only works for a new user.
        (, ReferralRegistry reg) = _revenueSetup();
        factory.setReferrals(address(reg));
        vm.prank(friendInviter);
        reg.registerCode(bytes8("tidewell"));
        vm.prank(user);
        vm.expectRevert(ReferralRegistry.NotNewUser.selector);
        factory.openWithPermit{value: 0}(1, bytes8("tidewell"), p, sig, call);
        // Only the factory may link a code for someone else.
        vm.prank(stranger);
        vm.expectRevert(ReferralRegistry.NotFactory.selector);
        reg.setReferrerByCodeFor(makeAddr("x"), bytes8("tidewell"));
    }

    // ------------------------------------------------------------ liquidity shapes

    /// Widths that are whole numbers of 7 bands on the 60-tick spacing.
    function _shapeSettings() internal pure returns (TidewellShapedBase.Settings memory) {
        return TidewellShapedBase.Settings({
            minWidth: 840,
            maxWidth: 8400,
            cooldown: 30 minutes,
            compoundBps: 10_000,
            slippageBps: 100,
            rule: 0,
            outDelay: 0
        });
    }

    function _openShape(uint8 shape) internal returns (uint256 id) {
        int24 base = _floor(_tick(ethKey), 60);
        TidewellShapedVaultV4.OpenParams memory p =
            _params(ethKey, base - 1260, base + 1260, 10 ether, 25_000e6, _shapeSettings());
        p.shape = shape;
        vm.prank(user);
        id = vault.open{value: 10 ether}(p);
    }

    function _bandLiq(uint256 id) internal view returns (uint128[] memory l) {
        TidewellShapedVaultV4.Position memory pos = vault.getPosition(id);
        uint256 n = vault.bandsOf(id);
        l = new uint128[](n);
        for (uint256 i; i < n; ++i) {
            l[i] = IPositionManagerV4(posm).getPositionLiquidity(pos.tokenId + i);
        }
    }

    /// Band liquidities must follow the shape's weights exactly (liquidity = weight × one common unit).
    function _assertShape(uint256 id, uint8 shape) internal view {
        uint128[] memory l = _bandLiq(id);
        assertEq(l.length, Shapes.bands(shape));
        uint256 unit = l[0] / Shapes.weight(shape, 0);
        for (uint256 i; i < l.length; ++i) {
            assertGt(l[i], 0, "band has liquidity");
            assertApproxEqRel(uint256(l[i]), unit * Shapes.weight(shape, i), 1e12, "weight");
        }
    }

    function test_shape_centered_sevenBandsInProportion() public {
        uint256 ethBefore = user.balance;
        uint256 usdBefore = usdg.balanceOf(user);
        uint256 id = _openShape(Shapes.CENTERED);
        TidewellShapedVaultV4.Position memory pos = vault.getPosition(id);
        assertEq(vault.bandsOf(id), 7);
        assertEq(pos.shape, Shapes.CENTERED);
        for (uint256 i; i < 7; ++i) {
            assertEq(IOwnerOf(posm).ownerOf(pos.tokenId + i), address(vault), "vault owns every band");
        }
        _assertShape(id, Shapes.CENTERED);
        // The middle band holds 4x the outer ones.
        uint128[] memory l = _bandLiq(id);
        assertEq(uint256(l[3]), uint256(l[0]) * 4);
        // Most of the deposit went in; what did not fit went back to the user, nothing stays behind.
        assertGt(user.balance, ethBefore - 10 ether);
        assertLt(usdBefore - usdg.balanceOf(user), 25_000e6 + 1);
        assertEq(usdg.balanceOf(address(vault)), 0);
        assertEq(address(vault).balance, 0.01 ether);
    }

    function test_shape_edges_moreAtTheEnds() public {
        uint256 id = _openShape(Shapes.EDGES);
        _assertShape(id, Shapes.EDGES);
        uint128[] memory l = _bandLiq(id);
        assertEq(uint256(l[0]), uint256(l[3]) * 4);
        assertEq(uint256(l[6]), uint256(l[3]) * 4);
    }

    function test_shape_rules() public {
        int24 base = _floor(_tick(ethKey), 60);
        // A width that is not a whole number of 7 bands on the tick spacing.
        TidewellShapedVaultV4.OpenParams memory p =
            _params(ethKey, base - 1200, base + 1200, 1 ether, 2_500e6, _shapeSettings());
        p.shape = Shapes.CENTERED;
        p.settings.maxWidth = 8400;
        vm.prank(user);
        vm.expectRevert(TidewellShapedBase.BadRange.selector);
        vault.open{value: 1 ether}(p);
        // Settings the keeper could never meet with whole bands.
        p = _params(ethKey, base - 1260, base + 1260, 1 ether, 2_500e6, _settings());
        p.shape = Shapes.CENTERED;
        vm.prank(user);
        vm.expectRevert(TidewellShapedBase.BadSettings.selector);
        vault.open{value: 1 ether}(p);
        // Unknown shape.
        p = _params(ethKey, base - 1260, base + 1260, 1 ether, 2_500e6, _shapeSettings());
        p.shape = 3;
        vm.prank(user);
        vm.expectRevert(Shapes.BadShape.selector);
        vault.open{value: 1 ether}(p);
    }

    function test_shape_compoundKeepsTheShape() public {
        uint256 id = _openShape(Shapes.CENTERED);
        uint128[] memory before = _bandLiq(id);
        _tradeEth(10);
        vm.prank(keeper);
        vault.poke(id);
        skip(61);
        vm.prank(keeper);
        vault.compound(id, false, 0, "");
        uint128[] memory afterL = _bandLiq(id);
        for (uint256 i; i < 7; ++i) {
            assertGt(afterL[i], before[i], "every band grew");
        }
        _assertShapeRatio(afterL, before);
    }

    /// The added liquidity follows the weights too, so the shape stays exactly the same.
    function _assertShapeRatio(uint128[] memory a, uint128[] memory b) internal pure {
        uint256 d0 = a[0] - b[0];
        for (uint256 i; i < a.length; ++i) {
            assertApproxEqRel(uint256(a[i] - b[i]), d0 * Shapes.weight(Shapes.CENTERED, i), 1e12, "added in shape");
        }
    }

    function test_shape_rebalanceMovesAllBands() public {
        uint256 id = _openShape(Shapes.CENTERED);
        uint256 oldFirst = vault.getPosition(id).tokenId;
        trader.swap(ethKey, false, 400_000e6); // price up and out of the middle
        skip(31 minutes);
        vm.prank(keeper);
        vault.poke(id);
        skip(61);
        int24 base = _floor(_tick(ethKey), 60);
        // Everything is in USDG now: about half is swapped to ETH for the new range.
        vm.prank(keeper);
        vault.rebalance(id, base - 1260, base + 1260, false, 12_000e6, "");
        TidewellShapedVaultV4.Position memory pos = vault.getPosition(id);
        assertEq(pos.tickLower, base - 1260);
        assertGt(pos.tokenId, oldFirst + 6, "new bands");
        for (uint256 i; i < 7; ++i) {
            vm.expectRevert();
            IOwnerOf(posm).ownerOf(oldFirst + i); // old bands burnt
            assertEq(IOwnerOf(posm).ownerOf(pos.tokenId + i), address(vault));
        }
        _assertShape(id, Shapes.CENTERED);
        // A width that is not whole bands is refused.
        skip(31 minutes);
        vm.prank(keeper);
        vault.poke(id);
        skip(61);
        vm.prank(keeper);
        vm.expectRevert(TidewellShapedBase.BadRange.selector);
        vault.rebalance(id, base - 1200, base + 1200, false, 0, "");
    }

    function test_shape_removeShareAndClose() public {
        uint256 id = _openShape(Shapes.EDGES);
        uint128[] memory before = _bandLiq(id);
        uint256 usdBefore = usdg.balanceOf(user);
        vm.prank(user);
        vm.expectRevert(TidewellShapedVaultV4.BadValue.selector);
        vault.remove(id, 2e18, 0, 0);
        vm.prank(user);
        vault.remove(id, 0.5e18, 0, 0);
        uint128[] memory half = _bandLiq(id);
        for (uint256 i; i < 7; ++i) {
            assertApproxEqAbs(uint256(half[i]) * 2, uint256(before[i]), 2, "half of every band");
        }
        assertGt(usdg.balanceOf(user), usdBefore, "paid out");
        // Minimums are for the whole position.
        vm.prank(user);
        vm.expectRevert(TidewellShapedVaultV4.PriceOutOfBounds.selector);
        vault.close(id, type(uint128).max, 0);
        uint256 first = vault.getPosition(id).tokenId;
        vm.prank(user);
        vault.close(id, 0, 0);
        for (uint256 i; i < 7; ++i) {
            vm.expectRevert();
            IOwnerOf(posm).ownerOf(first + i);
        }
        assertEq(usdg.balanceOf(address(vault)), 0);
        assertEq(vault.positionIds().length, 0);
    }

    function test_shape_rescueHandsOverEveryBand() public {
        uint256 id = _openShape(Shapes.CENTERED);
        uint256 first = vault.getPosition(id).tokenId;
        vm.prank(user);
        vault.rescue(id);
        for (uint256 i; i < 7; ++i) {
            assertEq(IOwnerOf(posm).ownerOf(first + i), user);
        }
    }

    function test_keeper_compoundCooldown_ownerFree() public {
        uint256 id = _openShape(Shapes.CENTERED);
        _tradeEth(5);
        vm.prank(keeper);
        vault.poke(id);
        skip(61);
        vm.prank(keeper);
        vault.compound(id, false, 0, "");
        _tradeEth(5);
        vm.prank(keeper);
        vault.poke(id);
        skip(61);
        vm.prank(keeper);
        vm.expectRevert(TidewellShapedBase.TooSoon.selector);
        vault.compound(id, false, 0, "");
        // The owner is not limited (a fresh price record is still needed).
        vm.prank(user);
        vault.poke(id);
        skip(61);
        vm.prank(user);
        vault.compound(id, false, 0, "");
        // After the cooldown the keeper may again.
        skip(4 hours);
        _tradeEth(5);
        vm.prank(keeper);
        vault.poke(id);
        skip(61);
        vm.prank(keeper);
        vault.compound(id, false, 0, "");
    }

    function test_keeper_swapsPerDayLimited() public {
        uint256 id = _openShape(Shapes.EVEN);
        for (uint256 k; k < 5; ++k) {
            _tradeEth(3);
            skip(4 hours);
            vm.prank(keeper);
            vault.poke(id);
            skip(61);
            if (k == 4) {
                vm.prank(keeper);
                vm.expectRevert(TidewellShapedBase.TooManySwaps.selector);
                vault.compound(id, false, 1e6, "");
            } else {
                vm.prank(keeper);
                vault.compound(id, false, 1e6, "");
            }
            (, uint8 cnt) = vault.keeperSwaps(id);
            if (k < 4) assertEq(cnt, k + 1);
        }
        // A day later the window starts again.
        skip(1 days);
        _tradeEth(3);
        vm.prank(keeper);
        vault.poke(id);
        skip(61);
        vm.prank(keeper);
        vault.compound(id, false, 1e6, "");
    }

    /// Gas of the keeper's actions, one band against seven (printed with -vv).
    function test_gas_evenVersusCentered() public {
        uint256 even = _openShape(Shapes.EVEN);
        uint256 centered = _openShape(Shapes.CENTERED);
        _tradeEth(10);
        skip(31 minutes);
        uint256[2] memory ids = [even, centered];
        for (uint256 j; j < 2; ++j) {
            vm.prank(keeper);
            vault.poke(ids[j]);
        }
        skip(61);
        uint256[2] memory gCompound;
        for (uint256 j; j < 2; ++j) {
            uint256 g = gasleft();
            vm.prank(keeper);
            vault.compound(ids[j], false, 0, "");
            gCompound[j] = g - gasleft();
        }
        skip(31 minutes);
        for (uint256 j; j < 2; ++j) {
            vm.prank(keeper);
            vault.poke(ids[j]);
        }
        skip(61);
        int24 base = _floor(_tick(ethKey), 60);
        uint256[2] memory gMove;
        for (uint256 j; j < 2; ++j) {
            uint256 g = gasleft();
            vm.prank(keeper);
            vault.rebalance(ids[j], base - 1260, base + 1260, false, 0, "");
            gMove[j] = g - gasleft();
        }
        console.log("compound gas: even", gCompound[0], "centered", gCompound[1]);
        console.log("range move gas: even", gMove[0], "centered", gMove[1]);
    }

    // ------------------------------------------------------------ number of bands (3 to 15)

    function _enc(uint8 kind, uint256 n) internal pure returns (uint8) {
        return uint8(n << 2) | kind;
    }

    function _bandSettings(uint256 n) internal pure returns (TidewellShapedBase.Settings memory s) {
        s = _shapeSettings();
        s.minWidth = int24(int256(n * 60));
        s.maxWidth = int24(int256(n * 60 * (9000 / (n * 60) + 1)));
    }

    function _openShapeAt(uint8 shape, int24 half, TidewellShapedBase.Settings memory s) internal returns (uint256 id) {
        int24 base = _floor(_tick(ethKey), 60);
        TidewellShapedVaultV4.OpenParams memory p = _params(ethKey, base - half, base + half, 10 ether, 25_000e6, s);
        p.shape = shape;
        vm.prank(user);
        id = vault.open{value: 10 ether}(p);
    }

    function test_shape_bandCounts() public {
        // 3 bands: weights 1 2 1.
        uint8 c3 = _enc(Shapes.CENTERED, 3);
        uint256 id = _openShapeAt(c3, 1260, _bandSettings(3));
        assertEq(vault.bandsOf(id), 3);
        _assertShape(id, c3);
        uint128[] memory l = _bandLiq(id);
        assertEq(uint256(l[1]), uint256(l[0]) * 2);
        // 15 bands: weights 1..8..1 and 8..1..8.
        uint8 c15 = _enc(Shapes.CENTERED, 15);
        id = _openShapeAt(c15, 1800, _bandSettings(15));
        assertEq(vault.bandsOf(id), 15);
        _assertShape(id, c15);
        l = _bandLiq(id);
        assertEq(uint256(l[7]), uint256(l[0]) * 8);
        uint8 e15 = _enc(Shapes.EDGES, 15);
        id = _openShapeAt(e15, 1800, _bandSettings(15));
        _assertShape(id, e15);
        l = _bandLiq(id);
        assertEq(uint256(l[0]), uint256(l[7]) * 8);
        assertEq(uint256(l[14]), uint256(l[7]) * 8);
        // 7 written out is the same as the default.
        assertEq(Shapes.bands(_enc(Shapes.CENTERED, 7)), 7);
        assertEq(Shapes.weight(_enc(Shapes.CENTERED, 7), 3), Shapes.weight(Shapes.CENTERED, 3));
        // 15 bands need a width of whole 15 x 60 ticks.
        int24 base = _floor(_tick(ethKey), 60);
        TidewellShapedVaultV4.OpenParams memory p =
            _params(ethKey, base - 1260, base + 1260, 1 ether, 2_500e6, _bandSettings(15));
        p.shape = c15;
        vm.prank(user);
        vm.expectRevert(TidewellShapedBase.BadRange.selector);
        vault.open{value: 1 ether}(p);
    }

    function test_shape_badBandCounts() public {
        int24 base = _floor(_tick(ethKey), 60);
        uint8[6] memory bad = [
            _enc(Shapes.EVEN, 1),
            _enc(Shapes.CENTERED, 1),
            _enc(Shapes.CENTERED, 2),
            _enc(Shapes.EDGES, 16),
            _enc(Shapes.EDGES, 17),
            uint8(3)
        ];
        for (uint256 k; k < bad.length; ++k) {
            TidewellShapedVaultV4.OpenParams memory p =
                _params(ethKey, base - 1260, base + 1260, 1 ether, 2_500e6, _shapeSettings());
            p.shape = bad[k];
            vm.prank(user);
            vm.expectRevert(Shapes.BadShape.selector);
            vault.open{value: 1 ether}(p);
        }
    }

    function test_shape_fifteenBands_compoundRebalanceAndGas() public {
        uint8 c15 = _enc(Shapes.CENTERED, 15);
        uint256 id = _openShapeAt(c15, 1800, _bandSettings(15));
        _tradeEth(10);
        skip(31 minutes);
        vm.prank(keeper);
        vault.poke(id);
        skip(61);
        uint256 g = gasleft();
        vm.prank(keeper);
        vault.compound(id, false, 0, "");
        uint256 gCompound = g - gasleft();
        _assertShape(id, c15);
        skip(31 minutes);
        vm.prank(keeper);
        vault.poke(id);
        skip(61);
        int24 base = _floor(_tick(ethKey), 60);
        g = gasleft();
        vm.prank(keeper);
        vault.rebalance(id, base - 1800, base + 1800, false, 0, "");
        uint256 gMove = g - gasleft();
        _assertShape(id, c15);
        console.log("15 bands: compound gas", gCompound, "range move gas", gMove);
        // Closing hands back every band.
        uint256 first = vault.getPosition(id).tokenId;
        vm.prank(user);
        vault.close(id, 0, 0);
        for (uint256 i; i < 15; ++i) {
            vm.expectRevert();
            IOwnerOf(posm).ownerOf(first + i);
        }
    }

    /// The wait out of range is stored per position (the keeper keeps it); at most 24 hours.
    function test_outDelay_storedAndCapped() public {
        TidewellShapedBase.Settings memory st = _shapeSettings();
        st.outDelay = 1 hours;
        int24 base = _floor(_tick(ethKey), 60);
        TidewellShapedVaultV4.OpenParams memory p = _params(ethKey, base - 1260, base + 1260, 1 ether, 2_500e6, st);
        p.shape = Shapes.CENTERED;
        vm.prank(user);
        uint256 id = vault.open{value: 1 ether}(p);
        assertEq(vault.getPosition(id).settings.outDelay, 1 hours);
        st.outDelay = 24 hours + 1;
        vm.prank(user);
        vm.expectRevert(TidewellShapedBase.BadSettings.selector);
        vault.setSettings(id, st);
        st.outDelay = 24 hours;
        vm.prank(user);
        vault.setSettings(id, st);
        assertEq(vault.getPosition(id).settings.outDelay, 24 hours);
    }
}
