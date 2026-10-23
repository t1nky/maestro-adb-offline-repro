"""Stub adb server: answers host:devices with the rows given on the command line.

usage: fake_adb_server.py 'emulator-5560=device' 'emulator-5562=offline' ...
Prints the port it listens on, then serves until killed. A transport opens only for a `device`
row, like a real adb server; anything else gets `FAIL device <state>`.
"""
import socket
import sys
import threading

ROWS = dict(arg.split('=', 1) for arg in sys.argv[1:])


def reply(conn, status, payload=None):
    body = b'' if payload is None else b'%04x' % len(payload) + payload.encode()
    conn.sendall(status.encode() + body)


def serve(conn):
    with conn:
        transport = None
        while True:
            head = conn.recv(4)
            if len(head) < 4:
                return
            request = conn.recv(int(head, 16)).decode()
            if request == 'host:devices':
                return reply(conn, 'OKAY', ''.join(f'{serial}\t{state}\n' for serial, state in ROWS.items()))
            if request.startswith('host:transport:'):
                serial = request.removeprefix('host:transport:')
                state = ROWS.get(serial)
                if state != 'device':
                    return reply(conn, 'FAIL', f"device {state or 'not found'}")
                transport = serial
                reply(conn, 'OKAY')
                continue
            if request == 'host:features' and transport:
                return reply(conn, 'OKAY', 'shell_v2,cmd')
            return reply(conn, 'FAIL', f'unsupported request {request}')


server = socket.socket()
server.bind(('127.0.0.1', 0))
server.listen()
print(server.getsockname()[1], flush=True)
while True:
    connection, _ = server.accept()
    threading.Thread(target=serve, args=(connection,), daemon=True).start()
