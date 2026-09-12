// ProwideParse — the independent parser of the breadth runner: Prowide's MX classes (prowide-iso20022 SRU2025)
// parse every document the canister emitted; each line is `OK <mxId> <messageId> <path>` when the document
// parsed, re-serialized, and parsed again to the same MX id, else `PARSE-FAILED` / `ROUNDTRIP-FAILED`.
// Build:  javac -cp <jars> -d <outdir> ProwideParse.java      Run:  java -cp <jars>:<outdir> ProwideParse <xml>...
import com.prowidesoftware.swift.model.mx.AbstractMX;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public class ProwideParse {
  public static void main(String[] a) throws Exception {
    int ok = 0;
    // Prowide writes prefixed elements (<Doc:MsgId>); the identifier is the first message id, or an investigation's assignment id
    Pattern msgId = Pattern.compile("<(?:\\w+:)?(?:MsgId|PyldIdr)>([^<]+)</(?:\\w+:)?(?:MsgId|PyldIdr)>|<(?:\\w+:)?Assgnmt>\\s*<(?:\\w+:)?Id>([^<]+)</(?:\\w+:)?Id>");
    for (String p : a) {
      String xml = new String(Files.readAllBytes(Paths.get(p)), "UTF-8");
      AbstractMX mx = null;
      try { mx = AbstractMX.parse(xml); } catch (Exception e) { System.out.println("PARSE-FAILED " + p + " " + e.getClass().getSimpleName()); continue; }
      if (mx == null) { System.out.println("PARSE-FAILED " + p + " null"); continue; }
      String back = mx.message();
      AbstractMX again = AbstractMX.parse(back);
      boolean round = again != null && again.getMxId().id().equals(mx.getMxId().id());
      // the message id as Prowide re-serialized it — the runner compares it with the fixture's
      Matcher m = msgId.matcher(back);
      String id = m.find() ? (m.group(1) != null ? m.group(1) : m.group(2)) : "-";
      System.out.println((round ? "OK " : "ROUNDTRIP-FAILED ") + mx.getMxId().id() + " " + id + " " + p);
      if (round) ok++;
    }
    System.out.println("PROWIDE-OK " + ok + "/" + a.length);
  }
}
