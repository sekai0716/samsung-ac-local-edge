"""실제 프로토콜 경계와 상태 누락·개인 정보 제거 규칙을 확인합니다."""

import io
import time
import unittest
from unittest.mock import patch

from tools import readonly_probe as probe


class FragmentedStream:
    """한 번에 한 바이트만 보내는 TCP 상대를 모사합니다."""

    def __init__(self, data):
        self.data = io.BytesIO(data)

    def settimeout(self, _timeout):
        pass

    def recv(self, count):
        return self.data.read(min(count, 1))

    def sendall(self, _data):
        pass


class ProtocolTests(unittest.TestCase):
    def test_rfc8323_example_with_no_options_or_payload(self):
        # RFC 8323 Figure 5: Len=0, TKL=1, Code=2.03, Token=0x7f.
        result = probe.read_frame(FragmentedStream(b"\x01\x43\x7f"), time.monotonic() + 1)
        self.assertEqual(result, (67, b"\x7f", b""))

    def test_split_extended_length_frame(self):
        # 13바이트 Options/Payload는 확장 길이 0이며 Code와 Token은 길이에 포함하지 않습니다.
        frame = b"\xd1\x00\x45\x7f" + b"a" * 13
        result = probe.read_frame(FragmentedStream(frame), time.monotonic() + 1)
        self.assertEqual(result, (69, b"\x7f", b"a" * 13))

    def test_truncated_frame_and_excessive_length_fail(self):
        with self.assertRaises(ConnectionError):
            probe.read_frame(FragmentedStream(b"\x11\x45\x7f"), time.monotonic() + 1)
        with self.assertRaises(ValueError):
            probe.read_frame(FragmentedStream(b"\xf0\xff\xff\xff\xff"), time.monotonic() + 1)

    def test_get_has_fixed_method_and_separate_uri_query(self):
        frame = probe.tcp_get("/device/0", b"abcd", "if=oic.if.b")
        code, token, body = probe.read_frame(FragmentedStream(frame), time.monotonic() + 1)
        options, payload = probe.parse_options(body)
        self.assertEqual(code, 1)
        self.assertEqual(token, b"abcd")
        self.assertEqual(options, [(11, b"device"), (11, b"0"), (15, b"if=oic.if.b")])
        self.assertEqual(payload, b"")

    def test_malformed_option_and_empty_payload_marker_fail(self):
        for malformed in (b"\xf0", b"\x01", b"\x0d", b"\xff"):
            with self.subTest(data=malformed), self.assertRaises(ValueError):
                probe.parse_options(malformed)

    def test_unrelated_tokens_are_not_accepted_as_device_state(self):
        # 빈 CSM, 다른 요청의 응답, 현재 요청의 응답이 차례로 도착합니다.
        payload = bytes.fromhex("ffa16576616c7565f4")  # CBOR {"value": false}
        frames = b"\x00\xe1" + b"\x94\x45nope" + payload + b"\x94\x45good" + payload
        with patch.object(probe.secrets, "token_bytes", return_value=b"good"):
            code, value, size = probe.authenticated_get(FragmentedStream(frames), "/power/0")
        self.assertEqual((code, value, size), (69, {"value": False}, 8))

    def test_forbidden_is_not_an_empty_or_off_state(self):
        with patch.object(probe.secrets, "token_bytes", return_value=b"good"):
            result = probe.authenticated_get(FragmentedStream(b"\x04\x83good"), "/power/0")
        self.assertEqual(result, (131, None, 0))

    def test_discovery_uses_tls_advertisement_not_udp_or_reply_port(self):
        directory = [{"links": [{"href": "/oic/sec/doxm", "p": {
            "sec": True, "port": 37034, "x.org.iotivity.tls": 43834,
        }}]}]
        self.assertEqual(probe.tcp_port(directory), 43834)
        for wrong_port in (True, 0, 65536, "43834"):
            directory[0]["links"][0]["p"]["x.org.iotivity.tls"] = wrong_port
            with self.subTest(port=wrong_port), self.assertRaises(ValueError):
                probe.tcp_port(directory)


