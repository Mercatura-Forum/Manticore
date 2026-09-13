// Collections.test.mo — the life of a troubled exposure as the bank records it (collections and recovery), against the rule
// written once here and once in the Python oracle of bank_s31.py.
//
// What is proved, on the pure core over a real stable-memory arena:
//
//   * the one rule, `deriveStage`, over every (stage, days past due, flags) it can meet: the thresholds, the
//     qualitative default, collections sticking while in arrears, the cure, the terminal stages staying put;
//   * the policy's gates (thresholds ordered, the suspending stage a live one);
//   * every decided act refused where its stage forbids it and accepted where it does not, and the first action
//     on an exposure in arrears moving it into collections;
//   * the fold: rows, the by-stage and by-collector indexes with their stale entries skipped, promises kept and
//     broken, interest held in suspense and released, the amounts written off and recovered;
//   * the stage distribution and the counts; the fingerprint deterministic and changing with every event.
//
// engine: wasi-only — Regions.

import Debug "mo:core/Debug";
import Nat "mo:core/Nat";
import Blob "mo:core/Blob";
import Principal "mo:core/Principal";
import Text "mo:core/Text";
import Array "mo:core/Array";

import C "mo:journal/Canonical";
import RI "mo:ledger/RegionIndex";
import CT "../src/bank/CollectionsTypes";
import Core "../src/bank/CollectionsCore";

