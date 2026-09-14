/// ArchiveTypes.mo: the archive component's recorded decisions and its spawning state machine.
///
/// An archive is a contract this bank creates and installs on the Thebes substrate to hold what the
/// journal no longer needs on the operating book. Creating a contract from a contract is a sequence
/// of management calls whose replies the parent cannot act on today, so the component is built as a
/// **step-by-step flow driven from outside**, each step its own ingress message, each step recorded
/// in a bank block before its management call is sent. This file names the steps; `ArchiveCore.mo`
/// decides when each is allowed; `Bank.mo` sends the calls.
///
/// ## Why a step per message, and why the record comes first
///
/// On the current substrate a write made after an awaited management reply is not kept, and the
/// method replies with the inner call's bytes instead of its own value; `async*` does not change
/// that, because the raw call primitive is itself a plain `async` wrapper in the compiler's prelude.
/// So a parent that created a child and then tried to remember it in the same message would forget
/// it. The shape that holds, proven on a live chain, is four calls:
///
///   1. `createArchiveChild`  ; the parent records that a create was issued, **then** sends
///                               `create_canister`; the reply carries the new id;
///   2. `rememberArchiveChild`; await-free: the id is recorded against the spawn;
///   3. `installArchiveChild` ; the parent records that an install was issued, then sends
///                               `install_code` with the sealed image;
///   4. `confirmArchiveChild` ; await-free: the module hash the caller read from the chain is
///                               compared with the **parent's own pin** of the image.
///
/// Then `setArchiveChildControllers` and `completeArchiveChild`, in the same shape, so the operator
/// can later upgrade the child with `thebes-deploy` (a second `install_code` through management is
/// refused by the engine: a child's code is write-once from the parent's side).
///
/// ## The confirmation rule
///
/// Step 4 compares the offered hash with the parent's own pin of the image it sent. The caller reads
/// the chain (through `archiveChildStatus`, which replies with the raw status bytes) and offers the
/// hash; the contract refuses anything but its pinned one, so a child running any other module is
/// never confirmed. When the substrate delivers management replies into the calling contract's
/// continuation, `confirmArchiveChild` reads the status itself and the four calls fold into one; the
/// transitions in `ArchiveCore` are the same either way.
///
/// ## Every step is repeatable and resumable
///
/// A crash or a rollback between any two steps leaves a state the next call can finish, and no step
/// can ever produce a child the parent does not know about:
///
///   * a create is refused while one is already outstanding (`#createIssued`), so a driver that lost
///     the reply cannot make a second orphan by retrying; it recovers the id from the chain and
///     remembers it, or the bank records a dual-authorised judgement that the attempt made nothing;
///   * an install is refused for any id the parent has not remembered;
///   * an install can be sent again for the same id (the engine refuses a second install onto a child
///     that holds code, which the driver reads as "installed; confirm it");
///   * a confirmation offering the empty-module hash is recorded as a refusal and leaves the spawn
///     where an install can be retried;
///   * a spawn with a known id is never abandoned: the id either holds no code (retry) or holds code
///     (confirm). Abandonment exists only for a create that provably made nothing.

import Text "mo:core/Text";

