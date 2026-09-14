/// PackingTypes.mo: closed-month packing as the bank records and refuses it.
///
/// A pack is a closed range of the journal; the blocks from the last pack's end to the block that
/// closed a period; packed into segments that unpack byte for byte, with one summary row and one
/// delta-coded posting list per account, its per-posting index rows dropped and its daily
/// aggregates rolled up into monthly rows. Opening one is a dual-authorised command whose gate is
/// here (`OpenGate`); advancing one is an open method, like the end-of-day batch's. Every step is a
/// bank block, so the boundary the reads honour (`packedThroughDay`) is a fact of the log.

module {

  /// What the bank's log says about packing.
  public type PackingEvent = {
    /// The pack's two ranges: the journal's blocks `lo … hi`, and; since the bank-log ruling of 12 September
    /// (measure 2); the bank's own blocks `bankLo … bankHi`, the last bank block stamped no later than the
    /// journal block that closed the period.
    #packOpened : { pack : Nat; period : Text; periodEnd : Nat; lo : Nat; hi : Nat; bankLo : Nat; bankHi : Nat };
    #segmentPacked : { pack : Nat; seq : Nat; lo : Nat; hi : Nat; bytes : Nat; rawBytes : Nat; postings : Nat; sha256 : Blob };
    /// A segment of bank blocks: `dropped` proposal bodies left under §18.2's rule, `kept` stayed.
    #bankSegmentPacked : { pack : Nat; seq : Nat; lo : Nat; hi : Nat; bytes : Nat; rawBytes : Nat; dropped : Nat; kept : Nat; sha256 : Blob };
    #packAdvanced : { pack : Nat; phase : Text; work : Nat };
    #packSealed : { pack : Nat; segments : Nat; postings : Nat; accounts : Nat; packedBytes : Nat; rawBytes : Nat; sha256 : Blob; hi : Nat; periodEnd : Nat;
                    bankHi : Nat; bankSegments : Nat; bankPackedBytes : Nat; bankRawBytes : Nat; bankDropped : Nat; bankKept : Nat };
    // ── the archive roll: a sealed pack's segments to an archive child, the journal's prefix gone ──
    /// The decision: pack `pack` rolls to archive child `cid`, addressed as `archive`. Dual.
    #rollAuthorised : { pack : Nat; cid : Nat64; archive : Principal; hi : Nat; periodEnd : Nat };
    #rollAdvanced : { pack : Nat; phase : Text; work : Nat };
    /// The checkpoint series written into the journal's log: blocks `first … last`, the state after `through`.
    #checkpointWritten : { pack : Nat; through : Nat; first : Nat; last : Nat };
    /// A segment's bytes were sent to the archive; recorded before the call is made.
    #segmentSent : { pack : Nat; seq : Nat; attempt : Nat };
    /// The archive said it holds the segment: recorded from the archive's own acknowledgement.
    #segmentArchived : { pack : Nat; seq : Nat; sha256 : Blob };
    /// Every segment acknowledged, the journal's rows of the range dropped, the log's prefix gone.
    #packArchived : { pack : Nat; cid : Nat64; archive : Principal; hi : Nat; journalBase : Nat; segments : Nat };
  };

  public type Error = {
    #PackingInProgress : { pack : Nat };
    #NotPacking;
    #NothingToPack : { period : Text };
    #Codec : { block : Nat; reason : Text };
    #RebuildBusy : { index : Text };
    #UnknownPack : { pack : Nat };
    #UnknownSegment : { pack : Nat; seq : Nat };
    /// The period is not closed, or its last day is not yet old enough for every reader.
    #PeriodNotClosed : { period : Text };
    #PeriodAlreadyPacked : { period : Text; packedThroughDay : Nat };
    #TooRecent : { period : Text; periodEnd : Nat; today : Nat; requiredAge : Nat };
    /// A posting, a resolution or a batch for a day the reads take from the packs.
    #DayPacked : { day : Nat; packedThroughDay : Nat };
    /// A rule whose window would reach into packed history, at declaration.
    #WindowReachesPacked : { windowDays : Nat; today : Nat; packedThroughDay : Nat };
    /// The bank range a pack would take still holds an awaiting proposal or an unreviewed override: what
    /// is packed is settled (§18.3).
    #OpenProposalInRange : { proposal : Nat; bankHi : Nat };
    #OpenOverrideInRange : { override_ : Nat; bankHi : Nat };
    // ── the archive roll ──
    #PackNotSealed : { pack : Nat };
    #PackAlreadyArchived : { pack : Nat };
    /// Packs roll in order: the journal's prefix leaves as a prefix.
    #PackNotNext : { pack : Nat; next : Nat };
    #RollInProgress : { pack : Nat };
    #NotRolling;
    #UnknownArchive : { cid : Nat64 };
    /// A pending reserved in the range is still open: its record would leave before its resolution.
    #OpenPendingInRange : { pending : Nat; hi : Nat };
    #RollNotAt : { pack : Nat; phase : Text; wanted : Text };
    /// An acknowledgement from a principal that is not the roll's archive, for a segment not sent, or
    /// with a hash that is not the segment's.
    #UnexpectedAck : { pack : Nat; seq : Nat; reason : Text };
    /// A read or a relation naming a block that left with an archive roll.
    #BlockArchived : { index : Nat; archivedThroughBlock : Nat };
    /// A period-level read of a period whose blocks left: the archive holds them.
    #PeriodArchived : { period : Text; pack : Nat; cid : Nat64; archive : Principal };
  };

  /// A query's refusal: a range that straddles the boundary is answered by no single index. The
  /// caller splits it at `packedThroughDay`, or names an account, whose packed rows are one read.
  public type RangeRefusal = { from : Nat; to : Nat; packedThroughDay : Nat };
}
