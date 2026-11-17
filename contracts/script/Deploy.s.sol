// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {TidewellSwapper} from "../src/TidewellSwapper.sol";
import {TidewellFactory} from "../src/TidewellFactory.sol";
import {TidewellVaultV3} from "../src/TidewellVaultV3.sol";
import {TidewellVaultV4} from "../src/TidewellVaultV4.sol";
import {TidewellShapedVaultV3} from "../src/TidewellShapedVaultV3.sol";
import {TidewellShapedVaultV4} from "../src/TidewellShapedVaultV4.sol";
import {ReferralRegistry} from "../src/ReferralRegistry.sol";
import {RevenueRouter} from "../src/RevenueRouter.sol";
import {BuybackBurner} from "../src/BuybackBurner.sol";
import {Reserve} from "../src/Reserve.sol";
import {TheWell} from "../src/TheWell.sol";

/// @title Tidewell deployment, in two parts
/// @notice Part 1 (before the TIDE launch): timelock, vaults, factory, referrals, revenue router, burner and reserves.
///         The TIDE launch on Pons then uses the revenue router as its fee wallet.
///         Part 2 (after the launch): The Well, the final wiring, and offering every contract to the timelock.
///         The admin Safe then schedules, through the timelock, one batch that accepts ownership of all of them; 48
///         hours later anyone can execute it. From then on the deployer wallet has no power left.
abstract contract TidewellDeploy is Script {
    /// Uniswap's Universal Router on Robinhood Chain (version 2.1.2, the one Uniswap's routing builds for).
    address constant UNIVERSAL_ROUTER = 0x204FAca1764B154221e35c0d20aBb3c525710498;

    struct Config {
        address adminSafe; // owns everything through the timelock, and is the pause guardian
        address teamSafe; // receives the team and development share
        address keeper;
        address weth;
        address usdg;
        address v3PositionManager;
        address v3Factory;
        address v4PoolManager;
        address v4PositionManager;
        address permit2;
        uint256 timelockDelay; // 48 hours on mainnet
    }

    struct Part1 {
        TimelockController timelock;
        TidewellFactory factory;
        ReferralRegistry referrals;
        RevenueRouter router;
        BuybackBurner burner;
        Reserve boostReserve;
        Reserve safetyFund;
        Reserve expansionReserve;
    }

    /// @param me the deploying wallet; it owns everything until part 2 hands it to the timelock
    function _part1(Config memory c, address me) internal returns (Part1 memory d) {
        address[] memory admins = new address[](1);
        admins[0] = c.adminSafe;
        d.timelock = new TimelockController(c.timelockDelay, admins, admins, address(0));
        d.factory = new TidewellFactory(
            me,
            TidewellFactory.Addresses({
                implementationV3: address(new TidewellVaultV3()),
                implementationV4: address(new TidewellVaultV4()),
                positionManager: c.v3PositionManager,
                uniswapFactory: c.v3Factory,
                poolManager: c.v4PoolManager,
                positionManagerV4: c.v4PositionManager,
                permit2: c.permit2,
                weth: c.weth
            }),
            c.keeper,
            c.adminSafe,
            c.teamSafe // placeholder fee recipient, replaced below
        );
        // Vault swaps run through the swapper, in the deepest pool the keeper sets per pair.
        d.factory.setSwapper(
            address(new TidewellSwapper(address(d.factory), c.v4PoolManager, c.permit2, UNIVERSAL_ROUTER))
        );
        d.referrals = new ReferralRegistry(address(d.factory));
        d.factory.setReferrals(address(d.referrals));
        d.burner = new BuybackBurner(me, c.v4PoolManager, address(d.factory));
        d.boostReserve = new Reserve(me, "Boosted pools reserve");
        d.safetyFund = new Reserve(me, "Safety fund");
        d.expansionReserve = new Reserve(me, "Expansion to other chains");
        // The staking reserve (The Well) does not exist yet: the team Safe stands in until part 2.
        d.router = new RevenueRouter(
            me,
            address(d.referrals),
            address(d.factory),
            c.teamSafe,
            address(d.boostReserve),
            address(d.burner),
            address(d.safetyFund),
            c.teamSafe
        );
        d.factory.setFee(address(d.router), 200, address(d.referrals));
        // Fees are taken in ETH where a pair has it, else in USDG; revenue in USDG is converted to ETH.
        d.factory.setFeeRank(c.usdg, 1);
        d.router.setUsdg(c.usdg, 100);
        d.router.setExpansionReserve(address(d.expansionReserve));
        // Every token may be deposited (the price checks and slippage limits still apply to every pool).
        d.factory.setOpenMode(true);
    }

    /// @notice A second factory with the current vault code (vaults keep track of what a range move could not place
    ///         and put it back with every compound). Vaults of the first factory keep working as they are; new
    ///         positions open here. Copies every setting of the first factory and lets its vaults pay the revenue
    ///         router. Its own swapper, since a swapper serves the vaults of one factory.
    /// @dev The referral registry only accepts links from the first factory, so this factory does not link invite
    ///      codes itself: the site links a new user's code at the registry, then opens without one.
    function _factory2(Config memory c, TidewellFactory old, RevenueRouter router, address me)
        internal
        returns (TidewellFactory f2)
    {
        f2 = new TidewellFactory(
            me,
            TidewellFactory.Addresses({
                implementationV3: address(new TidewellVaultV3()),
                implementationV4: address(new TidewellVaultV4()),
                positionManager: old.positionManager(),
                uniswapFactory: old.uniswapFactory(),
                poolManager: old.poolManager(),
                positionManagerV4: old.positionManagerV4(),
                permit2: old.permit2(),
                weth: old.weth()
            }),
            old.keeper(),
            old.guardian(),
            old.feeRecipient()
        );
        f2.setSwapper(address(new TidewellSwapper(address(f2), old.poolManager(), old.permit2(), UNIVERSAL_ROUTER)));
        f2.setFee(old.feeRecipient(), old.protocolFeeBps(), old.feeDiscount());
        f2.setLimits(old.maxSlippageBps(), old.maxPriceDeviationBps(), old.maxTickDeviation(), old.minCooldown());
        f2.setGasRefund(old.maxGasPrice(), old.maxRefundWei(), old.refundOverheadGas());
        f2.setCardinalityTarget(old.cardinalityTarget());
        f2.setFeeRank(c.usdg, old.feeRank(c.usdg));
        address[2] memory tokens = [c.weth, c.usdg];
        for (uint256 i; i < 2; ++i) {
            uint256 cap = old.tokenCap(tokens[i]);
            if (cap > 0) f2.setTokenCap(tokens[i], cap);
            (address feed, uint32 maxAge) = old.feeds(tokens[i]);
            if (feed != address(0)) f2.setFeed(tokens[i], feed, maxAge);
        }
        if (old.openMode()) f2.setOpenMode(true);
        // The revenue router takes the protocol fee from this factory's vaults too.
        if (router.owner() == me) router.setFactory(address(f2), true);
    }

    /// @notice The factory of vault version 2: liquidity shapes and keeper limits (TidewellShapedVaultV3/V4). Copies
    ///         every setting of the current factory, except a lower slippage ceiling (MAX_SLIPPAGE_SHAPED). Vaults of
    ///         the earlier factories keep working as they are; new positions open here. Its own swapper.
    /// @dev Offered to the timelock right away (Ownable2Step). The revenue router must also accept its vaults' fees:
    ///      both go in one timelock batch (router.setFactory + acceptOwnership), see scripts/mainnet-env.mjs. Until
    ///      that batch is executed the site keeps opening positions in the current factory.
    uint256 constant MAX_SLIPPAGE_SHAPED = 300;

    function _factoryShaped(Config memory c, TidewellFactory old, address ponsHook, address timelock, address me)
        internal
        returns (TidewellFactory f)
    {
        f = new TidewellFactory(
            me,
            TidewellFactory.Addresses({
                implementationV3: address(new TidewellShapedVaultV3()),
                implementationV4: address(new TidewellShapedVaultV4()),
                positionManager: old.positionManager(),
                uniswapFactory: old.uniswapFactory(),
                poolManager: old.poolManager(),
                positionManagerV4: old.positionManagerV4(),
                permit2: old.permit2(),
                weth: old.weth()
            }),
            old.keeper(),
            old.guardian(),
            old.feeRecipient()
        );
        f.setSwapper(address(new TidewellSwapper(address(f), old.poolManager(), old.permit2(), UNIVERSAL_ROUTER)));
        f.setFee(old.feeRecipient(), old.protocolFeeBps(), old.feeDiscount());
        uint256 slip = old.maxSlippageBps() < MAX_SLIPPAGE_SHAPED ? old.maxSlippageBps() : MAX_SLIPPAGE_SHAPED;
        f.setLimits(slip, old.maxPriceDeviationBps(), old.maxTickDeviation(), old.minCooldown());
        f.setGasRefund(old.maxGasPrice(), old.maxRefundWei(), old.refundOverheadGas());
        f.setCardinalityTarget(old.cardinalityTarget());
        f.setReferrals(old.referrals());
        f.setFeeRank(c.usdg, old.feeRank(c.usdg));
        address[2] memory tokens = [c.weth, c.usdg];
        for (uint256 i; i < 2; ++i) {
            uint256 cap = old.tokenCap(tokens[i]);
            if (cap > 0) f.setTokenCap(tokens[i], cap);
            (address feed, uint32 maxAge) = old.feeds(tokens[i]);
            if (feed != address(0)) f.setFeed(tokens[i], feed, maxAge);
        }
        if (old.openMode()) f.setOpenMode(true);
        if (ponsHook != address(0) && old.allowedHook(ponsHook)) f.setHookAllowed(ponsHook, true);
        f.transferOwnership(timelock);
    }

    /// @param tide the TIDE token, after its launch on Pons with the revenue router as fee wallet
    /// @param f2 the second factory (address zero when there is none): wired and handed over the same way
    function _part2(
        Config memory c,
        Part1 memory d,
        TidewellFactory f2,
        address tide,
        address ponsEscrow,
        address ponsHook,
        address ponsFactory
    ) internal returns (TheWell well) {
        well = new TheWell(address(d.factory.owner()), tide, address(d.referrals));
        d.router.setDestinations(address(well), address(d.boostReserve), address(d.burner), address(d.safetyFund), c.teamSafe);
        d.router.setPons(ponsEscrow, ponsHook, ponsFactory, tide);
        // The buyback starts on TIDE's bonding curve and moves to its pool by itself when TIDE graduates.
        d.burner.setPonsSource(ponsFactory, tide);
        // While TIDE trades on the Pons curve: a buyback at most every hour (the shortest the burner allows), so the
        // early creator fees are burned soon. The keeper buys as soon as enough ETH waits (see BURN_MIN_WEI).
        d.burner.setCurveLimits(1 hours, 100);
        // Pons pools (TIDE's own pool among them) use the Pons hook, reviewed and tested on a copy of mainnet.
        d.factory.setHookAllowed(ponsHook, true);
        d.factory.setFee(address(d.router), 200, address(well));
        if (address(f2) != address(0)) {
            f2.setHookAllowed(ponsHook, true);
            f2.setFee(address(d.router), 200, address(well));
            f2.transferOwnership(address(d.timelock));
        }

        address tl = address(d.timelock);
        d.factory.transferOwnership(tl);
        d.router.transferOwnership(tl);
        d.burner.transferOwnership(tl);
        d.boostReserve.transferOwnership(tl);
        d.safetyFund.transferOwnership(tl);
        d.expansionReserve.transferOwnership(tl);
        well.transferOwnership(tl);
    }

    function _config() internal view returns (Config memory) {
        return Config({
            adminSafe: vm.envAddress("ADMIN_SAFE"),
            teamSafe: vm.envAddress("TEAM_SAFE"),
            keeper: vm.envAddress("KEEPER"),
            weth: 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73,
            usdg: 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168,
            v3PositionManager: 0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3,
            v3Factory: 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA,
            v4PoolManager: 0x8366a39CC670B4001A1121B8F6A443A643e40951,
            v4PositionManager: 0x58daec3116aae6D93017bAAea7749052E8a04fA7,
            permit2: 0x000000000022D473030F116dDEE9F6B43aC78BA3,
            timelockDelay: 48 hours
        });
    }
}

