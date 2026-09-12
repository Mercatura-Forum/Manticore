/// Posting.mo — domain facts become journal postings, deterministically.
///
/// Every posting the product engine produces is built here, and every one of them
/// carries a **derived** idempotency key: a domain-separated digest of the facts
/// that identify the act (what kind of run, which account, which date, which
/// sequence within the run). Two consequences follow, and both are the point:
///
///   * a batch that is retried after a partial failure re-derives the same keys,
///     so the journal's own duplicate rejection makes the retry a no-op rather
///     than a second set of postings;
///   * the key is a function of the facts, so a reader who has the facts can
///     recompute it and confirm that the posting in the log is the posting the
///     run should have produced.
///
/// The sub-ledger key of a customer account is derived from its issued identifier
/// the same way, so a balance can be found from the identifier alone with no index
/// to keep in step.

import Text "mo:core/Text";
import Blob "mo:core/Blob";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Array "mo:core/Array";
import List "mo:core/List";
import Sha256 "mo:sha2/Sha256";

import JT "mo:journal/JournalTypes";
import JCore "mo:journal/JournalCore";

import I "Interest";

module {

  /// Domain separation. Every digest this module produces starts with a distinct
  /// tag, so a key derived for one purpose can never collide with a key derived
  /// for another even when the remaining bytes agree.
  let KEY_DOMAIN = "thebes.bank.posting.key.v1";
  let SUBLEDGER_DOMAIN = "thebes.bank.subledger.v1";

  func lenPrefixed(parts : [Text]) : Blob {
    let buf = List.empty<Nat8>();
    for (p in parts.vals()) {
      let b = Text.encodeUtf8(p);
      // a four-byte big-endian length before each part, so "ab"+"c" and "a"+"bc"
      // are different preimages
      let n = b.size();
      List.add(buf, Nat8.fromNat((n / 0x1000000) % 256));
      List.add(buf, Nat8.fromNat((n / 0x10000) % 256));
      List.add(buf, Nat8.fromNat((n / 0x100) % 256));
      List.add(buf, Nat8.fromNat(n % 256));
      for (x in b.vals()) { List.add(buf, x) };
    };
    Blob.fromArray(List.toArray(buf))
  };

  /// The sub-ledger key for a customer account: a digest of the issued identifier
  /// under its own domain. Fixed width, so no identifier can be a prefix of
  /// another, and independent of the identifier's length.
  public func subledgerOf(identifier : Text) : JT.SubledgerKey {
    Sha256.fromBlob(#sha256, lenPrefixed([SUBLEDGER_DOMAIN, identifier]))
  };

  /// A derived idempotency key. `purpose` names the run, and the remaining parts
  /// identify the act within it.
  public func key(purpose : Text, parts : [Text]) : Blob {
    let all = Array.tabulate<Text>(parts.size() + 2, func(i) {
      if (i == 0) KEY_DOMAIN else if (i == 1) purpose else parts[i - 2]
    });
    Sha256.fromBlob(#sha256, lenPrefixed(all))
  };

  // ═══════════════════════════════════════════════════════
  //  LEGS
  // ═══════════════════════════════════════════════════════

  public func leg(account : JT.AccountCode, sub : ?JT.SubledgerKey, side : JT.Side, ccy : JT.Currency, amount : Nat) : JT.Leg {
    { account; subledger = sub; side; currency = ccy; amount }
  };

  /// Total per side, so a caller can assert a posting balances before submitting
  /// it rather than discovering it at admission.
  public func sideTotals(legs : [JT.Leg]) : { debits : Nat; credits : Nat } {
    var d = 0; var c = 0;
    for (l in legs.vals()) { switch (l.side) { case (#debit) d += l.amount; case (#credit) c += l.amount } };
    { debits = d; credits = c }
  };

  public func balances(legs : [JT.Leg]) : Bool {
    let t = sideTotals(legs);
    t.debits == t.credits and t.debits > 0
  };

  // ═══════════════════════════════════════════════════════
  //  THE NET BALANCE OF A SUB-LEDGER, ON ITS OWN SIDE
  // ═══════════════════════════════════════════════════════

  /// The customer-facing balance of a product account: the journal balance read
  /// on the normal side of the control account, so a deposit reads positive and a
  /// loan reads as the outstanding principal. Value-dated, because that is the
  /// balance interest is computed on.
  public func accountBalanceOn(
    js : JCore.State,
    control : JT.AccountCode,
    sub : JT.SubledgerKey,
    ccy : JT.Currency,
    normalSide : JT.Side,
    asOf : JT.Day,
  ) : { net : Nat; overdrawn : Bool; debits : Nat; credits : Nat } {
    let b = JCore.valueDatedBalance(js, control, ?sub, ccy, asOf);
    switch (normalSide) {
      case (#credit) {
        if (b.credits >= b.debits) { { net = b.credits - b.debits; overdrawn = false; debits = b.debits; credits = b.credits } }
        else { { net = b.debits - b.credits; overdrawn = true; debits = b.debits; credits = b.credits } }
      };
      case (#debit) {
        if (b.debits >= b.credits) { { net = b.debits - b.credits; overdrawn = false; debits = b.debits; credits = b.credits } }
        else { { net = b.credits - b.debits; overdrawn = true; debits = b.debits; credits = b.credits } }
      };
    }
  };

  /// The balance function the accrual fold consumes: value-dated net balance on
  /// the product's own side, zero when the account is overdrawn (an overdrawn
  /// current account earns no credit interest; the debit interest of an overdraft
  /// is a separate accrual against the overdraft portfolio).
  public func creditBalanceReader(
    js : JCore.State,
    control : JT.AccountCode,
    sub : JT.SubledgerKey,
    ccy : JT.Currency,
    normalSide : JT.Side,
    minimumBalance : Nat,
  ) : (JT.Day) -> Nat {
    func(d : JT.Day) : Nat {
      let b = accountBalanceOn(js, control, sub, ccy, normalSide, d);
      if (b.overdrawn) 0
      else if (b.net < minimumBalance) 0
      else b.net
    }
  };

  /// The mirror: the overdrawn amount on each day, which is what debit interest is
  /// charged on. Zero on days the account is in credit.
  public func overdrawnBalanceReader(
    js : JCore.State,
    control : JT.AccountCode,
    sub : JT.SubledgerKey,
    ccy : JT.Currency,
    normalSide : JT.Side,
  ) : (JT.Day) -> Nat {
    func(d : JT.Day) : Nat {
      let b = accountBalanceOn(js, control, sub, ccy, normalSide, d);
      if (b.overdrawn) b.net else 0
    }
  };

  // ═══════════════════════════════════════════════════════
  //  BUILDING THE POSTINGS
  // ═══════════════════════════════════════════════════════

  public type Built = { posting : JT.PostingInput; examined : Nat; posted : Nat; zero : Nat; total : Nat };

  /// One capitalisation leg per account plus a single contra leg. The contra is
  /// **the sum of the rounded legs**, never the rounded sum, so the posting
  /// balances by construction and no rounding-difference account exists. Accounts
  /// whose accrual rounds to zero are examined and not posted, because the journal
  /// refuses a zero leg and a vacuously balanced posting is the fake-green pattern.
  public func capitalisation(
    control : JT.AccountCode,
    contraAccount : JT.AccountCode,
    ccy : JT.Currency,
    customerSide : JT.Side,
    rows : [{ sub : JT.SubledgerKey; amount : Nat }],
    purposeParts : [Text],
    postingDate : JT.Day,
    valueDate : JT.Day,
    period : JT.PeriodId,
    narration : Text,
  ) : ?Built {
    let legs = List.empty<JT.Leg>();
    var total : Nat = 0;
    var zeroes : Nat = 0;
    for (r in rows.vals()) {
      if (r.amount == 0) { zeroes += 1 }
      else {
        List.add(legs, leg(control, ?r.sub, customerSide, ccy, r.amount));
        total += r.amount;
      };
    };
    if (total == 0) return null;
    let contraSide : JT.Side = switch (customerSide) { case (#credit) #debit; case (#debit) #credit };
    List.add(legs, leg(contraAccount, null, contraSide, ccy, total));
    ?{
      posting = {
        idempotencyKey = key("capitalisation", purposeParts);
        postingDate; valueDate; period;
        legs = List.toArray(legs);
        sourceRef = { kind = "interest-capitalisation"; id = Text.join(purposeParts.vals(), "/") };
        narration;
        correctionOf = null;
      };
      examined = rows.size();
      posted = rows.size() - zeroes;
      zero = zeroes;
      total;
    }
  };

  /// A two-leg posting, the shape almost every product act takes.
  public func simple(
    purpose : Text,
    purposeParts : [Text],
    debit : JT.Leg,
    credit : JT.Leg,
    postingDate : JT.Day,
    valueDate : JT.Day,
    period : JT.PeriodId,
    narration : Text,
  ) : JT.PostingInput {
    {
      idempotencyKey = key(purpose, purposeParts);
      postingDate; valueDate; period;
      legs = [debit, credit];
      sourceRef = { kind = purpose; id = Text.join(purposeParts.vals(), "/") };
      narration;
      correctionOf = null;
    }
  };

  /// Chunk a capitalisation run into postings no larger than the journal's leg
  /// bound, with a deterministic chunk index in each key so the whole run is
  /// idempotent rather than only each posting.
  public func chunk<X>(rows : [X], size : Nat) : [[X]] {
    if (size == 0 or rows.size() == 0) return [];
    let out = List.empty<[X]>();
    var i = 0;
    while (i < rows.size()) {
      let n = if (i + size <= rows.size()) size else rows.size() - i;
      out |> List.add(_, Array.tabulate<X>(n, func(j) { rows[i + j] }));
      i += n;
    };
    List.toArray(out)
  };

  /// The largest number of customer legs a capitalisation posting may carry: the
  /// journal's leg bound less the single contra leg. A module-level `let` must be
  /// static, so the bound is asserted against the journal's own constant by
  /// `chunkBoundAgrees` rather than computed from it here.
  public let CAPITALISATION_CHUNK : Nat = 127;

  public func chunkBoundAgrees() : Bool { CAPITALISATION_CHUNK + 1 == JT.MAX_LEGS };

  /// The exact residue of a capitalisation run: the difference between the summed
  /// rounded legs and the unrounded total, reported so a run can state it rather
  /// than absorb it.
  public func residue(unrounded : [I.Signed], roundedTotal : Nat) : I.Signed {
    var num : Nat = 0;
    var den : Nat = 1;
    var negativeSum = false;
    for (x in unrounded.vals()) {
      if (x.numerator != 0 and x.negative) negativeSum := true;
      // num/den + x  (common denominator, kept exact)
      num := num * x.denominator + x.numerator * den;
      den := den * x.denominator;
    };
    // residue = unrounded total − rounded total, reduced so the figure a run reports
    // is readable rather than a product of every account's denominator
    let roundedNum = roundedTotal * den;
    let (rn, rd, rneg) =
      if (num >= roundedNum) (num - roundedNum, den, negativeSum)
      else (roundedNum - num, den, not negativeSum);
    if (rn == 0) return { numerator = 0; denominator = 1; negative = false };
    var a = rn;
    var b = rd;
    while (b != 0) { let t = a % b; a := b; b := t };
    { numerator = rn / a; denominator = rd / a; negative = rneg }
  };
};
