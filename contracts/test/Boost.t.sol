// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {BoostDistributor} from "../src/BoostDistributor.sol";
import {Reserve} from "../src/Reserve.sol";

contract MockVault {
    address public owner;
    uint256 public got;
    constructor(address o) { owner = o; }
    receive() external payable { got += msg.value; }
}

contract MockFactory {
    mapping(address => bool) public isVault;
    function add(address v) external { isVault[v] = true; }
}

contract Rejecter {
    function go(BoostDistributor d) external { d.claim(); }
    receive() external payable { revert(); }
}

contract Reenter {
    BoostDistributor d; uint256 n;
    constructor(BoostDistributor d_) { d = d_; }
    function go() external { d.claim(); }
    receive() external payable { if (n++ == 0) { try d.claim() {} catch {} } }
}

contract BoostTest is Test {
    BoostDistributor d;
    Reserve reserve;
    MockFactory fac;
    address op = makeAddr("op");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address burner = makeAddr("burner");
    Reserve reserve0;
    address carol = makeAddr("carol");
    address timelock = makeAddr("timelock");
    bytes32[3] pools = [bytes32(uint256(1)), bytes32(uint256(2)), bytes32(uint256(3))];

    function setUp() public {
        vm.warp(1_800_000_000);
        fac = new MockFactory();
        reserve0 = new Reserve(timelock, "boost-main");
        address[] memory f = new address[](1);
        f[0] = address(fac);
        d = new BoostDistributor(timelock, op, 14 days, f, address(reserve0), burner);
        vm.prank(timelock);
        d.setFirstStart(uint64(block.timestamp + 1 days));
        reserve = new Reserve(timelock, "boost");
        vm.deal(address(reserve), 10 ether);
        vm.prank(timelock);
        reserve.pay(address(d), 5 ether, "fund");
    }

    function _start() internal returns (uint256) {
        if (d.roundCount() == 0) vm.warp(d.firstStart());
        vm.prank(op);
        d.startRound(pools);
        return d.roundCount();
    }

    function _one(address w, uint256 a) internal pure returns (address[] memory ws, uint256[] memory as_) {
        ws = new address[](1); as_ = new uint256[](1); ws[0] = w; as_[0] = a;
    }

    function test_startRound_budgets() public {
        uint256 id = _start();
        BoostDistributor.Round memory r = d.getRound(id);
        assertEq(r.budget[0] + r.budget[1] + r.budget[2], 1.5 ether); // 30% of 5
        assertEq(r.budget[0], 0.45 ether);
        assertEq(r.budget[2], 0.6 ether);
        assertEq(d.committed(), 1.5 ether);
        assertEq(d.free(), 3.5 ether);
        assertEq(r.end - r.start, 14 days);
    }

    function test_onlyOperator() public {
        vm.expectRevert(BoostDistributor.NotOperator.selector);
        d.startRound(pools);
        uint256 id = _start();
        (address[] memory w, uint256[] memory a) = _one(alice, 1);
        vm.expectRevert(BoostDistributor.NotOperator.selector);
        d.credit(id, 0, w, a);
    }

    function test_noSecondRoundBeforeEnd_thenContinuous() public {
        uint256 id = _start();
        vm.prank(op);
        vm.expectRevert(BoostDistributor.TooEarly.selector);
        d.startRound(pools);
        uint64 end = d.getRound(id).end;
        vm.warp(end + 1 hours); // started late: next round still starts at the old end
        vm.prank(op);
        d.startRound(pools);
        assertEq(d.getRound(2).start, end);
    }

    function test_smallBalance_noRound() public {
        BoostDistributor e = new BoostDistributor(timelock, op, 14 days, new address[](0), address(reserve0), burner);
        vm.prank(timelock);
        e.setFirstStart(uint64(block.timestamp));
        vm.deal(address(e), 0.03 ether);
        vm.prank(op);
        vm.expectRevert(BoostDistributor.TooSmall.selector);
        e.startRound(pools);
    }

    function test_noRoundBeforeFirstStart() public {
        vm.prank(op);
        vm.expectRevert(BoostDistributor.TooEarly.selector);
        d.startRound(pools);
        vm.prank(timelock);
        vm.expectRevert(BoostDistributor.BadInput.selector);
        d.setFirstStart(1);
        BoostDistributor e = new BoostDistributor(timelock, op, 14 days, new address[](0), address(reserve0), burner);
        vm.prank(op);
        vm.expectRevert(BoostDistributor.TooEarly.selector); // no start date set
        e.startRound(pools);
    }

    function test_firstStartLockedAfterRound1() public {
        _start();
        vm.prank(timelock);
        vm.expectRevert(BoostDistributor.BadInput.selector);
        d.setFirstStart(uint64(block.timestamp + 5 days));
    }

    function test_zeroPool_rejected() public {
        bytes32[3] memory p = [bytes32(uint256(1)), bytes32(0), bytes32(uint256(3))];
        vm.warp(d.firstStart());
        vm.prank(op);
        vm.expectRevert(BoostDistributor.BadInput.selector);
        d.startRound(p);
    }

    function test_streaming_limit() public {
        uint256 id = _start();
        (address[] memory w, uint256[] memory a) = _one(alice, 0.01 ether);
        vm.prank(op);
        vm.expectRevert(BoostDistributor.OverCap.selector); // nothing streamed at t=start
        d.credit(id, 0, w, a);
        vm.warp(block.timestamp + 7 days); // half: pool budget 0.45 -> 0.225 streamed, cap 0.09 -> 0.045
        (w, a) = _one(alice, 0.045 ether);
        vm.prank(op);
        d.credit(id, 0, w, a);
        (w, a) = _one(alice, 1);
        vm.prank(op);
        vm.expectRevert(BoostDistributor.OverCap.selector);
        d.credit(id, 0, w, a);
    }

    function test_cap_perWallet_fullRound() public {
        uint256 id = _start();
        vm.warp(block.timestamp + 14 days);
        (address[] memory w, uint256[] memory a) = _one(alice, 0.09 ether + 1);
        vm.prank(op);
        vm.expectRevert(BoostDistributor.OverCap.selector);
        d.credit(id, 0, w, a);
        (w, a) = _one(alice, 0.09 ether);
        vm.prank(op);
        d.credit(id, 0, w, a);
        assertEq(d.claimable(alice), 0.09 ether);
    }

    function test_budget_neverExceeded_manyWallets() public {
        uint256 id = _start();
        vm.warp(block.timestamp + 14 days);
        for (uint256 i; i < 5; i++) {
            (address[] memory w, uint256[] memory a) = _one(address(uint160(100 + i)), 0.09 ether);
            vm.prank(op);
            d.credit(id, 0, w, a);
        }
        (address[] memory w2, uint256[] memory a2) = _one(address(uint160(999)), 1);
        vm.prank(op);
        vm.expectRevert(BoostDistributor.OverBudget.selector); // 5 x 0.09 = 0.45 is the whole budget
        d.credit(id, 0, w2, a2);
    }

    function test_claim_and_accounting() public {
        uint256 id = _start();
        vm.warp(block.timestamp + 14 days);
        (address[] memory w, uint256[] memory a) = _one(alice, 0.05 ether);
        vm.prank(op);
        d.credit(id, 2, w, a);
        uint256 before = alice.balance;
        vm.prank(alice);
        d.claim();
        assertEq(alice.balance - before, 0.05 ether);
        assertEq(d.claimable(alice), 0);
        assertEq(d.committed(), 1.5 ether - 0.05 ether);
        vm.prank(alice);
        vm.expectRevert(BoostDistributor.NothingToClaim.selector);
        d.claim();
    }

    function test_claimToVault_onlyOwnVault() public {
        uint256 id = _start();
        vm.warp(block.timestamp + 14 days);
        (address[] memory w, uint256[] memory a) = _one(alice, 0.05 ether);
        vm.prank(op);
        d.credit(id, 0, w, a);
        MockVault mine = new MockVault(alice);
        MockVault other = new MockVault(bob);
        MockVault fake = new MockVault(alice);
        fac.add(address(mine));
        fac.add(address(other));
        vm.startPrank(alice);
        vm.expectRevert(BoostDistributor.NotYourVault.selector);
        d.claimToVault(address(other));
        vm.expectRevert(BoostDistributor.NotYourVault.selector);
        d.claimToVault(address(fake));
        d.claimToVault(address(mine));
        vm.stopPrank();
        assertEq(mine.got(), 0.05 ether);
    }

    function test_release_returnsUnused_nextRoundUsesIt() public {
        uint256 id = _start();
        vm.warp(block.timestamp + 14 days);
        (address[] memory w, uint256[] memory a) = _one(alice, 0.05 ether);
        vm.prank(op);
        d.credit(id, 0, w, a);
        vm.expectRevert(BoostDistributor.TooEarly.selector);
        d.release(id);
        vm.warp(block.timestamp + 2 days + 1);
        d.release(id);
        assertEq(d.committed(), 0.05 ether);
        assertEq(burner.balance, (1.5 ether - 0.05 ether) / 2); // half of the unused goes to the burner
        vm.expectRevert(BoostDistributor.BadInput.selector);
        d.release(id);
        (w, a) = _one(alice, 1);
        vm.prank(op);
        vm.expectRevert(BoostDistributor.Closed.selector);
        d.credit(id, 0, w, a);
        // alice can still claim her credit after release
        vm.prank(alice);
        d.claim();
        assertEq(address(d).balance, 5 ether - 0.05 ether - (1.5 ether - 0.05 ether) / 2);
    }

    function test_creditAfterGrace_rejected() public {
        uint256 id = _start();
        vm.warp(block.timestamp + 14 days + 2 days + 1);
        (address[] memory w, uint256[] memory a) = _one(alice, 1);
        vm.prank(op);
        vm.expectRevert(BoostDistributor.Closed.selector);
        d.credit(id, 0, w, a);
    }

    function test_rejectingWallet_cannotLoseCredit() public {
        uint256 id = _start();
        vm.warp(block.timestamp + 14 days);
        Rejecter r = new Rejecter();
        (address[] memory w, uint256[] memory a) = _one(address(r), 0.01 ether);
        vm.prank(op);
        d.credit(id, 0, w, a);
        vm.expectRevert(BoostDistributor.TransferFailed.selector);
        r.go(d);
        assertEq(d.claimable(address(r)), 0.01 ether);
    }

    function test_reentrancy() public {
        uint256 id = _start();
        vm.warp(block.timestamp + 14 days);
        Reenter r = new Reenter(d);
        (address[] memory w, uint256[] memory a) = _one(address(r), 0.01 ether);
        vm.prank(op);
        d.credit(id, 0, w, a);
        r.go();
        assertEq(address(r).balance, 0.01 ether);
        assertEq(d.claimable(address(r)), 0);
    }

    function test_cannotTakeMoreThanFunded_invariant() public {
        // total of all claims can never pass the ETH held
        uint256 id = _start();
        vm.warp(block.timestamp + 14 days);
        for (uint256 s; s < 3; s++) {
            uint256 cap = (d.getRound(id).budget[s] * 2000) / 10_000;
            for (uint256 i; i < 5; i++) {
                (address[] memory w, uint256[] memory a) = _one(address(uint160(1000 + s * 10 + i)), cap);
                vm.prank(op);
                d.credit(id, s, w, a);
            }
        }
        uint256 bal = address(d).balance;
        uint256 owed;
        for (uint256 s; s < 3; s++) for (uint256 i; i < 5; i++) owed += d.claimable(address(uint160(1000 + s * 10 + i)));
        assertLe(owed, bal);
        assertEq(owed, 1.5 ether);
    }

    function test_setOperator_onlyOwner() public {
        vm.expectRevert();
        d.setOperator(alice);
        vm.prank(timelock);
        d.setOperator(alice);
        assertEq(d.operator(), alice);
    }

    function testFuzz_creditNeverBeatsStream(uint256 t, uint256 amt) public {
        uint256 id = _start();
        t = bound(t, 0, 20 days);
        amt = bound(amt, 0, 1 ether);
        vm.warp(block.timestamp + t);
        (address[] memory w, uint256[] memory a) = _one(alice, amt);
        vm.prank(op);
        try d.credit(id, 0, w, a) {
            assertLe(amt, d.streamed(id, 0.09 ether));
        } catch {}
    }

    function test_release_burnerRejects_staysFree() public {
        Rejecter rej = new Rejecter();
        BoostDistributor e = new BoostDistributor(timelock, op, 14 days, new address[](0), address(reserve0), address(rej));
        vm.deal(address(e), 5 ether);
        vm.prank(timelock);
        e.setFirstStart(uint64(block.timestamp));
        vm.prank(op);
        e.startRound(pools);
        vm.warp(block.timestamp + 14 days + 2 days + 1);
        e.release(1);
        assertEq(address(e).balance, 5 ether); // nothing lost
        assertEq(e.committed(), 0);
    }

    function test_nextRound_usesHalfOfLeftover() public {
        uint256 id = _start();
        vm.warp(block.timestamp + 14 days + 2 days + 1);
        d.release(id); // nothing credited: 1.5 unused, 0.75 burned, 0.75 stays
        assertEq(burner.balance, 0.75 ether);
        assertEq(d.free(), 5 ether - 0.75 ether);
        vm.prank(op);
        d.startRound(pools);
        BoostDistributor.Round memory r = d.getRound(2);
        assertEq(r.budget[0] + r.budget[1] + r.budget[2], ((5 ether - 0.75 ether) * 3000) / 10_000);
    }

    function test_returnToReserve_onlyOwner_onlyFree() public {
        _start(); // 1.5 committed, 3.5 free
        vm.expectRevert();
        d.returnToReserve(1 ether);
        vm.startPrank(timelock);
        vm.expectRevert(BoostDistributor.BadInput.selector);
        d.returnToReserve(3.5 ether + 1);
        vm.expectRevert(BoostDistributor.BadInput.selector);
        d.returnToReserve(0);
        d.returnToReserve(3.5 ether);
        vm.stopPrank();
        assertEq(address(reserve0).balance, 3.5 ether);
        assertEq(d.free(), 0);
        assertEq(address(d).balance, d.committed()); // the committed ETH stayed
    }

    function test_constructor_rejectsZero() public {
        vm.expectRevert(BoostDistributor.BadInput.selector);
        new BoostDistributor(timelock, op, 14 days, new address[](0), address(0), burner);
        vm.expectRevert(BoostDistributor.BadInput.selector);
        new BoostDistributor(timelock, op, 14 days, new address[](0), address(reserve0), address(0));
    }
}
