"""삼성 OCF 에어컨의 공개 정보와 인증된 상태를 GET으로만 확인합니다.

허브용 드라이버가 아닌 개발 PC용 검증 도구입니다. 인증 시험을 명시한 경우에만
임시 클라이언트 인증서를 만들며, 성공과 실패 모두 임시 디렉터리를 정리합니다.
출력에는 장비 UUID, 인증 정보, Wi-Fi 설정과 원문 응답을 포함하지 않습니다.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import ipaddress
import json
import math
import os
import re
import secrets
import socket
import ssl
import tempfile
import time
from pathlib import Path
from typing import Any

import cbor2
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID

# 공개 프로젝트의 서비스 식별자이며 사용자 계정의 토큰은 아닙니다.
# 출처와 시험 승인 범위는 docs/design.md에 기록합니다.
CLIENT_ID = "ab0b0ac4-aae9-4958-a04d-8ec36fe1b2f9"
MAX_FRAME = 65_536
TIMEOUT = 4.0
PREFIX = "x.com.samsung.da."
STATE_PATHS = (
    "/power/vs/0", "/power/0", "/mode/vs/0",
    "/temperature/current/0", "/temperature/desired/0", "/temperature/control/vs/0",
    "/temperatures/vs/0", "/airflow/vs/0", "/wind/strength/vs/0",
    "/wind/direction/vs/0", "/mode/convenient/vs/0",
    "/humidity/vs/0", "/humidity/0",
    "/sensors/vs/0", "/energy/consumption/vs/0", "/energy/consumption/0",
    "/airflow/0", "/mode/0", "/alarms/vs/0", "/diagnosis/vs/0",
    "/consumable/vs/0", "/drlc/0", "/drlc/vs/0",
    "/configuration/vs/0", "/file/information/vs/0",
    "/filter/airdustfilter/vs/0", "/filter/airdustPM1filter/vs/0",
    "/multidevice/vs/0", "/hass/state/vs/0", "/rm/micomdata/vs/0",
)
SAFE_FIELDS = {
    "value", "temperature", "humidity", "units", "range", "step", "increment",
    "energy", "power", "direction", "speed", "modes", "supportedModes",
    "DRLevel", "duration", "override", "start",
    "x.com.samsung.supprtedtype", "x.com.samsung.timeoffset",
    "x.com.samsung.rm.micomdataLength",
    *(PREFIX + key for key in (
        "power", "modes", "supportedModes", "speedLevel", "maxSpeedLevel",
        "direction", "supportedDirections", "current", "desired", "minimum",
        "maximum", "unit", "items", "options", "humidity", "fivepercentHumidity",
        "type", "value", "cleanLevel", "instantaneousPower", "cumulativePower",
        "cumulativeConsumption", "cumulativeSavedPower", "monthlyConsumption",
        "thismonthlyConsumption", "usageThreshold", "diagnosisStart", "region",
        "drlcLevel", "drlcStartTime", "duration", "override", "filterUsage",
        "filterCapacity", "filterCapacityUnit", "filterStatus", "filterDesiredUsage",
        "code", "state", "alarmType", "triggeredTime", "name",
        "numofsubdevice", "fileTransResult", "hassClosed", "hassResult", "hassUpdateReady",
    )),
}

# 상태 값으로 의미가 확인된 옵션만 보관합니다. ModelInfo 등 식별 토큰은 제외합니다.
OPTION_VALUES = {"Comode_" + mode for mode in (
    "Off", "Nano", "Sleep", "NanoSleep", "Speed", "Quiet", "Comfort", "2Step", "Smart",
)} | {prefix + "_" + value for prefix in (
    "Spi", "Autoclean", "AirMonitoring", "SmartCoolClean", "StopAutoClean",
) for value in ("On", "Off")} | {"Volume_Mute"}
NUMERIC_OPTION = re.compile(
    r"(?:Volume|Sleep|OutdoorTemp|FilterTime|FilterAlarmTime|AutocleanProgress|ProgressSmartClean)_[0-9]{1,8}"
)
# 실제로 광고된 추가 옵션입니다. 의미가 미확정이어도 원시 상태는 기록하며,
# 기기 식별자를 포함할 수 있는 ModelInfo/RacInfo 토큰은 계속 제외합니다.
EXTRA_OPTION_PREFIXES = {
    "AI", "AirpatrolInterval", "ArtificialWorking", "Blooming", "ComfortAICooling",
    "Dehumidification", "DiagnosisAI", "Display", "DurationOn", "EnergySaveIcon",
    "ExtendOptionCode", "Light", "OffTimer", "OnTimer", "Operation", "OptionCode",
    "PM1Progress", "Panel", "ProgressDiagnosisAI", "PurifiAI", "ResultDiagnosisAI",
    "Smarton", "UpdateAllow", "VoiceSet", "Volume", "WakeupWord", "WakeupWordRange",
    "Weather", "WelcomeCoolingState", "StopAutoClean",
}
APPLICATION_PATH = re.compile(r"/(?:[A-Za-z][A-Za-z0-9_]*/)*[0-9]{1,3}")
PRIVATE_PREFIXES = ("/oic/", "/sec/", "/voice/provisioning/", "/wirelessinfo/", "/connectionconfig/")


def _nibble(value: int) -> tuple[int, bytes]:
    """CoAP 옵션 길이와 TCP 프레임 길이의 확장 숫자를 인코딩합니다."""
    if not 0 <= value <= MAX_FRAME:
        raise ValueError("length outside diagnostic limit")
    if value < 13:
        return value, b""
    if value < 269:
        return 13, bytes((value - 13,))
    return 14, (value - 269).to_bytes(2, "big")


def get_options(path: str, query: str | None = None) -> bytes:
    """GET 경로와 쿼리만 인코딩하며 메서드는 호출자가 바꿀 수 없습니다."""
    pairs = [(11, segment.encode()) for segment in path.strip("/").split("/")]
    if query:
        pairs.append((15, query.encode()))
    encoded, previous = bytearray(), 0
    for number, value in pairs:
        delta, delta_ext = _nibble(number - previous)
        length, length_ext = _nibble(len(value))
        encoded.extend(bytes(((delta << 4) | length,)) + delta_ext + length_ext + value)
        previous = number
    return bytes(encoded)


def parse_options(data: bytes) -> tuple[list[tuple[int, bytes]], bytes]:
    """옵션 경계를 검증한 뒤 CBOR 페이로드를 분리합니다."""
    options, number, offset = [], 0, 0

    def extended(nibble: int) -> int:
        nonlocal offset
        if nibble < 13:
            return nibble
        if nibble == 15:
            raise ValueError("reserved CoAP option nibble")
        count = 1 if nibble == 13 else 2
        if offset + count > len(data):
            raise ValueError("truncated CoAP option extension")
        value = int.from_bytes(data[offset:offset + count], "big")
        offset += count
        return value + (13 if count == 1 else 269)

    while offset < len(data):
        head = data[offset]
        offset += 1
        if head == 255:
            if offset == len(data):
                raise ValueError("empty CoAP payload marker")
            return options, data[offset:]
        number += extended(head >> 4)
        length = extended(head & 15)
        if offset + length > len(data):
            raise ValueError("truncated CoAP option")
        options.append((number, data[offset:offset + length]))
        offset += length
    return options, b""


def read_exact(stream: Any, count: int, deadline: float) -> bytes:
    """분할된 TCP 수신을 합치며 전체 요청의 기한을 늘리지 않습니다."""
    output = bytearray()
    while len(output) < count:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("CoAP response deadline")
        stream.settimeout(remaining)
        chunk = stream.recv(count - len(output))
        if not chunk:
            raise ConnectionError("peer closed connection")
        output.extend(chunk)
    return bytes(output)


def read_frame(stream: Any, deadline: float) -> tuple[int, bytes, bytes]:
    """RFC 8323의 Len은 Code와 Token을 제외한다는 규칙을 적용합니다."""
    head = read_exact(stream, 1, deadline)[0]
    length, token_length = head >> 4, head & 15
    if token_length > 8:
        raise ValueError("invalid CoAP token length")
    if length >= 13:
        count, base = {13: (1, 13), 14: (2, 269), 15: (4, 65_805)}[length]
        length = int.from_bytes(read_exact(stream, count, deadline), "big") + base
    if length > MAX_FRAME:
        raise ValueError("response outside diagnostic limit")
    body = read_exact(stream, 1 + token_length + length, deadline)
    return body[0], body[1:1 + token_length], body[1 + token_length:]


def tcp_get(path: str, token: bytes, query: str | None = None) -> bytes:
    """페이로드 없는 GET만 생성합니다. 상태 변경 명령은 제공하지 않습니다."""
    if not 1 <= len(token) <= 8:
        raise ValueError("invalid request token length")
    options = get_options(path, query)
    length, extension = _nibble(len(options))
    return bytes(((length << 4) | len(token),)) + extension + b"\x01" + token + options


def public_get(host: str, path: str, query: str | None = None) -> Any:
    """UDP 5683에 공개 GET을 보내며 같은 호스트의 동적 응답 포트를 허용합니다."""
    token, message_id = secrets.token_bytes(4), secrets.token_bytes(2)
    packet = b"\x44\x01" + message_id + token + get_options(path, query)
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as stream:
        stream.bind(("", 0))
        stream.sendto(packet, (host, 5683))
        deadline = time.monotonic() + TIMEOUT
        while time.monotonic() < deadline:
            stream.settimeout(max(0.01, deadline - time.monotonic()))
            reply, peer = stream.recvfrom(MAX_FRAME)
            if peer[0] != host or len(reply) < 8 or reply[0] >> 6 != 1:
                continue
            token_length = reply[0] & 15
            if token_length > 8 or reply[4:4 + token_length] != token:
                continue
            if (reply[0] >> 4) & 3 == 0:
                stream.sendto(b"\x60\x00" + reply[2:4], peer)
            if reply[1] != 69:
                raise RuntimeError("public GET rejected: " + code_name(reply[1]))
            options, payload = parse_options(reply[4 + token_length:])
            if any(number == 23 and int.from_bytes(value, "big") & 8 for number, value in options):
                raise RuntimeError("public directory requires Block2; use filtered discovery")
            return cbor2.loads(payload)
    raise TimeoutError("no correlated public OCF response")


def code_name(code: int) -> str:
    return f"{code >> 5}.{code & 31:02d}"


def walk_maps(value: Any, depth: int = 0):
    """OCF 배열과 맵을 순회하며 고정된 배열 위치에 의존하지 않습니다."""
    if depth > 32:
        raise ValueError("OCF representation exceeds diagnostic nesting limit")
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from walk_maps(child, depth + 1)
    elif isinstance(value, list):
        for child in value:
            yield from walk_maps(child, depth + 1)


def tcp_port(directory: Any) -> int:
    """광고된 TLS 포트만 채택하며 UDP 포트와 구분합니다."""
    for entry in walk_maps(directory):
        if entry.get("href") != "/oic/sec/doxm":
            continue
        policy = entry.get("p", {})
        port = policy.get("x.org.iotivity.tls")
        if policy.get("sec") is True and type(port) is int and 1 <= port <= 65_535:
            return port
    raise ValueError("no advertised TCP TLS endpoint")


def make_certificate(directory: Path, validity_days: int = 1) -> tuple[str, str]:
    """지정한 유효기간의 자체서명 인증서를 만듭니다. 읽기 진단의 기본값은 하루입니다."""
    if type(validity_days) is not int or not 1 <= validity_days <= 36500:
        raise ValueError("certificate validity must be 1..36500 days")
    key = rsa.generate_private_key(public_exponent=65_537, key_size=2048)
    subject = x509.Name([
        x509.NameAttribute(NameOID.ORGANIZATIONAL_UNIT_NAME, "uuid:" + CLIENT_ID),
        x509.NameAttribute(NameOID.COMMON_NAME, "urn:uuid:" + CLIENT_ID),
    ])
    now = dt.datetime.now(dt.timezone.utc)
    cert = (x509.CertificateBuilder().subject_name(subject).issuer_name(subject)
        .public_key(key.public_key()).serial_number(x509.random_serial_number())
        .not_valid_before(now - dt.timedelta(minutes=5)).not_valid_after(now + dt.timedelta(days=validity_days))
        .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
        .add_extension(x509.KeyUsage(digital_signature=True, content_commitment=False, key_encipherment=True,
            data_encipherment=False, key_agreement=False, key_cert_sign=False, crl_sign=False,
            encipher_only=None, decipher_only=None), critical=True)
        .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.CLIENT_AUTH, ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
        .add_extension(x509.SubjectAlternativeName([
            x509.UniformResourceIdentifier("urn:uuid:" + CLIENT_ID),
            x509.UniformResourceIdentifier("uri:uuid:" + CLIENT_ID),
            x509.UniformResourceIdentifier("uuid:" + CLIENT_ID), x509.DNSName(CLIENT_ID),
        ]), critical=False).sign(key, hashes.SHA256()))
    key_path, cert_path = directory / "client.key", directory / "client.pem"
    key_path.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.TraditionalOpenSSL, serialization.NoEncryption()))
    os.chmod(key_path, 0o600)
    cert_path.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    return str(cert_path), str(key_path)


def safe_value(value: Any, depth: int = 0) -> Any:
    """확인한 상태 필드만 남기고 알려지지 않은 개인 정보는 출력하지 않습니다."""
    if depth > 32:
        raise ValueError("OCF state exceeds diagnostic nesting limit")
    if isinstance(value, dict):
        result = {}
        for key, item in value.items():
            if key not in SAFE_FIELDS:
                continue
            if key == PREFIX + "options":
                result[key] = [token for token in item if isinstance(token, str) and (
                    token in OPTION_VALUES or NUMERIC_OPTION.fullmatch(token)
                    or (token.partition("_")[0] in EXTRA_OPTION_PREFIXES
                        and re.fullmatch(r"[A-Za-z][A-Za-z0-9]*_[A-Za-z0-9_.:+-]{1,64}", token))
                )] if isinstance(item, list) else []
            else:
                result[key] = safe_value(item, depth + 1)
        return result
    if isinstance(value, list):
        return [safe_value(item, depth + 1) for item in value]
    if isinstance(value, (str, bool, int)) or value is None:
        return value
    if isinstance(value, float) and math.isfinite(value):
        return value
    return None


def state_path(path: str) -> bool:
    """같은 자원의 숫자 인덱스만 정규화하며 두 번째 실내기 존재를 추정하지 않습니다."""
    return re.sub(r"/[0-9]+$", "/0", path) in STATE_PATHS


def state_resources(batch: Any) -> dict[str, Any]:
    """href와 rep로 배치 응답을 연결하며 누락을 false로 바꾸지 않습니다."""
    result = {}
    for entry in walk_maps(batch):
        href, representation = entry.get("href"), entry.get("rep")
        if isinstance(href, str) and state_path(href) and isinstance(representation, dict):
            result[href] = safe_value(representation)
    return result


def authenticated_get(stream: Any, path: str, query: str | None = None) -> tuple[int, Any, int]:
    """응답 토큰을 대조하고 인증 거부와 통신 실패를 구분합니다."""
    token = secrets.token_bytes(4)
    stream.sendall(tcp_get(path, token, query))
    deadline = time.monotonic() + TIMEOUT
    for _ in range(8):
        code, response_token, body = read_frame(stream, deadline)
        if code == 225:
            continue  # CSM을 보내는 기기만 처리하며 상태 응답과 혼동하지 않습니다.
        if response_token != token:
            continue
        _, payload = parse_options(body)
        if code != 69:
            return code, None, len(payload)
        return code, cbor2.loads(payload) if payload else None, len(payload)
    raise RuntimeError("no matching response within frame limit")


def audit_resources(stream: Any, batch: Any, directory: Any = None) -> dict[str, Any]:
    """배치와 전체 디렉터리의 정적 상태 경로를 GET하고 부분 실패를 기록합니다.

    보안·계정·네트워크 경로는 제외합니다. 알려지지 않은 리소스도 GET 결과와
    필드명은 기록하지만, 개인 정보가 섞일 수 있는 원시 값은 저장하지 않습니다.
    """
    advertised = {entry["href"] for source in (batch, directory) for entry in walk_maps(source)
        if isinstance(entry.get("href"), str)}
    paths = sorted(path for path in advertised if APPLICATION_PATH.fullmatch(path)
        and not path.startswith(PRIVATE_PREFIXES))
    excluded = [{"path": path, "reason": "outside_application_state_scope"}
        for path in sorted(advertised - set(paths)) if re.fullmatch(r"/[A-Za-z0-9_/]+", path)]
    results = {}
    for path in paths:
        try:
            code, representation, size = authenticated_get(stream, path)
            record: dict[str, Any] = {"code": code_name(code), "payload_bytes": size}
            if isinstance(representation, (dict, list)):
                record["empty_representation"] = not representation
            if isinstance(representation, dict):
                record["fields"] = sorted(representation)
                items = representation.get(PREFIX + "items")
                if isinstance(items, list):
                    record["item_fields"] = sorted({key for item in items if isinstance(item, dict) for key in item})
                record["values"] = safe_value(representation) if state_path(path) else {}
                record["values_filtered"] = True
                if re.fullmatch(r"/mode/vs/[0-9]+", path):
                    options = representation.get(PREFIX + "options", [])
                    # 알 수 없는 옵션은 값 대신 접두어만 남겨 새 기능 후보를 추적합니다.
                    record["option_prefixes"] = sorted({token.split("_", 1)[0] for token in options
                        if isinstance(token, str) and re.fullmatch(r"[A-Za-z][A-Za-z0-9]*_.*", token)})
            elif isinstance(representation, list):
                record["collection_resources"] = state_resources(representation)
            results[path] = record
        except (OSError, ValueError, RuntimeError, cbor2.CBORDecodeError) as exc:
            # 특정 경로의 실패를 정상 빈 값이나 전체 조회 성공으로 바꾸지 않습니다.
            results[path] = {"error_type": type(exc).__name__}
    return {"advertised_path_count": len(advertised), "attempted_path_count": len(paths),
        "excluded_path_count": len(advertised) - len(paths), "excluded_paths": excluded, "results": results}


def probe(host: str, authenticated: bool, server_ca: str | None = None,
          all_state_reads: bool = False) -> dict[str, Any]:
    """공개 탐색, TLS, 승인된 배치 GET과 선택적 전체 경로 진단을 수행합니다."""
    address = ipaddress.IPv4Address(host)
    if address.is_multicast or address.is_unspecified or address.is_loopback:
        raise ValueError("a specific appliance IPv4 address is required")
    device = public_get(host, "/oic/d")
    platform = public_get(host, "/oic/p")
    directory = public_get(host, "/oic/res", "rt=oic.r.doxm")
    model = str(platform.get("mnmo", "")).split("|", 1)[0].lstrip(":")
    report: dict[str, Any] = {
        "observed_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "device": {"internal_model": model, "platform": platform.get("mnos"), "manufacturer": platform.get("mnmn"), "resource_types": device.get("rt")},
        "tcp_tls_port": tcp_port(directory), "authenticated_read_requested": authenticated,
        "device_state_written": False,
    }
    if not authenticated:
        return report
    with tempfile.TemporaryDirectory(prefix="samsung-ac-readonly-") as temporary:
        paths = make_certificate(Path(temporary))
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.check_hostname = False  # OCF 식별자는 DNS 이름이 아닙니다.
        if server_ca:
            context.load_verify_locations(cafile=server_ca)
            context.verify_mode = ssl.CERT_REQUIRED
        else:
            context.verify_mode = ssl.CERT_NONE  # 명시한 진단에만 적용하며 완성 드라이버의 기본값이 아닙니다.
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(*paths)
        with socket.create_connection((host, report["tcp_tls_port"]), timeout=TIMEOUT) as raw:
            with context.wrap_socket(raw, server_hostname=host) as stream:
                report["tls"] = {"version": stream.version(), "cipher": stream.cipher()[0], "server_chain_verified": bool(server_ca), "dns_hostname_verified": False, "alpn_offered": False, "peer_certificate_sha256": hashlib.sha256(stream.getpeercert(binary_form=True)).hexdigest()}
                # CSM 최대 수신 크기를 16 KiB로 알리고 접속 안에서 요청을 순서대로 처리합니다.
                stream.sendall(b"\x30\xe1\x22\x40\x00")
                identity_code, secure_device, _ = authenticated_get(stream, "/oic/d")
                if identity_code != 69:
                    raise RuntimeError("authenticated identity GET rejected: " + code_name(identity_code))
                identity_matches = identity_code == 69 and isinstance(secure_device, dict) and secure_device.get("di") == device.get("di") and bool(device.get("di"))
                report["tls"]["public_and_secure_ocf_identity_match"] = identity_matches
                if not identity_matches:
                    raise RuntimeError("appliance identity mismatch")
                code, batch, payload_size = authenticated_get(stream, "/device/0", "if=oic.if.b")
                if code != 69:
                    raise RuntimeError("authenticated state GET rejected: " + code_name(code))
                report["batch"] = {"code": code_name(code), "payload_bytes": payload_size}
                report["resources"] = state_resources(batch)
                report["resource_fields"] = {entry["href"]: sorted(entry["rep"]) for entry in walk_maps(batch) if entry.get("href") in STATE_PATHS and isinstance(entry.get("rep"), dict)}
                report["advertised_state_paths"] = sorted({entry["href"] for entry in walk_maps(batch) if entry.get("href") in STATE_PATHS})
                # 배치에 상태가 없으면 실제로 공개된 알려진 경로만 읽습니다.
                if not report["resources"]:
                    for path in report["advertised_state_paths"]:
                        status, representation, _ = authenticated_get(stream, path)
                        if status == 69 and isinstance(representation, dict):
                            report["resources"][path] = safe_value(representation)
                if not any(report["resources"].values()):
                    raise RuntimeError("authenticated GET contained no recognized AC state")
                if all_state_reads:
                    # 기본 배치 밖에만 광고된 추가 인덱스·진단 경로도 대조합니다.
                    directory_code, full_directory, directory_size = authenticated_get(stream, "/oic/res")
                    report["resource_directory"] = {"code": code_name(directory_code), "payload_bytes": directory_size}
                    report["individual_reads"] = audit_resources(stream, batch,
                        full_directory if directory_code == 69 else None)
    report["temporary_credentials_removed"] = not Path(temporary).exists()
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True)
    parser.add_argument("--authenticated-read", action="store_true", help="승인한 기기에서 임시 인증서로 GET 실행")
    parser.add_argument("--server-ca", help="이 접속에만 적용할 서버 CA PEM")
    parser.add_argument("--all-state-reads", action="store_true", help="배치에 광고된 상태 경로를 각각 GET하고 성공·실패 기록")
    parser.add_argument("--output", type=Path, help="개인 식별자를 제외한 JSON 저장 경로")
    args = parser.parse_args()
    if args.all_state_reads and not args.authenticated_read:
        parser.error("--all-state-reads requires --authenticated-read")
    try:
        report = probe(args.host, args.authenticated_read, args.server_ca, args.all_state_reads)
    except (OSError, ValueError, RuntimeError, cbor2.CBORDecodeError) as exc:
        print(json.dumps({"error_type": type(exc).__name__, "error": str(exc), "device_state_written": False}, ensure_ascii=False))
        return 1
    rendered = json.dumps(report, ensure_ascii=False, indent=2, allow_nan=False) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered, encoding="utf-8")
    print(rendered, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
