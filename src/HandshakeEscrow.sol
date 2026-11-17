// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";

/// @notice Holds bounty money apart from the escrow's own gas balance. The callback proxy bills the escrow contract
///         (AbstractPayer.pay draws on its balance), so keeping bounty funds here means a callback fee can never
///         eat into a bounty. Only the escrow that deployed it can move funds.
contract BountyVault {
    error OnlyEscrow();
    error TransferFailed();

    address public immutable escrow;

    constructor() {
        escrow = msg.sender;
    }

    receive() external payable {
        if (msg.sender != escrow) revert OnlyEscrow();
    }

    function release(address payable to_, uint256 amount_) external {
        if (msg.sender != escrow) revert OnlyEscrow();
        (bool ok,) = to_.call{ value: amount_ }("");
        if (!ok) revert TransferFailed();
    }

    /// @notice ERC-20 payout (USDC and friends). Accepts tokens that return nothing or true; anything else reverts.
    function releaseToken(address token_, address to_, uint256 amount_) external {
        if (msg.sender != escrow) revert OnlyEscrow();
        (bool ok, bytes memory ret) = token_.call(abi.encodeWithSelector(0xa9059cbb, to_, amount_)); // transfer(address,uint256)
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }
}

/// @title HandshakeEscrow
/// @notice Bounties that settle themselves. Funds sit here; the paired reactive contract on Reactive Network
///         (a) pays a PROOF bounty the moment the chain shows the work was done (a matching event on any watched chain),
///         (b) refunds any bounty still open at its deadline, so nobody has to remember to cancel it.
///         JUDGED bounties are paid by the issuer's own accept(); only their expiry runs through Reactive.
/// @dev Callbacks arrive through the Reactive callback proxy. Every callback is guarded twice (proxy + reactive sender)
///      and re-checks its own condition here, so a late, duplicate or forged callback can never move funds twice.
contract HandshakeEscrow is AbstractCallback {
    enum Kind { Judged, Proof }
    enum Status { None, Open, Paid, Refunded }

    /// @notice What a PROOF bounty waits for: a log on `chainId` from `emitter` with `topic0`, optionally pinned on topic1,
    ///         whose topic number `winnerTopic` (1-3) holds the address to pay, and whose first data word is >= minValue.
    struct Condition {
        uint256 chainId;
        address emitter;
        uint256 topic0;
        bool matchTopic1;
        uint256 topic1;
        uint8 winnerTopic;
        uint256 minValue;
    }

    struct Bounty {
        address payable issuer;
        uint96 deadline;
        Kind kind;
        Status status;
        uint256 amount;
        address winner;
        string title;
    }

    error NotIssuer();
    error NotOpen(uint256 id, Status status);
    error BadDeadline();
    error BadAmount();
    error BadCondition();
    error UnknownClaim();
    error TooEarly(uint256 id, uint256 deadline, uint256 nowTs);
    error BelowMinimum(uint256 sent, uint256 required);
    error WrongFee(uint256 sent, uint256 required);
    error TokenTransferFailed();
    error NotProof();

    event BountyPosted(
        uint256 indexed id,
        address indexed issuer,
        uint8 indexed kind,
        uint256 amount,
        uint256 deadline,
        string title
    );
    /// @dev Separate event so the reactive contract can subscribe without decoding the title.
    event ProofCondition(
        uint256 indexed id,
        uint256 chainId,
        address emitter,
        uint256 topic0,
        bool matchTopic1,
        uint256 topic1,
        uint8 winnerTopic,
        uint256 minValue
    );
    event ClaimSubmitted(uint256 indexed id, uint256 indexed claimId, address indexed claimant, string uri);
    event BountyPaid(uint256 indexed id, address indexed winner, uint256 amount, uint8 indexed via, bytes32 proofTx);
    event BountyRefunded(uint256 indexed id, address indexed issuer, uint256 amount, uint8 indexed via);
    event CallbackSkipped(uint256 indexed id, string reason);
    /// @notice The posting fee stays in this contract's own balance, the gas float the callback proxy bills for every
    ///         settleProof / expireByReactive delivered here. Spam therefore pays for the callbacks it causes.
    event FeeCollected(uint256 indexed id, uint256 fee);
    /// @notice An ERC-20 bounty (e.g. USDC). BountyPosted carries the token amount actually received by the vault.
    event BountyToken(uint256 indexed id, address indexed token);
    /// @notice Anti-front-running: once a PROOF bounty has any allowed claimant, only proofs that name an allowed address
    ///         pay. A bot that copies the claimant's job tx gets itself named in the log, so it is ignored (by the reactive
    ///         contract, which mirrors this event, and again here). Emitted before ProofCondition when posted together.
    event ClaimantAllowed(uint256 indexed id, address indexed claimant);

    uint8 internal constant VIA_ISSUER = 0;
    uint8 internal constant VIA_REACTIVE = 1;

    BountyVault public immutable vault;
    /// @notice Smallest bounty accepted (anti-spam: each open bounty costs the network a subscription and a cron check).
    uint256 public immutable minBounty;
    /// @notice Flat fee per posted bounty, kept as callback gas (see FeeCollected). Bounty amount = msg.value - postFee.
    uint256 public immutable postFee;
    uint256 public feesCollected;
    /// @notice Sum of all OPEN bounty amounts; the vault balance always equals it (tested as an invariant).
    uint256 public openTotal;
    /// @notice ERC-20 bounties: the token of bounty id (zero = native ETH) and the open total per token, which the vault's
    ///         token balance always equals (tested as an invariant).
    mapping(uint256 => address) public tokenOf;
    mapping(address => uint256) public openTotalOf;
    uint256 public nextId = 1;
    mapping(uint256 => Bounty) public bounties;
    mapping(uint256 => Condition) public conditions;
    mapping(uint256 => address[]) internal _claimants;
    /// @notice PROOF bounties with an allowlist: only proofs naming an allowed address pay (see ClaimantAllowed).
    mapping(uint256 => bool) public restricted;
    mapping(uint256 => mapping(address => bool)) public allowed;

    constructor(IPayable callbackProxy_, address reactive_, uint256 minBounty_, uint256 postFee_)
        payable
        AbstractCallback(callbackProxy_, reactive_)
    {
        vault = new BountyVault();
        minBounty = minBounty_ == 0 ? 1 : minBounty_;
        postFee = postFee_;
    }

    // ------------------------------------------------------------------ posting

    /// @notice Post a bounty judged by you. Pay it with accept(); if you never do, it refunds itself at the deadline.
    function postJudged(string calldata title_, uint256 deadline_) external payable returns (uint256 id) {
        id = _post(Kind.Judged, title_, deadline_);
    }

    /// @notice Post a bounty paid automatically to whoever the chain proves did the work.
    function postProof(string calldata title_, uint256 deadline_, Condition calldata c_) external payable returns (uint256 id) {
        _checkCondition(c_);
        id = _post(Kind.Proof, title_, deadline_);
        _setCondition(id, c_);
    }

    /// @notice postProof that pays only proofs naming one of `claimants_` (the front-running guard). The allowlist is
    ///         emitted before the condition, so the watcher knows it before it subscribes to the proof event.
    function postProofFor(string calldata title_, uint256 deadline_, Condition calldata c_, address[] calldata claimants_)
        external
        payable
        returns (uint256 id)
    {
        _checkCondition(c_);
        if (claimants_.length == 0) revert BadCondition();
        id = _post(Kind.Proof, title_, deadline_);
        _allow(id, claimants_);
        _setCondition(id, c_);
    }

    /// @notice The issuer adds allowed claimants to an open PROOF bounty (turns an open bounty into a restricted one).
    function allow(uint256 id_, address[] calldata claimants_) external {
        Bounty storage b = bounties[id_];
        if (msg.sender != b.issuer) revert NotIssuer();
        if (b.status != Status.Open) revert NotOpen(id_, b.status);
        if (b.kind != Kind.Proof) revert NotProof();
        if (claimants_.length == 0) revert BadCondition();
        _allow(id_, claimants_);
    }

    function _allow(uint256 id_, address[] calldata claimants_) internal {
        restricted[id_] = true;
        for (uint256 i; i < claimants_.length; ++i) {
            address who = claimants_[i];
            if (who == address(0)) revert BadCondition();
            if (allowed[id_][who]) continue;
            allowed[id_][who] = true;
            emit ClaimantAllowed(id_, who);
        }
    }

    function _setCondition(uint256 id_, Condition calldata c_) internal {
        conditions[id_] = c_;
        emit ProofCondition(id_, c_.chainId, c_.emitter, c_.topic0, c_.matchTopic1, c_.topic1, c_.winnerTopic, c_.minValue);
    }

    /// @notice Same as postJudged, paid in an ERC-20 (approve this escrow first). msg.value must equal postFee exactly.
    function postJudgedToken(string calldata title_, uint256 deadline_, address token_, uint256 amount_)
        external
        payable
        returns (uint256 id)
    {
        id = _postToken(Kind.Judged, title_, deadline_, token_, amount_);
    }

    /// @notice Same as postProof, paid in an ERC-20 (approve this escrow first). msg.value must equal postFee exactly.
    function postProofToken(string calldata title_, uint256 deadline_, Condition calldata c_, address token_, uint256 amount_)
        external
        payable
        returns (uint256 id)
    {
        _checkCondition(c_);
        id = _postToken(Kind.Proof, title_, deadline_, token_, amount_);
        _setCondition(id, c_);
    }

    /// @notice postProofToken with a claimant allowlist (see postProofFor).
    function postProofTokenFor(
        string calldata title_,
        uint256 deadline_,
        Condition calldata c_,
        address token_,
        uint256 amount_,
        address[] calldata claimants_
    ) external payable returns (uint256 id) {
        _checkCondition(c_);
        if (claimants_.length == 0) revert BadCondition();
        id = _postToken(Kind.Proof, title_, deadline_, token_, amount_);
        _allow(id, claimants_);
        _setCondition(id, c_);
    }

    function _postToken(Kind kind_, string calldata title_, uint256 deadline_, address token_, uint256 amount_)
        internal
        returns (uint256 id)
    {
        if (msg.value != postFee) revert WrongFee(msg.value, postFee);
        if (token_ == address(0) || token_.code.length == 0 || amount_ == 0) revert BadAmount();
        if (deadline_ <= block.timestamp || deadline_ > block.timestamp + 365 days) revert BadDeadline();
        id = nextId++;
        uint256 before = _balanceOf(token_, address(vault));
        (bool ok, bytes memory ret) =
            token_.call(abi.encodeWithSelector(0x23b872dd, msg.sender, address(vault), amount_)); // transferFrom
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TokenTransferFailed();
        uint256 received = _balanceOf(token_, address(vault)) - before; // fee-on-transfer tokens: record what arrived
        if (received == 0) revert BadAmount();
        tokenOf[id] = token_;
        openTotalOf[token_] += received;
        bounties[id] = Bounty({
            issuer: payable(msg.sender),
            deadline: uint96(deadline_),
            kind: kind_,
            status: Status.Open,
            amount: received,
            winner: address(0),
            title: title_
        });
        if (postFee != 0) {
            feesCollected += postFee;
            emit FeeCollected(id, postFee);
        }
        emit BountyToken(id, token_);
        emit BountyPosted(id, msg.sender, uint8(kind_), received, deadline_, title_);
    }

    function _balanceOf(address token_, address who_) internal view returns (uint256) {
        (bool ok, bytes memory ret) = token_.staticcall(abi.encodeWithSelector(0x70a08231, who_)); // balanceOf
        if (!ok || ret.length < 32) revert TokenTransferFailed();
        return abi.decode(ret, (uint256));
    }

    function _checkCondition(Condition calldata c_) internal pure {
        if (c_.chainId == 0 || c_.emitter == address(0) || c_.topic0 == 0 || c_.winnerTopic < 1 || c_.winnerTopic > 3) {
            revert BadCondition();
        }
        if (c_.matchTopic1 && c_.winnerTopic == 1) revert BadCondition(); // the winner cannot also be the pinned topic
    }

    function _post(Kind kind_, string calldata title_, uint256 deadline_) internal returns (uint256 id) {
        if (msg.value == 0) revert BadAmount();
        if (msg.value < minBounty + postFee) revert BelowMinimum(msg.value, minBounty + postFee);
        if (deadline_ <= block.timestamp || deadline_ > block.timestamp + 365 days) revert BadDeadline();
        id = nextId++;
        uint256 amount = msg.value - postFee;
        (bool ok,) = payable(address(vault)).call{ value: amount }("");
        if (!ok) revert TransferFailed();
        openTotal += amount;
        bounties[id] = Bounty({
            issuer: payable(msg.sender),
            deadline: uint96(deadline_),
            kind: kind_,
            status: Status.Open,
            amount: amount,
            winner: address(0),
            title: title_
        });
        if (postFee != 0) {
            feesCollected += postFee;
            emit FeeCollected(id, postFee);
        }
        emit BountyPosted(id, msg.sender, uint8(kind_), amount, deadline_, title_);
    }

    // ------------------------------------------------------------------ judged flow

    function claim(uint256 id_, string calldata uri_) external returns (uint256 claimId) {
        Bounty storage b = bounties[id_];
        if (b.status != Status.Open || b.kind != Kind.Judged) revert NotOpen(id_, b.status);
        if (block.timestamp >= b.deadline) revert NotOpen(id_, b.status);
        _claimants[id_].push(msg.sender);
        claimId = _claimants[id_].length - 1;
        emit ClaimSubmitted(id_, claimId, msg.sender, uri_);
    }

    function accept(uint256 id_, uint256 claimId_) external {
        Bounty storage b = bounties[id_];
        if (msg.sender != b.issuer) revert NotIssuer();
        if (b.status != Status.Open) revert NotOpen(id_, b.status);
        if (claimId_ >= _claimants[id_].length) revert UnknownClaim();
        _payWinner(id_, b, _claimants[id_][claimId_], VIA_ISSUER, bytes32(0));
    }

    /// @notice The issuer may cancel early; the deadline refund still happens by itself if they don't.
    function cancel(uint256 id_) external {
        Bounty storage b = bounties[id_];
        if (msg.sender != b.issuer) revert NotIssuer();
        if (b.status != Status.Open) revert NotOpen(id_, b.status);
        _refund(id_, b, VIA_ISSUER);
    }

    // ------------------------------------------------------------------ reactive callbacks

    /// @notice Called by Reactive when the watched chain emitted the proof. First valid proof wins; later ones are no-ops.
    function settleProof(address reactive_, uint256 id_, address winner_, bytes32 proofTx_)
        external
        onlyServiceProvider
        onlyCallbackSender(reactive_)
    {
        Bounty storage b = bounties[id_];
        if (b.status != Status.Open || b.kind != Kind.Proof) {
            emit CallbackSkipped(id_, "not open");
            return;
        }
        if (block.timestamp >= b.deadline) {
            // Too late to pay; the expiry callback (or anyone, via expire) refunds instead.
            emit CallbackSkipped(id_, "past deadline");
            return;
        }
        if (winner_ == address(0)) {
            emit CallbackSkipped(id_, "no winner");
            return;
        }
        if (restricted[id_] && !allowed[id_][winner_]) {
            // Front-run or wrong claimant: the bounty stays open for an allowed claimant's proof.
            emit CallbackSkipped(id_, "claimant not allowed");
            return;
        }
        _payWinner(id_, b, winner_, VIA_REACTIVE, proofTx_);
    }

    /// @notice Called by Reactive's cron watcher after the deadline. Re-checked here against this chain's clock.
    function expireByReactive(address reactive_, uint256 id_) external onlyServiceProvider onlyCallbackSender(reactive_) {
        Bounty storage b = bounties[id_];
        if (b.status != Status.Open) {
            emit CallbackSkipped(id_, "not open");
            return;
        }
        if (block.timestamp < b.deadline) {
            emit CallbackSkipped(id_, "not yet due");
            return;
        }
        _refund(id_, b, VIA_REACTIVE);
    }

    /// @notice Fallback for when Reactive is down or unfunded: anyone may trigger a due refund. Funds only go to the issuer.
    function expire(uint256 id_) external {
        Bounty storage b = bounties[id_];
        if (b.status != Status.Open) revert NotOpen(id_, b.status);
        if (block.timestamp < b.deadline) revert TooEarly(id_, b.deadline, block.timestamp);
        _refund(id_, b, VIA_ISSUER);
    }

    // ------------------------------------------------------------------ views + funding

    function claimants(uint256 id_) external view returns (address[] memory) {
        return _claimants[id_];
    }

    function coverDebt() external {
        _coverDebt();
    }

    // ------------------------------------------------------------------ internals

    function _payWinner(uint256 id_, Bounty storage b, address winner_, uint8 via_, bytes32 proofTx_) internal {
        b.status = Status.Paid;
        b.winner = winner_;
        uint256 amount = b.amount;
        b.amount = 0;
        address token = tokenOf[id_];
        if (token == address(0)) {
            openTotal -= amount;
            vault.release(payable(winner_), amount);
        } else {
            openTotalOf[token] -= amount;
            vault.releaseToken(token, winner_, amount);
        }
        emit BountyPaid(id_, winner_, amount, via_, proofTx_);
    }

    function _refund(uint256 id_, Bounty storage b, uint8 via_) internal {
        b.status = Status.Refunded;
        uint256 amount = b.amount;
        b.amount = 0;
        address token = tokenOf[id_];
        if (token == address(0)) {
            openTotal -= amount;
            vault.release(b.issuer, amount);
        } else {
            openTotalOf[token] -= amount;
            vault.releaseToken(token, b.issuer, amount);
        }
        emit BountyRefunded(id_, b.issuer, amount, via_);
    }
}
