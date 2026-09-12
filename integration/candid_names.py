"""Candid field-name recovery for ic-py's untyped decoder.

ic-py decodes records and variants it has no type for with hashed labels
("_<idl hash>"). This module recovers the names by hashing every identifier
that appears in the canister's Candid interface (journal.did) and builds a
reverse table, then rewrites decoded values recursively. Unknown hashes are
left as they are, so nothing is silently misnamed.
"""
import re
from ic.candid import labelHash
from ic.principal import Principal


def _load_names(did_path):
    text = open(did_path, encoding="utf-8").read()
    return set(re.findall(r"[A-Za-z_][A-Za-z0-9_]*", text))


class Names:
    def __init__(self, did_path):
        self.table = {}
        for n in _load_names(did_path):
            self.table[f"_{labelHash(n)}"] = n
        # variant tags and record fields used by the journal that are keywords in the did
        for n in ["ok", "err", "debit", "credit", "asset", "liability", "equity", "income", "expense",
                  "posted", "pending", "post", "void", "requested", "expired", "reversal", "correction",
                  "open", "closed", "active", "postedFromPending", "voided"]:
            self.table[f"_{labelHash(n)}"] = n

    def fix(self, value):
        if isinstance(value, Principal):
            return value.to_str()          # ic-py principals compare by identity; text compares by value
        if isinstance(value, dict):
            out = {}
            for k, v in value.items():
                name = self.table.get(k, k) if isinstance(k, str) and k.startswith("_") and k[1:].isdigit() else k
                out[name] = self.fix(v)
            return out
        if isinstance(value, list):
            return [self.fix(v) for v in value]
        if isinstance(value, tuple):
            return tuple(self.fix(v) for v in value)
        return value
