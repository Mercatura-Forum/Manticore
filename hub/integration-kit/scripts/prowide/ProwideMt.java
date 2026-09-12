// ProwideMt — the independent reader of the MT bridge runner: Prowide swift-core (SRU2025) parses each FIN file;
// one line per file: `OK <type> <20=value;21=value;32A=value;121=value> <path>` when the message parsed, was
// re-serialized, and parsed again to the same type; `PARSE-FAILED` / `ROUNDTRIP-FAILED` otherwise.
import com.prowidesoftware.swift.model.SwiftMessage;
import com.prowidesoftware.swift.model.SwiftBlock4;
import com.prowidesoftware.swift.model.Tag;
import com.prowidesoftware.swift.model.mt.AbstractMT;
import java.nio.file.Files;
import java.nio.file.Paths;

public class ProwideMt {
  static String field(SwiftMessage m, String name) {
    SwiftBlock4 b4 = m.getBlock4();
    if (b4 == null) return "";
    Tag t = b4.getTagByName(name);
    return t == null ? "" : t.getValue().split("\n")[0].trim();
  }
  public static void main(String[] a) throws Exception {
    int ok = 0;
    for (String p : a) {
      String fin = new String(Files.readAllBytes(Paths.get(p)), "UTF-8");
      SwiftMessage m;
      try { m = SwiftMessage.parse(fin); } catch (Exception e) { System.out.println("PARSE-FAILED " + p + " " + e.getClass().getSimpleName()); continue; }
      if (m == null || m.getBlock4() == null || m.getType() == null) { System.out.println("PARSE-FAILED " + p + " no-block4-or-type"); continue; }
      AbstractMT mt = AbstractMT.parse(fin);
      if (mt == null) { System.out.println("PARSE-FAILED " + p + " no-typed-class"); continue; }
      String back = mt.message();
      SwiftMessage again = SwiftMessage.parse(back);
      boolean round = again != null && again.getType() != null && again.getType().equals(m.getType()) && field(again, "20").equals(field(m, "20"));
      String uetr = m.getBlock3() != null && m.getBlock3().getTagByName("121") != null ? m.getBlock3().getTagByName("121").getValue() : "";
      String cov = m.getBlock3() != null && m.getBlock3().getTagByName("119") != null ? m.getBlock3().getTagByName("119").getValue() : "";
      System.out.println((round ? "OK " : "ROUNDTRIP-FAILED ") + "MT" + m.getType() + (cov.equals("COV") ? "COV" : "") + " 20=" + field(m, "20") + ";21=" + field(m, "21") + ";32A=" + field(m, "32A") + ";121=" + uetr + " " + p);
      if (round) ok++;
    }
    System.out.println("PROWIDE-OK " + ok + "/" + a.length);
  }
}
