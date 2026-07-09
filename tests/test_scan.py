from __future__ import annotations

import sys
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

from p50_ble_probe import discover_devices  # noqa: E402


class ScanFilterTests(unittest.IsolatedAsyncioTestCase):
    async def test_default_scan_only_returns_printer_candidates(self) -> None:
        p50 = SimpleNamespace(name="P50S_TEST_BLE", address="AA:BB")
        unrelated = SimpleNamespace(name="UPDATE", address="CC:DD")
        broad_name = SimpleNamespace(name="YQ-LAMP", address="EE:FF")
        advertisements = {
            "p50": (p50, SimpleNamespace(local_name="P50S_TEST_BLE", rssi=-50, service_uuids=[])),
            "other": (unrelated, SimpleNamespace(local_name="UPDATE", rssi=-40, service_uuids=[])),
            "broad": (broad_name, SimpleNamespace(local_name="YQ-LAMP", rssi=-45, service_uuids=[])),
        }

        with patch("p50_ble_probe.BleakScanner.discover", new=AsyncMock(return_value=advertisements)):
            cache: dict[str, object] = {}
            printers = await discover_devices(0.01, device_cache=cache)
            all_named = await discover_devices(0.01, show_all=True)

        self.assertEqual([row.name for row in printers], ["P50S_TEST_BLE"])
        self.assertEqual({row.name for row in all_named}, {"P50S_TEST_BLE", "UPDATE", "YQ-LAMP"})
        self.assertIs(cache["AA:BB"], p50)
        self.assertNotIn("CC:DD", cache)


if __name__ == "__main__":
    unittest.main()
