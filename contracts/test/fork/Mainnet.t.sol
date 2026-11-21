// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TidewellFactory} from "../../src/TidewellFactory.sol";
import {TidewellSwapper} from "../../src/TidewellSwapper.sol";
import {TidewellVaultBase} from "../../src/TidewellVaultBase.sol";
import {TidewellVaultV3} from "../../src/TidewellVaultV3.sol";
import {TidewellVaultV4} from "../../src/TidewellVaultV4.sol";
import {RevenueRouter} from "../../src/RevenueRouter.sol";
import {ReferralRegistry} from "../../src/ReferralRegistry.sol";
import {BuybackBurner} from "../../src/BuybackBurner.sol";
import {IUniswapV3Factory, IUniswapV3Pool, INonfungiblePositionManager} from "../../src/interfaces/IUniswapV3.sol";
import {Trader} from "../mocks/Mocks.t.sol";
import {V4Trader} from "../VaultV4.t.sol";

interface IPonsEscrowView {
    function balanceOf(address recipient) external view returns (uint256);
    function balanceOfToken(address recipient, address token) external view returns (uint256);
}

interface IPonsFactory {
    struct Socials {
        string twitter;
        string telegram;
        string discord;
        string website;
        string farcaster;
    }

    struct LaunchParams {
        string name;
        string symbol;
        string logo;
        string description;
        Socials socials;
        address creatorFeeRecipient;
        uint16 creatorTaxBps;
        bool buybackEnabled;
        bytes32 expectedEconomics;
        bytes32 salt;
    }

    struct LaunchConfig {
        uint256 supply;
        uint256 curveFeeBps;
        uint256 phantomQuote;
        uint256 graduationThreshold;
        uint24 poolFee;
        int24 tickSpacing;
        bool enabled;
    }

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

    function launchToken(LaunchParams calldata params, uint256 launchConfigId, address pairToken)
        external
        payable
        returns (address token, address curve);
    function launchFee() external view returns (uint256);
    function launchConfigCount() external view returns (uint256);
    function getLaunchConfig(uint256 id) external view returns (LaunchConfig memory);
    function previewLaunchEconomics(uint256 id, address pairToken) external view returns (bytes32);
    function getLaunchedToken(address token) external view returns (Launched memory);
    function memeHook() external view returns (address);
    function graduate(address token) external;
    function createGraduatedPool(address token) external returns (uint256 positionId);
    function canLaunch(address who) external view returns (bool);
}

interface IPonsCurve {
    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient) external payable returns (uint256);
    function graduated() external view returns (bool);
    function currentSnipeTaxBps(address recipient) external view returns (uint256);
}

interface IWETH {
    function deposit() external payable;
}

