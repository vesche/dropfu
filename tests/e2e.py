#!/usr/bin/env python3
"""Black-box reliability test for the server, agent, protocol, and plugins."""

from __future__ import annotations

import base64
import hashlib
import http.client
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
SERVER = ROOT / "dropfu-server" / "zig-out" / "bin" / "dropfu-server"
AGENT = ROOT / "dropfu-agent" / "zig-out" / "bin" / "dropfu-agent"
PLUGIN_DIR = ROOT / "dropfu-plugins" / "dist"
OPERATOR_TOKEN = "e2e-operator-token"
AGENT_TOKEN = "e2e-agent-token-1"


def reserve_ports(count: int) -> list[int]:
    sockets: list[socket.socket] = []
    try:
        for _ in range(count):
            sock = socket.socket()
            sock.bind(("127.0.0.1", 0))
            sockets.append(sock)
        return [sock.getsockname()[1] for sock in sockets]
    finally:
        for sock in sockets:
            sock.close()


def wait_for_health(port: int, process: subprocess.Popen[bytes], timeout: float = 5) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise AssertionError(f"server exited during startup with status {process.returncode}")
        try:
            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=0.25)
            conn.request("GET", "/health")
            response = conn.getresponse()
            body = response.read()
            conn.close()
            if response.status == 200 and body == b"ok":
                return
        except OSError:
            pass
        time.sleep(0.05)
    raise AssertionError("server health check timed out")


def login(port: int) -> str:
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
    body = json.dumps({"token": OPERATOR_TOKEN})
    conn.request("POST", "/login", body=body, headers={"Content-Type": "application/json"})
    response = conn.getresponse()
    response.read()
    cookie = response.getheader("Set-Cookie")
    conn.close()
    assert response.status == 200, f"login returned HTTP {response.status}"
    assert cookie, "login did not return a session cookie"
    return cookie.split(";", 1)[0]


def test_split_login_request(port: int) -> None:
    body = json.dumps({"token": OPERATOR_TOKEN}).encode()
    request = (
        "POST /login HTTP/1.1\r\n"
        f"Host: 127.0.0.1:{port}\r\n"
        "Content-Type: application/json\r\n"
        f"Content-Length: {len(body)}\r\n"
        "Connection: close\r\n"
        "\r\n"
    ).encode()
    with socket.create_connection(("127.0.0.1", port), timeout=2) as sock:
        sock.sendall(request)
        time.sleep(0.05)
        sock.sendall(body)
        response = bytearray()
        while True:
            chunk = sock.recv(4096)
            if not chunk:
                break
            response.extend(chunk)
    assert response.startswith(b"HTTP/1.1 200"), response.decode(errors="replace")


