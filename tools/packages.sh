#!/usr/bin/env bash
# Emits the moc --package flags for this repository: the mops dependencies plus
# the two packages vendored under vendor/thebes-ledger-core.
# `journal` is the double-entry journal; `ledger` is the canonical ICRC-ME family
# (MIT, see NOTICE) from which StableLog, MerkleMMR and CertifiedTree come.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
echo "$(mops sources 2>/dev/null) --package journal $ROOT/vendor/thebes-ledger-core/src/journal --package ledger $ROOT/vendor/thebes-ledger-core/src/ledger"
