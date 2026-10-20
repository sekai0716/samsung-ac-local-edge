"""메뉴 묶음 capability 정의·표시·테스트 스키마를 같은 명세에서 생성합니다. 업로드하지 않습니다."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NAMESPACE = "instantcommon43059"


def attribute(values, setter=None):
    result = {"schema": {"type": "object", "properties": {"value": {"type": "string", "enum": values}},
                         "required": ["value"], "additionalProperties": False}, "enumCommands": []}
    if setter:
        result["setter"] = setter
    return result


def alternatives(items):
    return [{"key": key, "value": label, "type": "inactive" if key in {"off", "closed", "normal"} else "active"}
            for key, label in items]


def build(name, slug, rows, gates, temperature=False):
    """보조 활성 속성은 화면·루틴에 별도 행을 만들지 않고 visibleCondition에서만 사용합니다."""
    identifier = NAMESPACE + "." + name[0].lower() + name[1:].replace(" ", "")
    definition = {"name": name, "attributes": {}, "commands": {}}
    presentation = {"id": identifier, "version": 1, "dashboard": {"states": [], "actions": []},
                    "detailView": [], "automation": {"conditions": [], "actions": []}}
    for key, label, choices, display_type, state_only in rows:
        command = "set" + key[0].upper() + key[1:]
        definition["attributes"][key] = attribute([value for value, _ in choices + state_only], command)
        definition["commands"][command] = {"name": command, "sensitive": False, "arguments": [{"name": "setting", "optional": False, "schema": {
            "type": "string", "enum": [value for value, _ in choices]}}]}
        state = {"value": key + ".value", "valueType": "string", "alternatives": alternatives(choices + state_only)}
        # 상세 switch와 toggleSwitch는 같은 명령·상태 매핑을 사용하며 앱의 버튼 형태만 다릅니다.
        if display_type in {"toggleSwitch", "switch"}:
            state.update(on="on", off="off", label="{{" + key + ".value}}")
            control = {"command": {"name": command, "on": "on", "off": "off", "argumentType": "string"}, "state": state}
        else:
            control = {"command": {"name": command, "argumentType": "string", "alternatives": alternatives(choices)}, "state": state}
        presentation["detailView"].append({"label": label, "displayType": display_type, display_type: control})
        presentation["automation"]["conditions"].append({"label": label, "displayType": "list", "list": {
            "value": key + ".value", "alternatives": alternatives(choices + state_only)}})
        presentation["automation"]["actions"].append({"label": label, "displayType": "list", "list": {
            "command": command, "alternatives": alternatives(choices)}})
    for gate in gates:
        definition["attributes"][gate + "Enabled"] = attribute(["enabled", "disabled"])
    if temperature:
        # 이 기기의 기존 18~30도·1도 간격을 운전 카드에도 그대로 사용합니다.
        definition["attributes"]["setpoint"] = {"schema": {"type": "object", "properties": {
            "value": {"type": "number", "minimum": 18, "maximum": 30}, "unit": {"type": "string", "enum": ["C", "F"]}},
            "required": ["value", "unit"], "additionalProperties": False}, "enumCommands": [], "setter": "setTemperature"}
        definition["commands"]["setTemperature"] = {"name": "setTemperature", "sensitive": False, "arguments": [
            {"name": "setpoint", "optional": False, "schema": {"type": "number", "minimum": 18, "maximum": 30}}]}
        presentation["detailView"].insert(1, {"label": "희망 온도", "displayType": "slider", "slider": {
            "value": "setpoint.value", "valueType": "number", "command": "setTemperature", "argumentType": "number",
            "unit": "setpoint.unit", "range": [18, 30], "step": 1}})
        presentation["automation"]["conditions"].insert(1, {"label": "희망 온도", "displayType": "numberField", "numberField": {
            "value": "setpoint.value", "valueType": "number", "unit": "setpoint.unit", "range": [18, 30]}})
        presentation["automation"]["actions"].insert(1, {"label": "희망 온도", "displayType": "numberField", "numberField": {
            "command": "setTemperature", "argumentType": "number", "unit": "setpoint.unit", "range": [18, 30]}})
    for suffix, value in [("", definition), ("-presentation", presentation)]:
        (ROOT / "capabilities" / (slug + suffix + ".json")).write_text(
            json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    # API 등록 뒤 반환 정의와 비교하는 로컬 이벤트 스키마입니다.
    fixture = {"id": identifier, "version": 1, **definition}
    (ROOT / "tests/fixtures/capabilities" / (identifier + ".json")).write_text(
        json.dumps(fixture, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def main():
    switch = [("on", "켜짐"), ("off", "꺼짐")]
    build("Samsung Ac Local Operation", "ac-operation", [
        ("mode", "운전 모드", [("aIComfort", "인공지능 쾌적"), ("auto", "스마트쾌적"), ("cool", "냉방"), ("dry", "제습"), ("wind", "청정")], "list", []),
        ("fan", "바람 세기", [("auto", "자동"), ("low", "약풍"), ("medium", "중풍"), ("high", "강풍"), ("turbo", "터보")], "list", []),
    ], [], temperature=True)
    build("Samsung Ac Local Comfort", "ac-comfort", [
        ("preset", "운전 옵션 (냉방 운전 중)", [("normal", "일반"), ("speed", "스피드 · 무풍 해제"), ("quiet", "정음 · 무풍 해제")],
         "list", [("sleep", "열대야 쾌면"), ("other", "기타 운전 기능")]),
        ("windfree", "무풍 (전원 켠 냉방·제습·청정)", switch, "toggleSwitch", []),
        ("purify", "청정 (냉방·제습)", switch, "toggleSwitch", []),
        ("outlet", "바람문", [("closed", "닫힘"), ("upper", "상단만"), ("lower", "하단만"), ("both", "상·하단")], "list", []),
    ], ["preset", "windfree", "purify", "setpoint", "fan"])
    build("Samsung Ac Local Device Settings", "ac-device-settings", [
        ("lighting", "라이팅", [("off", "꺼짐"), ("low", "약한 밝기"), ("medium", "중간 밝기"), ("high", "강한 밝기")], "list", []),
        ("voice", "음성선택", [("low", "최소볼륨"), ("medium", "기본볼륨"), ("high", "최대볼륨"), ("melody", "효과음"), ("mute", "음소거")], "list", []),
        ("display", "본체 화면", switch, "toggleSwitch", []),
    ], [])
    build("Samsung Ac Local Care", "ac-care", [
        ("autoclean", "자동건조", switch, "switch", []),
        ("panel", "청소용 패널 (전원 끈 상태)", [("closed", "닫힘"), ("open", "열림")], "list", []),
    ], ["panel"])

    # Android 앱은 목록·슬라이더·토글을 다른 카드로 나눕니다. 분리되는 카드마다
    # 독립된 표시 이름을 두고, 기존 capability는 저장된 루틴 호환용으로 유지합니다.
    build("Samsung Ac Local Operating", "ac-operating", [
        ("mode", "운전 모드", [("aIComfort", "인공지능 쾌적"), ("auto", "스마트쾌적"), ("cool", "냉방"), ("dry", "제습"), ("wind", "청정")], "list", []),
        ("fan", "바람 세기", [("auto", "자동"), ("low", "약풍"), ("medium", "중풍"), ("high", "강풍"), ("turbo", "터보")], "list", []),
    ], ["fan"])
    build("Samsung Ac Local Temperature", "ac-temperature", [], ["setpoint"], temperature=True)
    build("Samsung Ac Local Air Features", "ac-air-features", [
        ("windfree", "무풍 (전원 켠 냉방·제습·청정)", switch, "switch", []),
        ("purify", "청정 (냉방·제습)", switch, "switch", []),
    ], ["windfree", "purify"])
    build("Samsung Ac Local Display", "ac-display", [
        ("display", "화면 표시", switch, "switch", []),
    ], [])
    build("Samsung Ac Local Panel", "ac-panel", [
        ("panel", "열림·닫힘 (운전 꺼짐)", [("closed", "닫힘"), ("open", "열림")], "list", []),
    ], ["panel"])


if __name__ == "__main__":
    main()
