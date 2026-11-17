#!/usr/bin/env bash
# Planted-bug controls: each mutant breaks one safety rule in a scratch copy of the repo; the test suite MUST fail on every one.
# Exit 0 only if every mutant is killed (and the unmutated suite passes). The real source tree is never modified.
set -uo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cp -r src test foundry.toml remappings.txt "$work"/ && ln -s "$PWD/lib" "$work/lib"
run() { (cd "$work" && forge test -q >/dev/null 2>&1); }
run || { echo "BASELINE FAILS: fix the suite first"; exit 2; }
declare -a NAMES PATCHES
NAMES+=("payout forgets to reduce openTotal");   PATCHES+=('/function _payWinner/,/^    }/ s/openTotal -= amount;/\/\/ mutant/')
NAMES+=("refund forgets to reduce openTotal");   PATCHES+=('/function _refund/,/^    }/ s/openTotal -= amount;/\/\/ mutant/')
NAMES+=("settleProof skips the still-open check"); PATCHES+=('s/if (b.status != Status.Open || b.kind != Kind.Proof) {/if (b.kind != Kind.Proof) {/')
NAMES+=("settleProof pays after the deadline");  PATCHES+=('/function settleProof/,/^    }/ s/if (block.timestamp >= b.deadline) {/if (false) {/')
NAMES+=("expire() allowed before the deadline"); PATCHES+=('s/if (block.timestamp < b.deadline) revert TooEarly/if (false) revert TooEarly/')
NAMES+=("posting fee goes to the vault too");    PATCHES+=('s/uint256 amount = msg.value - postFee;/uint256 amount = msg.value;/')
NAMES+=("minimum not enforced");                 PATCHES+=('s/if (msg.value < minBounty + postFee) revert/if (false) revert/')
killed=0
for i in "${!NAMES[@]}"; do
  cp src/HandshakeEscrow.sol "$work/src/HandshakeEscrow.sol"
  sed -i "${PATCHES[$i]}" "$work/src/HandshakeEscrow.sol"
  if cmp -s src/HandshakeEscrow.sol "$work/src/HandshakeEscrow.sol"; then echo "PATCH DID NOT APPLY: ${NAMES[$i]}"; exit 3; fi
  if run; then echo "SURVIVED  ${NAMES[$i]}"; else echo "killed    ${NAMES[$i]}"; killed=$((killed+1)); fi
done
cp src/HandshakeEscrow.sol "$work/src/HandshakeEscrow.sol"
echo "$killed of ${#NAMES[@]} mutants killed"
[ "$killed" -eq "${#NAMES[@]}" ]
