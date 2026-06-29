#!/usr/bin/env python3
# Privacy-safe btsnoop -> ATT extractor.
# Outputs ONLY GATT/ATT layer (handles, UUIDs, written/notified bytes).
# Redacts BD_ADDRs entirely. No other bug-report content is touched.
import struct, sys

PATH = sys.argv[1] if len(sys.argv) > 1 else "btsnoop_hci.log"
data = open(PATH, "rb").read()

assert data[:8] == b"btsnoop\x00", "not a btsnoop file"
version, datalink = struct.unpack(">II", data[8:16])
off = 16
records = []
while off + 24 <= len(data):
    orig_len, incl_len, flags, drops, ts = struct.unpack(">IIIIq", data[off:off+24])
    off += 24
    pkt = data[off:off+incl_len]
    off += incl_len
    records.append((flags, ts, pkt))

# direction: flags bit0 (0=sent host->ctrl, 1=received ctrl->host)
def h4_type(flags, pkt):
    if datalink == 1002:  # H4: first byte is type
        return pkt[0], pkt[1:]
    # 1001 unencapsulated HCI: derive
    is_cmd_evt = flags & 0x02
    recv = flags & 0x01
    if is_cmd_evt:
        return (0x04 if recv else 0x01), pkt
    return 0x02, pkt  # assume ACL

# ACL reassembly per connection handle
bufs = {}   # handle -> (need_len, bytearray, dir)
handle_uuid = {}   # att handle -> uuid string
val_handle_char = {}  # char value handle -> char uuid
pending_read = {}  # conn -> last read handle
att_events = []    # (ts, dir, conn, text)

def uuid_str(b):
    if len(b) == 2:
        return "%04x" % struct.unpack("<H", b)[0]
    if len(b) == 16:
        u = b[::-1]
        return "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x" % tuple(u)
    return b.hex()

def parse_att(ts, recv, conn, att):
    if not att: return
    op = att[0]
    d = "RX" if recv else "TX"
    p = att[1:]
    def H(x): return struct.unpack("<H", x)[0]
    if op == 0x11:  # Read By Group Type Response (services)
        ln = p[0]; body = p[1:]
        for i in range(0, len(body), ln):
            e = body[i:i+ln]
            if len(e) < 4: break
            sh, eh = H(e[0:2]), H(e[2:4]); u = uuid_str(e[4:ln])
            att_events.append((ts, d, conn, f"SERVICE handles {sh:#06x}-{eh:#06x} uuid {u}"))
    elif op == 0x09:  # Read By Type Response (char declarations)
        ln = p[0]; body = p[1:]
        for i in range(0, len(body), ln):
            e = body[i:i+ln]
            if len(e) < 5: break
            decl_h = H(e[0:2]); props = e[2]; vh = H(e[3:5]); u = uuid_str(e[5:ln])
            val_handle_char[vh] = u
            handle_uuid[vh] = u
            att_events.append((ts, d, conn, f"CHAR decl@{decl_h:#06x} value_handle {vh:#06x} props {props:#04x} uuid {u}"))
    elif op == 0x05:  # Find Information Response
        fmt = p[0]; body = p[1:]
        step = 4 if fmt == 1 else 18
        for i in range(0, len(body), step):
            e = body[i:i+step]
            if len(e) < step: break
            h = H(e[0:2]); u = uuid_str(e[2:step])
            handle_uuid.setdefault(h, u)
    elif op in (0x52, 0x12, 0x18):  # Write Command / Write Request / Prepare? (0x18=exec) treat 0x12/0x52
        if op in (0x52, 0x12):
            h = H(p[0:2]); val = p[2:]
            u = handle_uuid.get(h, "?")
            att_events.append((ts, d, conn, f"WRITE handle {h:#06x} uuid {u} value[{len(val)}] {val.hex()}"))
    elif op in (0x1b, 0x1d):  # Notification / Indication
        h = H(p[0:2]); val = p[2:]
        u = handle_uuid.get(h, "?")
        kind = "NOTIFY" if op == 0x1b else "INDICATE"
        att_events.append((ts, d, conn, f"{kind} handle {h:#06x} uuid {u} value[{len(val)}] {val.hex()}"))
    elif op == 0x0a:  # Read Request
        h = H(p[0:2]); pending_read[conn] = h
    elif op == 0x0b:  # Read Response
        h = pending_read.get(conn); u = handle_uuid.get(h, "?") if h is not None else "?"
        att_events.append((ts, d, conn, f"READ_RESP handle {h if h is None else hex(h)} uuid {u} value[{len(p)}] {p.hex()}"))
    elif op == 0x1e:  # confirmation
        pass

for flags, ts, pkt in records:
    recv = flags & 0x01
    typ, body = h4_type(flags, pkt)
    if typ != 0x02:  # only ACL
        continue
    if len(body) < 4: continue
    hf = struct.unpack("<H", body[0:2])[0]
    conn = hf & 0x0FFF
    pb = (hf >> 12) & 0x3
    dlen = struct.unpack("<H", body[2:4])[0]
    payload = body[4:4+dlen]
    if pb in (0x0, 0x2):  # start of L2CAP PDU
        if len(payload) < 4:
            continue
        l2len, cid = struct.unpack("<HH", payload[0:4])
        frame = bytearray(payload[4:])
        bufs[conn] = (l2len, frame, cid, recv, ts)
        if len(frame) >= l2len and cid == 0x0004:
            parse_att(ts, recv, conn, bytes(frame[:l2len]))
            bufs.pop(conn, None)
    elif pb == 0x1:  # continuation
        if conn in bufs:
            l2len, frame, cid, rdir, rts = bufs[conn]
            frame += payload
            bufs[conn] = (l2len, frame, cid, rdir, rts)
            if len(frame) >= l2len and cid == 0x0004:
                parse_att(rts, rdir, conn, bytes(frame[:l2len]))
                bufs.pop(conn, None)

# Output
print(f"# btsnoop ATT extract (datalink {datalink}, {len(records)} records, {len(att_events)} ATT events)")
print("# BD_ADDRs redacted. Only GATT layer shown.\n")
print("## Handle -> UUID map (from discovery)")
for h in sorted(handle_uuid):
    print(f"  {h:#06x}  {handle_uuid[h]}")
print(f"\n## ATT exchange ({len(att_events)} events), ts in microseconds")
t0 = att_events[0][0] if att_events else 0
for ts, d, conn, text in att_events:
    print(f"  +{(ts-t0)/1e6:8.3f}s conn{conn:#06x} {d} {text}")