/// Run by the "Mainnet" GitHub workflow (docs/github-workflow-mainnet.yml), which also verifies the contracts on
/// Blockscout and writes the site and keeper settings. By hand:
/// forge script script/Deploy.s.sol:DeployPart1 --rpc-url $RPC --broadcast --verify
contract DeployPart1 is TidewellDeploy {
    function run() external {
        Config memory c = _config();
        vm.startBroadcast();
        Part1 memory d = _part1(c, msg.sender);
        vm.stopBroadcast();
        console.log("timelock", address(d.timelock));
        console.log("factory", address(d.factory));
        console.log("referrals", address(d.referrals));
        console.log("router (use as Pons fee wallet)", address(d.router));
        console.log("burner", address(d.burner));
        console.log("boostReserve", address(d.boostReserve));
        console.log("safetyFund", address(d.safetyFund));
        console.log("expansionReserve", address(d.expansionReserve));

        // For the deploy workflow: the addresses, read back by part 2 and turned into the site and keeper settings.
        string memory k = "part1";
        vm.serializeAddress(k, "timelock", address(d.timelock));
        vm.serializeAddress(k, "factory", address(d.factory));
        vm.serializeAddress(k, "swapper", d.factory.swapper());
        vm.serializeAddress(k, "referrals", address(d.referrals));
        vm.serializeAddress(k, "router", address(d.router));
        vm.serializeAddress(k, "burner", address(d.burner));
        vm.serializeAddress(k, "boostReserve", address(d.boostReserve));
        vm.serializeAddress(k, "safetyFund", address(d.safetyFund));
        vm.serializeAddress(k, "keeper", c.keeper);
        vm.serializeAddress(k, "adminSafe", c.adminSafe);
        vm.serializeAddress(k, "teamSafe", c.teamSafe);
        string memory json = vm.serializeAddress(k, "expansionReserve", address(d.expansionReserve));
        vm.writeJson(json, vm.envOr("PART1_OUT", string("../deployments/mainnet-part1.json")));
    }
}

