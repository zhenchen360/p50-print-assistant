from __future__ import annotations

import asyncio
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace
from typing import Any, Callable
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

from p50_ble_probe import APK_LUCKP_CONTROL, APK_LUCKP_NOTIFY, APK_P50S_NOTIFY  # noqa: E402
from p50_ble_session import (  # noqa: E402
    JobCompletionTimeoutError,
    P50BleSession,
    _decode_request_bytes,
    _parse_request_line,
)


class FakeBleClient:
    def __init__(
        self,
        on_write: Callable[[bytes], None] | None = None,
        notify_success: set[str] | None = None,
    ) -> None:
        self.is_connected = True
        self.on_write = on_write
        self.notify_success = notify_success
        self.writes: list[bytes] = []
        self.started_notifications: list[str] = []
        self.stopped_notifications: list[str] = []
        self.disconnect_count = 0

    async def write_gatt_char(self, _uuid: str, data: bytes, *, response: bool) -> None:
        del response
        packet = bytes(data)
        self.writes.append(packet)
        if self.on_write is not None:
            self.on_write(packet)

    async def stop_notify(self, _uuid: str) -> None:
        self.stopped_notifications.append(_uuid)

    async def start_notify(self, uuid: str, _callback: Callable[..., None]) -> None:
        if self.notify_success is not None and uuid not in self.notify_success:
            raise RuntimeError("unsupported notification")
        self.started_notifications.append(uuid)

    async def disconnect(self) -> None:
        self.disconnect_count += 1
        self.is_connected = False

    async def connect(self) -> None:
        self.is_connected = True


class FixedJobSession(P50BleSession):
    def __init__(self, jobs: list[bytes]) -> None:
        super().__init__()
        self._jobs = jobs

    def build_jobs(self, *args: Any, **kwargs: Any) -> list[bytes]:
        del args, kwargs
        return list(self._jobs)


def attach_client(session: P50BleSession, client: FakeBleClient, flow_control: str = "credit") -> None:
    session.client = client  # type: ignore[assignment]
    session.address = "TEST"
    session.name = "P50S_TEST"
    session.channel = "luckp"
    session.write_uuid = "test-write"
    session.flow_control = flow_control


