// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";
import { AbstractPayer } from "@reactive/src/base/AbstractPayer.sol";
import { IPayer } from "@reactive/src/interfaces/IPayer.sol";

/// @title HandshakeReactive
/// @notice Runs on Reactive Network. Watches a HandshakeEscrow on its chain and does the two jobs nobody wants to babysit:
///         1. PROOF bounties: subscribes on the fly to whatever event the issuer named (any chain Reactive watches);
///            the first matching log pays the address it names, through a callback to the escrow.
///         2. DEADLINES: a Cron1000 tick (~17 min) finds bounties past their deadline and asks the escrow to refund them.
///         It mirrors escrow state from the escrow's own events, so it never needs a keeper, an off-chain server or a poll.
contract HandshakeReactive is AbstractReactive {
    // ---- topics
    uint256 internal constant CRON1000_TOPIC_0 = 0xe20b31294d84c3661ddc8f423abb9c70310d0cf172aa2714ead78029b325e3f4;
    address internal constant CRON_SOURCE = 0x0000000000000000000000000000000000fffFfF;
    uint256 public constant POSTED_TOPIC_0 = uint256(keccak256("BountyPosted(uint256,address,uint8,uint256,uint256,string)"));
    uint256 public constant CONDITION_TOPIC_0 =
        uint256(keccak256("ProofCondition(uint256,uint256,address,uint256,bool,uint256,uint8,uint256)"));
    uint256 public constant PAID_TOPIC_0 = uint256(keccak256("BountyPaid(uint256,address,uint256,uint8,bytes32)"));
    uint256 public constant REFUNDED_TOPIC_0 = uint256(keccak256("BountyRefunded(uint256,address,uint256,uint8)"));
    uint256 public constant ALLOWED_TOPIC_0 = uint256(keccak256("ClaimantAllowed(uint256,address)"));

    uint64 internal constant CALLBACK_GAS = 400_000;
    uint256 internal constant MAX_EXPIRIES_PER_TICK = 16;
    uint256 internal constant MAX_PROOFS_PER_LOG = 8;
    uint256 internal constant RETRY_AFTER = 3 hours;

    struct Watch {
        uint256 deadline;
        bool open;
        bool isProof;
        uint256 requestedAt; // last time we asked the escrow to settle or refund; 0 = never
    }

    struct Condition {
        uint256 chainId;
        address emitter;
        uint256 topic0;
        bool matchTopic1;
        uint256 topic1;
        uint8 winnerTopic;
        uint256 minValue;
    }

    error NotOwner();
    error EscrowAlreadySet();

    event EscrowLinked(uint256 indexed chainId, address indexed escrow);
    event Watching(uint256 indexed id, uint256 deadline, bool isProof);
    event ProofSeen(uint256 indexed id, address indexed winner, uint256 indexed txHash);
    event ExpiryRequested(uint256 indexed id, uint256 deadline);
    event Closed(uint256 indexed id);
    event CronSwitched(bool on);
    /// @notice A proof named an address that is not on the bounty's allowlist (e.g. a bot that copied the job tx).
    ///         No callback is sent, so a front-runner costs no destination gas and cannot block the real claimant.
    event ProofIgnored(uint256 indexed id, address indexed named, uint256 indexed txHash);
    event Funded(address indexed from, uint256 amount);
    event BurnRateSet(uint256 costPerTick, uint256 secondsPerTick);

    address public immutable owner;
    uint256 public escrowChainId;
    address public escrow;
    bool public cronOn;

    mapping(uint256 => Watch) public watches;
    mapping(uint256 => Condition) public conditions;
    uint256[] public openIds; // swap-and-pop list of open bounty ids
    mapping(uint256 => uint256) internal _openIndex; // id => index + 1
    mapping(bytes32 => uint256[]) internal _byKey; // condition key => proof bounty ids (closed ones are skipped lazily)
    mapping(bytes32 => uint256) public keyRefs; // open bounties per condition key; subscription lives while > 0
    mapping(uint256 => bool) public restricted; // mirrored from ClaimantAllowed
    mapping(uint256 => mapping(address => bool)) public allowed;
    /// @notice Measured cost of one idle Cron1000 tick and the tick period, for fundedUntil(). Set from on-chain data.
    uint256 public costPerTick;
    uint256 public secondsPerTick;

    constructor() payable {
        owner = msg.sender;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ------------------------------------------------------------------ setup (a normal Reactive Network tx)

    /// @notice Link the escrow once it is deployed (it needs this contract's address first) and start watching it.
    function linkEscrow(uint256 chainId_, address escrow_) external onlyOwner {
        if (escrow != address(0)) revert EscrowAlreadySet();
        escrowChainId = chainId_;
        escrow = escrow_;
        SYSTEM.subscribe(chainId_, escrow_, POSTED_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(chainId_, escrow_, CONDITION_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(chainId_, escrow_, PAID_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(chainId_, escrow_, REFUNDED_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(chainId_, escrow_, ALLOWED_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        _setCron(true);
        emit EscrowLinked(chainId_, escrow_);
    }

    /// @notice Cron ticks are billed even when idle; switch them off when nothing is open.
    function setCron(bool on_) external onlyOwner {
        _setCron(on_);
    }

    function coverDebt() external {
        _coverDebt();
    }

    /// @notice Anyone can top up the REACT that pays for ticks and callbacks (e.g. the operator, from posting fees).
    receive() external payable override(AbstractPayer, IPayer) {
        emit Funded(msg.sender, msg.value);
    }

    function setBurnRate(uint256 costPerTick_, uint256 secondsPerTick_) external onlyOwner {
        costPerTick = costPerTick_;
        secondsPerTick = secondsPerTick_;
        emit BurnRateSet(costPerTick_, secondsPerTick_);
    }

    /// @notice Until when the deadline cron is paid for at the measured idle rate: (balance - debt) / costPerTick ticks.
    ///         Posters compare it with their deadline; past it, refunds fall back to the public expire().
    ///         type(uint256).max when the cron is off or no rate is set (nothing is being billed per tick).
    function fundedUntil() public view returns (uint256) {
        if (!cronOn || costPerTick == 0) return type(uint256).max;
        uint256 owed = SYSTEM.debt(address(this));
        uint256 bal = address(this).balance;
        if (bal <= owed) return block.timestamp;
        return block.timestamp + ((bal - owed) / costPerTick) * secondsPerTick;
    }

    function openCount() external view returns (uint256) {
        return openIds.length;
    }

    // ------------------------------------------------------------------ react

    /// @inheritdoc IReactive
    function react(LogRecord calldata log_) external onlySystem {
        if (log_.topic0 == CRON1000_TOPIC_0 && log_.contractAddress == CRON_SOURCE) {
            _onTick();
            return;
        }
        if (log_.chainId == escrowChainId && log_.contractAddress == escrow) {
            if (log_.topic0 == POSTED_TOPIC_0) _onPosted(log_);
            else if (log_.topic0 == CONDITION_TOPIC_0) _onCondition(log_);
            else if (log_.topic0 == PAID_TOPIC_0 || log_.topic0 == REFUNDED_TOPIC_0) _close(log_.topic1);
            else if (log_.topic0 == ALLOWED_TOPIC_0) _onAllowed(log_);
            return;
        }
        _onProofCandidate(log_);
    }

    // ------------------------------------------------------------------ escrow mirror

    function _onPosted(LogRecord calldata log_) internal {
        uint256 id = log_.topic1;
        (, uint256 deadline,) = abi.decode(log_.data, (uint256, uint256, string));
        bool isProof = log_.topic3 == 1;
        Watch storage w = watches[id];
        if (w.deadline != 0) return; // duplicate delivery
        w.deadline = deadline;
        w.open = true;
        w.isProof = isProof;
        openIds.push(id);
        _openIndex[id] = openIds.length;
        emit Watching(id, deadline, isProof);
    }

    function _onCondition(LogRecord calldata log_) internal {
        uint256 id = log_.topic1;
        (
            uint256 chainId,
            address emitter,
            uint256 topic0,
            bool matchTopic1,
            uint256 topic1,
            uint8 winnerTopic,
            uint256 minValue
        ) = abi.decode(log_.data, (uint256, address, uint256, bool, uint256, uint8, uint256));
        if (conditions[id].chainId != 0) return; // duplicate delivery
        conditions[id] = Condition(chainId, emitter, topic0, matchTopic1, topic1, winnerTopic, minValue);
        bytes32 key = _key(chainId, emitter, topic0, matchTopic1, topic1);
        _byKey[key].push(id);
        if (keyRefs[key]++ == 0) {
            SYSTEM.subscribe(chainId, emitter, topic0, matchTopic1 ? topic1 : REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        }
    }

    function _onAllowed(LogRecord calldata log_) internal {
        restricted[log_.topic1] = true;
        allowed[log_.topic1][address(uint160(log_.topic2))] = true;
    }

    function _close(uint256 id_) internal {
        Watch storage w = watches[id_];
        if (!w.open) return;
        w.open = false;
        uint256 idx = _openIndex[id_];
        if (idx != 0) {
            uint256 last = openIds[openIds.length - 1];
            openIds[idx - 1] = last;
            _openIndex[last] = idx;
            openIds.pop();
            delete _openIndex[id_];
        }
        Condition storage c = conditions[id_];
        if (c.chainId != 0) {
            bytes32 key = _key(c.chainId, c.emitter, c.topic0, c.matchTopic1, c.topic1);
            if (keyRefs[key] > 0 && --keyRefs[key] == 0) {
                SYSTEM.unsubscribe(
                    c.chainId, c.emitter, c.topic0, c.matchTopic1 ? c.topic1 : REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
                );
                delete _byKey[key];
            }
        }
        emit Closed(id_);
    }

    // ------------------------------------------------------------------ proof bounties

    function _onProofCandidate(LogRecord calldata log_) internal {
        // A log can match a pinned-topic1 subscription and a wildcard one; check both keys.
        _tryKey(log_, _key(log_.chainId, log_.contractAddress, log_.topic0, true, log_.topic1));
        _tryKey(log_, _key(log_.chainId, log_.contractAddress, log_.topic0, false, 0));
    }

    function _tryKey(LogRecord calldata log_, bytes32 key_) internal {
        uint256[] storage ids = _byKey[key_];
        uint256 n = ids.length;
        uint256 sent;
        for (uint256 i; i < n && sent < MAX_PROOFS_PER_LOG; ++i) {
            uint256 id = ids[i];
            Watch storage w = watches[id];
            if (!w.open || block.timestamp >= w.deadline) continue;
            if (w.requestedAt != 0 && block.timestamp < w.requestedAt + RETRY_AFTER) continue; // one in flight
            Condition storage c = conditions[id];
            if (log_.opCode <= c.winnerTopic) continue; // the log has no such topic
            if (c.minValue != 0) {
                if (log_.data.length < 32) continue;
                if (abi.decode(log_.data[:32], (uint256)) < c.minValue) continue;
            }
            uint256 raw = c.winnerTopic == 1 ? log_.topic1 : (c.winnerTopic == 2 ? log_.topic2 : log_.topic3);
            address winner = address(uint160(raw));
            if (winner == address(0)) continue;
            if (restricted[id] && !allowed[id][winner]) {
                emit ProofIgnored(id, winner, log_.txHash);
                continue;
            }
            w.requestedAt = block.timestamp;
            ++sent;
            emit ProofSeen(id, winner, log_.txHash);
            _callback(abi.encodeWithSignature(
                "settleProof(address,uint256,address,bytes32)", address(0), id, winner, bytes32(log_.txHash)
            ));
        }
    }

    // ------------------------------------------------------------------ deadlines

    function _onTick() internal {
        uint256 n = openIds.length;
        uint256 sent;
        for (uint256 i; i < n && sent < MAX_EXPIRIES_PER_TICK; ++i) {
            uint256 id = openIds[i];
            Watch storage w = watches[id];
            if (block.timestamp < w.deadline) continue;
            if (w.requestedAt != 0 && block.timestamp < w.requestedAt + RETRY_AFTER) continue;
            w.requestedAt = block.timestamp;
            ++sent;
            emit ExpiryRequested(id, w.deadline);
            _callback(abi.encodeWithSignature("expireByReactive(address,uint256)", address(0), id));
        }
    }

    // ------------------------------------------------------------------ helpers

    function _callback(bytes memory payload_) internal {
        SYSTEM.requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0({
            chainId: escrowChainId,
            recipient: escrow,
            gasLimit: CALLBACK_GAS,
            payload: payload_
        }));
    }

    function _setCron(bool on_) internal {
        if (on_ == cronOn) return;
        cronOn = on_;
        if (on_) {
            SYSTEM.subscribe(block.chainid, CRON_SOURCE, CRON1000_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        } else {
            SYSTEM.unsubscribe(block.chainid, CRON_SOURCE, CRON1000_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        }
        emit CronSwitched(on_);
    }

    function _key(uint256 chainId_, address emitter_, uint256 topic0_, bool pinned_, uint256 topic1_)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(chainId_, emitter_, topic0_, pinned_, pinned_ ? topic1_ : 0));
    }
}