class WebSocketClient:
    def __init__(self, port: int, cookie: str):
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=2)
        self.sock.settimeout(2)
        key = base64.b64encode(os.urandom(16)).decode()
        request = (
            "GET /ws HTTP/1.1\r\n"
            f"Host: 127.0.0.1:{port}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            f"Cookie: {cookie}\r\n"
            "Origin: http://127.0.0.1:3000\r\n"
            "\r\n"
        ).encode()
        self.sock.sendall(request)
        response = bytearray()
        while b"\r\n\r\n" not in response:
            chunk = self.sock.recv(4096)
            assert chunk, "connection closed during WebSocket handshake"
            response.extend(chunk)
        header, remainder = bytes(response).split(b"\r\n\r\n", 1)
        assert header.startswith(b"HTTP/1.1 101"), header.decode(errors="replace")
        self.buffer = bytearray(remainder)

    def close(self) -> None:
        try:
            self.sock.close()
        except OSError:
            pass

    def send(self, message: dict) -> None:
        payload = json.dumps(message, separators=(",", ":")).encode()
        mask = os.urandom(4)
        if len(payload) < 126:
            header = bytes((0x81, 0x80 | len(payload)))
        elif len(payload) <= 0xFFFF:
            header = bytes((0x81, 0xFE)) + struct.pack("!H", len(payload))
        else:
            header = bytes((0x81, 0xFF)) + struct.pack("!Q", len(payload))
        masked = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
        self.sock.sendall(header + mask + masked)

    def _read_exact(self, size: int, deadline: float) -> bytes:
        while len(self.buffer) < size:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("timed out waiting for WebSocket frame")
            self.sock.settimeout(remaining)
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("WebSocket closed")
            self.buffer.extend(chunk)
        data = bytes(self.buffer[:size])
        del self.buffer[:size]
        return data

    def receive(self, timeout: float = 5) -> dict:
        deadline = time.monotonic() + timeout
        while True:
            first, second = self._read_exact(2, deadline)
            opcode = first & 0x0F
            length = second & 0x7F
            if length == 126:
                length = struct.unpack("!H", self._read_exact(2, deadline))[0]
            elif length == 127:
                length = struct.unpack("!Q", self._read_exact(8, deadline))[0]
            if second & 0x80:
                mask = self._read_exact(4, deadline)
            else:
                mask = None
            payload = self._read_exact(length, deadline)
            if mask:
                payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
            if opcode == 0x8:
                raise ConnectionError("WebSocket close frame received")
            if opcode == 0x9:
                continue
            if opcode != 0x1:
                continue
            return json.loads(payload)

    def wait_for(self, predicate, timeout: float = 10) -> dict:
        deadline = time.monotonic() + timeout
        observed: list[dict] = []
        while time.monotonic() < deadline:
            try:
                message = self.receive(max(0.1, deadline - time.monotonic()))
            except TimeoutError:
                break
            observed.append(message)
            if predicate(message):
                return message
        raise AssertionError(f"message timeout; observed={observed!r}")


def envelope(message_type: str, message_id: str, **fields) -> dict:
    return {
        "type": message_type,
        "id": message_id,
        "timestamp": int(time.time()),
        "protocol_version": 1,
        "payload": {},
        **fields,
    }


def command(ws: WebSocketClient, agent_id: str, message_id: str, name: str, args: list[str]) -> dict:
    ws.send(
        envelope(
            "command",
            message_id,
            agent_id=agent_id,
            payload={"command": name, "args": args},
        )
    )
    result = ws.wait_for(
        lambda msg: msg.get("id") == message_id and msg.get("type") in {"result", "error"}
    )
    assert result["type"] == "result", result
    assert result["payload"]["status"] == "success", result
    return result


def terminate(process: subprocess.Popen[bytes] | None) -> None:
    if process is None or process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=3)


