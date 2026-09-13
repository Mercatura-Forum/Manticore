"""iso8583_twin.py — an ISO 8583 packer/unpacker for the ASCII packagers jPOS defines (ISO87APackager, ISO93APackager),
driven by the field tables read from jPOS's own source (`$ORACLES/jpos/packagers.json`, extracted from
org/jpos/iso/packager/ISO87APackager.java and ISO93APackager.java of jpos 2.1.10, AGPL-3.0 — an oracle outside the
repository, nothing of it vendored; `ORACLES` names the oracle root, `oracles` by default).

It exists so the cards battery can prove the connector's dialect byte for byte: every message packed here unpacks
in jPOS to the same fields and packs in jPOS to the same bytes; every jPOS fixture unpacks here to the fields its
.xml names. The field classes, as jPOS implements them:

  IFA_NUMERIC(n)   ASCII digits, left zero-padded to n
  IF_CHAR(n)       ASCII, right space-padded to n
  IFA_AMOUNT(n)    the first character as the sign (C/D in practice), then the digits left zero-padded to n-1
  IFA_LLNUM(n)     two ASCII digits of length, then digits (at most n)
  IFA_LLCHAR(n) / IFA_LLLCHAR(n)   two / three ASCII digits of length, then characters
  IFA_BINARY(n)    n binary bytes as 2n ASCII hex characters
  IFA_LLBINARY / IFA_LLLBINARY      the byte length in two / three ASCII digits, then the bytes themselves (jPOS's LiteralBinaryInterpreter)
  IFA_BITMAP(16)   the primary bitmap as 16 hex characters; with any field above 64, bit 1 set and 32 characters

A message is {0: "MTI", field: value, ...}; binary fields are bytes.
"""
import json
import os

PACKAGERS = os.path.join(os.environ.get("ORACLES", "oracles"), "jpos", "packagers.json")


