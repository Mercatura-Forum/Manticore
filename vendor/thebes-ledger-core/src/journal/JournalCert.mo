/// JournalCert.mo: IC certified data for the journal tip.
///
/// The canister's certified data is the root hash of this tree:
///
///   labeled "thebes_journal"
///     fork
///       fork
///         labeled "last_block_hash"  leaf(32-byte block hash)
///         labeled "last_block_index" leaf(big-endian index)
///       labeled "mmr_root"           leaf(32-byte MMR root)
///
/// The subnet signs the certified data with its BLS key on every state
/// change. A reader who does not trust the canister verifies: the certificate
/// signature against the IC root key (with delegation), the certified_data
/// entry for this canister against the hash of the tree below, the mmr_root
/// leaf inside that tree, and finally the entry's inclusion proof against that
/// root. Unlike the token ledger's tip tree (src/ledger/CertifiedTree.mo), the
/// MMR root is inside the certified tree; that is what makes an inclusion
/// proof verifiable without any uncertified query.
///
/// Labels are ordered lexicographically inside each fork, as IC hash-tree
/// lookup requires.

import Blob "mo:core/Blob";
import Nat8 "mo:core/Nat8";
import Array "mo:core/Array";
import Text "mo:core/Text";
import CertifiedData "mo:core/CertifiedData";

import Cert "../ledger/CertifiedTree";

module {

  public type State = {
    var lastBlockIndex : Nat;
    var lastBlockHash : Blob;
    var mmrRoot : Blob;
    var committed : Bool;   // false until the first block exists
  };

  public func newState() : State {
    { var lastBlockIndex = 0; var lastBlockHash = "" : Blob; var mmrRoot = "" : Blob; var committed = false }
  };

  public let LABEL_ROOT : Text = "thebes_journal";
  public let LABEL_HASH : Text = "last_block_hash";
  public let LABEL_INDEX : Text = "last_block_index";
  public let LABEL_MMR : Text = "mmr_root";

  /// Minimal big-endian encoding of a Nat (zero is a single 0x00 byte).
  public func natToBeBytes(n : Nat) : Blob {
    if (n == 0) return Blob.fromArray([0]);
    var tmp = n;
    var bc : Nat = 0;
    while (tmp > 0) { tmp /= 256; bc += 1 };
    Blob.fromArray(Array.tabulate<Nat8>(bc, func(i) { Nat8.fromNat((n / (256 ** (bc - 1 - i))) % 256) }))
  };

  public func buildTree(index : Nat, hash : Blob, root : Blob) : Cert.HashTree {
    #labeled(
      Text.encodeUtf8(LABEL_ROOT),
      #fork(
        #fork(
          #labeled(Text.encodeUtf8(LABEL_HASH), #leaf(hash)),
          #labeled(Text.encodeUtf8(LABEL_INDEX), #leaf(natToBeBytes(index))),
        ),
        #labeled(Text.encodeUtf8(LABEL_MMR), #leaf(root)),
      )
    )
  };

  /// Root hash of the tree (the value set as certified data).
  public func rootHash(index : Nat, hash : Blob, root : Blob) : Blob {
    Cert.hashTree(buildTree(index, hash, root))
  };

  /// Record the new tip and set certified data. Call after every append.
  public func update(state : State, index : Nat, hash : Blob, root : Blob) {
    state.lastBlockIndex := index;
    state.lastBlockHash := hash;
    state.mmrRoot := root;
    state.committed := true;
    CertifiedData.set(rootHash(index, hash, root));
  };

  /// Re-set certified data from persisted state (the IC clears it on upgrade).
  public func recertify(state : State) {
    if (state.committed) CertifiedData.set(rootHash(state.lastBlockIndex, state.lastBlockHash, state.mmrRoot));
  };

  /// The tip certificate and the CBOR-encoded tree it certifies. Null outside a
  /// query call or before the first block.
  public func certificate(state : State) : ?{ certificate : Blob; hash_tree : Blob; last_block_index : Nat; last_block_hash : Blob; mmr_root : Blob } {
    if (not state.committed) return null;
    switch (CertifiedData.getCertificate()) {
      case (?cert) {
        let tree = buildTree(state.lastBlockIndex, state.lastBlockHash, state.mmrRoot);
        ?{ certificate = cert; hash_tree = Cert.encodeCBOR(tree); last_block_index = state.lastBlockIndex; last_block_hash = state.lastBlockHash; mmr_root = state.mmrRoot }
      };
      case null null;
    }
  };
};