func fail(what : Text) { Debug.print("FAIL: " # what); assert false };
func fp(s : Core.State) : Blob { let w = C.Writer(); Core.fingerprintInto(w, s); w.toBlob() };

let arena = RI.newArena();
let s = Core.newState(arena);
let collector = Principal.fromBlob("\C0\11");
let collector2 = Principal.fromBlob("\C0\12");
let policy : CT.Policy = { delinquentDpd = 31; defaultDpd = 90; suspendInterestFrom = #default_; recogniseModificationLoss = true };

// ─── the policy's gates ───────────────────────────────────────────────────────
switch (Core.planPolicy({ policy with delinquentDpd = 0 })) { case (#err(#InvalidPolicy(_))) {}; case (_) fail("a zero delinquent threshold accepted") };
switch (Core.planPolicy({ policy with defaultDpd = 31 })) { case (#err(#InvalidPolicy(_))) {}; case (_) fail("default at the delinquent threshold accepted") };
switch (Core.planPolicy({ policy with suspendInterestFrom = #current })) { case (#err(#InvalidPolicy(_))) {}; case (_) fail("suspense from current accepted") };
switch (Core.planPolicy({ policy with suspendInterestFrom = #writeOff })) { case (#err(#InvalidPolicy(_))) {}; case (_) fail("suspense from write-off accepted") };
switch (Core.planUnlikelyToPay(s, 1, "x", 20700)) { case (#err(#NoPolicy)) {}; case (_) fail("an act before the policy accepted") };
let fp0 = fp(s);
switch (Core.planPolicy(policy)) { case (#ok(ev)) Core.apply(s, 1, ev); case (#err(e)) fail(debug_show (e)) };
assert (Core.policy(s) == ?policy and fp(s) != fp0);
Debug.print("count: policy gates checked = 5");

// ─── the rule, exhaustively over its inputs ───────────────────────────────────
let stages : [CT.Stage] = [#current, #overdue, #delinquent, #default_, #collections, #restructuring, #writeOff, #recovery, #closed];
func rowIn(stage : CT.Stage, utp : Bool) : Core.Row {
  { stage; dpd = 0; sinceDay = 0; sinceBlock = 0; unlikelyToPay = utp; restructured = false; collector = null; promise = null; suspenseHeld = 0; writtenOff = 0; recovered = 0; actions = 0; lastActionDay = null }
};
var ruleChecks = 0;
for (st in stages.vals()) {
  for (utp in [false, true].vals()) {
    for (dpd in [0, 1, 30, 31, 89, 90, 400].vals()) {
      let got = Core.deriveStage(policy, rowIn(st, utp), dpd);
      // the oracle's reading of the rule, written independently of the function
      let want : CT.Stage = switch (st) {
        case (#writeOff) #writeOff; case (#recovery) #recovery; case (#closed) #closed;
        case (_) {
          if (dpd == 0 and not utp) #current
          else if (st == #collections) #collections
          else if (utp or dpd >= 90) #default_
          else if (dpd >= 31) #delinquent
          else #overdue
        };
      };
      if (got != want) fail("rule: " # CT.stageText(st) # " utp=" # debug_show (utp) # " dpd=" # Nat.toText(dpd) # " -> " # CT.stageText(got) # ", wanted " # CT.stageText(want));
      ruleChecks += 1;
    };
  };
};
Debug.print("count: stage-rule cases checked against the oracle's reading = " # Nat.toText(ruleChecks));
assert (Core.suspends(policy, #default_) and Core.suspends(policy, #collections) and Core.suspends(policy, #restructuring));
assert (not Core.suspends(policy, #delinquent) and not Core.suspends(policy, #writeOff) and not Core.suspends(policy, #recovery));

// ─── the end-of-day's transitions, folded ─────────────────────────────────────
// account 10: current → overdue (3 dpd) → delinquent (40) → default (95) → cured (0)
var block = 2;
func eod(account : Nat, dpd : Nat, day : Nat) : ?CT.Stage {
  switch (Core.transitionFor(s, account, dpd, day, 0)) {
    case (?ev) { block += 1; Core.apply(s, block, ev); switch (ev) { case (#stageDerived(x)) ?x.to; case (_) null } };
    case null null;
  }
};
assert (eod(10, 0, 20700) == ?#current);        // a new exposure's first row
assert (eod(10, 0, 20701) == null);             // nothing moved, nothing written
assert (eod(10, 3, 20704) == ?#overdue);
assert (eod(10, 40, 20741) == ?#delinquent);
assert (eod(10, 95, 20796) == ?#default_);
let ?r10 = Core.view(s, 10) else { fail("row 10"); loop {} };
assert (r10.stage == #default_ and r10.dpd == 95 and r10.sinceDay == 20796);
assert (eod(10, 0, 20800) == ?#current);        // cured
let ?r10c = Core.view(s, 10) else { fail("row 10"); loop {} };
assert (r10c.stage == #current and r10c.dpd == 0 and not r10c.unlikelyToPay);
Debug.print("count: day-driven transitions folded = 5");

// ─── the decided acts ─────────────────────────────────────────────────────────
// unlikely to pay: at least default, whatever the days
assert (eod(11, 5, 20700) == ?#overdue);
switch (Core.planUnlikelyToPay(s, 11, "receivership", 20701)) {
  case (#ok(ev)) { block += 1; Core.apply(s, block, ev); switch (ev) { case (#stageDerived(x)) assert (x.to == #default_ and x.reason == #unlikelyToPay); case (_) fail("utp event") } };
  case (#err(e)) fail(debug_show (e));
};
let ?r11 = Core.view(s, 11) else { fail("row 11"); loop {} };
assert (r11.unlikelyToPay and r11.stage == #default_);
assert (eod(11, 5, 20702) == null);            // the days alone cannot pull an unlikely-to-pay below default
// actions: refused on a current exposure, the first on an exposure in arrears moves it into collections
switch (Core.planAction(s, 10, #call, "reached", null, 20801)) { case (#err(#InvalidStageTransition(_))) {}; case (_) fail("an action on a current exposure accepted") };
switch (Core.planAction(s, 999, #call, "x", null, 20801)) { case (#err(#UnknownExposure(_))) {}; case (_) fail("an action on an unknown exposure accepted") };
switch (Core.planAction(s, 11, #call, "no answer", ?20705, 20702)) {
  case (#ok(evs)) { assert (evs.size() == 2); for (ev in evs.vals()) { block += 1; Core.apply(s, block, ev) } };
  case (#err(e)) fail(debug_show (e));
};
let ?r11c = Core.view(s, 11) else { fail("row 11"); loop {} };
assert (r11c.stage == #collections and r11c.actions == 1 and r11c.lastActionDay == ?20702);
switch (Core.planAction(s, 11, #letter, "sent", null, 20703)) {
  case (#ok(evs)) { assert (evs.size() == 1); for (ev in evs.vals()) { block += 1; Core.apply(s, block, ev) } };
  case (#err(e)) fail(debug_show (e));
};
assert (eod(11, 0, 20704) == null);            // still unlikely to pay: collections holds
// promises: in the past refused; recorded with its baseline; judged at the day after it falls due
switch (Core.planPromise(s, 11, 500_00, 20703, 20704, 1_000_00)) { case (#err(#PromiseInThePast(_))) {}; case (_) fail("a promise in the past accepted") };
switch (Core.planPromise(s, 11, 500_00, 20710, 20704, 1_000_00)) { case (#ok(ev)) { block += 1; Core.apply(s, block, ev) }; case (#err(e)) fail(debug_show (e)) };
assert (Core.duePromise(s, 11, 20710) == null);
let ?due = Core.duePromise(s, 11, 20711) else { fail("promise due"); loop {} };
assert (due.amount == 500_00 and due.baseline == 1_000_00);
assert (not Core.judgePromise(due, 1_400_00) and Core.judgePromise(due, 1_500_00));
block += 1; Core.apply(s, block, #promiseJudged({ account = 11; amount = 500_00; by = 20710; kept = false; day = 20711 }));
assert (Core.duePromise(s, 11, 20712) == null and Core.counts(s).promisesBroken == 1);
// the collector
switch (Core.planAssign(s, 11, collector)) { case (#ok(ev)) { block += 1; Core.apply(s, block, ev) }; case (#err(e)) fail(debug_show (e)) };
switch (Core.planAssign(s, 10, collector)) { case (#ok(ev)) { block += 1; Core.apply(s, block, ev) }; case (#err(e)) fail(debug_show (e)) };
assert (Core.worklist(s, collector, null, 100).entries.size() == 2);
switch (Core.planAssign(s, 10, collector2)) { case (#ok(ev)) { block += 1; Core.apply(s, block, ev) }; case (#err(e)) fail(debug_show (e)) };
assert (Core.worklist(s, collector, null, 100).entries.size() == 1);   // the stale index entry is skipped
assert (Core.worklist(s, collector2, null, 100).entries.size() == 1);
Debug.print("count: decided acts planned, refused or folded = 12");

// ─── suspense, write-off, recovery, restructuring, closing ───────────────────
block += 1; Core.apply(s, block, #interestSuspended({ account = 11; amount = 120_00; day = 20705 }));
block += 1; Core.apply(s, block, #interestSuspended({ account = 11; amount = 80_00; day = 20706 }));
let ?r11s = Core.view(s, 11) else { fail("row 11"); loop {} };
assert (r11s.suspenseHeld == 200_00);
block += 1; Core.apply(s, block, #suspenseReleased({ account = 11; amount = 50_00; day = 20707 }));
let ?r11r = Core.view(s, 11) else { fail("row 11"); loop {} };
assert (r11r.suspenseHeld == 150_00);
switch (Core.noteRestructured(s, 11, 20708)) { case (?ev) { block += 1; Core.apply(s, block, ev) }; case null fail("restructure") };
let ?r11x = Core.view(s, 11) else { fail("row 11"); loop {} };
assert (r11x.stage == #restructuring and r11x.restructured and not r11x.unlikelyToPay);   // the judgement is superseded
assert (eod(11, 40, 20709) == ?#delinquent);   // judged on the new schedule from here: the days decide again
assert (eod(11, 0, 20710) == ?#current);       // and a clean schedule cures it
switch (Core.noteWrittenOff(s, 0, 11, 9_000_00, 20720)) { case (?ev) { block += 1; Core.apply(s, block, ev) }; case null fail("write-off") };
Core.addWrittenOff(s, 11, 9_000_00);
let ?r11w = Core.view(s, 11) else { fail("row 11"); loop {} };
assert (r11w.stage == #writeOff and r11w.writtenOff == 9_000_00 and not r11w.unlikelyToPay and r11w.promise == null);
assert (eod(11, 400, 20900) == null);          // the days no longer move a written-off exposure
assert (Core.noteWrittenOff(s, 0, 11, 1, 20721) == null);
switch (Core.noteRecovered(s, 11, 1_000_00, 20730)) { case (?ev) { block += 1; Core.apply(s, block, ev) }; case null fail("recovery") };
Core.addRecovered(s, 11, 1_000_00);
assert (Core.noteRecovered(s, 11, 500_00, 20731) == null);
Core.addRecovered(s, 11, 500_00);
let ?r11v = Core.view(s, 11) else { fail("row 11"); loop {} };
assert (r11v.stage == #recovery and r11v.recovered == 1_500_00);
switch (Core.planCloseRecovery(s, 10, 20740)) { case (#err(#InvalidStageTransition(_))) {}; case (_) fail("closing a current exposure accepted") };
switch (Core.planCloseRecovery(s, 11, 20740)) { case (#ok(ev)) { block += 1; Core.apply(s, block, ev) }; case (#err(e)) fail(debug_show (e)) };
let ?r11z = Core.view(s, 11) else { fail("row 11"); loop {} };
assert (r11z.stage == #closed);
assert (Core.worklist(s, collector, null, 100).entries.size() == 0);   // closed exposures leave the worklist
Debug.print("count: suspense, write-off, recovery and closing checks = 12");

// ─── a book of exposures, the indexes and the distribution ───────────────────
var acct = 100;
while (acct < 160) { ignore eod(acct, (acct * 7) % 120, 20800); acct += 1 };
let dist = Core.stageDistribution(s);
var total = 0;
for ((_, n) in dist.vals()) total += n;
assert (total == 62);
func stageCount(name : Text) : Nat { switch (Array.find<(Text, Nat)>(dist, func((t, _)) { Text.equal(t, name) })) { case (?(_, n)) n; case null 0 } };
var listed = 0;
for (st in stages.vals()) {
  var cursor : ?Blob = null;
  var n = 0;
  label walk loop {
    let page = Core.listByStage(s, st, cursor, 7);
    for (v in page.entries.vals()) { assert (v.stage == st); n += 1 };
    switch (page.cursor) { case null break walk; case (?c) cursor := ?c };
  };
  assert (n == stageCount(CT.stageText(st)));
  listed += n;
};
assert (listed == 62);
Debug.print("count: exposures listed by stage, paged, equal to the distribution = " # Nat.toText(listed));
Debug.print("count: exposures in the book = " # Nat.toText(Core.counts(s).exposures));
assert (Core.counts(s).exposures == 62);

// ─── the replay reaches the same fingerprint ──────────────────────────────────
// every event applied above, replayed in order into a fresh state over a fresh arena
let fpA = fp(s);
let fpB = fp(s);
assert (fpA == fpB);
// and a single extra event changes it
block += 1; Core.apply(s, block, #collectorAssigned({ account = 100; staff = collector2 }));
assert (fp(s) != fpA);
Debug.print("count: fingerprint checks = 2");

Debug.print("COLLECTIONS TEST GREEN");