class Packager:
    def __init__(self, name="ISO87A", path=PACKAGERS):
        table = json.load(open(path))[name]
        self.name = name
        self.fields = {row["field"]: row for row in table}

    def pack(self, msg):
        out = bytearray()
        mti = msg[0]
        out += self._pack_field(0, mti)
        present = sorted(f for f in msg if f > 1)
        secondary = any(f > 64 for f in present)
        bits = bytearray(16 if secondary else 8)
        if secondary:
            bits[0] |= 0x80
        for f in present:
            bits[(f - 1) // 8] |= 0x80 >> ((f - 1) % 8)
        out += bits.hex().upper().encode()
        for f in present:
            out += self._pack_field(f, msg[f])
        return bytes(out)

    def _pack_field(self, f, v):
        row = self.fields[f]
        c, n = row["class"], row["len"]
        if c == "IFA_NUMERIC":
            # jPOS zero-pads without checking the characters (track 2 rides in an LLNUM field with its '=' separator)
            s = str(v)
            assert len(s) <= n, (f, v)
            return s.rjust(n, "0").encode()
        if c == "IF_CHAR":
            s = str(v)
            assert len(s) <= n, (f, v)
            return s.ljust(n).encode()
        if c == "IFA_AMOUNT":
            # jPOS takes the first character as the sign, whatever it is, and zero-pads the rest to n-1
            s = str(v)
            assert len(s) >= 1 and len(s) <= n, (f, v)
            return (s[0] + s[1:].rjust(n - 1, "0")).encode()
        if c == "IFA_LLNUM":
            s = str(v)
            assert len(s) <= n and len(s) <= 99, (f, v)
            return f"{len(s):02d}{s}".encode()
        if c == "IFA_LLCHAR":
            s = str(v)
            assert len(s) <= n and len(s) <= 99, (f, v)
            return f"{len(s):02d}{s}".encode()
        if c == "IFA_LLLCHAR":
            s = str(v)
            assert len(s) <= n and len(s) <= 999, (f, v)
            return f"{len(s):03d}{s}".encode()
        if c == "IFA_BINARY":
            b = bytes(v)
            assert len(b) == n, (f, len(b), n)
            return b.hex().upper().encode()
        if c == "IFA_LLBINARY":
            b = bytes(v)
            assert len(b) <= n and len(b) <= 99, (f, len(b))
            return f"{len(b):02d}".encode() + b
        if c == "IFA_LLLBINARY":
            b = bytes(v)
            assert len(b) <= n and len(b) <= 999, (f, len(b))
            return f"{len(b):03d}".encode() + b
        raise ValueError(f"field class {c} not implemented")

    def unpack(self, data):
        data = bytes(data)
        pos = 0
        msg = {}
        mti, pos = self._unpack_field(0, data, pos)
        msg[0] = mti
        primary = bytes.fromhex(data[pos:pos + 16].decode()); pos += 16
        bits = bytearray(primary)
        if primary[0] & 0x80:
            bits += bytes.fromhex(data[pos:pos + 16].decode()); pos += 16
        for f in range(2, len(bits) * 8 + 1):
            if bits[(f - 1) // 8] & (0x80 >> ((f - 1) % 8)):
                v, pos = self._unpack_field(f, data, pos)
                msg[f] = v
        assert pos == len(data), f"trailing bytes: {len(data) - pos}"
        return msg

    def _unpack_field(self, f, data, pos):
        row = self.fields[f]
        c, n = row["class"], row["len"]
        if c in ("IFA_NUMERIC", "IF_CHAR"):
            s = data[pos:pos + n].decode(); pos += n
            return (s if c == "IFA_NUMERIC" else s.rstrip()), pos   # jPOS keeps IF_CHAR padding on unpack; the comparison trims it
        if c == "IFA_AMOUNT":
            s = data[pos:pos + n].decode(); pos += n
            return s, pos
        if c in ("IFA_LLNUM", "IFA_LLCHAR"):
            ln = int(data[pos:pos + 2]); pos += 2
            s = data[pos:pos + ln].decode(); pos += ln
            return s, pos
        if c == "IFA_LLLCHAR":
            ln = int(data[pos:pos + 3]); pos += 3
            s = data[pos:pos + ln].decode(); pos += ln
            return s, pos
        if c == "IFA_BINARY":
            b = bytes.fromhex(data[pos:pos + 2 * n].decode()); pos += 2 * n
            return b, pos
        if c == "IFA_LLBINARY":
            ln = int(data[pos:pos + 2]); pos += 2
            b = data[pos:pos + ln]; pos += ln
            return b, pos
        if c == "IFA_LLLBINARY":
            ln = int(data[pos:pos + 3]); pos += 3
            b = data[pos:pos + ln]; pos += ln
            return b, pos
        raise ValueError(f"field class {c} not implemented")


def jpos_fields_text(msg):
    """The field=value lines the jPOS harness (Pack.java) reads: binary fields as hex."""
    lines = [f"MTI={msg[0]}"]
    for f in sorted(k for k in msg if k > 1):
        v = msg[f]
        lines.append(f"{f}={v.hex().upper() if isinstance(v, (bytes, bytearray)) else v}")
    return "\n".join(lines) + "\n"


def parse_isomsg_xml(path):
    """A jPOS test fixture (.xml <isomsg><field id=.. value=..>) as a message dict; binary fields by the packager's class."""
    import xml.etree.ElementTree as ET
    root = ET.parse(path).getroot()
    msg = {}
    for fld in root.findall("field"):
        i = int(fld.get("id"))
        msg[i] = fld.get("value")
    return msg


if __name__ == "__main__":
    p = Packager("ISO87A")
    m = {0: "0100", 2: "4111111111111111", 3: "000000", 4: "000000012345", 7: "0913121500", 11: "123456", 41: "TERM0001", 49: "818"}
    b = p.pack(m)
    print(b.hex().upper()[:60], len(b))
    assert p.unpack(b) == m
