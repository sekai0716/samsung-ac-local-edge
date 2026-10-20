"""100년 유효 자체서명 인증서를 포함한 비공개 운영용 Edge 패키지 소스를 만듭니다.

소스 저장소에는 개인 키를 넣지 않습니다. 생성 폴더와 CLI zip은 dist/ 안에서만
보관하고, 출력에는 키·인증서 원문을 포함하지 않습니다. 이 도구는 업로드하지 않습니다.
"""

import argparse
import datetime as dt
import ipaddress
import json
import os
from pathlib import Path
import shutil
import sys

from cryptography import x509

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools.readonly_probe import make_certificate

CERTIFICATE_DAYS = 36500


def build(host: str | None = None) -> Path:
    """자동 검색용 인증 설정을 만듭니다. --host는 선택적인 추가 검색 후보로 보존합니다."""
    address = None
    if host:
        address = ipaddress.IPv4Address(host)
        if not address.is_private or address.is_loopback or address.is_unspecified or address.is_multicast:
            raise ValueError("a private appliance IPv4 address is required")
    project = Path(__file__).resolve().parents[1]
    build_id = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    target = project / "dist" / build_id
    target.mkdir(parents=True, mode=0o700, exist_ok=False)
    for name in ("src", "profiles"):
        shutil.copytree(project / "driver" / name, target / name)
    shutil.copy2(project / "driver/config.yml", target / "config.yml")
    certificate, key = make_certificate(target, validity_days=CERTIFICATE_DAYS)
    certificate = Path(certificate)
    cert = x509.load_pem_x509_certificate(certificate.read_bytes())
    expires = cert.not_valid_after.replace(tzinfo=dt.timezone.utc)
    certificate_pem = certificate.read_text(encoding="ascii")
    key_pem = Path(key).read_text(encoding="ascii")
    ca_pem = (project / "assets/ocf-root-ca.pem").read_text(encoding="ascii")
    # CLI가 src/ 바깥의 파일을 생략하므로 SDK가 지원하는 PEM 문자열을 사용합니다.
    # PEM은 Base64와 고정 헤더로 구성되어 Lua 긴 문자열 구분자를 포함하지 않습니다.
    config = ("-- 비공개 운영 설정. 생성 폴더와 키를 공개 저장소에 넣지 않습니다.\nreturn {\n"
        + (f'  discovery_host = "{address}",\n' if address else "")
        + f'  expires_at = {int(expires.timestamp())},\n  build_id = "{build_id}",\n'
        f'  ca_pem = [=[{ca_pem}]=],\n  client_certificate = [=[{certificate_pem}]=],\n'
        f'  client_key = [=[{key_pem}]=],\n' + "}\n")
    (target / "src/private_config.lua").write_text(config, encoding="utf-8")
    os.chmod(target / "src/private_config.lua", 0o600)
    # 별도 키 파일을 중복 보관하지 않습니다. 비공개 Lua 설정과 zip은 접근을 제한해 보관합니다.
    Path(key).unlink()
    certificate.unlink()
    metadata = {"build_id": build_id, "expires_at": expires.isoformat(), "appliance_write_commands": True,
        "certificate_validity_days": CERTIFICATE_DAYS,
        "discovery": "OCF IPv4 multicast; host is not fixed",
        "controls": ["power", "setpoint", "mode", "fan", "windfree", "autoclean", "purify", "doorUpper", "doorLower", "panel", "speed", "quiet", "lighting", "voice", "displayOff"],
        "hub_reservations": ["onTimer", "offTimer"], "native_timer_writes": False}
    (target / "package-manifest.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    return target


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", help="선택적인 추가 검색 후보 IP. 생략하면 멀티캐스트로 찾습니다.")
    args = parser.parse_args()
    print(build(args.host))


if __name__ == "__main__":
    main()