/// Reads the part 1 addresses and the TIDE / Pons addresses from the environment.
contract DeployPart2 is TidewellDeploy {
    function run() external {
        Config memory c = _config();
        Part1 memory d = Part1({
            timelock: TimelockController(payable(vm.envAddress("TIMELOCK"))),
            factory: TidewellFactory(vm.envAddress("FACTORY")),
            referrals: ReferralRegistry(vm.envAddress("REFERRALS")),
            router: RevenueRouter(payable(vm.envAddress("ROUTER"))),
            burner: BuybackBurner(payable(vm.envAddress("BURNER"))),
            boostReserve: Reserve(payable(vm.envAddress("BOOST_RESERVE"))),
            safetyFund: Reserve(payable(vm.envAddress("SAFETY_FUND"))),
            expansionReserve: Reserve(payable(vm.envAddress("EXPANSION_RESERVE")))
        });
        TidewellFactory f2 = TidewellFactory(vm.envOr("FACTORY2", address(0)));
        vm.startBroadcast();
        TheWell well = _part2(
            c, d, f2, vm.envAddress("TIDE"), vm.envAddress("PONS_ESCROW"), vm.envAddress("PONS_HOOK"), vm.envAddress("PONS_FACTORY")
        );
        vm.stopBroadcast();
        console.log("well", address(well));
        string memory k = "part2";
        vm.serializeAddress(k, "tide", vm.envAddress("TIDE"));
        string memory json = vm.serializeAddress(k, "well", address(well));
        vm.writeJson(json, vm.envOr("PART2_OUT", string("../deployments/mainnet-part2.json")));
    }
}

