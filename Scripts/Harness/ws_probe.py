#!/usr/bin/env python3
"""Quick stdlib WebSocket probe for the arc-agent webui (Python 3.9-safe)."""
import base64, json, os, socket, sys, struct, hashlib

URL = "ws://127.0.0.1:8890/ws"

def handshake(host, port, path, key):
    s = socket.create_connection((host, port), timeout=10)
    req = (
        f"GET {path} HTTP/1.1\r\n"
        f"Host: {host}:{port}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n\r\n"
    )
    s.sendall(req.encode())
    resp = b""
    while b"\r\n\r\n" not in resp:
        chunk = s.recv(4096)
        if not chunk:
            raise RuntimeError("closed during handshake")
        resp += chunk
    if b"101" not in resp.split(b"\r\n", 1)[0]:
        raise RuntimeError("handshake failed: %r" % resp[:200])
    return s

def send_text(s, payload):
    data = payload.encode()
    mask = os.urandom(4)
    header = bytearray([0x81])
    ln = len(data)
    if ln < 126:
        header.append(0x80 | ln)
    elif ln < 65536:
        header.append(0x80 | 126)
        header += struct.pack(">H", ln)
    else:
        header.append(0x80 | 127)
        header += struct.pack(">Q", ln)
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
    s.sendall(bytes(header) + mask + masked)

def recv_frame(s):
    head = s.recv(2)
    if not head:
        return None
    opcode = head[0] & 0x0F
    ln = head[1] & 0x7F
    if ln == 126:
        ln = struct.unpack(">H", s.recv(2))[0]
    elif ln == 127:
        ln = struct.unpack(">Q", s.recv(8))[0]
    payload = b""
    while len(payload) < ln:
        payload += s.recv(ln - len(payload))
    return opcode, payload

def probe(component, event, data):
    key = base64.b64encode(os.urandom(16)).decode()
    path = "/ws"
    parts = URL.split("://", 1)[1].split("/", 1)
    hostport, p = parts[0], parts[1] if len(parts) > 1 else ""
    host, port = hostport.split(":")
    s = handshake(host, int(port), "/" + p, key)
    msg = {"type": "event", "component": component, "event": event, "data": data}
    send_text(s, json.dumps(msg))
    s.settimeout(6)
    updates = []
    try:
        while True:
            f = recv_frame(s)
            if f is None:
                break
            opcode, payload = f
            if opcode == 1:
                obj = json.loads(payload.decode())
                if obj.get("type") == "update":
                    updates.append([u["id"] for u in obj.get("fragments", [])])
                elif obj.get("type") == "error":
                    print("  server error:", obj)
                else:
                    updates.append(obj.get("type"))
            elif opcode == 8:
                break
    except socket.timeout:
        pass
    s.close()
    return updates

if __name__ == "__main__":
    component, event = sys.argv[1], sys.argv[2]
    data = {}
    for a in sys.argv[3:]:
        if "=" in a:
            k, v = a.split("=", 1)
            data[k] = v
    result = probe(component, event, data)
    print(f"{component}/{event} -> {result}")