module {

  /// A Thebes canister id. Eight bytes on the wire: **little-endian** as an argument to management,
  /// **big-endian** as a principal. `ArchiveWire.mo` owns those encodings.
  public type Cid = Nat64;

  /// A spawn is identified by the bank block that authorised it.
  public type SpawnId = Nat;

  /// The steps of one spawn, in order. Each variant carries everything a resumer needs.
  public type SpawnStatus = {
    /// The dual-authorised decision to create an archive exists; nothing has been sent.
    #authorised;
    /// `create_canister` was sent (`attempts` times). The reply carried the id; the parent has not
    /// been told it yet. A second create is refused in this state.
    #createIssued : { attempts : Nat };
    /// The id is known. No install has been sent.
    #created : { cid : Cid };
    /// `install_code` of `image` was sent (`attempts` times). The parent has not yet confirmed that
    /// the child holds it.
    #installIssued : { cid : Cid; image : Blob; attempts : Nat };
    /// The child holds `image`; confirmed against the parent's pin. No controllers set yet.
    #installed : { cid : Cid; image : Blob };
    /// `update_settings` was sent (`attempts` times) with `controllers`.
    #controllersIssued : { cid : Cid; image : Blob; controllers : [Principal]; attempts : Nat };
    /// The child is an archive contract of this bank.
    #ready : { cid : Cid; image : Blob; controllers : [Principal] };
    /// A dual-authorised judgement that the spawn produced nothing, with the reason. Only reachable
    /// from `#authorised` and `#createIssued`; never from a state that knows an id.
    #abandoned : { reason : Text };
  };

  public type Spawn = {
    id : SpawnId;
    purpose : Text;
    status : SpawnStatus;
    /// The bank block that last moved this spawn.
    lastBlock : Nat;
  };

  /// An archive contract this bank owns: spawned here, or deployed by the operator and adopted.
  public type Child = {
    cid : Cid;
    image : Blob;
    controllers : [Principal];
    purpose : Text;
    /// The spawn that made it, or null when it was adopted (route 2).
    spawn : ?SpawnId;
    readyAt : Nat;
  };

  /// A pinned child image: the SHA-256 the bank has decided an archive child runs, and its size.
  /// `sealedAt` is the block that recorded the uploaded bytes hashing to the pin.
  public type Image = {
    sha256 : Blob;
    bytes : Nat;
    name : Text;
    pinnedAt : Nat;
    sealedAt : ?Nat;
  };

  public type ArchiveEvent = {
    /// A declared image: what an archive child must run. Dual-authorised.
    #imagePinned : { sha256 : Blob; bytes : Nat; name : Text };
    /// The uploaded bytes hash to the current pin. Recorded by the sealer's message, after the hash
    /// was computed over what is actually stored.
    #imageSealed : { sha256 : Blob; bytes : Nat };
    /// The principals every child gets as controllers besides the parent. Dual-authorised.
    #controllersSet : { controllers : [Principal] };
    /// The decision to create an archive. Its block index is the spawn id.
    #spawnAuthorised : { purpose : Text };
    #createIssued : { spawn : SpawnId; attempt : Nat };
    #childRemembered : { spawn : SpawnId; cid : Cid };
    #installIssued : { spawn : SpawnId; cid : Cid; image : Blob; attempt : Nat };
    #childConfirmed : { spawn : SpawnId; cid : Cid; image : Blob };
    /// A confirmation refused: the offered hash is not the pin. Recorded so the log shows the retry.
    #confirmRefused : { spawn : SpawnId; cid : Cid; offered : Blob };
    #controllersIssued : { spawn : SpawnId; cid : Cid; controllers : [Principal]; attempt : Nat };
    #childReady : { spawn : SpawnId; cid : Cid };
    #spawnAbandoned : { spawn : SpawnId; reason : Text };
    /// Route 2: a child the operator deployed, registered against a pinned image. Dual-authorised.
    #childAdopted : { cid : Cid; image : Blob; controllers : [Principal]; purpose : Text };
  };

  public type ArchiveError = {
    #NoImagePinned;
    #ImageNotSealed : { sha256 : Blob };
    #ImageAlreadySealed : { sha256 : Blob };
    #ImageMismatch : { pinned : Blob; found : Blob };
    #ImageTooLarge : { bytes : Nat; cap : Nat };
    #ImageInvalid : { reason : Text };
    /// The pin cannot change while a spawn is between its create and its confirmation.
    #ImageInUse : { spawns : Nat };
    #UploadIncomplete : { have : Nat; expected : Nat };
    #NoControllersSet;
    #InvalidControllers : { reason : Text };
    #InvalidPurpose : { reason : Text };
    #UnknownSpawn : { spawn : SpawnId };
    /// The step is not allowed from the spawn's current state. `expected` says which states are.
    #SpawnNotIn : { spawn : SpawnId; status : Text; expected : Text };
    #CidKnown : { cid : Cid; holder : Text };
    #UnknownChild : { cid : Cid };
    #HashNotPinned : { offered : Blob };
  };

  /// The runtime's wire cap (`node/src/runtime.rs`, `WIRE_MAX_PAYLOAD_BYTES`). The framed install
  /// travels inside one message.
  public let WIRE_MAX_PAYLOAD_BYTES : Nat = 1_800_000;
  /// `canister_id(8) ‖ wasm_len(4)`; the install frame's overhead over the module bytes.
  public let INSTALL_FRAME_OVERHEAD : Nat = 12;
  /// The largest child image the parent can install in one message: the wire cap less the frame
  /// overhead. Written as a literal because a module-level `let` must be static; the relation is
  /// asserted in `test/Archive.test.mo`.
  public let MAX_IMAGE_BYTES : Nat = 1_799_988;
  /// The parent plus the configured principals. The raw `update_settings` frame carries a count and
  /// each principal with a one-byte length, so the bound is a policy choice, not an encoding limit.
  public let MAX_CONTROLLERS : Nat = 8;
  public let MAX_PURPOSE_BYTES : Nat = 128;
  public let MAX_NAME_BYTES : Nat = 64;
  public let MAX_REASON_BYTES : Nat = 256;

  /// The SHA-256 of nothing: what `canister_status` reports for a canister with no wasm. Measured on
  /// the chain on child 1,000,000 before its code was installed.
  public let EMPTY_MODULE_HASH : Blob = "\e3\b0\c4\42\98\fc\1c\14\9a\fb\f4\c8\99\6f\b9\24\27\ae\41\e4\64\9b\93\4c\a4\95\99\1b\78\52\b8\55";

  public func statusName(s : SpawnStatus) : Text {
    switch (s) {
      case (#authorised) "authorised";
      case (#createIssued(_)) "createIssued";
      case (#created(_)) "created";
      case (#installIssued(_)) "installIssued";
      case (#installed(_)) "installed";
      case (#controllersIssued(_)) "controllersIssued";
      case (#ready(_)) "ready";
      case (#abandoned(_)) "abandoned";
    }
  };

  /// The id a spawn knows, if it knows one.
  public func cidOf(s : SpawnStatus) : ?Cid {
    switch (s) {
      case (#authorised) null;
      case (#createIssued(_)) null;
      case (#created(x)) ?x.cid;
      case (#installIssued(x)) ?x.cid;
      case (#installed(x)) ?x.cid;
      case (#controllersIssued(x)) ?x.cid;
      case (#ready(x)) ?x.cid;
      case (#abandoned(_)) null;
    }
  };

  /// A spawn is in flight from its create until its child holds the confirmed image. While one is,
  /// the pin must not move: an install in flight installs the sealed image, and a confirmation
  /// compares against it.
  public func inFlight(s : SpawnStatus) : Bool {
    switch (s) {
      case (#createIssued(_)) true;
      case (#created(_)) true;
      case (#installIssued(_)) true;
      case (_) false;
    }
  };

  public func textFits(t : Text, max : Nat) : Bool {
    let n = Text.encodeUtf8(t).size();
    n > 0 and n <= max
  };
}
