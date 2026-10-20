"""개인 키 생성 없이 자동 검색용 패키지 설정과 이전 --host 호출 호환성을 검사합니다."""

from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

from tools import build_private_package as builder


class PackageBuildTests(unittest.TestCase):
    def test_default_build_has_no_ip_and_optional_host_is_only_a_search_candidate(self):
        source = Path(__file__).resolve().parents[1]
        for host in (None, "192.168.1.170"):
            with self.subTest(host=host), tempfile.TemporaryDirectory(prefix="samsung-ac-package-test-") as folder:
                root = Path(folder)
                shutil.copytree(source / "driver", root / "driver")
                (root / "assets").mkdir()
                shutil.copy2(source / "assets/ocf-root-ca.pem", root / "assets/ocf-root-ca.pem")

                def credentials(target, validity_days):
                    self.assertEqual(validity_days, 36500)
                    # 공용 인증서는 날짜 파싱 fixture로만 사용합니다. 이 키 문자열은 인증 가능한 키가 아닙니다.
                    certificate, key = target / "test-certificate.pem", target / "test-key"
                    certificate.write_bytes((root / "assets/ocf-root-ca.pem").read_bytes())
                    key.write_text("test-only-noncredential")
                    return str(certificate), str(key)

                with patch.object(builder, "__file__", str(root / "tools/build_private_package.py")), patch.object(builder, "make_certificate", credentials):
                    target = builder.build(host)
                config = (target / "src/private_config.lua").read_text()
                self.assertNotIn("\n  host =", config)
                self.assertEqual("discovery_host =" in config, host is not None)
                self.assertTrue((target / "profiles/samsung-ac.yml").is_file())
                self.assertFalse((target / "test-key").exists())
                self.assertFalse((target / "test-certificate.pem").exists())

    def test_invalid_optional_hosts_are_rejected_before_building(self):
        for host in ("8.8.8.8", "0.0.0.0", "127.0.0.1", "224.0.1.187", "not-an-ip"):
            with self.subTest(host=host), self.assertRaises(ValueError):
                builder.build(host)


if __name__ == "__main__":
    unittest.main()
