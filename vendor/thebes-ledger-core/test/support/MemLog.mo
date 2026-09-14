/// MemLog.mo: test support: an in-heap block chain with the production
/// encoding and hashing (Canonical.mo) but no Region memory, so the pure core
/// can be driven with realistic blocks in the Motoko interpreter.

import List "mo:core/List";
import Principal "mo:core/Principal";

import T "../../src/journal/JournalTypes";
import C "../../src/journal/Canonical";
import Core "../../src/journal/JournalCore";

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

  /// The chain as the core's record reader. A posting's record lives in the block log, so the core
  /// reads it back through this; here the "log" is the chain this module keeps.
  public func reader(chain : Chain) : Core.Blocks {
    { get = func(i : Nat) : ?T.Block { List.get(chain.blocks, i) } }
  };

  /// Append and apply in one step, the way the canister's `commit` does.
  public func commit(chain : Chain, state : Core.State, timestamp : Nat64, caller : Principal, event : T.Event) : T.Block {
    let b = append(chain, timestamp, caller, event);
    Core.apply(state, reader(chain), b);
    b
  };

  public func blocks(chain : Chain) : [T.Block] { List.toArray(chain.blocks) };
};