/// The second factory (see _factory2). Reads the first factory and the revenue router from the environment. Run by the
/// "Mainnet" workflow (part: factory2) with the deploy wallet. Before part 2 (and until the timelock has accepted the
/// router) the deploy wallet adds the new factory to the router itself, and part 2 hands the new factory to the
/// timelock with the rest. Once the first factory is being handed to the timelock, the new one is offered to it here;
/// if the router already belongs to the timelock, the admin Safe adds the new factory to it through the timelock.
contract DeployFactory2 is TidewellDeploy {
    function run() external {
        Config memory c = _config();
        TidewellFactory old = TidewellFactory(vm.envAddress("FACTORY"));
        RevenueRouter router = RevenueRouter(payable(vm.envAddress("ROUTER")));
        vm.startBroadcast();
        TidewellFactory f2 = _factory2(c, old, router, msg.sender);
        bool routerDone = router.isFactory(address(f2));
        // Once the first factory is (being) handed to the timelock, this one goes the same way.
        address tl = vm.envAddress("TIMELOCK");
        if (old.owner() == tl || old.pendingOwner() == tl) f2.transferOwnership(tl);
        vm.stopBroadcast();
        console.log("factory2", address(f2));
        console.log("swapper2", f2.swapper());
        console.log("router accepts factory2", routerDone);
        string memory k = "factory2";
        vm.serializeAddress(k, "factory2", address(f2));
        string memory json = vm.serializeAddress(k, "swapper2", f2.swapper());
        vm.writeJson(json, vm.envOr("FACTORY2_OUT", string("../deployments/mainnet-factory2.json")));
    }
}

