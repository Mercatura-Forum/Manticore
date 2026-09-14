/// ArchiveWire.mo: the raw byte shapes the Thebes management contract speaks.
///
/// Management (`aaaaa-aa`, `CanisterId(0)`) takes raw arguments and gives
/// raw replies, not Candid, and every shape below was verified against the engine's own decoders
/// in `the substrate's management interface` and `engine.rs`, then exercised on the
/// live chain (`tools/spawn-proof/evidence.json`). Nothing here awaits; it is pure encoding, so it is
/// tested in the interpreter byte for byte.
///
/// **The substrate uses both endiannesses for a canister id, and which one depends on whether the id
/// is an argument or a principal.** It is the easiest thing here to get wrong and it does not fail
/// loudly; the wrong order addresses an id nobody owns:
///
/// | where the id appears | encoding | source |
/// |---|---|---|
/// | `create_canister`'s reply | 8 bytes **LE** | `engine.rs` `CreateCanister` arm, `id.to_le_bytes()` |
/// | the `canister_id` in a raw management argument (`install_code`, `canister_status`, `update_settings`) | 8 bytes **LE** | `management.rs` (`u64::from_le_bytes`) |
/// | a **callee principal**, and `canister_self` | 8 bytes **BE** | `engine.rs` `u64::from_be_bytes`; `host.rs` `canister_self_copy` |
/// | the caller a management call sees, hence a created child's first controller | 8 bytes **BE** | `engine.rs` `caller_id.0.to_be_bytes()` |
///
/// So: **little-endian for an argument, big-endian for a principal.** The parent's own principal
/// (`Principal.fromActor(self)`) is therefore exactly the bytes the engine holds as the child's
/// controller after `create_canister`, and it is what `controllersFrame` must keep.

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat64 "mo:core/Nat64";
import List "mo:core/List";
import Principal "mo:core/Principal";
import Result "mo:core/Result";

import AT "ArchiveTypes";

