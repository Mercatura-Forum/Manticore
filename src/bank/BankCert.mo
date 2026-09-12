/// BankCert.mo — IC certified data over both logs at once.
///
/// A posting must be provable and so must the authority behind it, so one
/// certificate carries both Merkle roots:
///
///   fork
///     labeled "thebes_bank"     fork( fork( labeled "last_block_hash", labeled "last_block_index" ),
///                                     labeled "mmr_root" )
///     labeled "thebes_journal"  (the journal's own tree, built by JournalCert)
///
/// Labels are in lexicographic order inside the fork, as IC hash-tree lookup
/// requires ("thebes_bank" < "thebes_journal"). A journal verifier finds
/// `thebes_journal/mmr_root` through the fork exactly as it does on a standalone
/// journal canister, so `integration/verify_entry.py` from the journal repository
/// works against this canister unchanged; a bank verifier finds
/// `thebes_bank/mmr_root` the same way. This is the construction
/// `src/facade/FacadeCert.mo` uses in the pinned submodule for the ICRC tip plus
/// the journal tip, applied to the bank tip plus the journal tip.

import Blob "mo:core/Blob";
import Text "mo:core/Text";
import Array "mo:core/Array";
import Nat8 "mo:core/Nat8";
import CertifiedData "mo:core/CertifiedData";

import Cert "mo:ledger/CertifiedTree";
import JCert "mo:journal/JournalCert";

module {

  public let LABEL_ROOT : Text = "thebes_bank";
  public let LABEL_HASH : Text = "last_block_hash";
  public let LABEL_INDEX : Text = "last_block_index";
  public let LABEL_MMR : Text = "mmr_root";

  public type State = {
    var bankIndex : Nat;
    var bankHash : Blob;
    var bankRoot : Blob;
    var journalIndex : Nat;
    var journalHash : Blob;
    var journalRoot : Blob;
    var committed : Bool;
  };

  public func newState() : State {
    {
      var bankIndex = 0; var bankHash = "" : Blob; var bankRoot = "" : Blob;
      var journalIndex = 0; var journalHash = "" : Blob; var journalRoot = "" : Blob;
      var committed = false;
    }
  };

  public func bankTree(index : Nat, hash : Blob, root : Blob) : Cert.HashTree {
    #labeled(
      Text.encodeUtf8(LABEL_ROOT),
      #fork(
        #fork(
          #labeled(Text.encodeUtf8(LABEL_HASH), #leaf(hash)),
          #labeled(Text.encodeUtf8(LABEL_INDEX), #leaf(JCert.natToBeBytes(index))),
        ),
        #labeled(Text.encodeUtf8(LABEL_MMR), #leaf(root)),
      )
    )
  };

  public func combinedTree(s : State) : Cert.HashTree {
    #fork(
      bankTree(s.bankIndex, s.bankHash, s.bankRoot),
      JCert.buildTree(s.journalIndex, s.journalHash, s.journalRoot),
    )
  };

  func truncate32(h : Blob) : Blob {
    let bytes = Blob.toArray(h);
    if (bytes.size() > 32) Blob.fromArray(Array.tabulate<Nat8>(32, func(i) { bytes[i] })) else h
  };

  /// Record both tips and set certified data. Called after every commit, so the
  /// two roots always describe the same message.
  public func update(s : State, bankIndex : Nat, bankHash : Blob, bankRoot : Blob, journalIndex : Nat, journalHash : Blob, journalRoot : Blob) {
    s.bankIndex := bankIndex;
    s.bankHash := bankHash;
    s.bankRoot := bankRoot;
    s.journalIndex := journalIndex;
    s.journalHash := journalHash;
    s.journalRoot := journalRoot;
    s.committed := true;
    CertifiedData.set(truncate32(Cert.hashTree(combinedTree(s))));
  };

  /// Re-set certified data from persisted state (the IC clears it on upgrade).
  public func recertify(s : State) {
    if (s.committed) CertifiedData.set(truncate32(Cert.hashTree(combinedTree(s))));
  };

  public type Certificate = {
    certificate : Blob;
    hash_tree : Blob;
    bank_block_index : Nat;
    bank_block_hash : Blob;
    bank_mmr_root : Blob;
    journal_block_index : Nat;
    journal_block_hash : Blob;
    journal_mmr_root : Blob;
  };

  /// The certificate and the CBOR tree it certifies. Null outside a query call
  /// or before the first block of either log.
  public func certificate(s : State) : ?Certificate {
    if (not s.committed) return null;
    switch (CertifiedData.getCertificate()) {
      case (?cert) ?{
        certificate = cert;
        hash_tree = Cert.encodeCBOR(combinedTree(s));
        bank_block_index = s.bankIndex;
        bank_block_hash = s.bankHash;
        bank_mmr_root = s.bankRoot;
        journal_block_index = s.journalIndex;
        journal_block_hash = s.journalHash;
        journal_mmr_root = s.journalRoot;
      };
      case null null;
    }
  };
};
