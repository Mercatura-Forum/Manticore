import AuditMMR "../AuditMMR";
import Bloom "../BloomFilter";
import Text "mo:core/Text";

var filter = Bloom.empty();
assert (not Bloom.mightContain(filter, "ISO-HUB-20260622-000001"));
filter := Bloom.add(filter, "ISO-HUB-20260622-000001");
assert (Bloom.mightContain(filter, "ISO-HUB-20260622-000001"));
assert (Bloom.fillRatioPermille(filter) > 0);

var mmr = AuditMMR.empty();
assert (mmr.leafCount == 0);
assert (AuditMMR.root(mmr) == null);

mmr := AuditMMR.append(mmr, Text.encodeUtf8("audit-0"));
assert (mmr.leafCount == 1);
assert (AuditMMR.root(mmr) != null);
assert (AuditMMR.peakCount(mmr) == 1);

mmr := AuditMMR.append(mmr, Text.encodeUtf8("audit-1"));
assert (mmr.leafCount == 2);
assert (AuditMMR.root(mmr) != null);
assert (AuditMMR.peakCount(mmr) == 1);

mmr := AuditMMR.append(mmr, Text.encodeUtf8("audit-2"));
assert (mmr.leafCount == 3);
assert (AuditMMR.root(mmr) != null);
assert (AuditMMR.peakCount(mmr) == 2);
