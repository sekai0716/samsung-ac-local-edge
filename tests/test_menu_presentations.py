"""앱 화면의 카드·스위치·활성 조건 계약을 검사합니다. 실제 렌더링은 휴대폰에서 별도 확인합니다."""

import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from tools import build_menu_capabilities as builder

ROOT = Path(__file__).resolve().parents[1]
PREFIX = "instantcommon43059.samsungAcLocal"
CARDS = [
    ("Operating", "ac-operating", "운전", "list", 2),
    ("Temperature", "ac-temperature", "희망 온도", "slider", 1),
    ("Comfort", "ac-comfort", "바람 설정", "list", 2),
    ("AirFeatures", "ac-air-features", "무풍·청정", "switch", 2),
    ("Timer", "ac-reservation", "예약", "list", 2),
    ("DeviceSettings", "ac-device-settings", "기기 설정", "list", 2),
    ("Display", "ac-display", "본체 화면", "switch", 1),
    ("Care", "ac-care", "자동청소", "switch", 1),
    ("Panel", "ac-panel", "청소용 패널", "list", 1),
]


def read_json(path):
    return json.loads((ROOT / path).read_text())


def configured_rows(slug, entry):
    """실제 구성의 add/replace/remove 패치를 순서대로 적용해 숨긴 행과 바뀐 인덱스까지 검사합니다."""
    rows = copy.deepcopy(read_json(f"capabilities/{slug}-presentation.json")["detailView"])
    for operation in entry["patch"]:
        parts = operation["path"].lstrip("/").split("/")
        parent = rows
        for part in parts[:-1]:
            parent = parent[int(part)] if isinstance(parent, list) else parent[part]
        key = int(parts[-1]) if isinstance(parent, list) else parts[-1]
        op = operation["op"]
        if op == "remove":
            del parent[key]
        elif op in {"add", "replace"}:
            if op == "replace":
                parent[key]  # 잘못된 대상에 대한 replace를 새 값 추가로 숨기지 않습니다.
            value = copy.deepcopy(operation["value"])
            if op == "add" and isinstance(parent, list):
                parent.insert(key, value)
            else:
                parent[key] = value
        else:
            raise AssertionError("검증하지 않은 화면 패치: " + op)
    return rows


class MenuPresentationTests(unittest.TestCase):
    def setUp(self):
        self.config = read_json("capabilities/ac-device-config.json")
        self.entries = {item["capability"]: item for item in self.config["detailView"]}
        self.rows = {suffix: configured_rows(slug, self.entries[PREFIX + suffix])
                     for suffix, slug, _, _, _ in CARDS}

    def test_cards_have_one_display_type_and_unique_korean_titles(self):
        custom = [item["capability"] for item in self.config["detailView"] if item["capability"].startswith(PREFIX)]
        self.assertEqual(custom, [PREFIX + card[0] for card in CARDS])
        for language in ("ko", "en"):
            titles = []
            for suffix, slug, title, display_type, count in CARDS:
                with self.subTest(card=suffix, language=language):
                    translation = read_json(f"capabilities/translations/{slug}-{language}.json")
                    self.assertEqual(translation["label"], title)
                    titles.append(translation["label"])
                    self.assertEqual(len(self.rows[suffix]), count)
                    self.assertEqual({row["displayType"] for row in self.rows[suffix]}, {display_type})
            self.assertEqual(len(titles), len(set(titles)))

    def test_switch_commands_and_mode_guards_are_preserved(self):
        switches = [("AirFeatures", 0, "windfree", "setWindfree"),
                    ("AirFeatures", 1, "purify", "setPurify"),
                    ("Display", 0, "display", "setDisplay"),
                    ("Care", 0, "autoclean", "setAutoclean")]
        for suffix, index, attribute, command in switches:
            with self.subTest(switch=attribute):
                row = self.rows[suffix][index]
                self.assertEqual(row["displayType"], "switch")
                control = row["switch"]
                self.assertEqual(control["command"], {"name": command, "on": "on", "off": "off", "argumentType": "string"})
                self.assertEqual(control["state"]["value"], attribute + ".value")
                self.assertEqual((control["state"]["on"], control["state"]["off"]), ("on", "off"))
                self.assertEqual({v["key"]: v["type"] for v in control["state"]["alternatives"]}, {"on": "active", "off": "inactive"})
                schema = read_json(f"tests/fixtures/capabilities/{PREFIX + suffix}.json")
                argument = schema["commands"][command]["arguments"][0]
                self.assertEqual(argument["name"], "setting")
                self.assertEqual(set(argument["schema"]["enum"]), {"on", "off"})
        self.assertEqual(self.rows["Care"][0]["label"], "자동청소")
        gates = {(suffix, index): row["visibleCondition"] for suffix, rows in self.rows.items()
                 for index, row in enumerate(rows) if "visibleCondition" in row}
        expected = {("Operating", 1): "fan", ("Temperature", 0): "setpoint", ("Comfort", 0): "preset",
                    ("AirFeatures", 0): "windfree", ("AirFeatures", 1): "purify", ("Panel", 0): "panel"}
        self.assertEqual(set(gates), set(expected))
        for key, attribute in expected.items():
            self.assertEqual(gates[key], {"component": "main", "capability": PREFIX + key[0], "version": 1,
                                         "value": attribute + "Enabled.value", "operator": "EQUALS", "operand": "enabled"})
        temperature = self.rows["Temperature"][0]["slider"]
        self.assertEqual((temperature["range"], temperature["step"], temperature["command"]), ([18, 30], 1, "setTemperature"))

    def test_generated_files_and_cached_operation_schema_stay_compatible(self):
        # 기존 ID에 새 속성을 끼워 넣으면 허브의 캐시된 정의에서 이벤트 생성이 실패할 수 있습니다.
        self.assertEqual(set(read_json("capabilities/ac-operation.json")["attributes"]), {"mode", "setpoint", "fan"})
        with tempfile.TemporaryDirectory(prefix="samsung-ac-menu-test-") as folder:
            temporary = Path(folder)
            (temporary / "capabilities").mkdir()
            (temporary / "tests/fixtures/capabilities").mkdir(parents=True)
            with patch.object(builder, "ROOT", temporary):
                builder.main()
            files = list((temporary / "capabilities").glob("*.json"))
            self.assertEqual(len(files), 18)
            for generated in files:
                with self.subTest(file=generated.name):
                    expected = json.loads(generated.read_text())
                    self.assertEqual(read_json("capabilities/" + generated.name), expected)
            for generated in (temporary / "tests/fixtures/capabilities").glob("*.json"):
                expected = json.loads(generated.read_text())
                actual = read_json("tests/fixtures/capabilities/" + generated.name)
                self.assertEqual(actual["attributes"], expected["attributes"])
                self.assertEqual(actual["commands"], expected["commands"])


if __name__ == "__main__":
    unittest.main()
