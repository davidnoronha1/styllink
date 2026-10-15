#!/usr/bin/env python3
"""Compile the Android-independent Link and exercise it against a mock WebSocket."""
import pathlib
import socket
import struct
import subprocess
import tempfile
import threading

ROOT = pathlib.Path(__file__).resolve().parents[1]
errors, received = [], []

def exact(conn, n):
    data = b''
    while len(data) < n:
        part = conn.recv(n - len(data))
        if not part:
            raise EOFError
        data += part
    return data

def serve(conn):
    try:
        with conn:
            conn.settimeout(8)
            head = b''
            while not head.endswith(b'\r\n\r\n'):
                head += exact(conn, 1)
            assert head.startswith(b'GET /ws?t=test-token HTTP/1.1\r\n')
            conn.sendall(b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n')
            conn.sendall(b'\x81\x04b123')
            while True:
                op, size = exact(conn, 2)
                assert size & 128, 'client must mask frames'
                size &= 127
                if size == 126:
                    size = struct.unpack('!H', exact(conn, 2))[0]
                mask = exact(conn, 4)
                data = bytes(b ^ mask[i % 4] for i, b in enumerate(exact(conn, size)))
                received.append((op & 15, data))
                if data == b'done':
                    return
    except (EOFError, ConnectionResetError, BrokenPipeError):
        pass
    except Exception as exc:
        errors.append(exc)

with socket.socket() as server, tempfile.TemporaryDirectory() as build:
    server.bind(('127.0.0.1', 0))
    server.listen()
    server.settimeout(0.2)
    stop = threading.Event()
    workers = []
    def accept():
        while not stop.is_set():
            try:
                conn, _ = server.accept()
            except socket.timeout:
                continue
            worker = threading.Thread(target=serve, args=(conn,), daemon=True)
            workers.append(worker)
            worker.start()
    listener = threading.Thread(target=accept)
    listener.start()
    try:
        subprocess.run(['javac', '-d', build, str(ROOT / 'android/src/dev/styllink/Link.java'),
                        str(ROOT / 'tests/LinkCheck.java')], check=True)
        subprocess.run(['java', '-cp', build, 'dev.styllink.LinkCheck',
                        f'127.0.0.1:{server.getsockname()[1]}'], check=True, timeout=30)
    finally:
        stop.set()
        listener.join()
        for worker in workers:
            worker.join(1)
assert not errors, errors
assert (1, b'i111111') in received
assert (1, b'b123') in received
assert any(op == 2 and len(data) == 644 and data[4] == 42 for op, data in received)
assert (1, b'reconnected') in received
print('Masked frames, batched samples, ping echo and reconnect verified')