/// Tests against a copy of Robinhood Chain mainnet. Run with: forge test --match-path "test/fork/*" --fork-url <rpc>
/// Without a fork every test here is skipped.
contract MainnetForkTest is Test {
    BuybackBurner internal ponsBurner;

    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address constant V3_NPM = 0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3;
    address constant V4_PM = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant V4_POSM = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant FEED_ETH = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;
    address constant FEED_USDG = 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2;
    address constant PONS_ESCROW = 0xd3AFEB2a57f70eF218Aa82451c51B2fb0416Ac9e;
    address constant PONS_HOOK = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044;
    address constant PONS_FACTORY = 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e;

    TidewellFactory factory;
    RevenueRouter router;
    ReferralRegistry reg;
    Trader trader;
    address user = makeAddr("user");
    address keeper = makeAddr("keeper");
    address team = makeAddr("team");
    address pool; // WETH / USDG on Uniswap v3

    function setUp() public {
        if (block.chainid != 4663) {
            vm.skip(true);
            return;
        }
        factory = new TidewellFactory(
            address(this),
            TidewellFactory.Addresses({
                implementationV3: address(new TidewellVaultV3()),
                implementationV4: address(new TidewellVaultV4()),
                positionManager: V3_NPM,
                uniswapFactory: V3_FACTORY,
                poolManager: V4_PM,
                positionManagerV4: V4_POSM,
                permit2: PERMIT2,
                weth: WETH
            }),
            keeper,
            address(this),
            team
        );
        factory.setSwapper(address(new TidewellSwapper(address(factory), V4_PM, PERMIT2, 0x204FAca1764B154221e35c0d20aBb3c525710498)));
        reg = new ReferralRegistry(address(factory));
        router = new RevenueRouter(address(this), address(reg), address(factory), team, team, team, team, team);
        factory.setFee(address(router), 200, address(reg));
        factory.setFeeRank(USDG, 1);
        factory.setTokenCap(WETH, 1_000 ether);
        factory.setTokenCap(USDG, 10_000_000e6);
        factory.setFeed(WETH, FEED_ETH, 1 days);
        factory.setFeed(USDG, FEED_USDG, 1 days);

        pool = _bestV3Pool();
        console.log("WETH/USDG v3 pool", pool, "fee", IUniswapV3Pool(pool).fee());
        console.log("pool WETH", IERC20(WETH).balanceOf(pool), "pool USDG", IERC20(USDG).balanceOf(pool));
        trader = new Trader();
        // Fund the user: wrap ETH, and buy USDG in the real pool (price may move at most ~5%).
        vm.deal(address(trader), 100 ether);
        vm.prank(address(trader));
        IWETH(WETH).deposit{value: 100 ether}();
        trader.swapCapped(pool, WETH < USDG, int256(5 ether));
        console.log("trader USDG after buying", IERC20(USDG).balanceOf(address(trader)));
        uint256 bought = IERC20(USDG).balanceOf(address(trader)); // read first: vm.prank applies to the next call
        vm.prank(address(trader));
        IERC20(USDG).transfer(user, bought);
        vm.prank(address(trader));
        IERC20(WETH).transfer(user, 20 ether);
        vm.deal(user, 20 ether);
    }

    function _bestV3Pool() internal view returns (address best) {
        uint24[4] memory fees = [uint24(100), 500, 3000, 10000];
        uint256 most;
        for (uint256 i; i < 4; ++i) {
            address p = IUniswapV3Factory(V3_FACTORY).getPool(WETH, USDG, fees[i]);
            if (p == address(0)) continue;
            uint256 bal = IERC20(USDG).balanceOf(p);
            if (bal > most) {
                most = bal;
                best = p;
            }
        }
        require(best != address(0), "no WETH/USDG v3 pool");
    }

    function _floor(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 c = tick / spacing;
        if (tick < 0 && tick % spacing != 0) c--;
        return c * spacing;
    }

    // ------------------------------------------------------------ the addresses are what we think they are

    function test_addresses() public view {
        assertEq(INonfungiblePositionManager(V3_NPM).factory(), V3_FACTORY);
        assertGt(V4_PM.code.length, 0);
        assertGt(V4_POSM.code.length, 0);
        assertGt(PERMIT2.code.length, 0);
        assertGt(PONS_ESCROW.code.length, 0);
        assertGt(PONS_HOOK.code.length, 0);
        assertGt(PONS_FACTORY.code.length, 0);
        // Real Chainlink prices agree with the real pool.
        factory.checkPrice(pool);
        console.log("WETH/USDG v3 pool", pool);
    }

    // ------------------------------------------------------------ Uniswap v3 vault on the real pool

    function test_v3_openCompoundRebalanceClose() public {
        vm.prank(user);
        TidewellVaultV3 vault = TidewellVaultV3(payable(factory.createVault(0)));
        vm.startPrank(user);
        IERC20(WETH).approve(address(vault), type(uint256).max);
        IERC20(USDG).approve(address(vault), type(uint256).max);
        vm.stopPrank();
        vm.deal(address(vault), 0.01 ether);

        IUniswapV3Pool p = IUniswapV3Pool(pool);
        int24 spacing = p.tickSpacing();
        (, int24 tick,,,,,) = p.slot0();
        int24 base = _floor(tick, spacing);
        (address t0, address t1) = WETH < USDG ? (WETH, USDG) : (USDG, WETH);
        uint256 usdgBal = IERC20(USDG).balanceOf(user);
        TidewellVaultV3.OpenParams memory op = TidewellVaultV3.OpenParams({
            token0: t0,
            token1: t1,
            fee: p.fee(),
            tickLower: base - 20 * spacing,
            tickUpper: base + 20 * spacing,
            amount0: t0 == WETH ? 3 ether : usdgBal / 2,
            amount1: t0 == WETH ? usdgBal / 2 : 3 ether,
            amount0Min: 0,
            amount1Min: 0,
            settings: TidewellVaultBase.Settings({
                minWidth: 10 * spacing,
                maxWidth: 200 * spacing,
                cooldown: 30 minutes,
                compoundBps: 5000,
                slippageBps: 100,
                rule: 0
            })
        });
        vm.prank(user);
        uint256 id = vault.open(op);

        // Trade through the real pool so the position earns fees.
        for (uint256 i; i < 6; ++i) {
            trader.swapCapped(pool, WETH < USDG, int256(1 ether));
            trader.swapCapped(pool, WETH > USDG, int256(IERC20(USDG).balanceOf(address(trader)) / 2));
        }
        vm.warp(vm.getBlockTimestamp() + 31 minutes);
        vm.roll(block.number + 100);

        vm.prank(keeper);
        vault.compound(id, false, 0, "");
        assertGt(router.pending(WETH) + router.pending(USDG), 0, "protocol fee arrived");

        (, tick,,,,,) = p.slot0();
        base = _floor(tick, spacing);
        vm.prank(keeper);
        vault.rebalance(id, base - 30 * spacing, base + 30 * spacing, false, 0, "");

        uint256 w = IERC20(WETH).balanceOf(user);
        vm.prank(user);
        vault.close(id, 0, 0);
        assertGt(IERC20(WETH).balanceOf(user), w);
        assertEq(vault.positionIds().length, 0);

        // Revenue becomes ETH and is split.
        if (router.pending(USDG) + router.referralTotal(USDG) > 0) {
            vm.prank(keeper);
            router.convert(USDG, p.fee());
        }
        if (router.pending(WETH) > 0) {
            vm.prank(keeper);
            router.convert(WETH, 0);
        }
        uint256 eth = router.pending(address(0));
        assertGt(eth, 0);
        router.distribute(address(0));
        assertEq(team.balance, eth); // every destination is the team in this test
    }

    // ------------------------------------------------------------ Uniswap v4: real PoolManager, a hookless ETH/USDG pool

    function _v4EthUsdgPool() internal view returns (bool found, PoolKey memory key) {
        uint24[4] memory fees = [uint24(500), 3000, 100, 10000];
        int24[4] memory spacings = [int24(10), 60, 1, 200];
        for (uint256 i; i < 4; ++i) {
            key = PoolKey(Currency.wrap(address(0)), Currency.wrap(USDG), fees[i], spacings[i], IHooks(address(0)));
            (uint160 sqrtP,,,) = IPoolManager(V4_PM).getSlot0(key.toId());
            if (sqrtP != 0 && IPoolManager(V4_PM).getLiquidity(key.toId()) > 0) return (true, key);
        }
    }

    function test_v4_openPokeCompoundClose_nativeEth() public {
        (bool found, PoolKey memory key) = _v4EthUsdgPool();
        if (!found) {
            console.log("no hookless ETH/USDG v4 pool with liquidity; skipped");
            return;
        }
        vm.prank(user);
        TidewellVaultV4 vault = TidewellVaultV4(payable(factory.createVault(1)));
        vm.prank(user);
        IERC20(USDG).approve(address(vault), type(uint256).max);
        (, int24 tick,,) = IPoolManager(V4_PM).getSlot0(key.toId());
        int24 base = _floor(tick, key.tickSpacing);
        TidewellVaultV4.OpenParams memory op = TidewellVaultV4.OpenParams({
            key: key,
            tickLower: base - 40 * key.tickSpacing,
            tickUpper: base + 40 * key.tickSpacing,
            amount0: 2 ether,
            amount1: IERC20(USDG).balanceOf(user) / 4,
            sqrtPriceMin: TickMath.MIN_SQRT_PRICE,
            sqrtPriceMax: TickMath.MAX_SQRT_PRICE,
            settings: TidewellVaultBase.Settings({
                minWidth: 10 * key.tickSpacing,
                maxWidth: 400 * key.tickSpacing,
                cooldown: 30 minutes,
                compoundBps: 5000,
                slippageBps: 100,
                rule: 0
            })
        });
        vm.prank(user);
        uint256 id = vault.open{value: 2 ether}(op);
        assertGt(vault.getPosition(id).tokenId, 0);

        // With fresh feeds for ETH and USDG no poke is needed.
        vm.warp(vm.getBlockTimestamp() + 31 minutes);
        vm.prank(keeper);
        vault.compound(id, false, 0, "");

        uint256 e = user.balance;
        vm.prank(user);
        vault.close(id, 0, 0);
        assertGt(user.balance, e);
    }

    function test_v4_burner_onRealPoolManager() public {
        (bool found, PoolKey memory key) = _v4EthUsdgPool();
        if (!found) return;
        // USDG stands in for TIDE: same pool shape (native ETH as currency0).
        BuybackBurner burner = new BuybackBurner(address(this), V4_PM, address(factory));
        burner.setPool(key);
        vm.deal(address(burner), 0.2 ether);
        vm.prank(keeper);
        burner.poke();
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(keeper);
        (uint256 ethIn, uint256 out) = burner.buyAndBurn();
        assertEq(ethIn, 0.2 ether);
        assertGt(out, 0);
        assertEq(IERC20(USDG).balanceOf(burner.DEAD()) >= out, true);
    }

    // ------------------------------------------------------------ Pons v2: our calls match the deployed contracts

    function test_pons_interfaces() public {
        // The escrow keeps a balance per recipient; claim() with nothing to claim reverts with NoBalance(), which
        // is why the router checks balanceOf first. claimPons must therefore succeed and book nothing.
        assertEq(IPonsEscrowView(PONS_ESCROW).balanceOf(address(router)), 0);
        vm.prank(address(router));
        (bool ok, bytes memory r0) = PONS_ESCROW.call(abi.encodeWithSignature("claim()"));
        assertFalse(ok);
        assertEq(bytes4(r0), bytes4(keccak256("NoBalance()")));
        router.setPons(PONS_ESCROW, PONS_HOOK, PONS_FACTORY, address(0xBEEF));
        assertEq(router.claimPons(address(0)), 0);
        // sweepPoolFees exists with this signature: an unknown pool reverts with the hook's own error, not a missing
        // function.
        (bool ok2, bytes memory ret) =
            PONS_HOOK.call(abi.encodeWithSignature("sweepPoolFees(bytes32,uint256,uint256)", bytes32(uint256(1)), 0, 0));
        assertFalse(ok2);
        assertEq(bytes4(ret), bytes4(keccak256("UnknownPool()")));
        // transferCreatorFeeRecipient exists: a token that was never launched reverts with the factory's error.
        (bool ok3, bytes memory ret3) = PONS_FACTORY.call(
            abi.encodeWithSignature("transferCreatorFeeRecipient(address,address)", address(0xBEEF), address(router))
        );
        assertFalse(ok3);
        assertEq(bytes4(ret3), bytes4(keccak256("TokenNotFound()")));
    }

    // ------------------------------------------------------------ dress rehearsal of the TIDE launch on Pons

    function _launchOnPons() internal returns (address token, PoolKey memory key) {
        IPonsFactory pf = IPonsFactory(PONS_FACTORY);
        console.log("canLaunch", pf.canLaunch(address(this)));
        uint256 cfg = type(uint256).max;
        uint256 n = pf.launchConfigCount();
        for (uint256 i; i < n; ++i) {
            if (pf.getLaunchConfig(i).enabled) {
                try pf.previewLaunchEconomics(i, address(0)) returns (bytes32) {
                    cfg = i;
                    break;
                } catch {}
            }
        }
        require(cfg != type(uint256).max, "no ETH launch config");
        IPonsFactory.LaunchParams memory lp = IPonsFactory.LaunchParams({
            name: "Tidewell Rehearsal",
            symbol: "TWTEST",
            logo: "",
            description: "fork test",
            socials: IPonsFactory.Socials("", "", "", "", ""),
            creatorFeeRecipient: address(router),
            creatorTaxBps: 0,
            buybackEnabled: false,
            expectedEconomics: pf.previewLaunchEconomics(cfg, address(0)),
            salt: keccak256(abi.encode(block.timestamp, address(this)))
        });
        address curve;
        (token, curve) = pf.launchToken{value: pf.launchFee()}(lp, cfg, address(0));
        console.log("launched", token, "curve", curve);

        // The buyback starts right after the launch, on the bonding curve (before graduation), past the snipe tax.
        ponsBurner = new BuybackBurner(address(this), V4_PM, address(factory));
        ponsBurner.setPonsSource(PONS_FACTORY, token);
        assertEq(ponsBurner.market(), 1, "burner buys on the curve");
        for (uint256 i; i < 60 && IPonsCurve(curve).currentSnipeTaxBps(address(ponsBurner)) != 0; ++i) {
            vm.warp(vm.getBlockTimestamp() + 10);
        }
        vm.deal(address(ponsBurner), 0.3 ether);
        vm.prank(keeper);
        ponsBurner.poke();
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(keeper);
        (uint256 cIn, uint256 cBurned) = ponsBurner.buyAndBurn();
        console.log("REHEARSAL curve buyback: ETH in (wei)", cIn);
        console.log("REHEARSAL curve buyback: token burned", cBurned);
        assertGt(cIn, 0, "curve buy spent ETH");
        assertGt(cBurned, 0, "curve buy burned tokens");
        assertEq(IERC20(token).balanceOf(ponsBurner.DEAD()), cBurned, "burned on the curve");

        // Past the opening snipe tax, a buyer fills the curve: it graduates into a Uniswap v4 pool with the Pons hook.
        vm.warp(vm.getBlockTimestamp() + 30);
        address buyer = makeAddr("ponsBuyer");
        vm.deal(buyer, 20 ether);
        vm.prank(buyer);
        IPonsCurve(curve).buy{value: 6 ether}(6 ether, 0, buyer);
        if (!IPonsCurve(curve).graduated()) pf.graduate(token);
        assertTrue(IPonsCurve(curve).graduated(), "graduated");
        // Graduation has two steps: the curve is swept (phase 1), then anyone creates the v4 pool (phase 2).
        // For TIDE the keeper does step two right away.
        if (pf.getLaunchedToken(token).phase == 1) pf.createGraduatedPool(token);
        IPonsFactory.Launched memory l = pf.getLaunchedToken(token);
        assertEq(l.phase, 2, "pool created");
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(token), l.poolFee, l.tickSpacing, IHooks(pf.memeHook()));
        (uint160 sqrtP,,,) = IPoolManager(V4_PM).getSlot0(key.toId());
        assertGt(sqrtP, 0, "graduated pool exists");
        assertEq(l.creatorFeeRecipient, address(router));
        // Give the user some of the token for the vault test.
        uint256 bal = IERC20(token).balanceOf(buyer);
        vm.prank(buyer);
        IERC20(token).transfer(user, bal / 4);
    }

    function _moneyFlow(address token) internal {
        address staking = makeAddr("stakingReserve");
        address boosts = makeAddr("boostReserve");
        address burnerDest = makeAddr("burnerDest");
        address safety = makeAddr("safetyFund");
        address teamDest = makeAddr("teamDest");
        address expansion = makeAddr("expansionReserve");
        router.setDestinations(staking, boosts, burnerDest, safety, teamDest);
        router.setExpansionReserve(expansion);

        router.sync(address(0));
        uint256 eth = router.pending(address(0));
        console.log("REHEARSAL ETH revenue to split (wei)", eth);
        if (eth > 0) {
            router.distribute(address(0));
            assertEq(router.pending(address(0)), 0, "ETH all split");
            assertEq(staking.balance, (eth * 3000) / 10_000, "30% staking");
            assertEq(boosts.balance, (eth * 500) / 10_000, "5% boosted pools");
            assertEq(burnerDest.balance, (eth * 3500) / 10_000, "35% buyback");
            assertEq(safety.balance, (eth * 1500) / 10_000, "15% safety");
            assertEq(staking.balance + boosts.balance + burnerDest.balance + safety.balance + teamDest.balance, eth, "nothing lost");
        }

        uint256 escrowTide = IPonsEscrowView(PONS_ESCROW).balanceOfToken(address(router), token);
        console.log("REHEARSAL token creator fees waiting in the Pons escrow", escrowTide);
        router.claimPons(token);
        uint256 tide = router.pending(token);
        console.log("REHEARSAL token creator fees booked by the router", tide);
        if (tide > 0) {
            address dead = router.DEAD();
            uint256 deadBefore = IERC20(token).balanceOf(dead);
            router.distribute(token);
            uint256 toBurn = (tide * 3500) / 10_000;
            uint256 toExpansion = (tide * 5000) / 10_000;
            assertEq(IERC20(token).balanceOf(dead) - deadBefore, toBurn, "35% burned");
            assertEq(IERC20(token).balanceOf(expansion), toExpansion, "50% expansion reserve");
            assertEq(IERC20(token).balanceOf(boosts), tide - toBurn - toExpansion, "15% boosted pools");
            assertEq(router.pending(token), 0, "token all split");
        }
    }

    function test_pons_rehearsal() public {
        (address token, PoolKey memory key) = _launchOnPons();
        router.setPons(PONS_ESCROW, PONS_HOOK, PONS_FACTORY, token);

        // 1. Creator fees from the bonding curve arrive at the router.
        uint256 claimed = router.claimPons(address(0));
        console.log("creator fees claimed after graduation (wei)", claimed);

        // 2. Trading in the graduated pool earns more; the router tries to sweep them itself.
        V4Trader vt = new V4Trader(IPoolManager(V4_PM));
        vm.deal(address(vt), 10 ether);
        vt.swap(key, true, 1 ether);
        uint256 tBal = IERC20(token).balanceOf(address(vt));
        vt.swap(key, false, tBal / 2);
        try router.sweepPons(PoolId.unwrap(key.toId()))
        {
            console.log("sweepPons by the router: ok");
        } catch (bytes memory err) {
            console.log("sweepPons by the router reverted; Pons' operator sweeps instead");
            console.logBytes(err);
        }
        console.log("claimed after trading (wei)", router.claimPons(address(0)));

        // 2b. The money flow as the keeper runs it. ETH: 30% staking, 5% boosted pools, 35% buyback, 15% safety,
        //     15% team. Creator fees in the token itself (TIDE): 35% burned, 50% expansion reserve, 15% boosted
        //     pools, never sold.
        _moneyFlow(token);

        // 3. The burner buys in the hooked pool and burns.
        //    The same burner switches to the graduated pool by itself at its next poke (no owner, no timelock).
        BuybackBurner burner = ponsBurner;
        assertEq(burner.market(), 2, "burner now buys in the pool");
        vm.prank(keeper);
        burner.poke();
        assertTrue(burner.poolSet(), "pool taken from Pons");
        {
            (,, uint24 bFee, int24 bSpacing, IHooks bHook) = burner.poolKey();
            assertEq(bFee, key.fee, "burner pool fee from Pons");
            assertEq(bSpacing, key.tickSpacing, "burner pool spacing from Pons");
            assertEq(address(bHook), address(key.hooks), "burner pool hook from Pons");
        }
        vm.deal(address(burner), 0.3 ether);
        uint256 deadBefore = IERC20(token).balanceOf(burner.DEAD());
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(keeper);
        (uint256 ethIn, uint256 burned) = burner.buyAndBurn();
        // A freshly graduated pool is thin: the 2% price limit stops the buy early, and the rest of the ETH waits for
        // the next buy. That is intended: the burner never pushes the price up by much at once.
        console.log("burner spent (wei)", ethIn, "of 0.3 ETH");
        assertGt(ethIn, 0);
        assertLe(ethIn, 0.3 ether);
        assertEq(address(burner).balance, 0.3 ether - ethIn);
        assertGt(burned, 0);
        assertEq(IERC20(token).balanceOf(burner.DEAD()), deadBefore + burned);

        // 4. A vault can provide liquidity in a Pons pool once its hook is allowed (the pool fee is 0 there, so LPs
        //    earn nothing from it: good to know for the app).
        factory.setHookAllowed(PONS_HOOK, true);
        factory.setTokenCap(token, type(uint128).max);
        vm.prank(user);
        TidewellVaultV4 vault = TidewellVaultV4(payable(factory.createVault(1)));
        vm.prank(user);
        IERC20(token).approve(address(vault), type(uint256).max);
        (, int24 tick,,) = IPoolManager(V4_PM).getSlot0(key.toId());
        int24 base = _floor(tick, key.tickSpacing);
        TidewellVaultV4.OpenParams memory op = TidewellVaultV4.OpenParams({
            key: key,
            tickLower: base - 10 * key.tickSpacing,
            tickUpper: base + 10 * key.tickSpacing,
            amount0: 0.5 ether,
            amount1: IERC20(token).balanceOf(user),
            sqrtPriceMin: TickMath.MIN_SQRT_PRICE,
            sqrtPriceMax: TickMath.MAX_SQRT_PRICE,
            settings: TidewellVaultBase.Settings({
                minWidth: 2 * key.tickSpacing,
                maxWidth: 100 * key.tickSpacing,
                cooldown: 30 minutes,
                compoundBps: 5000,
                slippageBps: 100,
                rule: 0
            })
        });
        vm.prank(user);
        uint256 id = vault.open{value: 0.5 ether}(op);
        vm.prank(keeper);
        vault.poke(id); // no Chainlink feed for a memecoin: the two-step check
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.prank(keeper);
        vault.compound(id, false, 0, "");
        vm.prank(user);
        vault.close(id, 0, 0);

        // 5. The fee wallet can be handed to a new router version.
        address next = makeAddr("routerV2");
        router.transferPonsRecipient(next);
        assertEq(IPonsFactory(PONS_FACTORY).getLaunchedToken(token).creatorFeeRecipient, next);
    }

    // ------------------------------------------------------------ a Stock Token on Uniswap v4

    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant FEED_NVDA = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;

    function _nvdaPool() internal view returns (bool found, PoolKey memory key) {
        uint24[5] memory fees = [uint24(3000), 500, 10000, 100, 2500];
        int24[5] memory spacings = [int24(60), 10, 200, 1, 50];
        (Currency a, Currency b) = NVDA < USDG
            ? (Currency.wrap(NVDA), Currency.wrap(USDG))
            : (Currency.wrap(USDG), Currency.wrap(NVDA));
        uint128 best;
        for (uint256 i; i < 5; ++i) {
            PoolKey memory k = PoolKey(a, b, fees[i], spacings[i], IHooks(address(0)));
            uint128 liq = IPoolManager(V4_PM).getLiquidity(k.toId());
            if (liq > best) {
                best = liq;
                key = k;
                found = true;
            }
        }
    }

    function test_stockToken_nvda() public {
        (bool found, PoolKey memory key) = _nvdaPool();
        if (!found) {
            console.log("no hookless NVDA/USDG v4 pool found; skipped");
            return;
        }
        console.log("NVDA/USDG v4 pool fee", key.fee);
        factory.setFeed(NVDA, FEED_NVDA, 1 days);
        router.setUsdg(USDG, IUniswapV3Pool(pool).fee());

        // Buy some NVDA with USDG through the real v4 pool.
        V4Trader vt = new V4Trader(IPoolManager(V4_PM));
        uint256 u = IERC20(USDG).balanceOf(user) / 4;
        vm.prank(user);
        IERC20(USDG).transfer(address(vt), u);
        vt.swap(key, Currency.unwrap(key.currency0) == USDG, u);
        uint256 nv = IERC20(NVDA).balanceOf(address(vt));
        assertGt(nv, 0);

        // NVDA that arrives as revenue becomes ETH, via USDG, when the NVDA price feed is fresh (trading days).
        vm.prank(address(vt));
        IERC20(NVDA).transfer(address(router), nv / 2);
        router.sync(NVDA);
        (, , , uint256 updatedAt,) = IFeed(FEED_NVDA).latestRoundData();
        bool fresh = updatedAt + 1 days >= block.timestamp;
        console.log("NVDA feed fresh", fresh);
        vm.prank(keeper);
        if (fresh) {
            uint256 eth = router.convertV4(NVDA, key);
            assertGt(eth, 0);
            console.log("NVDA converted to ETH (wei)", eth);
        } else {
            vm.expectRevert(RevenueRouter.NoPriceCheck.selector);
            router.convertV4(NVDA, key);
        }
    }
}

interface IFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}
