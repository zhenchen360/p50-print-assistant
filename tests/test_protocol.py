from __future__ import annotations

import sys
import unittest
import zlib
from pathlib import Path

from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

from p50_ble_probe import (  # noqa: E402
    _build_p50_commandport_image_packet,
    _build_p50_commandport_job,
    _image_to_p50_raster,
)


class CommandPortProtocolTests(unittest.TestCase):
    def setUp(self) -> None:
        self.image = Image.new("L", (240, 120), 255)
        draw = ImageDraw.Draw(self.image)
        draw.line((8, 10, 230, 100), fill=0, width=2)
        draw.rectangle((20, 20, 80, 70), outline=0, width=1)

    def tearDown(self) -> None:
        self.image.close()

    def test_compressed_packet_header_and_payload_round_trip(self) -> None:
        packet = _build_p50_commandport_image_packet(self.image, zlib_wbits=10, threshold=126)
        raw, width_bytes, height = _image_to_p50_raster(self.image, threshold=126)

        self.assertEqual(packet[:2], bytes.fromhex("1F10"))
        self.assertEqual(int.from_bytes(packet[2:4], "big"), width_bytes)
        self.assertEqual(int.from_bytes(packet[4:6], "big"), height)
        self.assertEqual(int.from_bytes(packet[6:10], "big"), len(packet) - 10)
        self.assertEqual(zlib.decompress(packet[10:], wbits=10), raw)

    def test_job_envelope_matches_captured_command_order(self) -> None:
        first = _build_p50_commandport_job(
            self.image,
            density=8,
            page_index=0,
            total_pages=2,
            zlib_wbits=10,
            include_location_between_pages=True,
        )
        second = _build_p50_commandport_job(
            self.image,
            density=8,
            page_index=1,
            total_pages=2,
            zlib_wbits=10,
            include_location_between_pages=True,
        )

        self.assertTrue(first.startswith(bytes.fromhex("1F7002081FC001001F1151")))
        self.assertTrue(first.endswith(bytes.fromhex("1F1220001FC00101")))
        self.assertTrue(second.startswith(bytes.fromhex("1FC00100")))
        self.assertNotIn(bytes.fromhex("1F700208"), second)
        self.assertNotIn(bytes.fromhex("1F1151"), second)
        self.assertTrue(second.endswith(bytes.fromhex("1F1220001FC001011F1150")))

    def test_supported_label_dot_dimensions(self) -> None:
        expected = {
            (30, 15): (240, 120),
            (40, 20): (320, 160),
            (40, 30): (320, 240),
        }
        for millimeters, dots in expected.items():
            with self.subTest(label=millimeters):
                self.assertEqual((millimeters[0] * 8, millimeters[1] * 8), dots)


if __name__ == "__main__":
    unittest.main()
