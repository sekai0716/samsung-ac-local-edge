"""IP 지정 없이 동일 Lua 검색 코드로 지원 에어컨을 찾습니다. 공개 GET만 보냅니다."""

from __future__ import annotations

import argparse
import datetime as dt
import json
from pathlib import Path
import socket
import sys
import time

from lupa.lua53 import LuaRuntime

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools.lua_pc_probe import Transport


def probe() -> dict:
    """Lua 멀티캐스트 검색을 실행하고 개인 식별자를 제외한 결과와 소켓 정리를 기록합니다."""
    root = Path(__file__).resolve().parents[1]
    runtime = LuaRuntime(encoding=None, unpack_returned_tuples=True, register_eval=False, register_builtins=False)
    runtime.globals()[b"source_path"] = str(root / "driver/src/?.lua").encode()
    runtime.execute(b'package.path = source_path .. ";" .. package.path')
    network = runtime.eval(b'require "network"')
    metrics = {"udp_gets": 0}
    transports = []

    def udp():
        value = Transport(socket.socket(socket.AF_INET, socket.SOCK_DGRAM), metrics)
        transports.append(value)
        return value

    runtime.globals()[b"py_discovery_udp"] = udp
    runtime.globals()[b"py_discovery_now"] = time.monotonic
    adapter = runtime.execute(b'''
      return { gettime = py_discovery_now, udp = function()
        local py = py_discovery_udp()
        return {
          setsockname = function(_, h, p) return py.setsockname(h, p) end,
          settimeout = function(_, n) return py.settimeout(n) end,
          sendto = function(_, data, h, p) return py.sendto(data, h, p) end,
          receivefrom = function() return py.receivefrom() end,
          close = function() return py.close() end,
        }
      end }
    ''')
    report = {"observed_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "execution": "Lua 5.3 discovery with Python UDP adapter", "hub_sdk_executed": False,
        "target_ip_supplied": False, "appliance_state_written": False,
        "client_credentials_used": False, "devices": []}
    try:
        results = network[b"scan"](adapter, runtime.table())
        for _, device in results.items():
            # OCF UUID와 mnmo의 추가 식별 필드는 공개 결과에 넣지 않습니다.
            report["devices"].append({name: device[name.encode()].decode() for name in ("host", "model", "manufacturer")})
    finally:
        for transport in transports:
            transport.close()
    report.update(metrics)
    report["open_socket_count"] = sum(transport.sock.fileno() >= 0 for transport in transports)
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        result = probe()
    except Exception as exc:
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
