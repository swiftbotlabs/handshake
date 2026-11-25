#!/usr/bin/env bash
# Planted-bug controls: each mutant breaks one safety rule in a scratch copy of the repo; the test suite MUST fail on every one.
# Exit 0 only if every mutant is killed (and the unmutated suite passes). The real source tree is never modified.
set -uo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cp -r src test foundry.toml remappings.txt "$work"/ && ln -s "$PWD/lib" "$work/lib"
run() { (cd "$work" && forge test -q >/dev/null 2>&1); }
run || { echo "BASELINE FAILS: fix the suite first"; exit 2; }
declare -a NAMES PATCHES FILES
NAMES+=("payout forgets to reduce openTotal");   PATCHES+=('/function _payWinner/,/^    }/ s/openTotal -= amount;/\/\/ mutant/')
FILES+=("src/HandshakeEscrow.sol")
NAMES+=("refund forgets to reduce openTotal");   PATCHES+=('/function _refund/,/^    }/ s/openTotal -= amount;/\/\/ mutant/')
FILES+=("src/HandshakeEscrow.sol")
NAMES+=("settleProof skips the still-open check"); PATCHES+=('s/if (b.status != Status.Open || b.kind != Kind.Proof) {/if (b.kind != Kind.Proof) {/')
FILES+=("src/HandshakeEscrow.sol")
NAMES+=("settleProof pays after the deadline");  PATCHES+=('/function settleProof/,/^    }/ s/if (block.timestamp >= b.deadline) {/if (false) {/')
FILES+=("src/HandshakeEscrow.sol")
NAMES+=("expire() allowed before the deadline"); PATCHES+=('s/if (block.timestamp < b.deadline) revert TooEarly/if (false) revert TooEarly/')
FILES+=("src/HandshakeEscrow.sol")
NAMES+=("posting fee goes to the vault too");    PATCHES+=('s/uint256 amount = msg.value - postFee;/uint256 amount = msg.value;/')
FILES+=("src/HandshakeEscrow.sol")
NAMES+=("minimum not enforced");                 PATCHES+=('s/if (msg.value < minBounty + postFee) revert/if (false) revert/')
FILES+=("src/HandshakeEscrow.sol")
NAMES+=("token payout forgets openTotalOf");    PATCHES+=('/function _payWinner/,/^    }/ s/openTotalOf\[token\] -= amount;/\/\/ mutant/')
FILES+=("src/HandshakeEscrow.sol")
NAMES+=("token bounty trusts the requested amount (fee-on-transfer)"); PATCHES+=('s/uint256 received = _balanceOf(token_, address(vault)) - before;/uint256 received = amount_;/')
FILES+=("src/HandshakeEscrow.sol")
NAMES+=("token post skips the exact-fee check"); PATCHES+=('s/if (msg.value != postFee) revert WrongFee/if (false) revert WrongFee/')
FILES+=("src/HandshakeEscrow.sol")
NAMES+=("escrow pays a claimant off the allowlist"); PATCHES+=('s/if (restricted\[id_\] \&\& !allowed\[id_\]\[winner_\]) {/if (false) {/'); FILES+=("src/HandshakeEscrow.sol")
NAMES+=("watcher forwards a front-runner's proof"); PATCHES+=('s/if (restricted\[id\] \&\& !allowed\[id\]\[winner\]) {/if (false) {/'); FILES+=("src/HandshakeReactive.sol")
NAMES+=("allowlist emitted after the condition"); PATCHES+=('/function postProofFor/,/^    }/ { s/_allow(id, claimants_);/_setCondition(id, c_);/; t; s/_setCondition(id, c_);/_allow(id, claimants_);/ }'); FILES+=("src/HandshakeEscrow.sol")
NAMES+=("fee sweep ignores the gas floor"); PATCHES+=('s/sent = bal - gasFloor;/sent = bal;/'); FILES+=("src/HandshakeEscrow.sol")
NAMES+=("fee sweep credits the caller, not the watcher"); PATCHES+=('s/abi.encodeWithSignature("request(address)", _CALLBACK_SENDER)/abi.encodeWithSignature("request(address)", msg.sender)/'); FILES+=("src/HandshakeEscrow.sol")
NAMES+=("data-word winner accepts a non-address"); PATCHES+=('s/if (raw >> 160 != 0) continue;/\/\/ mutant/'); FILES+=("src/HandshakeReactive.sol")
NAMES+=("event cap never pauses a busy proof"); PATCHES+=('s/if (++r.count > maxEventsPerWindow \&\& !r.paused) {/if (false) {/'); FILES+=("src/HandshakeReactive.sol")
NAMES+=("fundedUntil ignores proof events (the v5 formula)"); PATCHES+=('s/burn += (liveKeys \* (maxEventsPerWindow + 1)/burn += 0 * (liveKeys * (maxEventsPerWindow + 1)/'); FILES+=("src/HandshakeReactive.sol")
NAMES+=("paused subscription unsubscribed again on close"); PATCHES+=('s/if (!rates\[key\].paused) {/if (true) {/'); FILES+=("src/HandshakeReactive.sol")
NAMES+=("paused proof resumes before its window ends"); PATCHES+=('s/if (r.paused \&\& block.timestamp < uint256(r.windowStart) + eventWindow) {/if (false) {/'); FILES+=("src/HandshakeReactive.sol")
NAMES+=("open proof subscriptions not counted"); PATCHES+=('s/            ++liveKeys;/            \/\/ mutant/'); FILES+=("src/HandshakeReactive.sol")
killed=0
for i in "${!NAMES[@]}"; do
  f=${FILES[$i]}
  cp src/HandshakeEscrow.sol src/HandshakeReactive.sol "$work/src/"
  sed -i "${PATCHES[$i]}" "$work/$f"
  if cmp -s "$f" "$work/$f"; then echo "PATCH DID NOT APPLY: ${NAMES[$i]}"; exit 3; fi
  if run; then echo "SURVIVED  ${NAMES[$i]}"; else echo "killed    ${NAMES[$i]}"; killed=$((killed+1)); fi
done
cp src/HandshakeEscrow.sol src/HandshakeReactive.sol "$work/src/"
echo "$killed of ${#NAMES[@]} mutants killed"
[ "$killed" -eq "${#NAMES[@]}" ]
