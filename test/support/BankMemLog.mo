/// BankMemLog.mo; test support: an in-heap bank block chain using the
/// production encoding and hashing (BankCanonical.mo) but no Region memory, so
/// the pure core can be driven with realistic blocks in the Motoko interpreter
/// as well as under WASI. The journal's own test support does the same thing for
/// journal blocks (`mo:journal` test/support/MemLog.mo).

import List "mo:core/List";
import Principal "mo:core/Principal";

import T "../../src/bank/BankTypes";
import C "../../src/bank/BankCanonical";
import Core "../../src/bank/BankCore";

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

  /// The chain as the core reads it back, the way the canister hands in its `BankLog`.
  public func reader(chain : Chain) : Core.Blocks {
    { get = func(i : Nat) : ?T.Block { List.get(chain.blocks, i) } }
  };

  /// Append and apply in one step, the way the canister's `commitBank` does.
  public func commit(chain : Chain, state : Core.State, timestamp : Nat64, caller : Principal, event : T.Event) : T.Block {
    let b = append(chain, timestamp, caller, event);
    Core.apply(state, reader(chain), b);
    b
  };

  public func blocks(chain : Chain) : [T.Block] { List.toArray(chain.blocks) };
};