class CreditProtocolTests(unittest.IsolatedAsyncioTestCase):
    async def test_request_parser_accepts_utf8_bom(self) -> None:
        line = _decode_request_bytes(b'\xef\xbb\xbf{"id":7,"cmd":"status"}\r\n')
        request = _parse_request_line(line)

        self.assertEqual(request, {"id": 7, "cmd": "status"})

    async def test_request_parser_accepts_utf16_bom(self) -> None:
        line = _decode_request_bytes('{"id":8,"cmd":"status"}\r\n'.encode("utf-16"))
        request = _parse_request_line(line)

        self.assertEqual(request, {"id": 8, "cmd": "status"})

    async def test_control_notifications_follow_app_credit_rules(self) -> None:
        session = P50BleSession()

        session.on_notify("control", bytearray.fromhex("0104"))
        self.assertEqual(session.credit_state["credits"], 4)

        session.on_notify("control", bytearray.fromhex("0101"))
        self.assertEqual(session.credit_state["credits"], 5)

        session.on_notify("control", bytearray.fromhex("0102"))
        self.assertEqual(session.credit_state["credits"], 7)

        session.on_notify("control", bytearray.fromhex("0104"))
        self.assertEqual(session.credit_state["credits"], 4)

        session.on_notify("notify", bytearray.fromhex("0101"))
        self.assertEqual(session.credit_state["credits"], 4)

        session.on_notify("notify", bytearray.fromhex("AA0101BB"))
        self.assertEqual(session.credit_state["credits"], 4)

    async def test_fragmented_job_ok_resets_credit_to_four(self) -> None:
        session = P50BleSession()
        session.credit_state["credits"] = 0

        session.on_notify("notify", bytearray.fromhex("4F4B"))
        self.assertFalse(session.complete_event.is_set())
        session.on_notify("control", bytearray.fromhex("0101"))
        session.on_notify("notify", bytearray.fromhex("0D0A"))

        self.assertTrue(session.complete_event.is_set())
        self.assertEqual(session.credit_state["credits"], 4)
        self.assertIn("CREDIT reset after job OK -> 4", session.logs)

    async def test_incomplete_luckp_notifications_fall_back_to_p50s(self) -> None:
        session = P50BleSession()
        client = FakeBleClient(notify_success={APK_LUCKP_NOTIFY, APK_P50S_NOTIFY})
        session.client = client  # type: ignore[assignment]

        ready = await session._prepare_connected_client()

        self.assertTrue(ready)
        self.assertEqual(session.channel, "p50s")
        self.assertEqual(session.flow_control, "none")
        self.assertIn(APK_LUCKP_NOTIFY, client.stopped_notifications)

    async def test_connect_reuses_cached_scan_device(self) -> None:
        session = P50BleSession()
        cached_device = SimpleNamespace(name="P50S_TEST_BLE", address="AA:BB")
        session.discovered_devices["AA:BB"] = cached_device
        client = FakeBleClient(notify_success={APK_LUCKP_NOTIFY, APK_LUCKP_CONTROL})

        with patch("p50_ble_session.BleakClient", return_value=client) as constructor:
            result = await session.connect("AA:BB", "P50S_TEST_BLE", timeout=6, pair=False)

        self.assertIs(constructor.call_args.args[0], cached_device)
        self.assertEqual(constructor.call_count, 1)
        self.assertTrue(result["connected"])
        self.assertEqual(result["channel"], "luckp")

    async def test_old_flow_recovers_one_credit_after_wait(self) -> None:
        session = P50BleSession()
        client = FakeBleClient()
        attach_client(session, client)

        await session.write_chunks(
            b"AB",
            delay=0,
            chunk_size=1,
            write_response=False,
            credit_recovery_seconds=0.01,
        )

        self.assertEqual(client.writes, [b"A", b"B"])
        self.assertEqual(session.credit_state["credits"], 0)
        self.assertEqual(session.logs.count("CREDIT recovery after wait -> 1"), 2)

    async def test_two_pages_each_require_printer_ok(self) -> None:
        session = FixedJobSession([b"page-one", b"page-two"])

        def acknowledge_pages(packet: bytes) -> None:
            if packet.startswith(b"page-"):
                asyncio.get_running_loop().call_soon(
                    session.on_notify, "notify", bytearray.fromhex("4F4B0D0A")
                )

        client = FakeBleClient(acknowledge_pages)
        attach_client(session, client)
        session.on_notify("control", bytearray.fromhex("0104"))

        result = await session.print_image(
            {
                "image": "unused.png",
                "copies": 2,
                "sendStatusQuery": False,
                "chunkDelay": 0,
                "postJobDelay": 0,
                "jobCompleteTimeout": 0.1,
            }
        )

        self.assertEqual(client.writes, [b"page-one", b"page-two"])
        self.assertEqual(result["acknowledgedCopies"], 2)
        self.assertEqual(session.credit_state["credits"], 4)

    async def test_two_separate_print_requests_reuse_acknowledged_session(self) -> None:
        session = FixedJobSession([b"one-page"])

        def acknowledge_page(packet: bytes) -> None:
            if packet == b"one-page":
                asyncio.get_running_loop().call_soon(
                    session.on_notify, "notify", bytearray.fromhex("4F4B0D0A")
                )

        client = FakeBleClient(acknowledge_page)
        attach_client(session, client)
        session.on_notify("control", bytearray.fromhex("0104"))
        request = {
            "image": "unused.png",
            "copies": 1,
            "sendStatusQuery": False,
            "chunkDelay": 0,
            "postJobDelay": 0,
            "jobCompleteTimeout": 0.1,
        }

        first = await session.print_image(request)
        second = await session.print_image(request)

        self.assertEqual(client.writes, [b"one-page", b"one-page"])
        self.assertEqual(first["acknowledgedCopies"], 1)
        self.assertEqual(second["acknowledgedCopies"], 1)
        self.assertTrue(session.connected())
        self.assertEqual(session.credit_state["credits"], 4)

    async def test_missing_first_ok_aborts_before_second_page(self) -> None:
        session = FixedJobSession([b"page-one", b"page-two"])
        client = FakeBleClient()
        attach_client(session, client, flow_control="none")

        with self.assertRaises(JobCompletionTimeoutError):
            await session.print_image(
                {
                    "image": "unused.png",
                    "copies": 2,
                    "sendStatusQuery": False,
                    "chunkDelay": 0,
                    "postJobDelay": 0,
                    "jobCompleteTimeout": 0.01,
                }
            )

        self.assertEqual(client.writes, [b"page-one"])
        self.assertEqual(client.disconnect_count, 1)
        self.assertIsNone(session.client)
        self.assertEqual(session.credit_state["credits"], 0)


if __name__ == "__main__":
    unittest.main()
