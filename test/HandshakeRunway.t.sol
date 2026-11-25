// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { HandshakeEscrow } from "../src/HandshakeEscrow.sol";
import { HandshakeReactive } from "../src/HandshakeReactive.sol";
import { HandshakeBase } from "./Handshake.t.sol";

/// Runway honesty (judge, 11-25): Reactive bills every log a subscription delivers (~0.0125 lREACT each on Lasna), not only
/// cron ticks. A proof bounty on a busy event (11-22: every WETH9 Deposit on Sepolia) drained a watcher in 2.5 h while the
/// ticks-only fundedUntil() showed days. Fix: (a) a per-subscription event cap that unsubscribes a busy proof until its
/// window ends, so the event bill is bounded; (b) fundedUntil() budgets that bound for every open proof subscription.
contract HandshakeRunwayTest is HandshakeBase {
    uint256 constant TICK_COST = 0.0112 ether; // measured idle Cron1000 tick on Lasna (11-17)
    uint256 constant TICK_SECS = 1053;
    uint256 constant EVENT_COST = 0.0125 ether; // measured per delivered proof log on Lasna (11-22)
    uint256 jobTopic = uint256(keccak256("JobRun(uint256,address,uint256)"));

    function _postWild(uint256 minWork, uint256 deadline) internal returns (uint256 id) {
        // "first keeper to run ANY job with >= minWork": a wildcard (unpinned) proof, like the WETH9 Deposit bounty
        HandshakeEscrow.Condition memory c = HandshakeEscrow.Condition({
            chainId: JOBS_CHAIN, emitter: address(jobs), topic0: jobTopic,
            matchTopic1: false, topic1: 0, winnerTopic: 2, minValue: minWork
        });
        vm.recordLogs();
        vm.prank(issuer);
        id = esc.postProof{ value: 0.1 ether }("busy event", deadline, c);
        _pipe(vm.getRecordedLogs(), ESCROW_CHAIN);
    }

    function _jobLog(uint256 jobId, address who, uint256 work) internal {
        IReactive.LogRecord memory r;
        r.chainId = JOBS_CHAIN; r.contractAddress = address(jobs); r.opCode = 3;
        r.topic0 = jobTopic; r.topic1 = jobId; r.topic2 = uint256(uint160(who));
        r.data = abi.encode(work);
        r.txHash = uint256(keccak256(abi.encode(jobId, block.timestamp)));
        vm.prank(SYS);
        rx.react(r);
    }

    function _wildLive() internal view returns (bool) {
        return sys.isLive(JOBS_CHAIN, address(jobs), jobTopic, IGNORE);
    }

    // ---- fundedUntil budgets the capped event rate

    function test_fundedUntilBudgetsOpenProofSubscriptions() public {
        rx.setBurnRate(TICK_COST, TICK_SECS, EVENT_COST);
        vm.deal(address(rx), 1 ether);
        uint256 idle = rx.fundedUntil();
        assertEq(idle, block.timestamp + (1 ether / TICK_COST) * TICK_SECS); // no proof open: ticks only (89 ticks)
        _postWild(1e9, block.timestamp + 7 days);
        assertEq(rx.liveKeys(), 1);
        (uint256 burn, uint256 period) = rx.burnPerPeriod();
        assertEq(period, TICK_SECS);
        assertEq(burn, TICK_COST + (11 * EVENT_COST * TICK_SECS) / 1 hours);
        assertEq(rx.fundedUntil(), block.timestamp + (1 ether / burn) * TICK_SECS);
        assertLt(rx.fundedUntil(), idle); // an open proof shortens the honest runway
        // a second bounty on the SAME condition shares the subscription: no extra allowance
        _postWild(1e9, block.timestamp + 7 days);
        assertEq(rx.liveKeys(), 1);
        // a different condition is a second subscription: double the event allowance
        _postProof(7, 1, 0.1 ether, block.timestamp + 7 days);
        assertEq(rx.liveKeys(), 2);
        (uint256 burn2,) = rx.burnPerPeriod();
        assertEq(burn2, TICK_COST + (2 * 11 * EVENT_COST * TICK_SECS) / 1 hours);
    }

    function test_fundedUntilCountsEventsEvenWithCronOff() public {
        rx.setBurnRate(TICK_COST, TICK_SECS, EVENT_COST);
        rx.setCron(false);
        vm.deal(address(rx), 1 ether);
        assertEq(rx.fundedUntil(), type(uint256).max); // nothing billed
        _postWild(1e9, block.timestamp + 7 days);
        assertLt(rx.fundedUntil(), type(uint256).max); // open proof subscription is still billed per log
    }

    function test_liveKeysDropWhenTheLastBountyCloses() public {
        uint256 a = _postWild(1e9, block.timestamp + 1 days);
        assertEq(rx.liveKeys(), 1);
        vm.warp(block.timestamp + 1 days);
        _tick();
        _deliverCallbacks();
        (,,, HandshakeEscrow.Status st,,,) = esc.bounties(a);
        assertEq(uint8(st), uint8(HandshakeEscrow.Status.Refunded));
        assertEq(rx.liveKeys(), 0);
        assertFalse(_wildLive());
    }

    // ---- the cap

    function test_busyEventIsThrottledThenResumedAndStillPays() public {
        uint256 id = _postWild(5, block.timestamp + 7 days);
        uint256 t0 = block.timestamp;
        for (uint256 i; i < 10; ++i) _jobLog(100 + i, hunter, 1); // too little work: billed, no payout
        assertTrue(_wildLive());
        vm.expectEmit(true, false, false, true, address(rx));
        emit HandshakeReactive.ProofThrottled(keccak256(abi.encode(JOBS_CHAIN, address(jobs), jobTopic, false, 0)), t0 + 1 hours);
        _jobLog(200, hunter, 1); // the 11th in the window trips the cap
        assertFalse(_wildLive());
        assertEq(rx.pausedCount(), 1);
        vm.warp(t0 + 30 minutes);
        _tick(); // window not over: stays paused
        assertFalse(_wildLive());
        vm.warp(t0 + 1 hours);
        _tick(); // window over: re-subscribed with a fresh count
        assertTrue(_wildLive());
        assertEq(rx.pausedCount(), 0);
        _jobLog(300, keeper, 9); // the real proof still pays
        _deliverCallbacks();
        (,,, HandshakeEscrow.Status st,, address winner,) = esc.bounties(id);
        assertEq(uint8(st), uint8(HandshakeEscrow.Status.Paid));
        assertEq(winner, keeper);
        assertEq(rx.liveKeys(), 0);
        assertFalse(_wildLive());
    }

    function test_bountyClosingWhilePausedDoesNotDoubleUnsubscribe() public {
        uint256 id = _postWild(5, block.timestamp + 40 minutes); // deadline inside the throttle window
        for (uint256 i; i < 11; ++i) _jobLog(100 + i, hunter, 1);
        assertFalse(_wildLive());
        vm.warp(block.timestamp + 40 minutes);
        _tick(); // still paused (window ends at +60 min) and due: refunds; the mock system reverts on unsubscribing a dead subscription, so this proves the guard
        _deliverCallbacks();
        (,,, HandshakeEscrow.Status st,,,) = esc.bounties(id);
        assertEq(uint8(st), uint8(HandshakeEscrow.Status.Refunded));
        assertEq(rx.pausedCount(), 1); // closed while paused: stale entry until the window ends
        vm.warp(block.timestamp + 30 minutes);
        _tick(); // stale pausedKeys entry dropped, nothing re-subscribed
        assertEq(rx.pausedCount(), 0);
        assertFalse(_wildLive());
        assertEq(sys.liveCount(), 6); // the 5 escrow mirrors + cron, nothing else
    }

    function test_quietPinnedProofIsNeverThrottled() public {
        _postProof(7, 3, 0.1 ether, block.timestamp + 7 days);
        // ten logs an hour for a day on the pinned key: at the cap, never above it
        for (uint256 h; h < 24; ++h) {
            for (uint256 i; i < 10; ++i) _jobLog(7, hunter, 1);
            vm.warp(block.timestamp + 1 hours);
        }
        assertEq(rx.pausedCount(), 0);
        assertTrue(sys.isLive(JOBS_CHAIN, address(jobs), jobTopic, 7));
    }

    function test_pinnedProofOverTheCapPausesAndResumesItsOwnSubscription() public {
        _postProof(7, 3, 0.1 ether, block.timestamp + 7 days);
        for (uint256 i; i < 11; ++i) _jobLog(7, hunter, 1);
        assertFalse(sys.isLive(JOBS_CHAIN, address(jobs), jobTopic, 7));
        vm.warp(block.timestamp + 1 hours);
        _tick();
        assertTrue(sys.isLive(JOBS_CHAIN, address(jobs), jobTopic, 7));
        assertFalse(_wildLive()); // the pinned filter is restored, not widened
    }

    function test_onlyOwnerSetsCapAndItCannotBeSwitchedOff() public {
        vm.prank(hunter);
        vm.expectRevert(HandshakeReactive.NotOwner.selector);
        rx.setEventCap(5, 600);
        vm.expectRevert(HandshakeReactive.BadCap.selector);
        rx.setEventCap(0, 600);
        vm.expectRevert(HandshakeReactive.BadCap.selector);
        rx.setEventCap(5, 59);
        vm.expectRevert(HandshakeReactive.BadCap.selector);
        rx.setEventCap(1001, 600);
        vm.expectRevert(HandshakeReactive.BadCap.selector);
        rx.setEventCap(5, 1 days + 1);
        rx.setEventCap(5, 600);
        assertEq(rx.maxEventsPerWindow(), 5);
        assertEq(rx.eventWindow(), 600);
    }

    // ---- the 11-22 incident, replayed: a busy event at 300 logs/hour against a 1 lREACT watcher

    struct Sim { uint256 bal; uint256 nextTick; uint256 logs; uint256 billed; }

    /// Bills the watcher the way Reactive does (every delivered log while subscribed, every tick) and returns the time the
    /// balance would first go short, or `until` if it never does.
    function _simulate(uint256 bal, uint256 until, uint256 logEvery) internal returns (uint256 brokeAt, uint256 billed) {
        Sim memory s = Sim(bal, block.timestamp + TICK_SECS, 0, 0);
        uint256 t = block.timestamp;
        while (t < until) {
            t += logEvery;
            vm.warp(t);
            if (t >= s.nextTick) {
                if (s.bal < TICK_COST) return (t, s.billed);
                s.bal -= TICK_COST;
                s.nextTick += TICK_SECS;
                _tick();
            }
            if (_wildLive()) {
                if (s.bal < EVENT_COST) return (t, s.billed);
                s.bal -= EVENT_COST;
                ++s.billed;
                _jobLog(1000 + s.logs, hunter, 1);
            }
            ++s.logs;
        }
        return (until, s.billed);
    }

    function test_busyEventCannotOutrunFundedUntil() public {
        rx.setBurnRate(TICK_COST, TICK_SECS, EVENT_COST);
        vm.deal(address(rx), 1 ether);
        uint256 ticksOnly = block.timestamp + (1 ether / TICK_COST) * TICK_SECS; // what the v5 formula would publish
        _postWild(1e9, block.timestamp + 30 days); // nobody ever qualifies: pure bill
        uint256 promised = rx.fundedUntil();
        uint256 start = block.timestamp;
        assertLt(promised, ticksOnly);
        (uint256 brokeAt, uint256 billed) = _simulate(1 ether, promised, 12 seconds);
        assertEq(brokeAt, promised, "watcher went short before the time fundedUntil() published");
        assertGt(billed, 0);
        assertLt(billed, (promised - start) / 12 seconds / 10); // the cap kept >90% of the busy event's logs off the bill
        assertLe(billed, ((promised - start) / 1 hours + 1) * 11); // never above the cap per window
    }

    /// Positive control for the test above: the same busy event against a watcher WITHOUT a working cap (cap set to its
    /// loosest legal value) goes short long before the ticks-only runway, i.e. the v5 number really was dishonest.
    function test_control_withoutTheCapTheTicksOnlyRunwayIsALie() public {
        rx.setBurnRate(TICK_COST, TICK_SECS, EVENT_COST);
        rx.setEventCap(1000, 1 days); // ~1000 logs/day allowed: at 300/h the cap never trips in the run below
        vm.deal(address(rx), 1 ether);
        uint256 ticksOnly = block.timestamp + (1 ether / TICK_COST) * TICK_SECS;
        _postWild(1e9, block.timestamp + 30 days);
        uint256 start = block.timestamp;
        (uint256 brokeAt,) = _simulate(1 ether, ticksOnly, 12 seconds);
        assertLt(brokeAt, start + 4 hours, "busy event should drain 1 lREACT in hours");
        assertLt(brokeAt, ticksOnly);
        assertEq(rx.pausedCount(), 0);
    }
}