class RepresentationTests(unittest.TestCase):
    def test_off_zero_and_missing_remain_distinct(self):
        batch = [
            {"href": "/power/0", "rep": {"value": False}},
            {"href": "/airflow/vs/0", "rep": {probe.PREFIX + "speedLevel": "0"}},
            {"href": "/temperature/current/0", "rep": {"temperature": 0.0, "units": "C"}},
            {"href": "/humidity/vs/0", "rep": {
                probe.PREFIX + "humidity": "0", probe.PREFIX + "fivepercentHumidity": "65",
            }},
            {"href": "/humidity/0", "rep": {"humidity": 0}},
        ]
        resources = probe.state_resources(batch)
        self.assertIs(resources["/power/0"]["value"], False)
        self.assertEqual(resources["/airflow/vs/0"][probe.PREFIX + "speedLevel"], "0")
        self.assertEqual(resources["/temperature/current/0"]["temperature"], 0.0)
        # 진단 결과는 원시 0을 보존합니다. 측정 중 여부의 해석은 드라이버 매핑에서 수행합니다.
        self.assertEqual(resources["/humidity/vs/0"][probe.PREFIX + "humidity"], "0")
        self.assertEqual(resources["/humidity/vs/0"][probe.PREFIX + "fivepercentHumidity"], "65")
        self.assertEqual(resources["/humidity/0"]["humidity"], 0)
        self.assertNotIn("/temperature/desired/0", resources)

    def test_unknown_and_personal_fields_are_removed_recursively(self):
        batch = [{"href": "/mode/vs/0", "rep": {
            probe.PREFIX + "modes": ["Cool"],
            "di": "private-device-id", "serialNumber": "private-serial",
            probe.PREFIX + "options": ["ModelInfo_private-serial", "Comode_Nano"],
        }}, {"href": "/WiFiConfResURI", "rep": {"ssid": "private-network"}}]
        self.assertEqual(probe.state_resources(batch), {
            "/mode/vs/0": {probe.PREFIX + "modes": ["Cool"], probe.PREFIX + "options": ["Comode_Nano"]},
        })

    def test_array_order_is_not_part_of_resource_identity(self):
        entries = [
            {"href": "/power/vs/0", "rep": {probe.PREFIX + "power": "Off"}},
            {"href": "/mode/vs/0", "rep": {probe.PREFIX + "modes": ["Cool"]}},
        ]
        self.assertEqual(probe.state_resources(entries), probe.state_resources(list(reversed(entries))))

    def test_telemetry_keeps_raw_scale_and_sensor_values(self):
        batch = [
            {"href": "/sensors/vs/0", "rep": {probe.PREFIX + "items": [{
                probe.PREFIX + "type": "Dust", probe.PREFIX + "value": ["5.000000", "0.000000"],
            }]}},
            {"href": "/energy/consumption/vs/0", "rep": {
                probe.PREFIX + "instantaneousPower": "0.000000", probe.PREFIX + "cumulativePower": "275852400",
            }},
        ]
        resources = probe.state_resources(batch)
        self.assertEqual(resources["/sensors/vs/0"][probe.PREFIX + "items"][0][probe.PREFIX + "value"], ["5.000000", "0.000000"])
        self.assertEqual(resources["/energy/consumption/vs/0"][probe.PREFIX + "cumulativePower"], "275852400")

    def test_audit_deduplicates_and_preserves_partial_failures(self):
        batch = [{"href": path} for path in ("/power/0", "/power/0", "/humidity/0")]
        directory = [{"links": [{"href": "/mode/0"}, {"href": "/power/0"}]}]
        with patch.object(probe, "authenticated_get", side_effect=[
            (131, None, 0), TimeoutError(), (69, {"value": False}, 8),
        ]) as request:
            result = probe.audit_resources(None, batch, directory)
        self.assertEqual(request.call_count, 3)
        self.assertEqual(result["results"]["/humidity/0"]["code"], "4.03")
        self.assertNotIn("values", result["results"]["/humidity/0"])
        self.assertEqual(result["results"]["/mode/0"], {"error_type": "TimeoutError"})
        self.assertIs(result["results"]["/power/0"]["values"]["value"], False)

    def test_audit_filters_identity_network_and_private_option_values(self):
        batch = [{"href": path} for path in ("/information/vs/0", "/wirelessinfo/vs/0", "/mode/vs/0")]
        with patch.object(probe, "authenticated_get", side_effect=[
            (69, {probe.PREFIX + "items": [{probe.PREFIX + "value": "private-serial"}]}, 16),
            (69, {probe.PREFIX + "options": ["ModelInfo_private-serial", "FilterTime_95", "AirMonitoring_Off"]}, 16),
        ]):
            result = probe.audit_resources(None, batch)
        self.assertEqual(result["excluded_path_count"], 1)
        self.assertEqual(result["results"]["/information/vs/0"]["values"], {})
        self.assertEqual(result["results"]["/mode/vs/0"]["values"][probe.PREFIX + "options"], ["FilterTime_95", "AirMonitoring_Off"])

    def test_audit_collection_preserves_subdevice_index_and_hides_identity(self):
        collection = [
            {"href": "/power/1", "rep": {}},
            {"href": "/sensors/vs/1", "rep": {probe.PREFIX + "items": [{
                probe.PREFIX + "type": "Dust", probe.PREFIX + "value": ["0.000000", "0.000000"],
            }]}},
            {"href": "/information/vs/1", "rep": {probe.PREFIX + "serialNum": "private-serial"}},
        ]
        with patch.object(probe, "authenticated_get", return_value=(69, collection, 128)):
            result = probe.audit_resources(None, [{"href": "/device/1"}])
        resources = result["results"]["/device/1"]["collection_resources"]
        self.assertEqual(resources["/power/1"], {})
        self.assertEqual(resources["/sensors/vs/1"][probe.PREFIX + "items"][0][probe.PREFIX + "value"], ["0.000000", "0.000000"])
        self.assertNotIn("/information/vs/1", resources)


if __name__ == "__main__":
    unittest.main()
