/// ShardTypes.mo; accounts routed across bank contracts by a declared, versioned rule.
///
/// A **shard** is a whole bank contract; its own journal, its own indexes, its own accounts. The
/// rule that says which shard an account lives on is **in the account's identifier**: the first
/// `SHARD_DIGITS` characters of the serial are the shard index, written when the account is opened
/// (`serial = self · 10^(width − SHARD_DIGITS) + block`), so routing a foreign identifier is
/// arithmetic on the identifier and needs no lookup, and an account never moves. The rule is
/// declared by a dual-authorised command and versioned: a version names this contract's own index
/// and every shard's principal and the settlement account this contract books its movements with
/// that shard through. A later version may add shards; the indexes already issued keep their
/// meaning.
///
/// **A posting touching two shards is refused.** Every posting a shard admits names only accounts
/// it holds (a sub-ledger key the shard has not registered is an unknown account). What the bank
/// provides instead is the **inter-shard transfer**: two postings, each atomic within its shard,
/// joined into an exactly-once whole by a pending on the sending side, an idempotent posting on the
/// receiving side, and the receiving shard's own acknowledgement; the saga with idempotent steps
/// (Garcia-Molina and Salem 1987; Helland, "Life beyond Distributed Transactions", 2007;
/// TigerBeetle's two-phase transfers), not a two-phase commit, which this engine cannot make
/// atomic across contracts (a write after an awaited reply is dropped; `ArchiveTypes.mo`).
///
///   1. `openShardTransfer` (dual, money-moving): the sending shard reserves the amount as a
///      journal **pending**; debit the customer's sub-ledger, credit the settlement account for
///      the receiving shard; and records the transfer with the receiving identifier;
///   2. `sendShardTransfer` (open): recorded as sent, then the call to the receiving shard is
///      made and not waited for;
///   3. `receiveShardTransfer` (the receiving shard, caller held to a shard principal of the
///      rule): the identifier is one of its active accounts, so it **posts**; debit its
///      settlement account for the sending shard, credit the customer; under an idempotency key
///      derived from (sending shard, transfer), so a second delivery posts nothing and is
///      acknowledged again; then it calls the sender back; an identifier it does not hold is
///      refused and the refusal is called back;
///   4. `acknowledgeShardTransfer` / `rejectShardTransfer` (the sending shard, caller held to the
///      receiving shard's principal): the pending is **posted** on acknowledgement or **voided**
///      on refusal, once; a resolved pending refuses a second resolution.
///
/// Under failure: a receiver that is stopped or a call that is lost leaves the pending open and
/// the transfer sendable again; a second delivery is a duplicate and posts nothing; a second
/// acknowledgement finds the pending resolved and changes nothing; the sending shard's blocks are
/// written before every call. Across every shard the settlement accounts net to zero once every
/// open transfer is settled; the oracle `bank_shard.py` reads.

module {

  public let SHARD_DIGITS : Nat = 2;
  public let MAX_SHARDS : Nat = 100;

  public type ShardIndex = Nat;

  public type ShardEntry = { index : ShardIndex; principal : Principal; settlement : Text };

  public type Rule = {
    version : Nat;
    self : ShardIndex;
    shards : [ShardEntry];
    declaredAt : Nat;
  };

  public type TransferId = Nat;   // the bank block of #outboundOpened

  public type OutboundStatus = { #open; #sent : { attempts : Nat }; #settled : { receiverPosting : Nat }; #returned : { reason : Text } };

  public type Outbound = {
    id : TransferId;
    from : Nat;                 // the sending account
    toIdentifier : Text;
    toShard : ShardIndex;
    amount : Nat;
    currency : Text;
    valueDay : Nat;
    period : Text;
    narration : Text;
    pendingIndex : Nat;         // the journal pending that reserves the amount
    status : OutboundStatus;
    lastBlock : Nat;
  };

  public type Inbound = {
    fromShard : ShardIndex;
    transfer : TransferId;
    toAccount : Nat;
    amount : Nat;
    posting : Nat;
    receivedAt : Nat;
  };

  public type ShardEvent = {
    #ruleDeclared : { version : Nat; self : ShardIndex; shards : [ShardEntry] };
    #outboundOpened : { from : Nat; toIdentifier : Text; toShard : ShardIndex; amount : Nat; currency : Text; valueDay : Nat; period : Text; narration : Text; pendingIndex : Nat };
    #outboundSent : { transfer : TransferId; attempt : Nat };
    #outboundSettled : { transfer : TransferId; receiverPosting : Nat };
    #outboundReturned : { transfer : TransferId; reason : Text };
    #inboundPosted : { fromShard : ShardIndex; transfer : TransferId; toAccount : Nat; amount : Nat; posting : Nat };
    #inboundRefused : { fromShard : ShardIndex; transfer : TransferId; toIdentifier : Text; reason : Text };
  };

  public type ShardError = {
    #NoRule;
    #InvalidRule : { reason : Text };
    #NotAShard : { caller : Principal };
    #UnknownShard : { shard : ShardIndex };
    #SameShard : { identifier : Text };
    #NotRouted : { identifier : Text; reason : Text };
    #UnknownTransfer : { transfer : TransferId };
    #TransferNotIn : { transfer : TransferId; status : Text; expected : Text };
    #NotTheReceiver : { transfer : TransferId; caller : Principal };
    #IdentifierNotHere : { identifier : Text };
    #Duplicate : { fromShard : ShardIndex; transfer : TransferId; posting : Nat };
  };

  public func statusName(s : OutboundStatus) : Text {
    switch (s) { case (#open) "open"; case (#sent(_)) "sent"; case (#settled(_)) "settled"; case (#returned(_)) "returned" }
  };
}
