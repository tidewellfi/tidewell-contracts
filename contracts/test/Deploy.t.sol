// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TidewellDeploy} from "../script/Deploy.s.sol";
import {TheWell} from "../src/TheWell.sol";
import {MockERC20} from "./mocks/Mocks.sol";
import {TidewellFactory} from "../src/TidewellFactory.sol";

contract DeployTest is Test, TidewellDeploy {
    function test_wiring_andTimelockOwnership() public {
        address admin = makeAddr("adminSafe");
        address team = makeAddr("teamSafe");
        Config memory c = Config({
            adminSafe: admin,
            teamSafe: team,
            keeper: makeAddr("keeper"),
            weth: address(new MockERC20("WETH", 18)),
            usdg: address(new MockERC20("USDG", 6)),
            v3PositionManager: address(0x1001),
            v3Factory: address(0x1002),
            v4PoolManager: address(0x1003),
            v4PositionManager: address(0x1004),
            permit2: address(0x1005),
            timelockDelay: 48 hours
        });
        Part1 memory d = _part1(c, address(this));
        assertEq(d.factory.feeRecipient(), address(d.router));
        assertEq(d.factory.guardian(), admin);
        assertEq(d.factory.feeDiscount(), address(d.referrals));
        assertEq(d.factory.referrals(), address(d.referrals));
        assertEq(d.factory.feeRank(c.usdg), 1);
        assertEq(d.router.usdg(), c.usdg);
        assertEq(d.router.expansionReserve(), address(d.expansionReserve));

        // A second factory (current vault code): copies the first one's settings and is accepted by the router.
        TidewellFactory f2 = _factory2(c, d.factory, d.router, address(this));
        assertEq(f2.feeRecipient(), address(d.router));
        assertEq(f2.feeDiscount(), address(d.referrals));
        assertEq(f2.keeper(), d.factory.keeper());
        assertEq(f2.guardian(), admin);
        assertEq(f2.feeRank(c.usdg), 1);
        assertEq(f2.protocolFeeBps(), d.factory.protocolFeeBps());
        assertEq(f2.maxSlippageBps(), d.factory.maxSlippageBps());
        assertTrue(f2.openMode());
        assertTrue(f2.swapper() != address(0) && f2.swapper() != d.factory.swapper(), "own swapper");
        assertTrue(f2.implementationV4() != d.factory.implementationV4());
        assertTrue(d.router.isFactory(address(f2)), "router takes fees from its vaults");

        MockERC20 tide = new MockERC20("TIDE", 18);
        TheWell well = _part2(c, d, f2, address(tide), address(2), address(3), address(4));
        assertEq(f2.feeDiscount(), address(well));
        assertTrue(f2.allowedHook(address(3)), "Pons hook allowed on the second factory");
        assertEq(f2.pendingOwner(), address(d.timelock));
        assertEq(d.factory.feeDiscount(), address(well));
        assertEq(d.router.stakingReserve(), address(well));
        assertEq(d.router.team(), team);
        assertEq(d.router.tide(), address(tide));
        assertEq(address(d.burner.ponsFactory()), address(4));
        assertEq(d.burner.tide(), address(tide));
        assertTrue(d.factory.allowedHook(address(3)), "Pons hook allowed");
        assertTrue(d.factory.openMode(), "deposits open");

        // Ownership is offered to the timelock, which accepts it through its own 48-hour delay.
        address tl = address(d.timelock);
        assertEq(d.factory.pendingOwner(), tl);
        assertEq(d.router.pendingOwner(), tl);
        assertEq(d.burner.pendingOwner(), tl);
        assertEq(d.safetyFund.pendingOwner(), tl);
        assertEq(d.boostReserve.pendingOwner(), tl);
        assertEq(d.expansionReserve.pendingOwner(), tl);
        assertEq(well.pendingOwner(), tl);
        assertEq(d.timelock.getMinDelay(), 48 hours);
        assertTrue(d.timelock.hasRole(d.timelock.PROPOSER_ROLE(), admin));
        assertTrue(d.timelock.hasRole(d.timelock.EXECUTOR_ROLE(), admin));

        // The admin Safe schedules acceptOwnership; it only runs after 48 hours.
        bytes memory call = abi.encodeWithSignature("acceptOwnership()");
        vm.prank(admin);
        d.timelock.schedule(address(d.factory), 0, call, bytes32(0), bytes32(0), 48 hours);
        vm.prank(admin);
        vm.expectRevert();
        d.timelock.execute(address(d.factory), 0, call, bytes32(0), bytes32(0));
        skip(48 hours);
        vm.prank(admin);
        d.timelock.execute(address(d.factory), 0, call, bytes32(0), bytes32(0));
        assertEq(d.factory.owner(), tl);
    }

    /// Vault version 2 (shapes): a third factory with the shaped vaults, the current settings (slippage ceiling at
    /// most 3%), offered to the timelock; one timelock batch then lets the router take its fees and accepts it.
    function test_shapesFactory_wiringAndTimelockBatch() public {
        address admin = makeAddr("adminSafe");
        Config memory c = Config({
            adminSafe: admin,
            teamSafe: makeAddr("teamSafe"),
            keeper: makeAddr("keeper"),
            weth: address(new MockERC20("WETH", 18)),
            usdg: address(new MockERC20("USDG", 6)),
            v3PositionManager: address(0x1001),
            v3Factory: address(0x1002),
            v4PoolManager: address(0x1003),
            v4PositionManager: address(0x1004),
            permit2: address(0x1005),
            timelockDelay: 48 hours
        });
        Part1 memory d = _part1(c, address(this));
        MockERC20 tide = new MockERC20("TIDE", 18);
        TheWell well = _part2(c, d, TidewellFactory(address(0)), address(tide), address(2), address(3), address(4));
        address tl = address(d.timelock);
        // The timelock owns everything (step 2 of the handover).
        bytes memory accept = abi.encodeWithSignature("acceptOwnership()");
        vm.startPrank(admin);
        d.timelock.schedule(address(d.factory), 0, accept, bytes32(0), bytes32(0), 48 hours);
        d.timelock.schedule(address(d.router), 0, accept, bytes32(0), bytes32(0), 48 hours);
        skip(48 hours);
        d.timelock.execute(address(d.factory), 0, accept, bytes32(0), bytes32(0));
        d.timelock.execute(address(d.router), 0, accept, bytes32(0), bytes32(0));
        vm.stopPrank();

        TidewellFactory f3 = _factoryShaped(c, d.factory, address(3), tl, address(this));
        assertEq(f3.pendingOwner(), tl);
        assertEq(f3.feeRecipient(), address(d.router));
        assertEq(f3.feeDiscount(), address(well));
        assertEq(f3.referrals(), address(d.referrals));
        assertEq(f3.keeper(), d.factory.keeper());
        assertEq(f3.guardian(), admin);
        assertEq(f3.maxSlippageBps(), 300, "slippage ceiling lowered to 3%");
        assertEq(f3.minCooldown(), d.factory.minCooldown());
        assertEq(f3.maxRefundWei(), d.factory.maxRefundWei());
        assertTrue(f3.openMode());
        assertTrue(f3.allowedHook(address(3)), "Pons hook copied");
        assertTrue(f3.swapper() != d.factory.swapper(), "own swapper");
        assertFalse(d.router.isFactory(address(f3)), "router waits for the timelock");

        // One batch through the timelock: the router takes this factory's fees, the timelock accepts the factory.
        address[] memory targets = new address[](2);
        targets[0] = address(d.router);
        targets[1] = address(f3);
        uint256[] memory values = new uint256[](2);
        bytes[] memory payloads = new bytes[](2);
        payloads[0] = abi.encodeWithSignature("setFactory(address,bool)", address(f3), true);
        payloads[1] = accept;
        bytes32 salt = keccak256("tidewell-shapes-1");
        vm.prank(admin);
        d.timelock.scheduleBatch(targets, values, payloads, bytes32(0), salt, 48 hours);
        skip(48 hours);
        vm.prank(admin);
        d.timelock.executeBatch(targets, values, payloads, bytes32(0), salt);
        assertTrue(d.router.isFactory(address(f3)));
        assertEq(f3.owner(), tl);
    }

    /// Live right away: before the timelock handover is executed, the deploy wallet still owns the revenue router and
    /// registers the shapes factory itself (as DeployShapes does). The handover then runs unchanged, and one later
    /// timelock batch (setFactory again is harmless) accepts the new factory.
    function test_shapesFactory_liveBeforeHandover() public {
        address admin = makeAddr("adminSafe");
        Config memory c = Config({
            adminSafe: admin,
            teamSafe: makeAddr("teamSafe"),
            keeper: makeAddr("keeper"),
            weth: address(new MockERC20("WETH", 18)),
            usdg: address(new MockERC20("USDG", 6)),
            v3PositionManager: address(0x1001),
            v3Factory: address(0x1002),
            v4PoolManager: address(0x1003),
            v4PositionManager: address(0x1004),
            permit2: address(0x1005),
            timelockDelay: 48 hours
        });
        Part1 memory d = _part1(c, address(this));
        MockERC20 tide = new MockERC20("TIDE", 18);
        _part2(c, d, TidewellFactory(address(0)), address(tide), address(2), address(3), address(4));
        address tl = address(d.timelock);
        assertEq(d.router.owner(), address(this), "deploy wallet still owns the router");
        assertEq(d.router.pendingOwner(), tl);

        TidewellFactory f3 = _factoryShaped(c, d.factory, address(3), tl, address(this));
        d.router.setFactory(address(f3), true);
        assertTrue(d.router.isFactory(address(f3)), "live at once");
        assertTrue(d.router.isFactory(address(d.factory)), "first factory keeps working");
        assertEq(d.router.pendingOwner(), tl, "handover offer untouched");

        // Step 2 of the handover, unchanged.
        bytes memory accept = abi.encodeWithSignature("acceptOwnership()");
        vm.startPrank(admin);
        d.timelock.schedule(address(d.router), 0, accept, bytes32(0), bytes32(0), 48 hours);
        skip(48 hours);
        d.timelock.execute(address(d.router), 0, accept, bytes32(0), bytes32(0));
        vm.stopPrank();
        assertEq(d.router.owner(), tl);
        assertTrue(d.router.isFactory(address(f3)), "still registered after the handover");

        // The shapes batch: setFactory again (no change) and the timelock accepts the new factory.
        address[] memory targets = new address[](2);
        targets[0] = address(d.router);
        targets[1] = address(f3);
        uint256[] memory values = new uint256[](2);
        bytes[] memory payloads = new bytes[](2);
        payloads[0] = abi.encodeWithSignature("setFactory(address,bool)", address(f3), true);
        payloads[1] = accept;
        bytes32 salt = keccak256("tidewell-shapes-1");
        vm.prank(admin);
        d.timelock.scheduleBatch(targets, values, payloads, bytes32(0), salt, 48 hours);
        skip(48 hours);
        vm.prank(admin);
        d.timelock.executeBatch(targets, values, payloads, bytes32(0), salt);
        assertEq(f3.owner(), tl);
        assertTrue(d.router.isFactory(address(f3)));
    }
}
