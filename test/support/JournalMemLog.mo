/// JournalMemLog.mo — test support: an in-heap *journal* block chain using the
/// journal's production encoding and hashing, with no Region memory, so the bank
/// core and the journal core can be driven together in the interpreter as well as
/// under WASI.
///
/// This reproduces `test/support/MemLog.mo` of the pinned `thebes-ledger-core`
/// submodule (Apache-2.0, same programme), which is test-only and therefore not
/// reachable as a package from here. It is the journal's construction, not a
/// simplification of it: the same `Canonical.encodeBlock` and the same
/// `JournalCore.apply`.

import List "mo:core/List";
import Principal "mo:core/Principal";

import T "mo:journal/JournalTypes";
import C "mo:journal/Canonical";
import Core "mo:journal/JournalCore";

module {
  public type Chain = { blocks : List.List<T.Block>; var lastHash : ?Blob };

  public func new() : Chain { { blocks = List.empty<T.Block>(); var lastHash = null } };

  public func append(chain : Chain, timestamp : Nat64, caller : Principal, event : T.Event) : T.Block {
    let index = List.size(chain.blocks);
    let enc = C.encodeBlock(index, timestamp, caller, chain.lastHash, event);
    let b : T.Block = { index; timestamp; caller; parentHash = chain.lastHash; hash = enc.hash; event };
    List.add(chain.blocks, b);
    chain.lastHash := ?enc.hash;
    b
  };

  /// The chain as the journal core's record reader. A posting's record lives in the block log, so the
  /// core reads it back through this; here the "log" is the chain this module keeps.
  public func reader(chain : Chain) : Core.Blocks {
    { get = func(i : Nat) : ?T.Block { List.get(chain.blocks, i) } }
  };

  public func commit(chain : Chain, state : Core.State, timestamp : Nat64, caller : Principal, event : T.Event) : T.Block {
    let b = append(chain, timestamp, caller, event);
    Core.apply(state, reader(chain), b);
    b
  };

  public func blocks(chain : Chain) : [T.Block] { List.toArray(chain.blocks) };
};