module {

  /// `create_canister` takes no argument at all. Named so the call site says so.
  public let CREATE_ARG : Blob = "";

  public func leBytes(value : Nat, width : Nat) : [Nat8] {
    var v = value;
    Array.tabulate<Nat8>(width, func(_) { let b = Nat8.fromNat(v % 256); v /= 256; b })
  };

  public func beBytes(value : Nat, width : Nat) : [Nat8] {
    let le = leBytes(value, width);
    Array.tabulate<Nat8>(width, func(i) { le[width - 1 - i] })
  };

  public func leNat(bytes : [Nat8]) : Nat {
    var v = 0;
    var i = bytes.size();
    while (i > 0) { i -= 1; v := v * 256 + Nat8.toNat(bytes[i]) };
    v
  };

  /// The raw `canister_id` argument every management method but `create_canister` starts with.
  public func idArg(cid : AT.Cid) : Blob { Blob.fromArray(leBytes(Nat64.toNat(cid), 8)) };

  /// A child's principal, for calling it: its id as eight big-endian bytes.
  public func childPrincipal(cid : AT.Cid) : Principal {
    Principal.fromBlob(Blob.fromArray(beBytes(Nat64.toNat(cid), 8)))
  };

  /// The id a principal of the canister form carries, or null for any other principal.
  public func cidOfPrincipal(p : Principal) : ?AT.Cid {
    let a = Blob.toArray(Principal.toBlob(p));
    if (a.size() != 8) return null;
    var v = 0;
    for (b in a.vals()) { v := v * 256 + Nat8.toNat(b) };
    ?Nat64.fromNat(v)
  };

  /// `create_canister`'s reply: the new id as eight little-endian bytes, and nothing else. A reply
  /// of any other length is refused rather than read; a Candid-decoding caller reads rubbish here.
  public func parseCreateReply(reply : Blob) : Result.Result<AT.Cid, Text> {
    let a = Blob.toArray(reply);
    if (a.size() != 8) return #err("create_canister replied " # Nat.toText(a.size()) # " bytes, expected 8 little-endian");
    #ok(Nat64.fromNat(leNat(a)))
  };

  /// `install_code`'s raw argument: `canister_id(8 LE) ‖ wasm_len(4 LE) ‖ wasm ‖ init_arg`. There is
  /// **no mode field**, the engine has none, and the init argument is **empty**: an archive child's
  /// `canister_init` must never write and then trap (a trap after a write in `canister_init` is
  /// fatal to every validator), so the child is given nothing to decode at install and configured afterwards by
  /// a call that can refuse cleanly.
  public func installFrame(cid : AT.Cid, wasm : Blob) : Result.Result<Blob, AT.ArchiveError> {
    let n = wasm.size();
    if (n == 0) return #err(#ImageInvalid({ reason = "no image bytes to install" }));
    if (n + AT.INSTALL_FRAME_OVERHEAD > AT.WIRE_MAX_PAYLOAD_BYTES) {
      return #err(#ImageTooLarge({ bytes = n; cap = AT.MAX_IMAGE_BYTES }));
    };
    let out = List.empty<Nat8>();
    for (b in leBytes(Nat64.toNat(cid), 8).vals()) List.add(out, b);
    for (b in leBytes(n, 4).vals()) List.add(out, b);
    for (b in wasm.vals()) List.add(out, b);
    #ok(Blob.fromArray(List.toArray(out)))
  };

  /// What `canister_status` replies, decoded from the engine's own layout
  /// (`management.rs` `encode_canister_status`): `running(1) ‖ cycles(8 LE) ‖ memory(8 LE) ‖
  /// wasm_size(8 LE) ‖ module_hash(32)`; 57 bytes, and the hash is the SHA-256 of the installed
  /// module (`wasm_module_hash`). Controllers are **not** in it; nothing a contract can call reports
  /// them, which is why `completeArchiveChild` cannot check them and says so.
  public type Status = { running : Bool; cycles : Nat; memoryBytes : Nat; wasmBytes : Nat; moduleHash : Blob };

  public let STATUS_REPLY_BYTES : Nat = 57;

  public func parseStatusReply(reply : Blob) : Result.Result<Status, Text> {
    let a = Blob.toArray(reply);
    if (a.size() != STATUS_REPLY_BYTES) {
      return #err("canister_status replied " # Nat.toText(a.size()) # " bytes, expected " # Nat.toText(STATUS_REPLY_BYTES));
    };
    let slice = func(from : Nat, len : Nat) : [Nat8] { Array.tabulate<Nat8>(len, func(i) { a[from + i] }) };
    #ok({
      running = a[0] == 1;
      cycles = leNat(slice(1, 8));
      memoryBytes = leNat(slice(9, 8));
      wasmBytes = leNat(slice(17, 8));
      moduleHash = Blob.fromArray(slice(25, 32));
    })
  };

  /// `update_settings`' raw frame: `canister_id(8 LE) ‖ flag(1) ‖ count(4 LE) ‖ [len(1) ‖ principal]…`
  /// (`management.rs`, the raw branch beside the Candid one). The engine **replaces** the controller
  /// set with this list, it does not add to it, so the parent must be in the list to stay a
  /// controller, and the caller of this function is required to have put it there.
  public func controllersFrame(cid : AT.Cid, controllers : [Principal]) : Result.Result<Blob, AT.ArchiveError> {
    if (controllers.size() == 0) return #err(#InvalidControllers({ reason = "an empty controller set would orphan the child" }));
    if (controllers.size() > AT.MAX_CONTROLLERS) return #err(#InvalidControllers({ reason = "more than " # Nat.toText(AT.MAX_CONTROLLERS) # " controllers" }));
    let out = List.empty<Nat8>();
    for (b in leBytes(Nat64.toNat(cid), 8).vals()) List.add(out, b);
    List.add(out, 1 : Nat8);
    for (b in leBytes(controllers.size(), 4).vals()) List.add(out, b);
    for (c in controllers.vals()) {
      let p = Blob.toArray(Principal.toBlob(c));
      if (p.size() == 0 or p.size() > 29) return #err(#InvalidControllers({ reason = "a principal of " # Nat.toText(p.size()) # " bytes" }));
      List.add(out, Nat8.fromNat(p.size()));
      for (b in p.vals()) List.add(out, b);
    };
    #ok(Blob.fromArray(List.toArray(out)))
  };

  public func hex(b : Blob) : Text {
    let digits = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"];
    var out = "";
    for (x in b.vals()) { let n = Nat8.toNat(x); out #= digits[n / 16] # digits[n % 16] };
    out
  };
}
