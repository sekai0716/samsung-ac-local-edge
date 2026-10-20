"""Lua 5.3에서 프로토콜 경계·실측 상태 fixture·드라이버 등록을 검사합니다."""

import argparse
import json
from pathlib import Path
import subprocess
import tempfile

import cbor2
from jsonschema import Draft4Validator


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lua", help="별도 Lua 5.3 실행기. 생략하면 Lupa의 Lua 5.3 사용")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    observed = json.loads((root / "docs/observed-resources.json").read_text())
    fixture = [{"href": href, "rep": value} for href, value in observed["resources"].items()]
    with tempfile.TemporaryDirectory(prefix="samsung-ac-lua-tests-") as folder:
        path = Path(folder) / "state.cbor"
        events_path = Path(folder) / "events.cbor"
        path.write_bytes(cbor2.dumps(fixture))
        if args.lua:
            subprocess.run([args.lua, str(root / "tests/lua/test.lua"), str(root), str(path), str(events_path)], check=True, cwd=root)
        else:
            from lupa.lua53 import LuaRuntime
            runtime = LuaRuntime(encoding=None, unpack_returned_tuples=True)
            runtime.globals()[b"arg"] = runtime.table_from({1: str(root).encode(), 2: str(path).encode(), 3: str(events_path).encode()})
            runtime.execute((root / "tests/lua/test.lua").read_bytes())
        # 모사 SDK가 만든 이벤트도 실제 공개 capability의 속성 스키마로 검사합니다.
        # 개수와 개별 CBOR 항목으로 수집해, 전체 검사 로그에 본체 프레임 크기 제한을 적용하지 않습니다.
        with events_path.open("rb") as stream:
            decoder = cbor2.CBORDecoder(stream)
            count = decoder.decode()
            assert isinstance(count, int) and count > 0, "no capability events collected"
            events = [decoder.decode() for _ in range(count)]
            assert stream.read(1) == b"", "unexpected trailing event data"
        for event in events:
            capability = json.loads((root / "tests/fixtures/capabilities" / (event["capability"] + ".json")).read_text())
            Draft4Validator(capability["attributes"][event["attribute"]]["schema"]).validate(event["data"])
        print(f"Official capability schema validation passed: {len(events)} events")


if __name__ == "__main__":
    main()