def main() -> None:
    assert SERVER.is_file(), f"missing server binary: {SERVER}"
    assert AGENT.is_file(), f"missing agent binary: {AGENT}"
    assert (PLUGIN_DIR / "portscan.pyz").is_file(), "plugins must be built before e2e"

    client_port, agent_port = reserve_ports(2)
    server_log = tempfile.TemporaryFile()
    agent_logs: list = []
    agents: list[subprocess.Popen[bytes]] = []
    ws: WebSocketClient | None = None

    server_env = os.environ.copy()
    server_env.update(
        {
            "DROPFU_OPERATOR_TOKEN": OPERATOR_TOKEN,
            "DROPFU_AGENT_TOKEN": AGENT_TOKEN,
            "DROPFU_ALLOW_INSECURE": "1",
            "DROPFU_CLIENT_PORT": str(client_port),
            "DROPFU_AGENT_PORT": str(agent_port),
            "DROPFU_PLUGIN_DIR": str(PLUGIN_DIR),
        }
    )

    with tempfile.TemporaryDirectory(prefix="dropfu-e2e-") as agent_cwd:
        for overrides, expected in (
            ({"DROPFU_CLIENT_PORT": "not-a-port"}, b"invalid DROPFU_CLIENT_PORT"),
            (
                {
                    "DROPFU_CLIENT_PORT": str(client_port),
                    "DROPFU_AGENT_PORT": str(client_port),
                },
                b"ports must be different",
            ),
        ):
            invalid_env = server_env.copy()
            invalid_env.update(overrides)
            invalid = subprocess.run(
                [str(SERVER)],
                cwd=ROOT,
                env=invalid_env,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=3,
                check=False,
            )
            assert invalid.returncode != 0, invalid.stdout.decode(errors="replace")
            assert expected in invalid.stdout, invalid.stdout.decode(errors="replace")

        server = subprocess.Popen(
            [str(SERVER)],
            cwd=ROOT,
            env=server_env,
            stdout=server_log,
            stderr=subprocess.STDOUT,
        )
        try:
            wait_for_health(client_port, server)
            test_split_login_request(client_port)

            # A normal restart must succeed immediately even while accepted
            # connections from the prior process remain in TIME_WAIT.
            terminate(server)
            server = subprocess.Popen(
                [str(SERVER)],
                cwd=ROOT,
                env=server_env,
                stdout=server_log,
                stderr=subprocess.STDOUT,
            )
            wait_for_health(client_port, server)

            duplicate = subprocess.run(
                [str(SERVER)],
                cwd=ROOT,
                env=server_env,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=3,
                check=False,
            )
            assert duplicate.returncode != 0, "duplicate server unexpectedly exited successfully"
            assert (
                b"already owns ports" in duplicate.stdout or b"AddressInUse" in duplicate.stdout
            ), duplicate.stdout.decode(errors="replace")

            agent_env = os.environ.copy()
            fake_path = Path(agent_cwd, "host-python-must-not-run")
            fake_path.mkdir()
            fake_python = fake_path / "python3"
            fake_python.write_text(
                "#!/bin/sh\n"
                "echo 'host python was executed' >&2\n"
                "exit 99\n",
                encoding="utf-8",
            )
            fake_python.chmod(0o755)
            runtime_tmp = Path(agent_cwd, "runtime-tmp")
            runtime_tmp.mkdir()
            agent_env.update(
                {
                    "DROPFU_AGENT_TOKEN": AGENT_TOKEN,
                    "DROPFU_SERVER_HOST": "127.0.0.1",
                    "DROPFU_SERVER_PORT": str(agent_port),
                    "DROPFU_CLIENT_PORT": str(client_port),
                    # A host-interpreter implementation fails the plugin run.
                    # The embedded runtime also has to ignore Python env hooks.
                    "PATH": str(fake_path) + os.pathsep + agent_env.get("PATH", ""),
                    "PYTHONHOME": str(Path(agent_cwd, "invalid-python-home")),
                    "PYTHONPATH": str(Path(agent_cwd, "invalid-python-path")),
                    "TMPDIR": str(runtime_tmp),
                    "TEMP": str(runtime_tmp),
                }
            )
            invalid_agent_env = agent_env.copy()
            invalid_agent_env["DROPFU_SERVER_PORT"] = "not-a-port"
            invalid_agent = subprocess.run(
                [str(AGENT)],
                cwd=agent_cwd,
                env=invalid_agent_env,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=3,
                check=False,
            )
            assert invalid_agent.returncode != 0, invalid_agent.stdout.decode(errors="replace")
            assert b"invalid DROPFU_SERVER_PORT" in invalid_agent.stdout

            agent_log = tempfile.TemporaryFile()
            agent_logs.append(agent_log)
            agent = subprocess.Popen(
                [str(AGENT)],
                cwd=agent_cwd,
                env=agent_env,
                stdout=agent_log,
                stderr=subprocess.STDOUT,
            )
            agents.append(agent)

            ws = WebSocketClient(client_port, login(client_port))
            listing = ws.wait_for(
                lambda msg: msg.get("type") == "agent_list" and len(msg["payload"]["agents"]) == 1,
                timeout=8,
            )
            agent_id = listing["payload"]["agents"][0]["agent_id"]

            ws.send(envelope("heartbeat", "0000000000000001"))
            heartbeat = ws.wait_for(lambda msg: msg.get("type") == "heartbeat" and msg.get("id") == "0000000000000001")
            assert "agent_id" not in heartbeat

            pwd = command(ws, agent_id, "0000000000000002", "pwd", [])
            assert agent_cwd in pwd["payload"]["data"]

            shell_id = "0000000000000009"
            shell_started = command(ws, agent_id, shell_id, "shell", [])
            assert "started" in shell_started["payload"]["data"]
            ws.send(
                envelope(
                    "shell_data",
                    shell_id,
                    agent_id=agent_id,
                    payload={"data": "echo DROPFU_SHELL_OK\n", "eof": False},
                )
            )
            shell_output = ws.wait_for(
                lambda msg: msg.get("type") == "shell_data"
                and msg.get("id") == shell_id
                and "DROPFU_SHELL_OK" in msg["payload"].get("data", "")
            )
            assert "DROPFU_SHELL_OK" in shell_output["payload"]["data"]
            ws.send(
                envelope(
                    "shell_close",
                    shell_id,
                    agent_id=agent_id,
                    payload={},
                )
            )
            ws.wait_for(
                lambda msg: msg.get("type") == "shell_data"
                and msg.get("id") == shell_id
                and msg["payload"].get("eof") is True
            )

            # A syntax error must be reported without ending the interactive
            # shell. A later command on the same session has to succeed, and
            # the shell exiting by itself must still allow a new one.
            shell_id = "000000000000000a"
            shell_started = command(ws, agent_id, shell_id, "shell", [])
            assert "started" in shell_started["payload"]["data"]
            ws.send(
                envelope(
                    "shell_data",
                    shell_id,
                    agent_id=agent_id,
                    payload={"data": "echo (foo)\n", "eof": False},
                )
            )
            ws.wait_for(
                lambda msg: msg.get("type") == "shell_data"
                and msg.get("id") == shell_id
                # dash reports "Syntax error"; bash reports "syntax error".
                and "syntax error" in msg["payload"].get("data", "").lower()
            )
            ws.send(
                envelope(
                    "shell_data",
                    shell_id,
                    agent_id=agent_id,
                    payload={"data": "echo DROPFU_SHELL_STILL_ALIVE\n", "eof": False},
                )
            )
            ws.wait_for(
                lambda msg: msg.get("type") == "shell_data"
                and msg.get("id") == shell_id
                and "DROPFU_SHELL_STILL_ALIVE" in msg["payload"].get("data", "")
                and msg["payload"].get("eof") is not True
            )
            ws.send(
                envelope(
                    "shell_data",
                    shell_id,
                    agent_id=agent_id,
                    payload={"data": "exit\n", "eof": False},
                )
            )
            ws.wait_for(
                lambda msg: msg.get("type") == "shell_data"
                and msg.get("id") == shell_id
                and msg["payload"].get("eof") is True
            )
            restarted = command(ws, agent_id, "000000000000000b", "shell", [])
            assert "started" in restarted["payload"]["data"], restarted
            ws.send(
                envelope(
                    "shell_close",
                    "000000000000000b",
                    agent_id=agent_id,
                    payload={},
                )
            )
            ws.wait_for(
                lambda msg: msg.get("type") == "shell_data"
                and msg.get("id") == "000000000000000b"
                and msg["payload"].get("eof") is True
            )

            plugins = command(ws, agent_id, "0000000000000003", "plugin", ["list"])
            assert "portscan" in plugins["payload"]["data"]

            installed = command(ws, agent_id, "0000000000000004", "plugin", ["install", "portscan"])
            assert "installed" in installed["payload"]["data"], installed
            assert agent.poll() is None, "agent crashed during plugin install"
            assert Path(agent_cwd, "plugins", "portscan.pyz").is_file()

            scan = command(
                ws,
                agent_id,
                "0000000000000005",
                "plugin",
                ["run", "portscan", "--ports", str(client_port), "--timeout", "0.1", "127.0.0.1"],
            )
            assert str(client_port) in scan["payload"]["data"], scan
            runtime_dirs = set(runtime_tmp.glob(".dropfu-python-*"))
            assert len(runtime_dirs) == 1, runtime_dirs

            installed_ps = command(ws, agent_id, "000000000000000c", "plugin", ["install", "ps"])
            assert "installed" in installed_ps["payload"]["data"], installed_ps
            ps_result = command(
                ws,
                agent_id,
                "000000000000000d",
                "plugin",
                ["run", "ps", "--sort", "pid", "--top", "1"],
            )
            assert "PID" in ps_result["payload"]["data"], ps_result

            installed_file = command(
                ws, agent_id, "000000000000000e", "plugin", ["install", "file"]
            )
            assert "installed" in installed_file["payload"]["data"], installed_file
            file_result = command(
                ws,
                agent_id,
                "000000000000000f",
                "plugin",
                ["run", "file", "plugins/portscan.pyz"],
            )
            assert "application/zip" in file_result["payload"]["data"], file_result
            assert set(runtime_tmp.glob(".dropfu-python-*")) == runtime_dirs

            upload_data = b"dropfu-e2e-upload\x00\xff"
            upload_path = str(Path(agent_cwd, "uploaded.bin"))
            upload_id = "0000000000000006"
            ready = command(ws, agent_id, upload_id, "upload", [upload_path, str(len(upload_data))])
            assert ready["payload"]["data"] == "ready for upload"
            ws.send(
                envelope(
                    "file_chunk",
                    upload_id,
                    agent_id=agent_id,
                    payload={
                        "offset": 0,
                        "data": base64.b64encode(upload_data).decode(),
                        "final": True,
                    },
                )
            )
            ack = ws.wait_for(lambda msg: msg.get("type") == "file_ack" and msg.get("id") == upload_id)
            assert ack["payload"]["status"] == "success", ack
            assert Path(upload_path).read_bytes() == upload_data
            assert ack["payload"]["sha256"] == hashlib.sha256(upload_data).hexdigest()

            download_id = "0000000000000007"
            ws.send(
                envelope(
                    "command",
                    download_id,
                    agent_id=agent_id,
                    payload={"command": "download", "args": [upload_path]},
                )
            )
            downloaded = bytearray()
            saw_meta = False
            saw_result = False
            while not saw_result:
                message = ws.receive(timeout=5)
                if message.get("id") != download_id:
                    continue
                if message.get("type") == "file_meta":
                    saw_meta = True
                    assert message["payload"]["size"] == len(upload_data)
                elif message.get("type") == "file_chunk":
                    assert message["payload"]["offset"] == len(downloaded)
                    downloaded.extend(base64.b64decode(message["payload"]["data"], validate=True))
                elif message.get("type") == "result":
                    assert message["payload"]["status"] == "success", message
                    saw_result = True
            assert saw_meta
            assert bytes(downloaded) == upload_data

            # Exercise same-ID replacement: the new registration must survive
            # teardown of the old connection.
            replacement_log = tempfile.TemporaryFile()
            agent_logs.append(replacement_log)
            replacement = subprocess.Popen(
                [str(AGENT)],
                cwd=agent_cwd,
                env=agent_env,
                stdout=replacement_log,
                stderr=subprocess.STDOUT,
            )
            agents.append(replacement)
            time.sleep(0.5)
            terminate(agent)
            time.sleep(0.5)
            reconnect_result = command(ws, agent_id, "0000000000000008", "pwd", [])
            assert reconnect_result["payload"]["status"] == "success"
            assert replacement.poll() is None

            print("e2e: auth, heartbeat, commands, shell, plugins, transfers, reconnect, and bind protection passed")
        except Exception:
            server_log.seek(0)
            print("\n--- server log ---")
            print(server_log.read().decode(errors="replace"))
            for index, log in enumerate(agent_logs):
                log.seek(0)
                print(f"\n--- agent {index + 1} log ---")
                print(log.read().decode(errors="replace"))
            raise
        finally:
            if ws:
                ws.close()
            for process in agents:
                terminate(process)
            terminate(server)
            server_log.close()
            for log in agent_logs:
                log.close()


if __name__ == "__main__":
    main()
