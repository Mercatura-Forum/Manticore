/// ArchiveCore.mo: the archive component's folded state, and the rule for every step.
///
/// Pure. Nothing here sends a message or reads the chain: each `plan*` function looks at the state
/// the log has produced and answers with the event the step would record, or the refusal. `Bank.mo`
/// commits the event and, for the steps that have one, sends the management call **afterwards**, so
/// the record exists whatever the call's reply does to the continuation. `apply` is the fold, run on
/// every block at commit time and again on replay, so what a resumer sees after a crash is exactly
/// what the log says happened.
///
/// The one invariant every planner protects: **no id the chain has given this parent is ever
/// forgotten.** A create is refused while one is outstanding; an install is refused for an id that
/// was never remembered; an id, once remembered, belongs to one spawn or one child for ever and no
/// state with an id can be abandoned. `ArchiveTypes.mo` has the reasoning; this file has the rules.

import Map "mo:core/Map";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import Text "mo:core/Text";
import Blob "mo:core/Blob";
import Array "mo:core/Array";
import Principal "mo:core/Principal";
import Result "mo:core/Result";
import Runtime "mo:core/Runtime";

import C "mo:journal/Canonical";
import AT "ArchiveTypes";

module {

  public type State = {
    /// Every image ever pinned, by hash. A pin is never forgotten: an adopted child may run an
    /// earlier image, and the log must be able to say it was a pinned one.
    images : Map.Map<Blob, AT.Image>;
    /// The image route-1 spawns install: the most recent pin.
    var current : ?Blob;
    /// The principals every child gets as controllers, besides the parent.
    var controllers : [Principal];
    spawns : Map.Map<AT.SpawnId, AT.Spawn>;
    children : Map.Map<AT.Cid, AT.Child>;
    /// Which spawn or child holds an id. One holder, for ever.
    holders : Map.Map<AT.Cid, Text>;
    var imageCount : Nat;
    var spawnCount : Nat;
    var childCount : Nat;
    var refusedConfirmations : Nat;
  };

  public func newState() : State {
    {
      images = Map.empty<Blob, AT.Image>();
      var current = null;
      var controllers = [];
      spawns = Map.empty<AT.SpawnId, AT.Spawn>();
      children = Map.empty<AT.Cid, AT.Child>();
      holders = Map.empty<AT.Cid, Text>();
      var imageCount = 0;
      var spawnCount = 0;
      var childCount = 0;
      var refusedConfirmations = 0;
    }
  };

  // ─── the fold ─────────────────────────────────────────────────────────────

  func spawnOf(s : State, id : AT.SpawnId) : AT.Spawn {
    let ?sp = Map.get(s.spawns, Nat.compare, id) else Runtime.trap("ArchiveCore: event names an unknown spawn " # Nat.toText(id));
    sp
  };

  func setStatus(s : State, id : AT.SpawnId, status : AT.SpawnStatus, block : Nat) {
    let sp = spawnOf(s, id);
    Map.add(s.spawns, Nat.compare, id, { id = sp.id; purpose = sp.purpose; status; lastBlock = block });
  };

  public func apply(s : State, block : Nat, e : AT.ArchiveEvent) {
    switch (e) {
      case (#imagePinned(x)) {
        Map.add(s.images, Blob.compare, x.sha256, { sha256 = x.sha256; bytes = x.bytes; name = x.name; pinnedAt = block; sealedAt = null });
        s.current := ?x.sha256;
        s.imageCount += 1;
      };
      case (#imageSealed(x)) {
        let ?img = Map.get(s.images, Blob.compare, x.sha256) else Runtime.trap("ArchiveCore: seal of an unpinned image");
        Map.add(s.images, Blob.compare, x.sha256, { img with sealedAt = ?block });
      };
      case (#controllersSet(x)) { s.controllers := x.controllers };
      case (#spawnAuthorised(x)) {
        Map.add(s.spawns, Nat.compare, block, { id = block; purpose = x.purpose; status = #authorised; lastBlock = block });
        s.spawnCount += 1;
      };
      case (#createIssued(x)) {
        let attempts = switch (spawnOf(s, x.spawn).status) { case (#createIssued(c)) c.attempts + 1; case (_) 1 };
        setStatus(s, x.spawn, #createIssued({ attempts }), block);
      };
      case (#childRemembered(x)) {
        setStatus(s, x.spawn, #created({ cid = x.cid }), block);
        Map.add(s.holders, Nat64.compare, x.cid, "spawn " # Nat.toText(x.spawn));
      };
      case (#installIssued(x)) {
        let attempts = switch (spawnOf(s, x.spawn).status) { case (#installIssued(i)) i.attempts + 1; case (_) 1 };
        setStatus(s, x.spawn, #installIssued({ cid = x.cid; image = x.image; attempts }), block);
      };
      case (#childConfirmed(x)) { setStatus(s, x.spawn, #installed({ cid = x.cid; image = x.image }), block) };
      case (#confirmRefused(_)) { s.refusedConfirmations += 1 };
      case (#controllersIssued(x)) {
        let sp = spawnOf(s, x.spawn);
        let (image, attempts) = switch (sp.status) {
          case (#installed(i)) (i.image, 1);
          case (#controllersIssued(c)) (c.image, c.attempts + 1);
          case (_) Runtime.trap("ArchiveCore: controllers issued from " # AT.statusName(sp.status));
        };
        setStatus(s, x.spawn, #controllersIssued({ cid = x.cid; image; controllers = x.controllers; attempts }), block);
      };
      case (#childReady(x)) {
        let sp = spawnOf(s, x.spawn);
        let (image, controllers) = switch (sp.status) {
          case (#controllersIssued(c)) (c.image, c.controllers);
          case (_) Runtime.trap("ArchiveCore: ready from " # AT.statusName(sp.status));
        };
        setStatus(s, x.spawn, #ready({ cid = x.cid; image; controllers }), block);
        Map.add(s.children, Nat64.compare, x.cid, { cid = x.cid; image; controllers; purpose = sp.purpose; spawn = ?x.spawn; readyAt = block });
        Map.add(s.holders, Nat64.compare, x.cid, "child " # Nat64.toText(x.cid));
        s.childCount += 1;
      };
      case (#spawnAbandoned(x)) { setStatus(s, x.spawn, #abandoned({ reason = x.reason }), block) };
      case (#childAdopted(x)) {
        Map.add(s.children, Nat64.compare, x.cid, { cid = x.cid; image = x.image; controllers = x.controllers; purpose = x.purpose; spawn = null; readyAt = block });
        Map.add(s.holders, Nat64.compare, x.cid, "child " # Nat64.toText(x.cid));
        s.childCount += 1;
      };
    }
  };

  // ─── reads ────────────────────────────────────────────────────────────────

  public func currentImage(s : State) : ?AT.Image {
    switch (s.current) { case (?h) Map.get(s.images, Blob.compare, h); case null null }
  };

  public func image(s : State, sha256 : Blob) : ?AT.Image { Map.get(s.images, Blob.compare, sha256) };

  public func controllers(s : State) : [Principal] { s.controllers };

  public func spawn(s : State, id : AT.SpawnId) : ?AT.Spawn { Map.get(s.spawns, Nat.compare, id) };

  public func child(s : State, cid : AT.Cid) : ?AT.Child { Map.get(s.children, Nat64.compare, cid) };

  public func holder(s : State, cid : AT.Cid) : ?Text { Map.get(s.holders, Nat64.compare, cid) };

  /// Spawns between their create and their confirmation.
  public func inFlight(s : State) : Nat {
    var n = 0;
    for ((_, sp) in Map.entries(s.spawns)) { if (AT.inFlight(sp.status)) n += 1 };
    n
  };

  public func counts(s : State) : { images : Nat; spawns : Nat; children : Nat; inFlight : Nat; refusedConfirmations : Nat } {
    { images = s.imageCount; spawns = s.spawnCount; children = s.childCount; inFlight = inFlight(s); refusedConfirmations = s.refusedConfirmations }
  };

  /// Cursor-paged, ascending by spawn id; the cursor is the next id to read.
  public func listSpawnsPaged(s : State, cursor : ?AT.SpawnId, limit : Nat) : { rows : [AT.Spawn]; cursor : ?AT.SpawnId; total : Nat } {
    let from = switch (cursor) { case (?c) c; case null 0 };
    let rows = List.empty<AT.Spawn>();
    var next : ?AT.SpawnId = null;
    label walk for ((id, sp) in Map.entries(s.spawns)) {
      if (id < from) continue walk;
      if (List.size(rows) >= limit) { next := ?id; break walk };
      List.add(rows, sp);
    };
    { rows = List.toArray(rows); cursor = next; total = Map.size(s.spawns) }
  };

  public func listChildrenPaged(s : State, cursor : ?AT.Cid, limit : Nat) : { rows : [AT.Child]; cursor : ?AT.Cid; total : Nat } {
    let from : AT.Cid = switch (cursor) { case (?c) c; case null 0 };
    let rows = List.empty<AT.Child>();
    var next : ?AT.Cid = null;
    label walk for ((cid, ch) in Map.entries(s.children)) {
      if (cid < from) continue walk;
      if (List.size(rows) >= limit) { next := ?cid; break walk };
      List.add(rows, ch);
    };
    { rows = List.toArray(rows); cursor = next; total = Map.size(s.children) }
  };

  // ─── the decisions (dual-authorised commands) ─────────────────────────────

  public func planPin(s : State, sha256 : Blob, bytes : Nat, name : Text) : Result.Result<AT.ArchiveEvent, AT.ArchiveError> {
    if (sha256.size() != 32) return #err(#ImageInvalid({ reason = "a pin is a 32-byte SHA-256" }));
    if (sha256 == AT.EMPTY_MODULE_HASH) return #err(#ImageInvalid({ reason = "that is the hash of no module at all" }));
    if (bytes == 0) return #err(#ImageInvalid({ reason = "an image has bytes" }));
    if (bytes > AT.MAX_IMAGE_BYTES) return #err(#ImageTooLarge({ bytes; cap = AT.MAX_IMAGE_BYTES }));
    if (not AT.textFits(name, AT.MAX_NAME_BYTES)) return #err(#ImageInvalid({ reason = "name must be 1.." # Nat.toText(AT.MAX_NAME_BYTES) # " bytes" }));
    switch (Map.get(s.images, Blob.compare, sha256)) {
      case (?img) {
        if (img.bytes != bytes) return #err(#ImageInvalid({ reason = "that hash is already pinned with " # Nat.toText(img.bytes) # " bytes" }));
        switch (s.current) {
          case (?c) { if (c == sha256) return #err(#ImageInvalid({ reason = "that image is already the current pin" })) };
          case null {};
        };
      };
      case null {};
    };
    // A spawn in flight installs the sealed image and is confirmed against it; moving the pin under
    // it would confirm the wrong thing or refuse the right one.
    let flying = inFlight(s);
    if (flying > 0) return #err(#ImageInUse({ spawns = flying }));
    #ok(#imagePinned({ sha256; bytes; name }))
  };

  /// The seal: `computed` is the SHA-256 the sealer's message took over the bytes actually stored,
  /// `bytes` their count. Both must be the pin's; a seal is the statement "what is in the region is
  /// what was decided", and it is made by the contract, not the uploader.
  public func planSeal(s : State, computed : Blob, bytes : Nat) : Result.Result<AT.ArchiveEvent, AT.ArchiveError> {
    let ?img = currentImage(s) else return #err(#NoImagePinned);
    switch (img.sealedAt) { case (?_) return #err(#ImageAlreadySealed({ sha256 = img.sha256 })); case null {} };
    if (bytes != img.bytes) return #err(#UploadIncomplete({ have = bytes; expected = img.bytes }));
    if (computed != img.sha256) return #err(#ImageMismatch({ pinned = img.sha256; found = computed }));
    #ok(#imageSealed({ sha256 = img.sha256; bytes }))
  };

  public func planSetControllers(s : State, controllers : [Principal]) : Result.Result<AT.ArchiveEvent, AT.ArchiveError> {
    if (controllers.size() == 0) return #err(#InvalidControllers({ reason = "at least one controller besides the parent, or the operator can never upgrade a child" }));
    if (controllers.size() + 1 > AT.MAX_CONTROLLERS) return #err(#InvalidControllers({ reason = "more than " # Nat.toText(AT.MAX_CONTROLLERS - 1) # " besides the parent" }));
    var i = 0;
    while (i < controllers.size()) {
      let p = controllers[i];
      if (Principal.isAnonymous(p)) return #err(#InvalidControllers({ reason = "the anonymous principal cannot control anything" }));
      let n = Principal.toBlob(p).size();
      if (n == 0 or n > 29) return #err(#InvalidControllers({ reason = "a principal of " # Nat.toText(n) # " bytes" }));
      var j = 0;
      while (j < i) { if (Principal.equal(controllers[j], p)) return #err(#InvalidControllers({ reason = "a principal is listed twice" })); j += 1 };
      i += 1;
    };
    if (Array.equal<Principal>(controllers, s.controllers, Principal.equal)) return #err(#InvalidControllers({ reason = "that is already the controller set" }));
    #ok(#controllersSet({ controllers }))
  };

  /// Authorise a spawn. Refused unless everything a spawn will need is already in place, so a spawn
  /// can never be authorised into a state where its first step must fail: a sealed image, and a
  /// controller set.
  public func planSpawn(s : State, purpose : Text) : Result.Result<AT.ArchiveEvent, AT.ArchiveError> {
    if (not AT.textFits(purpose, AT.MAX_PURPOSE_BYTES)) return #err(#InvalidPurpose({ reason = "purpose must be 1.." # Nat.toText(AT.MAX_PURPOSE_BYTES) # " bytes" }));
    let ?img = currentImage(s) else return #err(#NoImagePinned);
    switch (img.sealedAt) { case null return #err(#ImageNotSealed({ sha256 = img.sha256 })); case (?_) {} };
    if (s.controllers.size() == 0) return #err(#NoControllersSet);
    #ok(#spawnAuthorised({ purpose }))
  };

  /// Abandon a spawn that made nothing. Allowed from `#authorised` (nothing was ever sent) and from
  /// `#createIssued` (a judgement, recorded with its reason, that the create produced no child; for
  /// instance because the management call was rejected). Never from a state that knows an id.
  public func planAbandon(s : State, id : AT.SpawnId, reason : Text) : Result.Result<AT.ArchiveEvent, AT.ArchiveError> {
    let ?sp = spawn(s, id) else return #err(#UnknownSpawn({ spawn = id }));
    if (not AT.textFits(reason, AT.MAX_REASON_BYTES)) return #err(#InvalidPurpose({ reason = "reason must be 1.." # Nat.toText(AT.MAX_REASON_BYTES) # " bytes" }));
    switch (sp.status) {
      case (#authorised) {};
      case (#createIssued(_)) {};
      case (other) return #err(#SpawnNotIn({ spawn = id; status = AT.statusName(other); expected = "authorised or createIssued — a spawn that knows an id is finished, never abandoned" }));
    };
    #ok(#spawnAbandoned({ spawn = id; reason }))
  };

  /// Route 2: adopt a child the operator deployed, against a pinned image. The hash
  /// is what the operator read from the chain (`archiveChildStatus`), and it must be a pin.
  public func planAdopt(s : State, cid : AT.Cid, moduleHash : Blob, controllers : [Principal], purpose : Text) : Result.Result<AT.ArchiveEvent, AT.ArchiveError> {
    if (not AT.textFits(purpose, AT.MAX_PURPOSE_BYTES)) return #err(#InvalidPurpose({ reason = "purpose must be 1.." # Nat.toText(AT.MAX_PURPOSE_BYTES) # " bytes" }));
    switch (holder(s, cid)) { case (?h) return #err(#CidKnown({ cid; holder = h })); case null {} };
    if (moduleHash == AT.EMPTY_MODULE_HASH) return #err(#HashNotPinned({ offered = moduleHash }));
    switch (Map.get(s.images, Blob.compare, moduleHash)) { case null return #err(#HashNotPinned({ offered = moduleHash })); case (?_) {} };
    if (controllers.size() == 0) return #err(#InvalidControllers({ reason = "an adopted child records who controls it" }));
    if (controllers.size() > AT.MAX_CONTROLLERS) return #err(#InvalidControllers({ reason = "more than " # Nat.toText(AT.MAX_CONTROLLERS) # " controllers" }));
    #ok(#childAdopted({ cid; image = moduleHash; controllers; purpose }))
  };

  func notIn(id : AT.SpawnId, sp : AT.Spawn, expected : Text) : AT.ArchiveError {
    #SpawnNotIn({ spawn = id; status = AT.statusName(sp.status); expected })
  };

  /// Attach an id the chain already holds for this parent to a spawn that has sent nothing: the
  /// recovery for a child found code-less after its spawn was abandoned on a wrong judgement, or
  /// left behind by the Sep-10 single-message flow. Dual-authorised, because the id is the
  /// operator's claim; what protects the bank is that the id must be unknown here, and that the
  /// install it then receives is refused by the engine if the id holds code it did not expect.
  public func planAttach(s : State, id : AT.SpawnId, cid : AT.Cid) : Result.Result<AT.ArchiveEvent, AT.ArchiveError> {
    let ?sp = spawn(s, id) else return #err(#UnknownSpawn({ spawn = id }));
    switch (sp.status) {
      case (#authorised) {};
      case (_) return #err(notIn(id, sp, "authorised — only a spawn that has sent nothing can take a found id"));
    };
    switch (holder(s, cid)) { case (?h) return #err(#CidKnown({ cid; holder = h })); case null {} };
    #ok(#childRemembered({ spawn = id; cid }))
  };

  // ─── the steps (single-authority methods, driven from outside) ────────────

  /// Step 1. From `#authorised` only: an outstanding create must be resolved first.
  public func planCreate(s : State, id : AT.SpawnId) : Result.Result<AT.ArchiveEvent, AT.ArchiveError> {
    let ?sp = spawn(s, id) else return #err(#UnknownSpawn({ spawn = id }));
    switch (sp.status) {
      case (#authorised) #ok(#createIssued({ spawn = id; attempt = 1 }));
      case (#createIssued(c)) #err(notIn(id, sp, "authorised — a create is outstanding (attempt " # Nat.toText(c.attempts) # "): remember its cid, or abandon the spawn"));
      case (_) #err(notIn(id, sp, "authorised"));
    }
  };

  /// Step 2. From `#createIssued`; the same id offered again for a spawn that already holds it is
  /// accepted and records nothing (`#ok(null)`), so a driver that retries after a crash between the
  /// call and its reply changes nothing.
  public func planRemember(s : State, id : AT.SpawnId, cid : AT.Cid) : Result.Result<?AT.ArchiveEvent, AT.ArchiveError> {
    let ?sp = spawn(s, id) else return #err(#UnknownSpawn({ spawn = id }));
    switch (AT.cidOf(sp.status)) {
      case (?known) { if (known == cid) return #ok(null) else return #err(notIn(id, sp, "createIssued — the spawn already holds cid " # Nat64.toText(known))) };
      case null {};
    };
    switch (sp.status) {
      case (#createIssued(_)) {};
      case (_) return #err(notIn(id, sp, "createIssued"));
    };
    switch (holder(s, cid)) { case (?h) return #err(#CidKnown({ cid; holder = h })); case null {} };
    #ok(?#childRemembered({ spawn = id; cid }))
  };

  /// Step 3. From `#created`, or again from `#installIssued` (a retry with the **same** id; the engine
  /// refuses a second install onto a child that already holds code, which the driver reads as
  /// "installed; confirm it"). The image is the current, sealed pin.
  public func planInstall(s : State, id : AT.SpawnId) : Result.Result<{ event : AT.ArchiveEvent; cid : AT.Cid; image : Blob }, AT.ArchiveError> {
    let ?sp = spawn(s, id) else return #err(#UnknownSpawn({ spawn = id }));
    let ?img = currentImage(s) else return #err(#NoImagePinned);
    switch (img.sealedAt) { case null return #err(#ImageNotSealed({ sha256 = img.sha256 })); case (?_) {} };
    let (cid, attempt) = switch (sp.status) {
      case (#created(c)) (c.cid, 1);
      case (#installIssued(i)) {
        if (i.image != img.sha256) return #err(#ImageMismatch({ pinned = img.sha256; found = i.image }));
        (i.cid, i.attempts + 1)
      };
      case (_) return #err(notIn(id, sp, "created or installIssued"));
    };
    #ok({ event = #installIssued({ spawn = id; cid; image = img.sha256; attempt }); cid; image = img.sha256 })
  };

  /// Step 4. From `#installIssued`. `offered` is the module hash the caller read from the chain.
  /// **Compared against the parent's pin of the image it sent; the marked gap** (`ArchiveTypes.mo`).
  /// A wrong hash is recorded as a refusal and leaves the spawn where the install can be retried;
  /// the empty-module hash in particular means the install did not land.
  public func planConfirm(s : State, id : AT.SpawnId, offered : Blob) : Result.Result<{ event : AT.ArchiveEvent; confirmed : Bool }, AT.ArchiveError> {
    let ?sp = spawn(s, id) else return #err(#UnknownSpawn({ spawn = id }));
    switch (sp.status) {
      case (#installIssued(i)) {
        if (offered == i.image) #ok({ event = #childConfirmed({ spawn = id; cid = i.cid; image = i.image }); confirmed = true })
        else #ok({ event = #confirmRefused({ spawn = id; cid = i.cid; offered }); confirmed = false })
      };
      case (_) #err(notIn(id, sp, "installIssued"));
    }
  };

  /// Step 5. From `#installed`, or again from `#controllersIssued`. The set sent is the parent
  /// itself first; the engine replaces the controller set, so leaving the parent out would strip
  /// it; then the configured principals.
  public func planControllers(s : State, id : AT.SpawnId, self : Principal) : Result.Result<{ event : AT.ArchiveEvent; cid : AT.Cid; controllers : [Principal] }, AT.ArchiveError> {
    let ?sp = spawn(s, id) else return #err(#UnknownSpawn({ spawn = id }));
    if (s.controllers.size() == 0) return #err(#NoControllersSet);
    let (cid, attempt) = switch (sp.status) {
      case (#installed(i)) (i.cid, 1);
      case (#controllersIssued(c)) (c.cid, c.attempts + 1);
      case (_) return #err(notIn(id, sp, "installed or controllersIssued"));
    };
    let set = List.empty<Principal>();
    List.add(set, self);
    for (p in s.controllers.vals()) { if (not Principal.equal(p, self)) List.add(set, p) };
    let controllers = List.toArray(set);
    #ok({ event = #controllersIssued({ spawn = id; cid; controllers; attempt }); cid; controllers })
  };

  /// Step 6. From `#controllersIssued`: the child becomes an archive of this bank. Nothing a contract
  /// can call reports a child's controllers (`ArchiveWire.parseStatusReply`), so this step records
  /// that the driver saw `update_settings` reply; the second place that substrate change closes a gap.
  public func planComplete(s : State, id : AT.SpawnId) : Result.Result<AT.ArchiveEvent, AT.ArchiveError> {
    let ?sp = spawn(s, id) else return #err(#UnknownSpawn({ spawn = id }));
    switch (sp.status) {
      case (#controllersIssued(c)) #ok(#childReady({ spawn = id; cid = c.cid }));
      case (_) #err(notIn(id, sp, "controllersIssued"));
    }
  };

  /// The re-check before each archive write: the chain's hash for a child must
  /// still be the one recorded.
  public func checkChild(s : State, cid : AT.Cid, found : Blob) : Result.Result<{ matches : Bool; recorded : Blob }, AT.ArchiveError> {
    let ?ch = child(s, cid) else return #err(#UnknownChild({ cid }));
    #ok({ matches = found == ch.image; recorded = ch.image })
  };

  // ─── fingerprint ──────────────────────────────────────────────────────────

  func writeStatus(w : C.Writer, st : AT.SpawnStatus) {
    switch (st) {
      case (#authorised) w.byte(0);
      case (#createIssued(c)) { w.byte(1); w.nat(c.attempts) };
      case (#created(c)) { w.byte(2); w.nat64(c.cid) };
      case (#installIssued(i)) { w.byte(3); w.nat64(i.cid); w.blob(i.image); w.nat(i.attempts) };
      case (#installed(i)) { w.byte(4); w.nat64(i.cid); w.blob(i.image) };
      case (#controllersIssued(c)) { w.byte(5); w.nat64(c.cid); w.blob(c.image); w.len16(c.controllers.size()); for (p in c.controllers.vals()) w.principal(p); w.nat(c.attempts) };
      case (#ready(r)) { w.byte(6); w.nat64(r.cid); w.blob(r.image); w.len16(r.controllers.size()); for (p in r.controllers.vals()) w.principal(p) };
      case (#abandoned(a)) { w.byte(7); w.text(a.reason) };
    }
  };

  public func fingerprintInto(w : C.Writer, s : State) {
    w.nat(s.imageCount);
    for ((h, img) in Map.entries(s.images)) { w.blob(h); w.nat(img.bytes); w.text(img.name); w.nat(img.pinnedAt); w.optNat(img.sealedAt) };
    w.optBlob(s.current);
    w.len16(s.controllers.size());
    for (p in s.controllers.vals()) w.principal(p);
    w.nat(s.spawnCount);
    for ((id, sp) in Map.entries(s.spawns)) { w.nat(id); w.text(sp.purpose); writeStatus(w, sp.status); w.nat(sp.lastBlock) };
    w.nat(s.childCount);
    for ((cid, ch) in Map.entries(s.children)) {
      w.nat64(cid); w.blob(ch.image); w.len16(ch.controllers.size()); for (p in ch.controllers.vals()) w.principal(p);
      w.text(ch.purpose); w.optNat(ch.spawn); w.nat(ch.readyAt);
    };
    w.nat(s.refusedConfirmations);
  };
}
