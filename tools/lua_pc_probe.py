"""동일 Lua 프로토콜 코드를 PC 소켓·TLS 어댑터로 실제 기기에 연결합니다.

허브 SDK를 실행하는 도구가 아닙니다. 네트워크·CBOR·상태 해석은 driver/src의
Lua 5.3 코드를 사용하고, 전송 계층만 Python socket/ssl로 제공합니다.
GET·CSM만 허용하며 임시 인증서·키를 시험 종료 시 정리합니다.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
from pathlib import Path
import socket
import ssl
import sys
import tempfile
import time

from lupa.lua53 import LuaRuntime, lua_type

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools.readonly_probe import make_certificate


class Transport:
    """LuaSocket의 바이트 인덱스·부분 수신 계약을 Python 소켓에 연결합니다."""

    def __init__(self, sock: socket.socket, metrics: dict):
        self.sock = sock
        self.metrics = metrics

    def settimeout(self, seconds: float):
        self.sock.settimeout(seconds)
        return 1

    def connect(self, host: bytes, port: int):
        self.sock.connect((host.decode("ascii"), int(port)))
        return 1

    def send(self, data: bytes, first: int = 1):
        # 최초 송신에서 CoAP 메서드를 확인합니다. 부분 송신은 같은 원문을 이어 보냅니다.
        if first == 1:
            nibble = data[0] >> 4
            extra = {13: 1, 14: 2, 15: 4}.get(nibble, 0)
            code = data[1 + extra]
            if code not in (1, 225):
                raise ValueError("PC probe permits only GET and CSM")
            self.metrics["tcp_gets" if code == 1 else "csm"] += 1
        sent = self.sock.send(data[first - 1:])
        return first + sent - 1

    def receive(self, count: int):
        data = self.sock.recv(int(count))
        return data if data else (None, b"closed", b"")

    def sendto(self, data: bytes, host: bytes, port: int):
        if len(data) < 4 or data[1] != 1:
            if len(data) != 4 or data[:2] != b"\x60\x00":
                raise ValueError("PC probe permits only UDP GET and empty ACK")
        else:
            self.metrics["udp_gets"] += 1
        return self.sock.sendto(data, (host.decode("ascii"), int(port)))

    def receivefrom(self):
        try:
            data, (host, port) = self.sock.recvfrom(65536)
        except socket.timeout:
            return None, b"timeout"
        return data, host.encode("ascii"), port

    def setsockname(self, host: bytes, port: int):
        if int(port) != 0:
            raise ValueError("PC discovery binds only an ephemeral port")
        self.sock.bind(("" if host == b"*" else host.decode("ascii"), 0))
        return 1

    def dohandshake(self):
        self.sock.do_handshake()
        self.metrics["tls"] = {
            "version": self.sock.version(), "cipher": self.sock.cipher()[0],
            "server_chain_verified": True, "dns_hostname_verified": False,
        }
        return 1

    def close(self):
        self.sock.close()
        return 1


def summary_to_python(state) -> dict:
    """Lua의 평면 상태 요약과 지원 모드 문자열 배열을 JSON 값으로 변환합니다."""
    result = {}
    for name, value in state.items():
        if lua_type(value) == "table":
            entries = sorted(value.items())
            if [key for key, _ in entries] != list(range(1, len(entries) + 1)):
                raise ValueError("summary array must be contiguous")
            if not all(isinstance(child, bytes) for _, child in entries):
                raise ValueError("summary array must contain strings")
            value = [child.decode("utf-8") for _, child in entries]
        elif isinstance(value, bytes):
            value = value.decode("utf-8")
        result[name.decode("utf-8")] = value
    return result


def probe(host: str) -> dict:
    """임시 키·Lua 런타임·PC 어댑터를 준비하고 Lua의 전체 읽기 경로를 실행합니다."""
    root = Path(__file__).resolve().parents[1]
    runtime = LuaRuntime(encoding=None, unpack_returned_tuples=True, register_eval=False, register_builtins=False)
    assert runtime.eval(b"_VERSION") == b"Lua 5.3", "Lua 5.3 runtime is required"
    runtime.globals()[b"source_path"] = str(root / "driver/src/?.lua").encode()
    runtime.execute(b'package.path = source_path .. ";" .. package.path')
    network = runtime.eval(b'require "network"')
    if not network[b"valid_host"](host.encode("ascii")):
        raise ValueError("a private appliance IPv4 address is required")
    metrics = {"udp_gets": 0, "tcp_gets": 0, "csm": 0}
    transports: list[Transport] = []
    phases = []
    report = {"observed_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "execution": "Lua 5.3 protocol with Python socket/TLS adapter", "hub_sdk_executed": False,
        "appliance_state_written": False}

    def transport(sock):
        value = Transport(sock, metrics)
        transports.append(value)
        return value

    with tempfile.TemporaryDirectory(prefix="samsung-ac-lua-pc-") as folder:
        certificate, key = make_certificate(Path(folder))

        def ssl_wrap(raw: Transport, config):
            if config[b"verify"] != b"peer" or config[b"mode"] != b"client":
                raise ValueError("CA-verified client TLS is required")
            certificates = config[b"certificates"][1]
            if certificates[b"certificate"] != Path(certificate).read_bytes() or certificates[b"key"] != Path(key).read_bytes():
                raise ValueError("unexpected trial credentials")
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            context.check_hostname = False  # 장비 식별자는 Lua가 TLS 안에서 별도로 대조합니다.
            context.verify_mode = ssl.CERT_REQUIRED
            context.minimum_version = ssl.TLSVersion.TLSv1_2
            context.load_verify_locations(cadata=config[b"cafile"].decode("ascii"))
            context.load_cert_chain(certificate, key)
            return transport(context.wrap_socket(raw.sock, do_handshake_on_connect=False))

        globals_ = runtime.globals()
        globals_[b"py_udp"] = lambda: transport(socket.socket(socket.AF_INET, socket.SOCK_DGRAM))
        globals_[b"py_tcp"] = lambda: transport(socket.socket(socket.AF_INET, socket.SOCK_STREAM))
        globals_[b"py_now"] = time.monotonic
        globals_[b"py_ssl_wrap"] = ssl_wrap
        # Python 바운드 메서드와 Lua의 colon 호출을 명시적으로 연결합니다.
        socket_api, ssl_api = runtime.execute(b'''
          local function wrap(py)
            return {
              _py = py,
              settimeout = function(_, n) return py.settimeout(n) end,
              connect = function(_, h, p) return py.connect(h, p) end,
              send = function(_, data, first) return py.send(data, first or 1) end,
              receive = function(_, n) return py.receive(n) end,
              sendto = function(_, data, h, p) return py.sendto(data, h, p) end,
              receivefrom = function() return py.receivefrom() end,
              dohandshake = function() return py.dohandshake() end,
              close = function() return py.close() end,
            }
          end
          return { gettime = py_now, udp = function() return wrap(py_udp()) end,
            tcp = function() return wrap(py_tcp()) end },
            { wrap = function(raw, config) return wrap(py_ssl_wrap(raw._py, config)) end }
        ''')
        config = runtime.table_from({
            b"expires_at": int(time.time()) + 3600,
            b"ca_pem": (root / "assets/ocf-root-ca.pem").read_bytes(),
            b"client_certificate": Path(certificate).read_bytes(), b"client_key": Path(key).read_bytes(),
        })
        context = runtime.table()
        try:
            state, _identity = network[b"read"](socket_api, ssl_api, config, host.encode("ascii"), None, context,
                lambda name: phases.append(name.decode("ascii")))
            report["state"] = summary_to_python(state)
            report["public_and_secure_identity_match"] = True
        finally:
            # Lua가 오류를 던진 경우도 Python 어댑터가 소켓의 최종 정리를 보장합니다.
            for value in transports:
                value.close()
    report.update(metrics)
    report["phases"] = phases
    report["temporary_credentials_removed"] = not Path(folder).exists()
    report["open_socket_count"] = sum(value.sock.fileno() >= 0 for value in transports)
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        result = probe(args.host)
    except Exception as exc:
        # 런타임 예외에 원문 응답이나 자격 증명이 들어갈 가능성을 피합니다.
        print(json.dumps({"error_type": type(exc).__name__, "appliance_state_written": False}))
        return 1
    rendered = json.dumps(result, ensure_ascii=False, indent=2, allow_nan=False) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered, encoding="utf-8")
    print(rendered, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
