// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TidewellFactory} from "../src/TidewellFactory.sol";
import {TidewellVaultV3} from "../src/TidewellVaultV3.sol";
import {TidewellVaultV4} from "../src/TidewellVaultV4.sol";
import {TidewellVaultBase} from "../src/TidewellVaultBase.sol";
import {INonfungiblePositionManager, IUniswapV3Pool} from "../src/interfaces/IUniswapV3.sol";
import {MockERC20, MockWETH, MockFeed, MockSink, MockDiscount, Trader} from "./mocks/Mocks.sol";
import {MockRouter} from "./mocks/Mocks.sol";
import {TidewellSwapper} from "../src/TidewellSwapper.sol";
import {RevenueRouter} from "../src/RevenueRouter.sol";
import {ReferralRegistry} from "../src/ReferralRegistry.sol";

interface INPMExtra {
    function createAndInitializePoolIfNecessary(address token0, address token1, uint24 fee, uint160 sqrtPriceX96)
        external
        payable
        returns (address pool);
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// Runs against the real Uniswap v3 bytecode (npm packages v3-core 1.0.1 and v3-periphery 1.4.4).
contract VaultTest is Test {
    TidewellFactory factory;
    INonfungiblePositionManager npm;
    address uniFactory;
    MockWETH weth; // 18 decimals, priced at 2,500
    MockERC20 usdg; // 6 decimals
    address t0;
    address t1;
    address pool;
    MockSink sink;
    Trader trader;

    address user = makeAddr("user");
    address keeper = makeAddr("keeper");
    address guardian = makeAddr("guardian");
    address stranger = makeAddr("stranger");

    TidewellVaultV3 vault;
    uint24 constant FEE = 3000;
    int24 constant SPACING = 60;

    function setUp() public {
        vm.warp(1_800_000_000);
        uniFactory = _deploy("UniswapV3Factory.json", "");
        weth = new MockWETH();
        vm.deal(address(weth), 1_000_000 ether);
        usdg = new MockERC20("USDG", 6);
        npm = INonfungiblePositionManager(
            _deploy("NonfungiblePositionManager.json", abi.encode(uniFactory, address(weth), address(0)))
        );
        (t0, t1) = address(weth) < address(usdg) ? (address(weth), address(usdg)) : (address(usdg), address(weth));

        // 1 WETH = 2,500 USDG, in raw units of token1 per token0.
        uint160 sqrtP = t0 == address(weth) ? _sqrtPrice(2500e6, 1e18) : _sqrtPrice(1e18, 2500e6);
        pool = INPMExtra(address(npm)).createAndInitializePoolIfNecessary(t0, t1, FEE, sqrtP);

        sink = new MockSink();
        factory = new TidewellFactory(
            address(this),
            TidewellFactory.Addresses({
                implementationV3: address(new TidewellVaultV3()),
                implementationV4: address(new TidewellVaultV4()),
                positionManager: address(npm),
                uniswapFactory: uniFactory,
                poolManager: address(0xdead),
                positionManagerV4: address(0xdead),
                permit2: address(0xdead),
                weth: address(weth)
            }),
            keeper,
            guardian,
            address(sink)
        );
        factory.setTokenCap(address(weth), 1_000 ether);
        factory.setTokenCap(address(usdg), 5_000_000e6);

        // Background liquidity so trades have depth.
        _mintBackground();
        trader = new Trader();
        weth.mint(address(trader), 10_000 ether);
        usdg.mint(address(trader), 50_000_000e6);

        weth.mint(user, 100 ether);
        usdg.mint(user, 1_000_000e6);
        vm.prank(user);
        vault = TidewellVaultV3(payable(factory.createVault(0)));
        vm.startPrank(user);
        weth.approve(address(vault), type(uint256).max);
        usdg.approve(address(vault), type(uint256).max);
        vm.stopPrank();
        vm.deal(address(vault), 0.01 ether); // gas tank
    }

    // ------------------------------------------------------------ helpers

    function _deploy(string memory file, bytes memory args) internal returns (address a) {
        string memory json = vm.readFile(string.concat("uniswap-artifacts/", file));
        bytes memory code = abi.encodePacked(vm.parseJsonBytes(json, ".bytecode"), args);
        assembly {
            a := create(0, add(code, 0x20), mload(code))
        }
        require(a != address(0), "deploy failed");
    }

    function _sqrtPrice(uint256 num, uint256 den) internal pure returns (uint160) {
        return uint160(Math.sqrt(Math.mulDiv(num, 1 << 192, den)));
    }

    function _mintBackground() internal {
        weth.mint(address(this), 1_000 ether);
        usdg.mint(address(this), 2_500_000e6);
        weth.approve(address(npm), type(uint256).max);
        usdg.approve(address(npm), type(uint256).max);
        npm.mint(
            INonfungiblePositionManager.MintParams({
                token0: t0,
                token1: t1,
                fee: FEE,
                tickLower: -887220,
                tickUpper: 887220,
                amount0Desired: t0 == address(weth) ? 1_000 ether : 2_500_000e6,
                amount1Desired: t0 == address(weth) ? 2_500_000e6 : 1_000 ether,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp
            })
        );
    }

    /// Amount of token0 / token1, given what it would be in WETH and in USDG.
    function _in0(uint256 w, uint256 u) internal view returns (int256) {
        return int256(t0 == address(weth) ? w : u);
    }

    function _in1(uint256 w, uint256 u) internal view returns (int256) {
        return int256(t0 == address(weth) ? u : w);
    }

    function _tick() internal view returns (int24 tick) {
        (, tick,,,,,) = IUniswapV3Pool(pool).slot0();
    }

    function _floor(int24 tick) internal pure returns (int24) {
        int24 c = tick / SPACING;
        if (tick < 0 && tick % SPACING != 0) c--;
        return c * SPACING;
    }

    function _settings() internal pure returns (TidewellVaultBase.Settings memory) {
        return TidewellVaultBase.Settings({
            minWidth: 600,
            maxWidth: 6000,
            cooldown: 30 minutes,
            compoundBps: 5000,
            slippageBps: 100,
            rule: 0
        });
    }

    function _open() internal returns (uint256 id) {
        int24 base = _floor(_tick());
        uint256 a0 = uint256(_in0(10 ether, 25_000e6));
        uint256 a1 = uint256(_in1(10 ether, 25_000e6));
        TidewellVaultV3.OpenParams memory p = TidewellVaultV3.OpenParams({
            token0: t0,
            token1: t1,
            fee: FEE,
            tickLower: base - 600,
            tickUpper: base + 600,
            amount0: a0,
            amount1: a1,
            amount0Min: 0,
            amount1Min: 0,
            settings: _settings()
        });
        vm.prank(user);
        id = vault.open(p);
    }

    /// Trades back and forth so the position earns fees in both tokens, then lets time pass.
    function _trade(uint256 rounds) internal {
        for (uint256 i; i < rounds; ++i) {
            trader.swap(pool, true, _in0(5 ether, 12_500e6));
            vm.warp(block.timestamp + 15);
            trader.swap(pool, false, _in1(5 ether, 12_500e6));
            vm.warp(block.timestamp + 15);
        }
        vm.warp(block.timestamp + 700); // let the average catch up with the price
        vm.roll(block.number + 1);
    }

    // ------------------------------------------------------------ tests

    function test_open_holdsPositionInVault() public {
        uint256 id = _open();
        TidewellVaultV3.Position memory pos = vault.getPosition(id);
        assertEq(INPMExtra(address(npm)).ownerOf(pos.tokenId), address(vault));
        assertEq(vault.positionIds().length, 1);
        // Leftovers went straight back to the user, nothing idle in the vault.
        assertEq(weth.balanceOf(address(vault)), 0);
        assertEq(usdg.balanceOf(address(vault)), 0);
        (,,,, uint16 cardNext,,) = IUniswapV3Pool(pool).slot0();
        assertGe(cardNext, factory.cardinalityTarget());
    }

    function test_openFromBalance_usesWhatIsInTheVault() public {
        int24 base = _floor(_tick());
        uint256 a0 = uint256(_in0(10 ether, 25_000e6));
        uint256 a1 = uint256(_in1(10 ether, 25_000e6));
        TidewellVaultV3.OpenParams memory p = TidewellVaultV3.OpenParams({
            token0: t0,
            token1: t1,
            fee: FEE,
            tickLower: base - 600,
            tickUpper: base + 600,
            amount0: a0,
            amount1: a1,
            amount0Min: 0,
            amount1Min: 0,
            settings: _settings()
        });
        // Not enough in the vault yet.
        vm.prank(user);
        vm.expectRevert(TidewellVaultBase.TransferFailed.selector);
        vault.openFromBalance(p);
        vm.startPrank(user);
        IERC20(t0).transfer(address(vault), a0);
        IERC20(t1).transfer(address(vault), a1);
        vm.stopPrank();
        vm.prank(stranger);
        vm.expectRevert(TidewellVaultBase.NotOwner.selector);
        vault.openFromBalance(p);
        vm.prank(user);
        uint256 id = vault.openFromBalance(p);
        assertEq(INPMExtra(address(npm)).ownerOf(vault.getPosition(id).tokenId), address(vault));
        assertEq(IERC20(t0).balanceOf(address(vault)), 0);
        assertEq(IERC20(t1).balanceOf(address(vault)), 0);
    }

    function test_onlyOwnerCanOpenAndWithdraw() public {
        uint256 id = _open();
        vm.startPrank(stranger);
        vm.expectRevert(TidewellVaultBase.NotOwner.selector);
        vault.close(id, 0, 0);
        vm.expectRevert(TidewellVaultBase.NotOwner.selector);
        vault.claim(address(weth), 0);
        vm.expectRevert(TidewellVaultBase.NotOwner.selector);
        vault.claim(address(0), 0);
        vm.stopPrank();

        // The keeper cannot take anything out either.
        vm.startPrank(keeper);
        vm.expectRevert(TidewellVaultBase.NotOwner.selector);
        vault.claim(address(weth), 0);
        vm.expectRevert(TidewellVaultBase.NotOwner.selector);
        vault.remove(id, 1, 0, 0);
        vm.stopPrank();
    }

    function test_compound_takesProtocolFeeAndReinvestsShare() public {
        uint256 id = _open();
        _trade(10);
        uint256 keeperBefore = keeper.balance;

        vm.txGasPrice(0.1 gwei);
        vm.prank(keeper);
        vault.compound(id, false, 0, "");

        // 2% of fees went to the fee recipient, reported with the user's address.
        assertGt(sink.total(), 0);
        assertEq(sink.lastUser(), user);
        assertGt(IERC20(t0).balanceOf(address(sink)) + IERC20(t1).balanceOf(address(sink)), 0);
        // Half of the fees stayed in the vault, ready to claim.
        assertGt(weth.balanceOf(address(vault)) + usdg.balanceOf(address(vault)), 0);
        // Gas was refunded from the vault's ETH, within the cap.
        uint256 refund = keeper.balance - keeperBefore;
        assertGt(refund, 0);
        assertLe(refund, factory.maxRefundWei());
    }

    /// Claim as ETH in one transaction: the USDG fees are swapped to WETH in the pool, unwrapped and sent as ETH.
    function test_claimAsEth_oneTransaction() public {
        uint256 id = _open();
        _trade(10);
        address other = t0 == address(weth) ? t1 : t0;
        uint256 ethBefore = user.balance;
        vm.prank(keeper);
        vm.expectRevert(TidewellVaultBase.NotOwner.selector);
        vault.claimAsEth(id, 0, type(uint160).max, 0, "");
        vm.prank(user);
        vm.expectRevert(TidewellVaultV3.PriceOutOfBounds.selector);
        vault.claimAsEth(id, 0, 1, 0, "");
        vm.prank(user);
        vault.claimAsEth(id, 0, type(uint160).max, 0, "");
        assertGt(user.balance, ethBefore, "fees arrived as ETH");
        assertEq(IERC20(other).balanceOf(address(vault)), 0, "nothing of the other token left");
        assertEq(weth.balanceOf(address(vault)), 0, "all WETH unwrapped");
    }

    function test_compoundNow_ownerReinvestsAllFeesWhateverTheSetting() public {
        uint256 id = _open(); // the setting reinvests half
        _trade(10);

        vm.prank(keeper);
        vm.expectRevert(TidewellVaultBase.NotOwner.selector);
        vault.compoundNow(id, 0, type(uint160).max, false, 0, "");

        vm.recordLogs();
        vm.prank(user);
        vault.compoundNow(id, 0, type(uint160).max, false, 0, "");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint256 n0, uint256 n1, uint256 u0, uint256 u1) = (0, 0, 0, 0);
        bool collected;
        bool reinvested;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(vault)) continue;
            if (logs[i].topics[0] == keccak256("FeesCollected(uint256,uint256,uint256,uint256,uint256)")) {
                (uint256 c0, uint256 c1, uint256 p0, uint256 p1) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
                (n0, n1) = (c0 - p0, c1 - p1);
                collected = true;
            } else if (logs[i].topics[0] == keccak256("Compounded(uint256,uint256,uint256)")) {
                (u0, u1) = abi.decode(logs[i].data, (uint256, uint256));
                reinvested = true;
            }
        }
        assertTrue(collected && reinvested);
        // Far more than the setting's half went back in (the range fixes the ratio, so one token can have a rest).
        assertTrue(u0 * 10 >= n0 * 9 || u1 * 10 >= n1 * 9);
        assertGt(u0 + u1, 0);
    }

    /// With a route, the swap runs through Uniswap's Universal Router (here a stand-in) via the swapper.
    function test_route_throughRouter() public {
        address p2 = deployCode("out/Permit2.sol/Permit2.json");
        MockRouter mr = new MockRouter(p2);
        factory.setSwapper(address(new TidewellSwapper(address(factory), address(0xdead), p2, address(mr))));
        uint256 id = _open();
        _trade(10);
        // Fair price: 1 WETH = 2,500 USDG. Swap 0.001 WETH (or USDG side) for about 2.49 USDG.
        bool wethIs0 = t0 == address(weth);
        bytes memory route = wethIs0
            ? abi.encode(address(weth), address(usdg), uint256(1e15), uint256(2_480_000))
            : abi.encode(address(usdg), address(weth), uint256(2_500_000), uint256(0.00099 ether));
        uint256 amountIn = wethIs0 ? 1e15 : 2_500_000;
        // A route that gives 20% too little is refused by the vault's price check.
        bytes memory bad = wethIs0
            ? abi.encode(address(weth), address(usdg), uint256(1e15), uint256(2_000_000))
            : abi.encode(address(usdg), address(weth), uint256(2_500_000), uint256(0.0008 ether));
        vm.prank(keeper);
        vm.expectRevert(TidewellVaultBase.BadSwap.selector);
        vault.compound(id, true, amountIn, bad);

        vm.prank(keeper);
        vault.compound(id, true, amountIn, route);
        assertEq(IERC20(t0).balanceOf(address(mr)), amountIn, "router pulled the input via Permit2");
        assertEq(IERC20(t0).balanceOf(factory.swapper()), 0, "swapper keeps nothing");
        assertEq(IERC20(t1).balanceOf(factory.swapper()), 0, "swapper keeps nothing");
    }

    /// The keeper's compound swaps the reinvested fees to the range's ratio in the pool itself, then adds them.
    function test_compound_withSwap() public {
        uint256 id = _open();
        _trade(10);
        // More than the fees can never be swapped.
        vm.prank(keeper);
        vm.expectRevert(TidewellVaultBase.SwapTooLarge.selector);
        vault.compound(id, true, 1e30, "");

        (,,,,,,, uint128 liqBefore,,,,) = npm.positions(vault.getPosition(id).tokenId);
        vm.recordLogs();
        vm.prank(keeper);
        vault.compound(id, true, 1e9, "");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool swapped;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == keccak256("Swapped(uint256,bool,uint256,uint256)")) swapped = true;
        }
        assertTrue(swapped, "fees swapped in the pool");
        (,,,,,,, uint128 liqAfter,,,,) = npm.positions(vault.getPosition(id).tokenId);
        assertGt(liqAfter, liqBefore, "fees went back into the position");
    }

    function test_protocolFeeIsTwoPercent_withDiscount() public {
        MockDiscount d = new MockDiscount();
        d.set(9000); // asks for 90%, capped at 50%
        factory.setFee(address(sink), 200, address(d));
        uint256 id = _open();
        _trade(10);

        vm.recordLogs();
        vm.prank(keeper);
        vault.compound(id, false, 0, "");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("FeesCollected(uint256,uint256,uint256,uint256,uint256)");
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != sig) continue;
            (uint256 c0, uint256 c1, uint256 p0, uint256 p1) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
            assertGt(c0, 0);
            assertGt(c1, 0);
            // 2% with the maximum 50% discount = 1% of earned fees, all taken in WETH at the pool price.
            (uint160 sqrtP,,,,,,) = IUniswapV3Pool(pool).slot0();
            uint256 p2 = 1 << 96;
            if (t0 == address(weth)) {
                uint256 inWeth = Math.mulDiv(Math.mulDiv(c1, p2, sqrtP), p2, sqrtP);
                assertEq(p1, 0);
                assertApproxEqRel(p0, ((c0 + inWeth) * 100) / 10_000, 0.001e18);
            } else {
                uint256 inWeth = Math.mulDiv(Math.mulDiv(c0, sqrtP, p2), sqrtP, p2);
                assertEq(p0, 0);
                assertApproxEqRel(p1, ((c1 + inWeth) * 100) / 10_000, 0.001e18);
            }
            found = true;
        }
        assertTrue(found);
    }

    function test_rebalance_movesRangeAroundNewPrice() public {
        uint256 id = _open();
        uint256 oldToken = vault.getPosition(id).tokenId;
        // Push the price far out of range.
        trader.swap(pool, true, _in0(60 ether, 150_000e6));
        vm.warp(block.timestamp + 31 minutes);
        vm.roll(block.number + 1);

        int24 base = _floor(_tick());
        // Without a swap the position holds only one token, which cannot fill a range around the price.
        vm.prank(keeper);
        vm.expectRevert();
        vault.rebalance(id, base - 600, base + 600, false, 0, "");
        vm.prank(keeper);
        vault.rebalance(id, base - 600, base + 600, true, uint256(_in0(4 ether, 10_000e6)), "");

        TidewellVaultV3.Position memory pos = vault.getPosition(id);
        assertTrue(pos.tokenId != oldToken);
        assertEq(INPMExtra(address(npm)).ownerOf(pos.tokenId), address(vault));
        (,,,,, int24 lo, int24 hi, uint128 liq,,,,) = npm.positions(pos.tokenId);
        assertEq(lo, base - 600);
        assertEq(hi, base + 600);
        assertGt(liq, 0);
    }

    function test_rebalance_withSwap() public {
        uint256 id = _open();
        trader.swap(pool, true, _in0(60 ether, 150_000e6));
        vm.warp(block.timestamp + 31 minutes);
        vm.roll(block.number + 1);
        // After a fall in token0's price the position holds only token0; swap part of it to token1.
        TidewellVaultV3.Position memory before = vault.getPosition(id);
        (,,,,,,, uint128 liqBefore,,,,) = npm.positions(before.tokenId);
        int24 base = _floor(_tick());
        uint256 swapIn = uint256(_in0(4 ether, 10_000e6));
        vm.prank(keeper);
        vault.rebalance(id, base - 600, base + 600, true, swapIn, "");
        (,,,,,,, uint128 liqAfter,,,,) = npm.positions(vault.getPosition(id).tokenId);
        assertGt(liqAfter, 0);
        assertTrue(liqBefore > 0);
    }

    /// What a range move cannot place belongs to the position, not to the fees: at a 50% reinvest setting the next
    /// compound still puts all of it back, and only the fee share stays ready to claim.
    function test_unplaced_rangeMoveLeftover_goesBackWhateverTheSetting() public {
        uint256 id = _open();
        trader.swap(pool, true, _in0(60 ether, 150_000e6));
        vm.warp(block.timestamp + 31 minutes);
        vm.roll(block.number + 1);
        int24 base = _floor(_tick());
        // A swap that is too small leaves part of the position over.
        vm.prank(keeper);
        vault.rebalance(id, base - 600, base + 600, true, uint256(_in0(1 ether, 2_500e6)), "");
        (uint256 u0, uint256 u1) = vault.unplaced(id);
        assertGt(u0 + u1, 0, "leftover recorded");
        assertLe(u0, IERC20(t0).balanceOf(address(vault)));
        assertLe(u1, IERC20(t1).balanceOf(address(vault)));

        _trade(3);
        (,,,,,,, uint128 liqBefore,,,,) = npm.positions(vault.getPosition(id).tokenId);
        // The keeper swaps part of the leftover to the ratio; everything that fits goes in.
        vm.prank(keeper);
        vault.compound(id, u0 > 0, u0 > 0 ? u0 / 2 : u1 / 2, "");
        (,,,,,,, uint128 liqAfter,,,,) = npm.positions(vault.getPosition(id).tokenId);
        assertGt(liqAfter, liqBefore);
        // The leftover went in (only the part the rough swap could not match is still waiting).
        (uint256 v0, uint256 v1) = vault.unplaced(id);
        if (u0 > 0) assertLt(v0, (u0 * 3) / 4, "leftover went back in");
        else assertLt(v1, (u1 * 3) / 4, "leftover went back in");
    }

    function test_unplaced_notClaimable_closeReturnsIt() public {
        uint256 id = _open();
        trader.swap(pool, true, _in0(60 ether, 150_000e6));
        vm.warp(block.timestamp + 31 minutes);
        vm.roll(block.number + 1);
        int24 base = _floor(_tick());
        vm.prank(keeper);
        vault.rebalance(id, base - 600, base + 600, true, uint256(_in0(1 ether, 2_500e6)), "");
        (uint256 u0, uint256 u1) = vault.unplaced(id);
        assertGt(u0 + u1, 0);
        // Claiming takes what is ready to claim only: the leftover belongs to the position and stays.
        vm.startPrank(user);
        vault.claim(t0, 0);
        vault.claim(t1, 0);
        vm.stopPrank();
        (uint256 v0, uint256 v1) = vault.unplaced(id);
        assertEq(v0, u0);
        assertEq(v1, u1);
        assertEq(IERC20(t0).balanceOf(address(vault)), u0);
        assertEq(IERC20(t1).balanceOf(address(vault)), u1);
        // Closing returns everything, the leftover included.
        uint256 b0 = IERC20(t0).balanceOf(user);
        uint256 b1 = IERC20(t1).balanceOf(user);
        vm.prank(user);
        vault.close(id, 0, 0);
        assertGe(IERC20(t0).balanceOf(user) - b0, u0);
        assertGe(IERC20(t1).balanceOf(user) - b1, u1);
        (v0, v1) = vault.unplaced(id);
        assertEq(v0 + v1, 0);
    }

    function test_rebalance_rules() public {
        uint256 id = _open();
        int24 base = _floor(_tick());

        // Too soon after opening.
        vm.prank(keeper);
        vm.expectRevert(TidewellVaultBase.TooSoon.selector);
        vault.rebalance(id, base - 600, base + 600, false, 0, "");

        vm.warp(block.timestamp + 31 minutes);
        // Range that does not contain the current price.
        vm.prank(keeper);
        vm.expectRevert(TidewellVaultBase.BadRange.selector);
        vault.rebalance(id, base + 600, base + 1200, false, 0, "");
        // Range wider than the owner allows.
        vm.prank(keeper);
        vm.expectRevert(TidewellVaultBase.BadRange.selector);
        vault.rebalance(id, base - 6000, base + 6000, false, 0, "");
        // A stranger cannot rebalance.
        vm.prank(stranger);
        vm.expectRevert(TidewellVaultBase.NotAllowed.selector);
        vault.rebalance(id, base - 600, base + 600, false, 0, "");
        // Swap larger than what the position holds.
        vm.prank(keeper);
        vm.expectRevert(TidewellVaultBase.SwapTooLarge.selector);
        vault.rebalance(id, base - 600, base + 600, true, 1e30, "");
    }

    function test_rebalance_refusesManipulatedPrice() public {
        uint256 id = _open();
        vm.warp(block.timestamp + 31 minutes);
        // Someone moves the price hard in the same block the keeper acts: the pool average disagrees.
        trader.swap(pool, true, _in0(60 ether, 150_000e6));
        int24 base = _floor(_tick());
        vm.prank(keeper);
        vm.expectRevert();
        vault.rebalance(id, base - 600, base + 600, false, 0, "");
    }

    function test_chainlinkCheck() public {
        uint256 id = _open();
        MockFeed fw = new MockFeed();
        MockFeed fu = new MockFeed();
        fw.set(2500e8, block.timestamp);
        fu.set(1e8, block.timestamp);
        factory.setFeed(address(weth), address(fw), 1 days);
        factory.setFeed(address(usdg), address(fu), 1 days);
        vm.warp(block.timestamp + 31 minutes);
        fw.set(2500e8, block.timestamp);
        fu.set(1e8, block.timestamp);
        vm.prank(keeper);
        vault.compound(id, false, 0, ""); // price matches the feeds

        fw.set(2000e8, block.timestamp); // feed says ETH is 20% cheaper than the pool
        vm.prank(keeper);
        vm.expectRevert();
        vault.compound(id, false, 0, "");

        // A stale feed falls back to the pool's own average, which is fine here.
        vm.warp(block.timestamp + 2 days);
        vm.prank(keeper);
        vault.compound(id, false, 0, "");
    }

    function test_pause_blocksKeeperButNeverWithdrawals() public {
        uint256 id = _open();
        vm.prank(guardian);
        factory.setPaused(true);

        vm.prank(keeper);
        vm.expectRevert(TidewellVaultBase.Paused.selector);
        vault.compound(id, false, 0, "");

        uint256 w = weth.balanceOf(user);
        uint256 u = usdg.balanceOf(user);
        vm.prank(user);
        vault.close(id, 0, 0);
        assertGt(weth.balanceOf(user) + usdg.balanceOf(user), w + u);
        assertEq(vault.positionIds().length, 0);
        assertEq(weth.balanceOf(address(vault)), 0);
        assertEq(usdg.balanceOf(address(vault)), 0);
    }

    function test_close_worksWhenFeeRecipientBroken() public {
        uint256 id = _open();
        _trade(5);
        sink.setBroken(true);
        // The keeper's actions stop, but the owner can still leave.
        vm.prank(keeper);
        vm.expectRevert();
        vault.compound(id, false, 0, "");
        vm.prank(user);
        vault.close(id, 0, 0);
        assertEq(vault.positionIds().length, 0);
    }

    function test_rescue_handsOverNft() public {
        uint256 id = _open();
        uint256 tokenId = vault.getPosition(id).tokenId;
        vm.prank(user);
        vault.rescue(id);
        assertEq(INPMExtra(address(npm)).ownerOf(tokenId), user);
    }

    function test_guardedMode_refusesUnknownTokens() public {
        MockERC20 other = new MockERC20("OTHER", 18);
        factory.setTokenCap(address(weth), 1 ether);
        int24 base = _floor(_tick());
        TidewellVaultV3.OpenParams memory p = TidewellVaultV3.OpenParams({
            token0: t0,
            token1: t1,
            fee: FEE,
            tickLower: base - 600,
            tickUpper: base + 600,
            amount0: 10 ether,
            amount1: 10 ether,
            amount0Min: 0,
            amount1Min: 0,
            settings: _settings()
        });
        vm.prank(user);
        vm.expectRevert(); // above the 1 WETH cap
        vault.open(p);
        assertEq(factory.tokenCap(address(other)), 0);
        vm.expectRevert(abi.encodeWithSelector(TidewellFactory.TokenNotAllowed.selector, address(other)));
        factory.checkDeposit(address(other), 1);
    }

    function test_settingsLimits() public {
        TidewellVaultBase.Settings memory s = _settings();
        s.cooldown = 1 minutes; // below the factory minimum
        int24 base = _floor(_tick());
        TidewellVaultV3.OpenParams memory p = TidewellVaultV3.OpenParams({
            token0: t0,
            token1: t1,
            fee: FEE,
            tickLower: base - 600,
            tickUpper: base + 600,
            amount0: 1e6,
            amount1: 1e6,
            amount0Min: 0,
            amount1Min: 0,
            settings: s
        });
        vm.prank(user);
        vm.expectRevert(TidewellVaultBase.BadSettings.selector);
        vault.open(p);

        // A range rule the keeper does not know is refused too; rules 1 to 4 are stored for the keeper.
        p.settings = _settings();
        p.settings.rule = 5;
        vm.prank(user);
        vm.expectRevert(TidewellVaultBase.BadSettings.selector);
        vault.open(p);
        p.settings.rule = 2;
        p.settings.minWidth = 600;
        p.settings.maxWidth = 6000;
        vm.prank(user);
        uint256 id = vault.open(p);
        assertEq(vault.getPosition(id).settings.rule, 2);
    }

    function test_factoryHardLimits() public {
        vm.expectRevert(TidewellFactory.OutOfBounds.selector);
        factory.setFee(address(sink), 1001, address(0));
        vm.expectRevert(TidewellFactory.OutOfBounds.selector);
        factory.setGasRefund(1 gwei, 1 ether, 0);
        vm.prank(stranger);
        vm.expectRevert();
        factory.setKeeper(stranger);
        vm.prank(stranger);
        vm.expectRevert(TidewellFactory.NotGuardian.selector);
        factory.setPaused(true);
    }

    function test_oneVaultPerUser_andPredictable() public {
        address predicted = factory.predictVault(stranger, 0);
        vm.prank(stranger);
        address v = factory.createVault(0);
        assertEq(v, predicted);
        vm.prank(stranger);
        assertEq(factory.createVault(0), v);
        vm.prank(stranger);
        address v4 = factory.createVault(1);
        assertEq(v4, factory.predictVault(stranger, 1));
        assertTrue(v4 != v);
        vm.expectRevert(TidewellVaultBase.AlreadyInitialized.selector);
        TidewellVaultV3(payable(v)).initialize(stranger);
        address impl = factory.implementationV3();
        vm.expectRevert(TidewellVaultBase.AlreadyInitialized.selector);
        TidewellVaultV3(payable(impl)).initialize(stranger);
    }

    function test_compound_oneSidedFeesStayClaimable() public {
        uint256 id = _open();
        // Trades in one direction only, staying inside the range: fees in token0 only.
        for (uint256 i; i < 5; ++i) {
            trader.swap(pool, true, _in0(0.2 ether, 500e6));
            vm.warp(block.timestamp + 20);
        }
        vm.warp(block.timestamp + 700);
        vm.prank(keeper);
        vault.compound(id, false, 0, "");
        assertGt(IERC20(t0).balanceOf(address(vault)), 0);
    }

    function test_swapCallback_onlyFromActivePool() public {
        vm.expectRevert(TidewellVaultBase.NotAllowed.selector);
        vault.uniswapV3SwapCallback(1, 0, abi.encode(t0, t1));
    }

    // ------------------------------------------------------------ revenue in ETH

    function test_router_convertsUsdgToEth_andPaysReferralsInEth() public {
        address inviter = makeAddr("inviter");
        address friend = makeAddr("friend");
        address[5] memory d = [makeAddr("well"), makeAddr("boost"), makeAddr("burn"), makeAddr("safety"), makeAddr("team")];
        ReferralRegistry reg = new ReferralRegistry(address(factory));
        RevenueRouter router = new RevenueRouter(address(this), address(reg), address(factory), d[0], d[1], d[2], d[3], d[4]);
        factory.setFee(address(router), 200, address(reg));
        // Take fees in USDG for this test, as in a Stock Token / USDG pool.
        factory.setFeeRank(address(weth), 0);
        factory.setFeeRank(address(usdg), 1);

        weth.mint(friend, 100 ether);
        usdg.mint(friend, 1_000_000e6);
        vm.prank(friend);
        reg.setReferrer(inviter);
        vm.prank(friend);
        TidewellVaultV3 fv = TidewellVaultV3(payable(factory.createVault(0)));
        vm.startPrank(friend);
        weth.approve(address(fv), type(uint256).max);
        usdg.approve(address(fv), type(uint256).max);
        vm.stopPrank();
        int24 base = _floor(_tick());
        TidewellVaultV3.OpenParams memory p = TidewellVaultV3.OpenParams({
            token0: t0,
            token1: t1,
            fee: FEE,
            tickLower: base - 600,
            tickUpper: base + 600,
            amount0: uint256(_in0(10 ether, 25_000e6)),
            amount1: uint256(_in1(10 ether, 25_000e6)),
            amount0Min: 0,
            amount1Min: 0,
            settings: _settings()
        });
        vm.prank(friend);
        uint256 id = fv.open(p);
        _trade(10);
        vm.prank(keeper);
        fv.compound(id, false, 0, "");

        uint256 usdgIn = router.pending(address(usdg)) + router.referralTotal(address(usdg));
        assertGt(usdgIn, 0);
        assertEq(router.pending(address(weth)), 0); // the whole fee came in USDG
        uint256 refUnits = router.referralOwed(inviter, address(usdg));
        assertEq(refUnits, (usdgIn * 2000) / 10_000);

        // Distributing USDG directly is refused: it must become ETH first.
        vm.expectRevert(RevenueRouter.UnknownPool.selector);
        router.distribute(address(usdg));
        vm.prank(stranger);
        vm.expectRevert(RevenueRouter.NotKeeper.selector);
        router.convert(address(usdg), FEE);

        vm.prank(keeper);
        uint256 ethOut = router.convert(address(usdg), FEE);
        // About 1 ETH per 2,500 USDG, minus the pool fee and price impact.
        assertApproxEqRel(ethOut, (usdgIn * 1e12) / 2500, 0.01e18);
        assertEq(router.pending(address(usdg)), 0);
        assertEq(address(router).balance, ethOut);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdg);
        vm.prank(inviter);
        uint256 refEth = router.claimReferral(tokens);
        assertApproxEqRel(refEth, (ethOut * 2000) / 10_000, 0.0001e18);
        assertEq(inviter.balance, refEth);

        uint256 rest = router.pending(address(0));
        router.distribute(address(0));
        assertEq(d[4].balance, rest - (rest * 3000) / 10_000 - (rest * 500) / 10_000 - (rest * 3500) / 10_000 - (rest * 1500) / 10_000);
        assertEq(address(router).balance, 0);
    }

    function test_router_unwrapsWeth() public {
        address[5] memory d = [makeAddr("well"), makeAddr("boost"), makeAddr("burn"), makeAddr("safety"), makeAddr("team")];
        ReferralRegistry reg = new ReferralRegistry(address(factory));
        RevenueRouter router = new RevenueRouter(address(this), address(reg), address(factory), d[0], d[1], d[2], d[3], d[4]);
        factory.setFee(address(router), 200, address(0));
        uint256 id = _open();
        _trade(10);
        vm.prank(keeper);
        vault.compound(id, false, 0, "");
        uint256 w = router.pending(address(weth));
        assertGt(w, 0);
        vm.prank(keeper);
        assertEq(router.convert(address(weth), 0), w);
        assertEq(router.pending(address(0)), w);
        router.distribute(address(0));
        assertEq(d[0].balance, (w * 3000) / 10_000);
    }
}
