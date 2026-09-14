/// FacadeCert.mo: certified data for the token-ledger facade.
///
/// Below the journal activation height the certified tree is exactly the
/// ICRC-ME tree (`CertifiedTree.buildTipTree`: labeled "tip" → fork(labeled
/// "last_block_index", labeled "last_block_hash")), so the certified data and
/// `icrc3_get_tip_certificate` are byte-identical to the unmodified ledger.
/// Above it the tree is
///
///   fork( labeled "thebes_journal" → JournalCert tree , labeled "tip" → ICRC tree )
///
/// with the labels in lexicographic order. ICRC-3 clients keep finding the
/// token tip under `tip/…`; a journal verifier finds `thebes_journal/mmr_root`
/// through the fork exactly as it does on the journal canister.

import Blob "mo:core/Blob";
import Text "mo:core/Text";
import Array "mo:core/Array";
import Nat8 "mo:core/Nat8";
import CertifiedData "mo:core/CertifiedData";

import Cert "../ledger/CertifiedTree";
import JCert "../journal/JournalCert";

module {

  func natToBeBytes(n : Nat) : Blob { JCert.natToBeBytes(n) };

  /// The ICRC-ME tip tree, reproduced from CertifiedTree.mo (its builder is private).
  public func icrcTipTree(blockIndex : Nat, blockHash : Blob) : Cert.HashTree {
    #labeled(
      Text.encodeUtf8("tip"),
      #fork(
        #labeled(Text.encodeUtf8("last_block_index"), #leaf(natToBeBytes(blockIndex))),
        #labeled(Text.encodeUtf8("last_block_hash"), #leaf(blockHash)),
      )
    )
  };

  public func combinedTree(icrcIndex : Nat, icrcHash : Blob, jIndex : Nat, jHash : Blob, mmrRoot : Blob) : Cert.HashTree {
    #fork(JCert.buildTree(jIndex, jHash, mmrRoot), icrcTipTree(icrcIndex, icrcHash))
  };

  func truncate32(h : Blob) : Blob {
    let bytes = Blob.toArray(h);
    if (bytes.size() > 32) Blob.fromArray(Array.tabulate<Nat8>(32, func(i) { bytes[i] })) else h
  };

  /// Set certified data for the combined tree (journal active).
  public func setCombined(icrcIndex : Nat, icrcHash : Blob, jIndex : Nat, jHash : Blob, mmrRoot : Blob) {
    CertifiedData.set(truncate32(Cert.hashTree(combinedTree(icrcIndex, icrcHash, jIndex, jHash, mmrRoot))));
  };

  /// Certificate and CBOR tree for the combined state (query context only).
  public func combinedCertificate(icrcIndex : Nat, icrcHash : Blob, jIndex : Nat, jHash : Blob, mmrRoot : Blob) : ?{ certificate : Blob; hash_tree : Blob } {
    switch (CertifiedData.getCertificate()) {
      case (?cert) ?{ certificate = cert; hash_tree = Cert.encodeCBOR(combinedTree(icrcIndex, icrcHash, jIndex, jHash, mmrRoot)) };
      case null null;
    }
  };
};