/// Vault version 2: liquidity shapes and keeper limits (see _factoryShaped). Reads the current factory, the timelock
/// and the Pons hook from the environment; ROUTER optional. Run by the "Mainnet" workflow (part: shapes). The new
/// factory is offered to the timelock straight away. When the deploy wallet still owns the revenue router (before the
/// timelock handover is executed), it also registers the new factory there, so new positions can open in it at once;
/// otherwise that waits for the timelock batch (mainnet-safe-shapes-*.json).
contract DeployShapes is TidewellDeploy {
    function run() external {
        Config memory c = _config();
        TidewellFactory old = TidewellFactory(vm.envAddress("FACTORY"));
        address tl = vm.envAddress("TIMELOCK");
        RevenueRouter router = RevenueRouter(payable(vm.envOr("ROUTER", address(0))));
        vm.startBroadcast();
        TidewellFactory f = _factoryShaped(c, old, vm.envOr("PONS_HOOK", address(0)), tl, msg.sender);
        bool registered;
        if (address(router) != address(0) && router.owner() == msg.sender) {
            router.setFactory(address(f), true);
            registered = true;
        }
        vm.stopBroadcast();
        require(f.pendingOwner() == tl, "not offered to the timelock");
        if (registered) require(router.isFactory(address(f)), "not registered at the router");
        console.log(registered ? "registered at the revenue router: live now" : "not registered: needs the timelock batch");
        console.log("factory3 (shapes)", address(f));
        console.log("swapper3", f.swapper());
        string memory k = "shapes";
        vm.serializeAddress(k, "factory3", address(f));
        vm.serializeAddress(k, "implementationV3Shaped", f.implementationV3());
        vm.serializeAddress(k, "implementationV4Shaped", f.implementationV4());
        string memory json = vm.serializeAddress(k, "swapper3", f.swapper());
        vm.writeJson(json, vm.envOr("SHAPES_OUT", string("../deployments/mainnet-shapes.json")));
    }
}

/// For the first mainnet deployment, whose part 1 left deposits closed: opens them for every token. Run by the
/// "Mainnet" workflow (part: open) with the deploy wallet, which owns the factory until the timelock takes over.
contract OpenDeposits is Script {
    function run() external {
        TidewellFactory factory = TidewellFactory(vm.envAddress("FACTORY"));
        vm.startBroadcast();
        factory.setOpenMode(true);
        vm.stopBroadcast();
        require(factory.openMode(), "deposits not open");
        console.log("openMode", factory.openMode());
    }
}
