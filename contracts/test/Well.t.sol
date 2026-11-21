// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TheWell} from "../src/TheWell.sol";
import {Reserve} from "../src/Reserve.sol";
import {MockERC20, MockDiscount} from "./mocks/Mocks.t.sol";

contract WellTest is Test {
    TheWell well;
    MockERC20 tide;
    MockDiscount refs;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        vm.warp(1_800_000_000);
        tide = new MockERC20("TIDE", 18);
        refs = new MockDiscount();
        well = new TheWell(address(this), address(tide), address(refs));
        tide.mint(alice, 30_000_000e18);
        vm.prank(alice);
        tide.approve(address(well), type(uint256).max);
    }

    function test_discountRightAway_andGrowsWithTime() public {
        vm.prank(alice);
        well.stake(50_000e18);
        assertEq(well.discountBps(alice), 300); // 3% from the first moment
        vm.warp(block.timestamp + 30 days);
        assertEq(well.discountBps(alice), 500);
        vm.prank(alice);
        well.stake(1_950_000e18); // now 2M, but most of it is new: the time moves forward
        (, int256 col) = well.tierOf(alice);
        assertEq(col, 0);
        assertEq(well.discountBps(alice), 1500);
        vm.warp(block.timestamp + 180 days);
        assertEq(well.discountBps(alice), 5000);
        assertEq(well.boostBps(alice), 20000);
    }

    function test_belowFirstTier_noDiscount() public {
        vm.prank(alice);
        well.stake(49_999e18);
        assertEq(well.discountBps(alice), 0);
    }

    function test_unstake_anyTime_partialKeepsTime() public {
        vm.prank(alice);
        well.stake(1_000_000e18);
        vm.warp(block.timestamp + 90 days);
        vm.prank(alice);
        well.unstake(250_000e18);
        assertEq(well.discountBps(alice), 2400); // still 750k+ for 3 months
        vm.prank(alice);
        well.unstake(750_000e18);
        assertEq(tide.balanceOf(alice), 30_000_000e18);
        assertEq(well.totalStaked(), 0);
        (, uint64 since) = well.stakes(alice);
        assertEq(since, 0);
        vm.prank(alice);
        vm.expectRevert(TheWell.TooMuch.selector);
        well.unstake(1);
    }

    function test_referralDiscountAdds_cappedAtHalf() public {
        refs.set(1000);
        assertEq(well.discountBps(bob), 1000); // invited, not staking
        vm.prank(alice);
        well.stake(2_000_000e18);
        vm.warp(block.timestamp + 180 days);
        assertEq(well.discountBps(alice), 5000); // 50% + 10% capped at 50%
    }

    function _pay(uint256 amount) internal {
        vm.deal(address(this), amount);
        (bool ok,) = address(well).call{value: amount}("");
        assertTrue(ok);
    }

    function _bob(uint256 amount) internal {
        tide.mint(bob, amount);
        vm.startPrank(bob);
        tide.approve(address(well), type(uint256).max);
        well.stake(amount);
        vm.stopPrank();
    }

    function test_rewards_streamOver30Days() public {
        vm.prank(alice);
        well.stake(50_000e18);
        _pay(30 ether);
        vm.warp(block.timestamp + 1 days);
        assertApproxEqRel(well.earned(alice), 1 ether, 1e12); // one day of thirty
        vm.warp(block.timestamp + 14 days);
        assertApproxEqRel(well.earned(alice), 15 ether, 1e12);
        uint256 before = alice.balance;
        vm.prank(alice);
        uint256 got = well.claim();
        assertEq(alice.balance - before, got);
        assertApproxEqRel(got, 15 ether, 1e12);
        assertEq(well.earned(alice), 0);
        vm.warp(block.timestamp + 30 days); // past the end: the rest, and no more
        assertApproxEqRel(well.earned(alice), 15 ether, 1e12);
        vm.prank(alice);
        well.claim();
        assertLe(well.totalPaid(), 30 ether);
        assertGe(address(well).balance, 0);
        assertApproxEqAbs(address(well).balance, 0, 1e9);
    }

    function test_rewards_rolling_newMoneyJoinsTheStream() public {
        vm.prank(alice);
        well.stake(50_000e18);
        _pay(30 ether);
        vm.warp(block.timestamp + 15 days);
        _pay(30 ether); // 15 left + 30 new, over the next 30 days: 1.5 ETH a day
        vm.warp(block.timestamp + 10 days);
        assertApproxEqRel(well.earned(alice), 15 ether + 15 ether, 1e12);
    }

    function test_rewards_splitByWeight_amountTimesBoost() public {
        vm.prank(alice);
        well.stake(2_000_000e18); // boost 1.3x
        _bob(2_000_000e18); // boost 1.3x as well
        _pay(30 ether);
        vm.warp(block.timestamp + 30 days);
        assertApproxEqRel(well.earned(alice), 15 ether, 1e12);
        assertApproxEqRel(well.earned(bob), 15 ether, 1e12);
    }

    function test_rewards_boostCountsAfterRefresh() public {
        vm.prank(alice);
        well.stake(2_000_000e18);
        _bob(2_000_000e18);
        vm.warp(block.timestamp + 180 days); // alice and bob both reach 2x, but weights still say 1.3x
        address[] memory us = new address[](1);
        us[0] = alice;
        well.refresh(us); // only alice is refreshed (anyone may do it)
        assertEq(well.weightOf(alice), 4_000_000e18);
        assertEq(well.weightOf(bob), 2_600_000e18);
        _pay(33 ether);
        vm.warp(block.timestamp + 30 days);
        assertApproxEqRel(well.earned(alice), 20 ether, 1e12);
        assertApproxEqRel(well.earned(bob), 13 ether, 1e12);
    }

    function test_rewards_nobodyStaking_streamWaits() public {
        _pay(30 ether); // before anyone stakes
        vm.warp(block.timestamp + 10 days);
        vm.prank(alice);
        well.stake(50_000e18);
        vm.warp(block.timestamp + 30 days);
        assertApproxEqRel(well.earned(alice), 30 ether, 1e12); // nothing was lost in the empty days
    }

    function test_rewards_unstakeKeepsWhatWasEarned() public {
        vm.prank(alice);
        well.stake(50_000e18);
        _pay(30 ether);
        vm.warp(block.timestamp + 10 days);
        vm.prank(alice);
        well.unstake(50_000e18);
        uint256 e = well.earned(alice);
        assertApproxEqRel(e, 10 ether, 1e12);
        vm.warp(block.timestamp + 10 days);
        assertEq(well.earned(alice), e); // no stake, no more earning
        vm.prank(alice);
        assertEq(well.claim(), e);
    }

    function test_rewards_lateStakerGetsOnlyFromThen() public {
        vm.prank(alice);
        well.stake(1_000_000e18);
        _pay(30 ether);
        vm.warp(block.timestamp + 29 days);
        _bob(1_000_000e18); // joins on the last day: a big stake right before a payout gets almost nothing
        vm.warp(block.timestamp + 1 days);
        assertApproxEqRel(well.earned(alice), 29.5 ether, 1e12);
        assertApproxEqRel(well.earned(bob), 0.5 ether, 1e12);
    }

    /// Whatever the order of payments, stakes and claims: everyone can always be paid in full.
    function testFuzz_rewards_alwaysSolvent(uint96 p1, uint96 p2, uint32 d1, uint32 d2, uint96 b) public {
        p1 = uint96(bound(p1, 1e9, 1000 ether));
        p2 = uint96(bound(p2, 1e9, 1000 ether));
        d1 = uint32(bound(d1, 0, 60 days));
        d2 = uint32(bound(d2, 0, 60 days));
        b = uint96(bound(b, 1e18, 15_000_000e18));
        _pay(p1);
        vm.warp(block.timestamp + d1);
        vm.prank(alice);
        well.stake(50_000e18);
        _bob(b);
        _pay(p2);
        vm.warp(block.timestamp + d2);
        vm.prank(bob);
        well.unstake(b / 2);
        vm.warp(block.timestamp + 61 days);
        assertGe(address(well).balance, well.earned(alice) + well.earned(bob));
        vm.prank(alice);
        well.claim();
        vm.prank(bob);
        well.claim();
        assertLe(well.totalPaid(), uint256(p1) + p2);
        assertApproxEqAbs(well.totalPaid(), uint256(p1) + p2, 1e8 + (uint256(p1) + p2) / 1e9); // all paid out, up to dust (well under a millionth of a cent)
    }

    function test_ownerCannotTouchStakes_andTierLimits() public {
        vm.prank(alice);
        well.stake(50_000e18);
        uint256[4] memory a = [uint256(1e18), 2e18, 3e18, 4e18];
        uint256[4] memory d = [uint256(0), 1, 2, 3];
        uint16[4][4] memory disc;
        uint16[4][4] memory boost;
        for (uint256 i; i < 4; ++i) {
            for (uint256 j; j < 4; ++j) {
                disc[i][j] = 6000; // above 50%
                boost[i][j] = 10000;
            }
        }
        vm.expectRevert(TheWell.BadTiers.selector);
        well.setTiers(a, d, disc, boost);
        assertEq(tide.balanceOf(address(well)), 50_000e18);
    }

    function test_reserveContract_paysOnlyByOwner() public {
        Reserve r = new Reserve(address(this), "Safety fund");
        vm.deal(address(r), 1 ether);
        vm.prank(alice);
        vm.expectRevert();
        r.pay(alice, 1 ether, "nope");
        r.pay(bob, 0.4 ether, "Covered a loss");
        assertEq(bob.balance, 0.4 ether);
    }
}
