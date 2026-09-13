// Archive.test.mo — the archive spawning flow, interrupted after every step.
//
// The archive rule: "Every step must be safely repeatable and resumable. A
// crash or rollback between any two steps must leave a state the next call can finish, never a
// code-less child the parent does not know. Your incident with child 1000000 is the test case: the
// parent must never lose a cid. Prove it with a test that interrupts after each step."
//
// What is proved here, and what each check exists to stop:
//
//   * a full spawn reaches `#ready` through the six steps, and the fake chain — which decodes every
//     raw frame independently, from the engine's own layouts — ends with exactly one child holding
//     exactly the pinned image and the intended controllers;
//   * after every step the run is cut: the bank's state is thrown away and re-folded from the block
//     log, the driver's memory of the last reply is lost, and the flow still finishes — with the
//     invariant that no id the chain ever gave this parent is unaccounted for;
//   * the create step cannot be repeated while one is outstanding, so a driver that lost the reply
//     cannot make a second orphan — and both recoveries work: finding the id and remembering it, or
//     a dual-authorised abandonment followed by attaching the found id to a fresh spawn;
//   * an install that the chain rejects leaves the spawn where the install can be sent again with
//     the same id, and a confirmation offering the empty-module hash is refused and recorded;
//   * the step table: from every state, every step is either the one allowed next or refused;
//   * the pin cannot move under a spawn in flight; a seal must hash to the pin; an upload cannot
//     exceed it; an adoption needs a pinned hash; an id can have only one holder;
//   * the raw encodings, byte for byte: both endiannesses, the install frame, the 57-byte status
//     reply, the controllers frame;
//   * every archive event and command survives the canonical encoding, and the folded state's
//     fingerprint is the same whether reached live or by replay.
//
// engine: wasi-only — the image store is a Region, and the journal core keeps its per-posting state
// in one; the moc interpreter provides no Region.

import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat64 "mo:core/Nat64";
import Text "mo:core/Text";
import Blob "mo:core/Blob";
import Array "mo:core/Array";
import List "mo:core/List";
import Map "mo:core/Map";
import Principal "mo:core/Principal";
import Sha256 "mo:sha2/Sha256";
import Runtime "mo:core/Runtime";

import JT "mo:journal/JournalTypes";
import JCore "mo:journal/JournalCore";

import T "../src/bank/BankTypes";
import C "../src/bank/BankCanonical";
import Core "../src/bank/BankCore";
import P "../src/bank/Permissions";
import E "../src/bank/Entitlements";
import AT "../src/bank/ArchiveTypes";
import AC "../src/bank/ArchiveCore";
import AW "../src/bank/ArchiveWire";
import AImg "../src/bank/ArchiveImage";
import BankMemLog "support/BankMemLog";
import JMemLog "support/JournalMemLog";

// ─── fixtures ────────────────────────────────────────────────────────────────

/// The parent's principal: a canister id as eight big-endian bytes, as the engine represents it.
let PARENT_ID : Nat64 = 108_729_799_726_739;
let bankP = AW.childPrincipal(PARENT_ID);
let installer = Principal.fromBlob("\1A\01");
let maker = Principal.fromBlob("\2A\01");
let checker = Principal.fromBlob("\3A\01");
let driver = Principal.fromBlob("\4A\01");
let operatorKey = Principal.fromBlob("\6E\3E\78\13\82\8D\F2\C7\FC\7D\B1\EC\56\D1\8D\B5\FC\84\E2\DE\19\FB\D4\05\79\11\2C\D5\02");
let governance = Principal.fromBlob("\7A\01");

let DAY : Nat64 = 86_400_000_000_000;
let clock : Nat64 = 20705 * DAY + 43_200_000_000_000;

// ─── a fake chain: the engine's management contract, decoded from its own layouts ────────────────
//
// Not a mock of what the parent hopes happens: an independent decoder of the raw frames, written
// from `management.rs`, so a frame the parent gets wrong is refused here the way the engine would
// refuse it. Ids are allocated sequentially from 1,000,000 as the engine does (`next_canister_id`).

type Canister = { var wasm : Blob; var controllers : [Principal] };

let chain = {
  var nextId : Nat64 = 1_000_000;
  canisters = Map.empty<Nat64, Canister>();
  /// Every id ever handed out, and to whom. The invariant is checked against this.
  created = List.empty<(Nat64, Principal)>();
  var rejectNextInstall = false;
  var installs = 0;
  var refusedInstalls = 0;
};

func leAt(a : [Nat8], from : Nat, width : Nat) : Nat {
  var v = 0;
  var i = width;
  while (i > 0) { i -= 1; v := v * 256 + Nat8.toNat(a[from + i]) };
  v
};

func chainCreate(caller : Principal) : Blob {
  let id = chain.nextId;
  chain.nextId += 1;
  Map.add(chain.canisters, Nat64.compare, id, { var wasm = "" : Blob; var controllers = [caller] });
  List.add(chain.created, (id, caller));
  // the reply: eight little-endian bytes
  Blob.fromArray(AW.leBytes(Nat64.toNat(id), 8))
};

func chainInstall(frame : Blob) : { #ok; #err : Text } {
  let a = Blob.toArray(frame);
  if (a.size() < 12) return #err("install_code: frame shorter than its header");
  let id = Nat64.fromNat(leAt(a, 0, 8));
  let len = leAt(a, 8, 4);
  if (a.size() != 12 + len) return #err("install_code: wasm_len " # Nat.toText(len) # " does not match the frame; an init argument is not expected");
  let ?c = Map.get(chain.canisters, Nat64.compare, id) else return #err("CanisterNotFound");
  if (c.wasm.size() > 0) { chain.refusedInstalls += 1; return #err("CanisterAlreadyHasWasm") };
  if (chain.rejectNextInstall) { chain.rejectNextInstall := false; chain.refusedInstalls += 1; return #err("install_code: rejected by the test") };
  c.wasm := Blob.fromArray(Array.tabulate<Nat8>(len, func(i) { a[12 + i] }));
  chain.installs += 1;
  #ok
};

func chainStatus(arg : Blob) : Blob {
  let a = Blob.toArray(arg);
  assert (a.size() == 8);
  let id = Nat64.fromNat(leAt(a, 0, 8));
  let ?c = Map.get(chain.canisters, Nat64.compare, id) else { Runtime.trap("status of an unknown canister") };
  let hash = Sha256.fromBlob(#sha256, c.wasm);
  let out = List.empty<Nat8>();
  List.add(out, 1 : Nat8);
  for (b in AW.leBytes(0, 8).vals()) List.add(out, b);            // cycles
  for (b in AW.leBytes(0, 8).vals()) List.add(out, b);            // memory
  for (b in AW.leBytes(c.wasm.size(), 8).vals()) List.add(out, b); // wasm_size
  for (b in hash.vals()) List.add(out, b);
  Blob.fromArray(List.toArray(out))
};

func chainUpdateSettings(caller : Principal, frame : Blob) : { #ok; #err : Text } {
  let a = Blob.toArray(frame);
  if (a.size() < 13) return #err("update_settings: frame shorter than its header");
  let id = Nat64.fromNat(leAt(a, 0, 8));
  if (a[8] != 1) return #err("update_settings: controllers flag not set");
  let n = leAt(a, 9, 4);
  var pos = 13;
  let ps = List.empty<Principal>();
  var i = 0;
  while (i < n) {
    let len = Nat8.toNat(a[pos]);
    pos += 1;
    List.add(ps, Principal.fromBlob(Blob.fromArray(Array.tabulate<Nat8>(len, func(j) { a[pos + j] }))));
    pos += len;
    i += 1;
  };
  if (pos != a.size()) return #err("update_settings: trailing bytes");
  let ?c = Map.get(chain.canisters, Nat64.compare, id) else return #err("CanisterNotFound");
  var authorised = false;
  for (p in c.controllers.vals()) { if (Principal.equal(p, caller)) authorised := true };
  if (not authorised) return #err("update_settings: caller is not a controller of canister " # Nat64.toText(id));
  c.controllers := List.toArray(ps);   // replaced, not added to
  #ok
};

// ─── the bank: log, state, genesis ───────────────────────────────────────────

let bchain = BankMemLog.new();
let jchain = JMemLog.new();
var bs = Core.newState(installer);
let js = JCore.newState(bankP);
let image = AImg.newState();

func bcommit(caller : Principal, e : T.Event) : T.Block { BankMemLog.commit(bchain, bs, clock, caller, e) };
func jcommit(e : JT.Event) : JT.Block { JMemLog.commit(jchain, js, clock, bankP, e) };

func execute(authority : Principal, command : T.Command, authorityIndex : Nat) {
  switch (Core.planCommand(bs, BankMemLog.reader(bchain), js, JMemLog.reader(jchain), bankP, clock, command, authorityIndex)) {
    case (#err(e)) { Debug.print("plan failed: " # debug_show (e)); assert false };
    case (#ok(plan)) {
      switch (plan.bankEvent) { case (?ev) { ignore bcommit(authority, ev) }; case null {} };
      for (ev in plan.extra.vals()) { ignore bcommit(authority, ev) };
      for (step in plan.journal.vals()) { switch (step) { case (#event(ev)) ignore jcommit(ev); case (#existing(_)) {} } };
    };
  }
};

ignore jcommit(switch (JCore.prepareAddPoster(js, bankP, bankP)) { case (#ok(e)) e; case (#err(e)) { Debug.print(debug_show (e)); assert false; #posterAdded({ poster = bankP }) } });
ignore bcommit(installer, #bankAdminTransferred({ admin = installer }));
func genesis(command : T.Command) { execute(installer, command, Core.height(bs)) };

genesis(#openBook({ id = "HQ"; name = "Head office"; parent = null }));
genesis(#defineRole({ id = "checker"; name = "Checker"; permissions = ["command.approve", "command.reject"] }));
genesis(#defineRole({ id = "maker"; name = "Maker"; permissions = ["command.create", "archive.image.pin", "archive.controllers.update", "archive.spawn.authorise", "archive.spawn.abandon", "archive.child.attach", "archive.child.adopt"] }));
// the driver: every step, and nothing dual
let driverPermissions = List.empty<Text>();
for (perm in P.catalogue().vals()) {
  switch (perm.guards) {
    case (#method(_)) { if (Text.startsWith(perm.id, #text "archive.")) List.add(driverPermissions, perm.id) };
    case (#command(_)) {};
  };
};
genesis(#defineRole({ id = "archive-driver"; name = "Archive driver"; permissions = List.toArray(driverPermissions) }));
genesis(#grantRole({ subject = maker; role = "maker"; scope = E.emptyScope() }));
genesis(#grantRole({ subject = checker; role = "checker"; scope = E.emptyScope() }));
genesis(#grantRole({ subject = driver; role = "archive-driver"; scope = E.emptyScope() }));
var archivePolicies = 0;
for (perm in P.catalogue().vals()) {
  if (perm.dualByDefault and Text.startsWith(perm.id, #text "archive.")) {
    genesis(#setDualPolicy({ permission = perm.id; required = 1; eligibleRole = "checker"; ttlSeconds = 3600 }));
    archivePolicies += 1;
  };
};
Debug.print("count: archive permissions under dual policy = " # Nat.toText(archivePolicies));
assert (archivePolicies == 6);
Debug.print("count: archive step methods granted to the driver = " # Nat.toText(List.size(driverPermissions)));
assert (List.size(driverPermissions) == 11);

// ─── the four-eyes path for the decisions ────────────────────────────────────

func fourEyes(command : T.Command) : { ok : Bool; error : ?T.BankError; block : ?Nat } {
  let proposal = switch (Core.prepareProposal(bs, BankMemLog.reader(bchain), js, JMemLog.reader(jchain), bankP, maker, clock, command, "archive test")) {
    case (#ok(out)) bcommit(maker, out.event).index;
    case (#err(r)) return { ok = false; error = ?r.error; block = null };
  };
  switch (Core.prepareApprove(bs, js, JMemLog.reader(jchain), BankMemLog.reader(bchain), bankP, checker, clock, proposal)) {
    case (#err(r)) { { ok = false; error = ?r.error; block = null } };
    case (#ok(out)) {
      ignore bcommit(checker, out.approval);
      let ?ex = out.execute else { Runtime.trap("a required-1 policy executes on approval") };
      let before = Core.height(bs);
      execute(ex.maker, ex.command, ex.proposal);
      ignore bcommit(checker, #commandExecuted({ proposal = ex.proposal; commandHash = ex.commandHash; postings = []; charge = Core.chargeOf(bs, ex.command) }));
      { ok = true; error = null; block = ?before }
    };
  }
};

func mustPass(command : T.Command) : Nat {
  let r = fourEyes(command);
  if (not r.ok) { Debug.print("expected to pass: " # P.commandName(command) # " → " # debug_show (r.error)); assert false };
  let ?b = r.block else { Runtime.trap("no block") };
  b
};

var refusals = 0;
func mustRefuse(command : T.Command, why : Text) {
  let r = fourEyes(command);
  if (r.ok) { Debug.print("expected refusal (" # why # "): " # P.commandName(command)); assert false };
  refusals += 1;
};

// ─── the image ───────────────────────────────────────────────────────────────

// A child that is not a real module — the flow never inspects the bytes, the chain here hashes
// them, and the point is the pin, the seal and the frame. 182 bytes, like the proof's child.wat.
let childWasm : Blob = Blob.fromArray(Array.tabulate<Nat8>(182, func(i) { Nat8.fromNat((i * 7 + 3) % 256) }));
let childHash = Sha256.fromBlob(#sha256, childWasm);

// the encodings, before anything depends on them
assert (AW.leBytes(1_000_002, 8) == [0x42, 0x42, 0x0F, 0, 0, 0, 0, 0]);
assert (AW.beBytes(1_000_002, 8) == [0, 0, 0, 0, 0, 0x0F, 0x42, 0x42]);
assert (AW.leNat([0x42, 0x42, 0x0F, 0, 0, 0, 0, 0]) == 1_000_002);
assert (AW.cidOfPrincipal(AW.childPrincipal(1_000_002)) == ?1_000_002);
assert (AW.cidOfPrincipal(operatorKey) == null);
assert (AW.idArg(1_000_002) == Blob.fromArray([0x42, 0x42, 0x0F, 0, 0, 0, 0, 0]));
switch (AW.parseCreateReply(Blob.fromArray([0x42, 0x42, 0x0F, 0, 0, 0, 0, 0]))) { case (#ok(c)) assert (c == 1_000_002); case (#err(_)) assert false };
switch (AW.parseCreateReply("\42\42\0F")) { case (#ok(_)) assert false; case (#err(_)) {} };
switch (AW.installFrame(1_000_002, childWasm)) {
  case (#err(_)) assert false;
  case (#ok(f)) {
    let a = Blob.toArray(f);
    assert (a.size() == 12 + 182);
    assert (Array.tabulate<Nat8>(8, func(i) { a[i] }) == [0x42, 0x42, 0x0F, 0, 0, 0, 0, 0]);
    assert (Array.tabulate<Nat8>(4, func(i) { a[8 + i] }) == [182, 0, 0, 0]);
    assert (Blob.fromArray(Array.tabulate<Nat8>(182, func(i) { a[12 + i] })) == childWasm);
  };
};
switch (AW.installFrame(1, "" : Blob)) { case (#ok(_)) assert false; case (#err(#ImageInvalid(_))) {}; case (#err(_)) assert false };
assert (AT.MAX_IMAGE_BYTES == AT.WIRE_MAX_PAYLOAD_BYTES - AT.INSTALL_FRAME_OVERHEAD);
switch (AW.installFrame(1, Blob.fromArray(Array.tabulate<Nat8>(AT.MAX_IMAGE_BYTES + 1, func(_) { 0 })))) { case (#ok(_)) assert false; case (#err(#ImageTooLarge(_))) {}; case (#err(_)) assert false };
// the 57-byte status reply, built by hand from the engine's layout
do {
  let out = List.empty<Nat8>();
  List.add(out, 1 : Nat8);
  for (b in AW.leBytes(123_456, 8).vals()) List.add(out, b);
  for (b in AW.leBytes(65_536, 8).vals()) List.add(out, b);
  for (b in AW.leBytes(182, 8).vals()) List.add(out, b);
  for (b in childHash.vals()) List.add(out, b);
  let raw = Blob.fromArray(List.toArray(out));
  assert (raw.size() == AW.STATUS_REPLY_BYTES);
  switch (AW.parseStatusReply(raw)) {
    case (#err(_)) assert false;
    case (#ok(st)) { assert (st.running and st.cycles == 123_456 and st.memoryBytes == 65_536 and st.wasmBytes == 182 and st.moduleHash == childHash) };
  };
  switch (AW.parseStatusReply("\01\02")) { case (#ok(_)) assert false; case (#err(_)) {} };
};
// the controllers frame, decoded by the fake chain's independent parser
switch (AW.controllersFrame(7, [bankP, operatorKey])) {
  case (#err(_)) assert false;
  case (#ok(f)) {
    let a = Blob.toArray(f);
    assert (a.size() == 8 + 1 + 4 + (1 + 8) + (1 + 29));
    assert (a[8] == 1);
    assert (leAt(a, 9, 4) == 2);
    assert (a[13] == 8 and a[22] == 29);
  };
};
switch (AW.controllersFrame(7, [])) { case (#ok(_)) assert false; case (#err(_)) {} };
Debug.print("count: raw encodings checked byte for byte = 14");

// ─── the decisions ───────────────────────────────────────────────────────────

// nothing can be spawned before an image is pinned, sealed, and controllers are set
mustRefuse(#spawnArchive({ purpose = "2026-09 postings" }), "no image pinned");
mustRefuse(#pinArchiveImage({ sha256 = AT.EMPTY_MODULE_HASH; bytes = 1; name = "nothing" }), "the empty hash");
mustRefuse(#pinArchiveImage({ sha256 = "\01\02"; bytes = 1; name = "short" }), "not 32 bytes");
mustRefuse(#pinArchiveImage({ sha256 = childHash; bytes = AT.MAX_IMAGE_BYTES + 1; name = "too big" }), "past the wire cap");
ignore mustPass(#pinArchiveImage({ sha256 = childHash; bytes = 182; name = "archive-child" }));
mustRefuse(#pinArchiveImage({ sha256 = childHash; bytes = 182; name = "archive-child" }), "already current");
mustRefuse(#spawnArchive({ purpose = "2026-09 postings" }), "pinned but not sealed");

// the upload, through the region, exactly as Bank.mo does it
func seal() : { ok : Bool } {
  let computed = AImg.hash(image);
  switch (AC.planSeal(bs.archive, computed, AImg.size(image))) {
    case (#err(_)) { { ok = false } };
    case (#ok(ev)) { ignore bcommit(driver, #archive(ev)); { ok = true } };
  }
};
// a wrong upload cannot be sealed
switch (AImg.append(image, "\00\01\02")) { case (#ok(_)) {}; case (#err(_)) assert false };
assert (not seal().ok);
AImg.reset(image);
assert (AImg.size(image) == 0);
// the right bytes, in two chunks
let a1 = Blob.fromArray(Array.tabulate<Nat8>(100, func(i) { Blob.toArray(childWasm)[i] }));
let a2 = Blob.fromArray(Array.tabulate<Nat8>(82, func(i) { Blob.toArray(childWasm)[100 + i] }));
switch (AImg.append(image, a1)) { case (#ok(n)) assert (n == 100); case (#err(_)) assert false };
switch (AImg.append(image, a2)) { case (#ok(n)) assert (n == 182); case (#err(_)) assert false };
assert (AImg.hash(image) == childHash);
assert (AImg.bytes(image) == childWasm);
assert (seal().ok);
assert (not seal().ok);   // sealed once
switch (AC.currentImage(bs.archive)) { case (?img) { assert (img.sealedAt != null and img.bytes == 182) }; case null assert false };
Debug.print("count: image seals attempted = 3");

mustRefuse(#spawnArchive({ purpose = "2026-09 postings" }), "no controllers set");
mustRefuse(#setArchiveControllers({ controllers = [] }), "empty");
mustRefuse(#setArchiveControllers({ controllers = [operatorKey, operatorKey] }), "duplicate");
mustRefuse(#setArchiveControllers({ controllers = [Principal.fromText("2vxsx-fae")] }), "anonymous");
ignore mustPass(#setArchiveControllers({ controllers = [operatorKey, governance] }));
mustRefuse(#setArchiveControllers({ controllers = [operatorKey, governance] }), "unchanged");

// ─── the driver: Bank.mo's steps, against the fake chain ─────────────────────
//
// Each function is the body of the corresponding Bank.mo method: plan, commit, then the call. The
// call's reply is returned to the caller and **nothing is written after it**, which is the shape
// the engine forces today; a crash between steps is then just the loss of that reply.

type Reply<X> = { #ok : X; #refused : AT.ArchiveError; #chain : Text };

func stepCreate(spawn : Nat) : Reply<Nat64> {
  let ev = switch (AC.planCreate(bs.archive, spawn)) { case (#err(e)) return #refused(e); case (#ok(ev)) ev };
  ignore bcommit(driver, #archive(ev));
  switch (AW.parseCreateReply(chainCreate(bankP))) { case (#ok(c)) #ok(c); case (#err(w)) #chain(w) }
};
func stepRemember(spawn : Nat, cid : Nat64) : Reply<Bool> {
  switch (AC.planRemember(bs.archive, spawn, cid)) {
    case (#err(e)) #refused(e);
    case (#ok(null)) #ok(false);
    case (#ok(?ev)) { ignore bcommit(driver, #archive(ev)); #ok(true) };
  }
};
func stepInstall(spawn : Nat) : Reply<Nat64> {
  let plan = switch (AC.planInstall(bs.archive, spawn)) { case (#err(e)) return #refused(e); case (#ok(p)) p };
  let frame = switch (AW.installFrame(plan.cid, AImg.bytes(image))) { case (#err(e)) return #refused(e); case (#ok(f)) f };
  ignore bcommit(driver, #archive(plan.event));
  switch (chainInstall(frame)) { case (#ok) #ok(plan.cid); case (#err(w)) #chain(w) }
};
func stepStatus(cid : Nat64) : AW.Status {
  switch (AW.parseStatusReply(chainStatus(AW.idArg(cid)))) { case (#ok(st)) st; case (#err(w)) { Debug.print(w); assert false; { running = false; cycles = 0; memoryBytes = 0; wasmBytes = 0; moduleHash = "" } } }
};
func stepConfirm(spawn : Nat, offered : Blob) : Reply<Bool> {
  switch (AC.planConfirm(bs.archive, spawn, offered)) {
    case (#err(e)) #refused(e);
    case (#ok(out)) { ignore bcommit(driver, #archive(out.event)); #ok(out.confirmed) };
  }
};
func stepControllers(spawn : Nat) : Reply<[Principal]> {
  let plan = switch (AC.planControllers(bs.archive, spawn, bankP)) { case (#err(e)) return #refused(e); case (#ok(p)) p };
  let frame = switch (AW.controllersFrame(plan.cid, plan.controllers)) { case (#err(e)) return #refused(e); case (#ok(f)) f };
  ignore bcommit(driver, #archive(plan.event));
  switch (chainUpdateSettings(bankP, frame)) { case (#ok) #ok(plan.controllers); case (#err(w)) #chain(w) }
};
func stepComplete(spawn : Nat) : Reply<()> {
  switch (AC.planComplete(bs.archive, spawn)) {
    case (#err(e)) #refused(e);
    case (#ok(ev)) { ignore bcommit(driver, #archive(ev)); #ok(()) };
  }
};

func status(spawn : Nat) : Text {
  switch (AC.spawn(bs.archive, spawn)) { case (?sp) AT.statusName(sp.status); case null "unknown" }
};

/// The crash: the folded state is thrown away and rebuilt from the block log. Whatever the driver
/// remembered is the caller's business and is deliberately not carried.
var crashes = 0;
func crash() {
  let fp = Core.fingerprint(bs);
  bs := Core.replay(installer, BankMemLog.blocks(bchain));
  assert (Core.fingerprint(bs) == fp);
  crashes += 1;
};

/// The invariant, checked against the chain's own record of who was given what: every id the chain
/// created for this parent is either held by a spawn or a child, or its spawn is marked
/// `#createIssued` — visible, never silent.
var invariantChecks = 0;
func invariant() {
  var outstanding = 0;
  for ((_, sp) in Map.entries(bs.archive.spawns)) {
    switch (sp.status) { case (#createIssued(_)) outstanding += 1; case (_) {} };
  };
  var unheld = 0;
  for ((id, who) in List.values(chain.created)) {
    if (Principal.equal(who, bankP)) {
      switch (AC.holder(bs.archive, id)) { case (?_) {}; case null unheld += 1 };
    };
  };
  // an unheld id must be explained by an outstanding create, or by an abandonment whose id was
  // later attached (which makes it held) — so unheld ≤ outstanding + abandoned-and-not-attached
  var abandoned = 0;
  for ((_, sp) in Map.entries(bs.archive.spawns)) {
    switch (sp.status) { case (#abandoned(_)) abandoned += 1; case (_) {} };
  };
  if (unheld > outstanding + abandoned) { Debug.print("INVARIANT: " # Nat.toText(unheld) # " ids unheld, " # Nat.toText(outstanding) # " creates outstanding"); assert false };
  invariantChecks += 1;
};

// ─── run 1: the whole flow, cut after every step ─────────────────────────────

let spawn1 = mustPass(#spawnArchive({ purpose = "2026-09 postings" }));
assert (status(spawn1) == "authorised");
// the pin cannot move under a spawn that is in flight — but an authorised, unsent spawn is not yet
mustRefuse(#spawnArchive({ purpose = "" }), "empty purpose");

// step 1
let cid1 = switch (stepCreate(spawn1)) { case (#ok(c)) c; case (other) { Debug.print(debug_show (other)); assert false; 0 : Nat64 } };
assert (cid1 == 1_000_000);
assert (status(spawn1) == "createIssued");
crash(); invariant();
// a second create is refused while this one is outstanding — the driver cannot make a second orphan
switch (stepCreate(spawn1)) { case (#refused(#SpawnNotIn(_))) {}; case (other) { Debug.print(debug_show (other)); assert false } };
assert (chain.nextId == 1_000_001);
// the pin cannot move now
mustRefuse(#pinArchiveImage({ sha256 = Sha256.fromBlob(#sha256, "\01"); bytes = 1; name = "other" }), "spawn in flight");
// an install before the id is remembered is refused
switch (stepInstall(spawn1)) { case (#refused(#SpawnNotIn(_))) {}; case (other) { Debug.print(debug_show (other)); assert false } };

// step 2 — the driver lost the reply in the crash; it reads the id back from the chain (here: the
// chain's record; on the substrate: canister_status of the ids after the last known one)
let found1 = List.last(chain.created);
let recovered1 = switch (found1) { case (?(id, _)) id; case null { assert false; 0 : Nat64 } };
assert (recovered1 == cid1);
switch (stepRemember(spawn1, recovered1)) { case (#ok(true)) {}; case (other) { Debug.print(debug_show (other)); assert false } };
assert (status(spawn1) == "created");
crash(); invariant();
// again: the same id records nothing; a different id is refused
switch (stepRemember(spawn1, recovered1)) { case (#ok(false)) {}; case (other) { Debug.print(debug_show (other)); assert false } };
switch (stepRemember(spawn1, 999)) { case (#refused(#SpawnNotIn(_))) {}; case (other) { Debug.print(debug_show (other)); assert false } };
// and a spawn that knows an id can never be abandoned
mustRefuse(#abandonArchiveSpawn({ spawn = spawn1; reason = "no" }), "a spawn with an id");

// step 3 — the chain rejects the first install
chain.rejectNextInstall := true;
switch (stepInstall(spawn1)) { case (#chain(_)) {}; case (other) { Debug.print(debug_show (other)); assert false } };
assert (status(spawn1) == "installIssued");
crash(); invariant();
// the child holds no code: a confirmation offering what the chain reports is refused and recorded
let st0 = stepStatus(cid1);
assert (st0.moduleHash == AT.EMPTY_MODULE_HASH and st0.wasmBytes == 0);
switch (stepConfirm(spawn1, st0.moduleHash)) { case (#ok(false)) {}; case (other) { Debug.print(debug_show (other)); assert false } };
assert (status(spawn1) == "installIssued");
assert (AC.counts(bs.archive).refusedConfirmations == 1);
// the install is sent again, with the same id
switch (stepInstall(spawn1)) { case (#ok(c)) assert (c == cid1); case (other) { Debug.print(debug_show (other)); assert false } };
switch (AC.spawn(bs.archive, spawn1)) { case (?sp) { switch (sp.status) { case (#installIssued(i)) assert (i.attempts == 2); case (_) assert false } }; case null assert false };
crash(); invariant();
// a third install is refused by the chain — the child holds code — which the driver reads as "confirm"
switch (stepInstall(spawn1)) { case (#chain(w)) assert (Text.equal(w, "CanisterAlreadyHasWasm")); case (other) { Debug.print(debug_show (other)); assert false } };
crash(); invariant();

// step 4 — a wrong hash is refused; the chain's hash, which is the pin, confirms
switch (stepConfirm(spawn1, Sha256.fromBlob(#sha256, "\FF"))) { case (#ok(false)) {}; case (other) { Debug.print(debug_show (other)); assert false } };
let st1 = stepStatus(cid1);
assert (st1.moduleHash == childHash and st1.wasmBytes == 182);
switch (stepConfirm(spawn1, st1.moduleHash)) { case (#ok(true)) {}; case (other) { Debug.print(debug_show (other)); assert false } };
assert (status(spawn1) == "installed");
crash(); invariant();
switch (stepConfirm(spawn1, st1.moduleHash)) { case (#refused(#SpawnNotIn(_))) {}; case (other) { Debug.print(debug_show (other)); assert false } };
// the pin may move again once the child holds the confirmed image — but not to the same pin
mustRefuse(#pinArchiveImage({ sha256 = childHash; bytes = 182; name = "archive-child" }), "already current");

// step 5 — controllers: the parent first, then the configured set; the chain checks the caller
switch (stepControllers(spawn1)) {
  case (#ok(cs)) { assert (cs.size() == 3 and Principal.equal(cs[0], bankP) and Principal.equal(cs[1], operatorKey) and Principal.equal(cs[2], governance)) };
  case (other) { Debug.print(debug_show (other)); assert false };
};
assert (status(spawn1) == "controllersIssued");
crash(); invariant();
// again, after the crash: the parent listed itself, so it is still a controller and the call lands
switch (stepControllers(spawn1)) { case (#ok(_)) {}; case (other) { Debug.print(debug_show (other)); assert false } };
switch (Map.get(chain.canisters, Nat64.compare, cid1)) { case (?c) assert (c.controllers.size() == 3); case null assert false };

// step 6
switch (stepComplete(spawn1)) { case (#ok(_)) {}; case (other) { Debug.print(debug_show (other)); assert false } };
assert (status(spawn1) == "ready");
crash(); invariant();
switch (AC.child(bs.archive, cid1)) {
  case (?ch) { assert (ch.image == childHash and ch.spawn == ?spawn1 and ch.controllers.size() == 3 and Text.equal(ch.purpose, "2026-09 postings")) };
  case null assert false;
};
switch (AC.checkChild(bs.archive, cid1, stepStatus(cid1).moduleHash)) { case (#ok(r)) assert (r.matches); case (#err(_)) assert false };
switch (AC.checkChild(bs.archive, cid1, AT.EMPTY_MODULE_HASH)) { case (#ok(r)) assert (not r.matches); case (#err(_)) assert false };
Debug.print("count: spawns brought to ready through every step = 1");

// ─── run 2: the other recovery — abandon the create, attach the found id to a fresh spawn ──────

let spawn2 = mustPass(#spawnArchive({ purpose = "2026-10 postings" }));
let cid2 = switch (stepCreate(spawn2)) { case (#ok(c)) c; case (other) { Debug.print(debug_show (other)); assert false; 0 : Nat64 } };
assert (cid2 == 1_000_001);
crash(); invariant();
// the operator judges (wrongly, as it turns out) that the create made nothing
ignore mustPass(#abandonArchiveSpawn({ spawn = spawn2; reason = "the create call was reported rejected" }));
assert (status(spawn2) == "abandoned");
crash(); invariant();
switch (stepCreate(spawn2)) { case (#refused(#SpawnNotIn(_))) {}; case (other) { Debug.print(debug_show (other)); assert false } };
// the child is found code-less on the chain; a fresh spawn takes it, dual-authorised
let spawn3 = mustPass(#spawnArchive({ purpose = "2026-10 postings, retry" }));
mustRefuse(#attachArchiveChild({ spawn = spawn3; cid = cid1 }), "an id a child holds");
mustRefuse(#attachArchiveChild({ spawn = spawn1; cid = cid2 }), "a spawn that is not authorised");
ignore mustPass(#attachArchiveChild({ spawn = spawn3; cid = cid2 }));
assert (status(spawn3) == "created");
crash(); invariant();
mustRefuse(#attachArchiveChild({ spawn = spawn3; cid = cid2 }), "attached twice");
switch (stepInstall(spawn3)) { case (#ok(c)) assert (c == cid2); case (other) { Debug.print(debug_show (other)); assert false } };
switch (stepConfirm(spawn3, stepStatus(cid2).moduleHash)) { case (#ok(true)) {}; case (other) { Debug.print(debug_show (other)); assert false } };
switch (stepControllers(spawn3)) { case (#ok(_)) {}; case (other) { Debug.print(debug_show (other)); assert false } };
switch (stepComplete(spawn3)) { case (#ok(_)) {}; case (other) { Debug.print(debug_show (other)); assert false } };
assert (status(spawn3) == "ready");
crash(); invariant();
Debug.print("count: spawns recovered by abandon-and-attach = 1");

// ─── run 3: the step table — from every state, every step is allowed or refused as documented ──

// A fresh spawn walked through the states; at each state every step is tried, and the one that is
// allowed next is the only one that is not refused (the create step is tried on a copy of the
// question, since a create that is allowed changes the chain).
let steps = ["create", "remember", "install", "confirm", "controllers", "complete"];
func tryStep(name : Text, spawn : Nat, cid : Nat64, hash : Blob) : Bool {
  switch (name) {
    case "create" { switch (AC.planCreate(bs.archive, spawn)) { case (#ok(_)) true; case (#err(_)) false } };
    case "remember" { switch (AC.planRemember(bs.archive, spawn, cid)) { case (#ok(?_)) true; case (#ok(null)) false; case (#err(_)) false } };  // the same id again is a no-op, not a step
    case "install" { switch (AC.planInstall(bs.archive, spawn)) { case (#ok(_)) true; case (#err(_)) false } };
    case "confirm" { switch (AC.planConfirm(bs.archive, spawn, hash)) { case (#ok(_)) true; case (#err(_)) false } };
    case "controllers" { switch (AC.planControllers(bs.archive, spawn, bankP)) { case (#ok(_)) true; case (#err(_)) false } };
    case "complete" { switch (AC.planComplete(bs.archive, spawn)) { case (#ok(_)) true; case (#err(_)) false } };
    case _ { assert false; false };
  }
};
func allowedFrom(state : Text) : [Text] {
  switch (state) {
    case "authorised" ["create"];
    case "createIssued" ["remember"];
    case "created" ["install"];
    case "installIssued" ["install", "confirm"];
    case "installed" ["controllers"];
    case "controllersIssued" ["controllers", "complete"];
    case "ready" [];
    case _ { assert false; [] };
  }
};
var tableChecks = 0;
func checkTable(spawn : Nat, cid : Nat64) {
  let state = status(spawn);
  let allowed = allowedFrom(state);
  for (st in steps.vals()) {
    let expected = Array.find<Text>(allowed, func(a) { Text.equal(a, st) }) != null;
    let actual = tryStep(st, spawn, cid, childHash);
    if (expected != actual) { Debug.print("step table: from " # state # ", " # st # " expected " # debug_show (expected)); assert false };
    tableChecks += 1;
  };
};
let spawn4 = mustPass(#spawnArchive({ purpose = "step table" }));
checkTable(spawn4, 1_000_002);
let cid4 = switch (stepCreate(spawn4)) { case (#ok(c)) c; case (_) { assert false; 0 : Nat64 } };
checkTable(spawn4, cid4);
ignore stepRemember(spawn4, cid4); checkTable(spawn4, cid4);
ignore stepInstall(spawn4); checkTable(spawn4, cid4);
ignore stepConfirm(spawn4, stepStatus(cid4).moduleHash); checkTable(spawn4, cid4);
ignore stepControllers(spawn4); checkTable(spawn4, cid4);
ignore stepComplete(spawn4); checkTable(spawn4, cid4);
crash(); invariant();
Debug.print("count: step-table cells checked = " # Nat.toText(tableChecks));
assert (tableChecks == 7 * 6);

// ─── route 2: adoption ───────────────────────────────────────────────────────

// a child the operator deployed: created and installed outside the flow, with an image that is a pin
let adopted = switch (AW.parseCreateReply(chainCreate(operatorKey))) { case (#ok(c)) c; case (#err(_)) { assert false; 0 : Nat64 } };
switch (AW.installFrame(adopted, childWasm)) { case (#ok(f)) { switch (chainInstall(f)) { case (#ok) {}; case (#err(_)) assert false } }; case (#err(_)) assert false };
mustRefuse(#adoptArchiveChild({ cid = adopted; moduleHash = AT.EMPTY_MODULE_HASH; controllers = [operatorKey]; purpose = "operator-deployed" }), "the empty hash");
mustRefuse(#adoptArchiveChild({ cid = adopted; moduleHash = Sha256.fromBlob(#sha256, "\AA"); controllers = [operatorKey]; purpose = "operator-deployed" }), "not a pin");
mustRefuse(#adoptArchiveChild({ cid = cid1; moduleHash = childHash; controllers = [operatorKey]; purpose = "operator-deployed" }), "held already");
mustRefuse(#adoptArchiveChild({ cid = adopted; moduleHash = childHash; controllers = []; purpose = "operator-deployed" }), "no controllers");
ignore mustPass(#adoptArchiveChild({ cid = adopted; moduleHash = stepStatus(adopted).moduleHash; controllers = [operatorKey, bankP]; purpose = "operator-deployed" }));
switch (AC.child(bs.archive, adopted)) { case (?ch) assert (ch.spawn == null and ch.image == childHash); case null assert false };
crash(); invariant();
Debug.print("count: children adopted on route 2 = 1");

// ─── the chain's view at the end ─────────────────────────────────────────────

var withCode = 0;
var codeless = 0;
for ((id, c) in Map.entries(chain.canisters)) {
  if (c.wasm.size() == 0) codeless += 1 else { assert (c.wasm == childWasm); withCode += 1 };
};
assert (codeless == 0);
assert (withCode == 4);
assert (AC.counts(bs.archive).children == 4);
assert (AC.counts(bs.archive).inFlight == 0);
assert (AC.counts(bs.archive).spawns == 4);
Debug.print("count: children on the chain, none code-less = " # Nat.toText(withCode));
Debug.print("count: crashes survived = " # Nat.toText(crashes));
Debug.print("count: invariant checks = " # Nat.toText(invariantChecks));
Debug.print("count: dual-authorised refusals = " # Nat.toText(refusals));
Debug.print("count: installs the chain refused = " # Nat.toText(chain.refusedInstalls));

// ─── paging ──────────────────────────────────────────────────────────────────
var seen = 0;
var cursor : ?Nat = null;
var pages = 0;
label paging loop {
  let pg = AC.listSpawnsPaged(bs.archive, cursor, 3);
  seen += pg.rows.size();
  pages += 1;
  switch (pg.cursor) { case null break paging; case (?c) cursor := ?c };
};
assert (seen == 4 and pages == 2);
let kids = AC.listChildrenPaged(bs.archive, null, 10);
assert (kids.rows.size() == 4 and kids.cursor == null and kids.total == 4);
Debug.print("count: spawns walked by cursor = " # Nat.toText(seen));

// ─── every event and command survives the canonical encoding ─────────────────

let archiveEvents : [T.Event] = [
  #archive(#imagePinned({ sha256 = childHash; bytes = 182; name = "archive-child" })),
  #archive(#imageSealed({ sha256 = childHash; bytes = 182 })),
  #archive(#controllersSet({ controllers = [operatorKey, governance] })),
  #archive(#spawnAuthorised({ purpose = "2026-09 postings" })),
  #archive(#createIssued({ spawn = 9; attempt = 2 })),
  #archive(#childRemembered({ spawn = 9; cid = 1_000_002 })),
  #archive(#installIssued({ spawn = 9; cid = 1_000_002; image = childHash; attempt = 1 })),
  #archive(#childConfirmed({ spawn = 9; cid = 1_000_002; image = childHash })),
  #archive(#confirmRefused({ spawn = 9; cid = 1_000_002; offered = AT.EMPTY_MODULE_HASH })),
  #archive(#controllersIssued({ spawn = 9; cid = 1_000_002; controllers = [bankP, operatorKey]; attempt = 1 })),
  #archive(#childReady({ spawn = 9; cid = 1_000_002 })),
  #archive(#spawnAbandoned({ spawn = 9; reason = "rejected" })),
  #archive(#childAdopted({ cid = 7; image = childHash; controllers = [operatorKey]; purpose = "operator-deployed" })),
];
var roundTrips = 0;
for (e in archiveEvents.vals()) {
  let enc = C.encodeBlock(roundTrips, clock, driver, null, e);
  switch (C.decodeBlock(enc.bytes)) { case (?b) assert (b.event == e); case null { Debug.print("decode failed: " # debug_show (e)); assert false } };
  roundTrips += 1;
};
let archiveCommands : [T.Command] = [
  #pinArchiveImage({ sha256 = childHash; bytes = 182; name = "archive-child" }),
  #setArchiveControllers({ controllers = [operatorKey, governance] }),
  #spawnArchive({ purpose = "2026-09 postings" }),
  #abandonArchiveSpawn({ spawn = 9; reason = "rejected" }),
  #attachArchiveChild({ spawn = 9; cid = 1_000_001 }),
  #adoptArchiveChild({ cid = 7; moduleHash = childHash; controllers = [operatorKey]; purpose = "operator-deployed" }),
];
for (c in archiveCommands.vals()) {
  let e : T.Event = #commandProposed({ command = ?c; commandHash = C.commandHash(c); commandEncoding = 2 : Nat8; permission = P.commandName(c); book = null; maker; required = 1; eligibleRole = "checker"; expiresAt = clock; justification = "x" });
  let enc = C.encodeBlock(roundTrips, clock, maker, null, e);
  switch (C.decodeBlock(enc.bytes)) { case (?b) assert (b.event == e); case null { Debug.print("decode failed: " # P.commandName(c)); assert false } };
  roundTrips += 1;
};
Debug.print("count: archive events and commands round-tripped = " # Nat.toText(roundTrips));
assert (roundTrips == 13 + 6);

// the live fold and the replayed fold agree on everything, and the bank's fingerprint moved
let replayed = Core.replay(installer, BankMemLog.blocks(bchain));
assert (Core.fingerprint(replayed) == Core.fingerprint(bs));
assert (Core.fingerprint(replayed) != Core.fingerprint(Core.newState(installer)));
Debug.print("count: bank blocks written by the archive battery = " # Nat.toText(BankMemLog.blocks(bchain).size()));
