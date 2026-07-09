#!/usr/bin/env python
"""Minimal BLE probe for Marklife/P50 printers.

Step 1 is intentionally scan-only: it does not connect and does not write any
data to the printer.
"""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
import os
import time
import zlib
from dataclasses import dataclass
from typing import Iterable

from bleak import BleakClient, BleakScanner
from PIL import Image, ImageDraw, ImageFont


P50_NAME_HINTS = (
    "P50",
    "P50S",
    "S8",
    "YQ",
    "YXQ",
    "FEIOOU",
    "DELI",
    "MARKLIFE",
    "LUCKP",
)

APK_P50S_SERVICE = "49535343-fe7d-4ae5-8fa9-9fafd205e455"
APK_P50S_NOTIFY = "49535343-1e4d-4bd9-ba61-23c647249616"
APK_P50S_WRITE = "49535343-8841-43f4-a8d4-ecbe34729bb3"
APK_LUCKP_SERVICE = "0000ff00-0000-1000-8000-00805f9b34fb"
APK_LUCKP_NOTIFY = "0000ff01-0000-1000-8000-00805f9b34fb"
APK_LUCKP_WRITE = "0000ff02-0000-1000-8000-00805f9b34fb"
APK_LUCKP_CONTROL = "0000ff03-0000-1000-8000-00805f9b34fb"

SAFE_QUERY_COMMANDS = {
    "model": "10ff20f0",
    "version": "10ff20f1",
    "sn": "10ff20f2",
    "battery": "10ff50f1",
    "btname": "10ff3011",
    "status": "10ff40",
}

DOTS_PER_MM = 8
# Runtime logcat from the Android app on a P50S_xxxx_BLE shows print jobs
# split as 97/97/97/82 bytes with a 30 ms timer and 01 01 credit notifications.
BLE_CHUNK_SIZE = 97
BLE_CHUNK_DELAY = 0.03


def _load_font(size: int, bold: bool = False):
    candidates = []
    if bold:
        candidates.extend(
            [
                r"C:\Windows\Fonts\arialbd.ttf",
                r"C:\Windows\Fonts\msyhbd.ttc",
                r"C:\Windows\Fonts\simheib.ttf",
            ]
        )
    candidates.extend(
        [
            r"C:\Windows\Fonts\arial.ttf",
            r"C:\Windows\Fonts\msyh.ttc",
            r"C:\Windows\Fonts\simsun.ttc",
        ]
    )
    for path in candidates:
        try:
            return ImageFont.truetype(path, size=size)
        except Exception:
            continue
    return ImageFont.load_default()


def _center_text(draw: ImageDraw.ImageDraw, box: tuple[int, int, int, int], text: str, font, fill: int = 0) -> None:
    bbox = draw.textbbox((0, 0), text, font=font)
    text_width = bbox[2] - bbox[0]
    text_height = bbox[3] - bbox[1]
    x = box[0] + (box[2] - box[0] - text_width) // 2
    y = box[1] + (box[3] - box[1] - text_height) // 2 - bbox[1]
    draw.text((x, y), text, fill=fill, font=font)


@dataclass
class ScanRow:
    name: str
    address: str
    rssi: str
    services: str
    matched: bool


def _matches_printer(name: str, services: Iterable[str]) -> bool:
    upper_name = name.upper()
    if any(hint in upper_name for hint in P50_NAME_HINTS):
        return True
    # Microchip Transparent UART service used by the Android APK for non-LuckP
    # devices such as P50S.
    return any(str(s).lower() == APK_P50S_SERVICE for s in services)


def _role(uuid: str) -> str:
    lowered = uuid.lower()
    roles = {
        APK_P50S_SERVICE: "APK P50S service",
        APK_P50S_NOTIFY: "APK P50S notify",
        APK_P50S_WRITE: "APK P50S write",
        APK_LUCKP_SERVICE: "APK LuckP service",
        APK_LUCKP_NOTIFY: "APK LuckP notify",
        APK_LUCKP_WRITE: "APK LuckP write",
        APK_LUCKP_CONTROL: "APK LuckP control",
    }
    return roles.get(lowered, "")


async def _find_device(address: str | None, name: str | None, timeout: float):
    target_address = (address or "").upper()
    target_name = (name or "").upper()
    seen = await BleakScanner.discover(timeout=timeout, return_adv=True)
    items = seen.values() if isinstance(seen, dict) else ((device, None) for device in seen)
    best = None
    for device, adv in items:
        dev_address = (getattr(device, "address", "") or "").upper()
        dev_name = (
            getattr(device, "name", None)
            or getattr(adv, "local_name", None)
            or ""
        ).upper()
        if target_address and dev_address == target_address:
            return device
        if target_name and target_name in dev_name:
            best = device
    return best


async def scan(timeout: float, show_all: bool, output_json: bool) -> int:
    if not output_json:
        print(f"Scanning BLE advertisements for {timeout:g}s...")
    seen = await BleakScanner.discover(timeout=timeout, return_adv=True)
    rows: list[ScanRow] = []

    items = seen.values() if isinstance(seen, dict) else ((device, None) for device in seen)
    for device, adv in items:
        name = (getattr(device, "name", None) or getattr(adv, "local_name", None) or "").strip()
        address = getattr(device, "address", "") or ""
        rssi_value = getattr(adv, "rssi", None)
        if rssi_value is None:
            rssi_value = getattr(device, "rssi", None)
        rssi = "" if rssi_value is None else str(rssi_value)
        services_list = list(getattr(adv, "service_uuids", None) or [])
        services = ",".join(services_list)
        matched = _matches_printer(name, services_list)
        if show_all or matched or name:
            rows.append(ScanRow(name or "(no name)", address, rssi, services, matched))

    rows.sort(key=lambda row: (not row.matched, row.name.upper(), row.address))
    if output_json:
        print(json.dumps([row.__dict__ for row in rows], ensure_ascii=False, indent=2))
        return 0 if rows else 1

    if not rows:
        print("No BLE advertisements were visible.")
        return 1

    print()
    print(f"{'HIT':3}  {'NAME':32}  {'ADDRESS':36}  {'RSSI':5}  SERVICES")
    print("-" * 104)
    for row in rows:
        hit = "YES" if row.matched else ""
        print(f"{hit:3}  {row.name[:32]:32}  {row.address[:36]:36}  {row.rssi[:5]:5}  {row.services}")

    matches = [row for row in rows if row.matched]
    print()
    print(f"Visible devices: {len(rows)}; printer-like matches: {len(matches)}")
    if matches:
        print("Next safe step: enumerate services for one matched address, still without printing.")
    else:
        print("If the P50S is on but absent, turn off the phone app connection and scan again.")
    return 0


async def services(address: str | None, name: str | None, timeout: float, pair: bool) -> int:
    if not address and not name:
        raise SystemExit("services needs --address or --name")

    label = address or name or ""
    print(f"Finding {label!r} for up to {timeout:g}s...")
    device = await _find_device(address, name, timeout)
    if device is None:
        print("Device was not visible during the scan window.")
        return 1

    print(f"Connecting to {device.name or '(no name)'} [{device.address}]...")
    async with BleakClient(device, timeout=timeout, pair=pair) as client:
        print(f"Connected: {client.is_connected}")
        print(f"Pair requested: {pair}")
        mtu_size = getattr(client, "mtu_size", None)
        if mtu_size:
            print(f"MTU reported by backend: {mtu_size}")

        services_obj = getattr(client, "services", None)
        if services_obj is None and hasattr(client, "get_services"):
            services_obj = await client.get_services()

        print()
        for service in services_obj:
            service_uuid = str(service.uuid).lower()
            service_role = _role(service_uuid)
            suffix = f"  [{service_role}]" if service_role else ""
            print(f"Service {service_uuid}{suffix}")
            for char in service.characteristics:
                char_uuid = str(char.uuid).lower()
                char_role = _role(char_uuid)
                role_suffix = f"  [{char_role}]" if char_role else ""
                props = ",".join(char.properties)
                print(f"  Char {char_uuid}  props={props}{role_suffix}")
                for desc in char.descriptors:
                    print(f"    Desc {str(desc.uuid).lower()}")

    print()
    print("Disconnected. No data was written.")
    return 0


def _hex_to_bytes(hex_text: str) -> bytes:
    cleaned = "".join(ch for ch in hex_text if ch in "0123456789abcdefABCDEF")
    if len(cleaned) % 2:
        raise SystemExit(f"Odd number of hex digits: {hex_text}")
    return bytes.fromhex(cleaned)


def _parse_hex_list(hex_list: str) -> list[bytes]:
    values: list[bytes] = []
    for item in hex_list.split(","):
        item = item.strip()
        if not item:
            continue
        values.append(_hex_to_bytes(item))
    return values


async def query(
    address: str | None,
    name: str | None,
    timeout: float,
    command: str,
    channel: str,
    pair: bool,
) -> int:
    if not address and not name:
        raise SystemExit("query needs --address or --name")

    if command.lower() in SAFE_QUERY_COMMANDS:
        command_hex = SAFE_QUERY_COMMANDS[command.lower()]
    else:
        command_hex = command
    payload = _hex_to_bytes(command_hex)

    if channel == "p50s":
        notify_uuid = APK_P50S_NOTIFY
        write_uuid = APK_P50S_WRITE
    elif channel == "luckp":
        notify_uuid = APK_LUCKP_NOTIFY
        write_uuid = APK_LUCKP_WRITE
    else:
        raise SystemExit(f"Unknown channel: {channel}")

    label = address or name or ""
    print(f"Finding {label!r} for up to {timeout:g}s...")
    device = await _find_device(address, name, timeout)
    if device is None:
        print("Device was not visible during the scan window.")
        return 1

    received: list[bytes] = []

    def on_notify(sender, data: bytearray):
        data_bytes = bytes(data)
        received.append(data_bytes)
        print(f"NOTIFY {sender}: {data_bytes.hex(' ').upper()}")

    print(f"Connecting to {device.name or '(no name)'} [{device.address}]...")
    async with BleakClient(device, timeout=timeout, pair=pair) as client:
        print(f"Connected: {client.is_connected}")
        print(f"Channel: {channel}; notify={notify_uuid}; write={write_uuid}")
        await client.start_notify(notify_uuid, on_notify)
        await asyncio.sleep(0.2)
        print(f"WRITE: {payload.hex(' ').upper()}")
        await client.write_gatt_char(write_uuid, payload, response=False)
        await asyncio.sleep(2.0)
        try:
            await client.stop_notify(notify_uuid)
        except Exception:
            pass

    print("Disconnected.")
    if not received:
        print("No notification was received.")
        return 2
    return 0


def _make_test_label(width_mm: float, height_mm: float, test_id: str = "", timestamp_text: str | None = None) -> Image.Image:
    width = int(round(width_mm * DOTS_PER_MM))
    height = int(round(height_mm * DOTS_PER_MM))
    image = Image.new("L", (width, height), 255)
    draw = ImageDraw.Draw(image)
    id_font = _load_font(18, bold=True)
    time_font = _load_font(30, bold=True)
    small_font = _load_font(15, bold=True)

    draw.rectangle((0, 0, width - 1, height - 1), outline=0, width=2)
    draw.line((8, 8, width - 9, height - 9), fill=0, width=1)
    draw.line((8, height - 9, width - 9, 8), fill=0, width=1)
    _center_text(draw, (4, 6, width - 4, 36), (test_id or "P50 BLE")[:24], id_font)
    _center_text(draw, (4, 34, width - 4, 86), timestamp_text if timestamp_text is not None else time.strftime("%H:%M:%S"), time_font)
    _center_text(draw, (4, 82, width - 4, height - 4), f"{width_mm:g}x{height_mm:g}mm", small_font)
    return image


def _offset_label_image(image: Image.Image, x_dots: int = 0, y_dots: int = 0) -> Image.Image:
    if x_dots == 0 and y_dots == 0:
        return image
    source = image.convert("L")
    shifted = Image.new("L", source.size, 255)
    shifted.paste(source, (x_dots, y_dots))
    return shifted


def _copy_job_path(save_job: str, copy_index: int) -> str:
    root, ext = os.path.splitext(save_job)
    if not ext:
        ext = ".bin"
    return f"{root}.copy{copy_index + 1:02d}{ext}"


def _image_to_raster(image: Image.Image, threshold: int) -> tuple[bytes, int, int]:
    gray = image.convert("L")
    width, height = gray.size
    width_bytes = (width + 7) // 8
    raster = bytearray(width_bytes * height)
    pixels = gray.load()
    for y in range(height):
        row_offset = y * width_bytes
        for x in range(width):
            if pixels[x, y] < threshold:
                raster[row_offset + (x // 8)] |= 1 << (7 - (x % 8))
    return bytes(raster), width_bytes, height


def _image_to_s8_raster(image: Image.Image) -> tuple[bytes, int, int]:
    return _image_to_raster(image, threshold=128)


def _image_to_p50_raster(image: Image.Image, threshold: int = 126) -> tuple[bytes, int, int]:
    # CommandPort.imageProcess uses average RGB < 126 and packs MSB first.
    return _image_to_raster(image, threshold=threshold)


def _zlib_code_android(raw: bytes, wbits: int = 10) -> bytes:
    # Android DFunction.code(raw) calls YxqZLib.code(raw, 10, 16384, 6).
    # Newer CommandPort can also call YxqZLib with wbits=14.
    compressor = zlib.compressobj(level=6, method=zlib.DEFLATED, wbits=wbits)
    return compressor.compress(raw) + compressor.flush()


def _build_s8_image_packet(image: Image.Image) -> bytes:
    raw, width_bytes, height = _image_to_s8_raster(image)
    compressed = _zlib_code_android(raw)
    header = bytearray(10)
    header[0] = 0x1F
    header[1] = 0x10
    header[2] = (width_bytes >> 8) & 0xFF
    header[3] = width_bytes & 0xFF
    header[4] = (height >> 8) & 0xFF
    header[5] = height & 0xFF
    clen = len(compressed)
    header[6] = (clen >> 24) & 0xFF
    header[7] = (clen >> 16) & 0xFF
    header[8] = (clen >> 8) & 0xFF
    header[9] = clen & 0xFF
    return bytes(header) + compressed


def _build_p50_commandport_image_packet(image: Image.Image, zlib_wbits: int = 10, threshold: int = 126) -> bytes:
    raw, width_bytes, height = _image_to_p50_raster(image, threshold=threshold)
    compressed = _zlib_code_android(raw, wbits=zlib_wbits)
    header = bytearray(10)
    header[0] = 0x1F
    header[1] = 0x10
    header[2] = (width_bytes >> 8) & 0xFF
    header[3] = width_bytes & 0xFF
    header[4] = (height >> 8) & 0xFF
    header[5] = height & 0xFF
    clen = len(compressed)
    header[6] = (clen >> 24) & 0xFF
    header[7] = (clen >> 16) & 0xFF
    header[8] = (clen >> 8) & 0xFF
    header[9] = clen & 0xFF
    return bytes(header) + compressed


def _describe_image_packet(packet: bytes, label: str) -> str:
    if len(packet) < 10 or packet[0:2] != b"\x1F\x10":
        return f"{label} packet: unknown header"
    width_bytes = int.from_bytes(packet[2:4], "big")
    height = int.from_bytes(packet[4:6], "big")
    compressed_len = int.from_bytes(packet[6:10], "big")
    return (
        f"{label} header: widthBytes={width_bytes}, heightDots={height}, "
        f"compressedLen={compressed_len}, packetLen={len(packet)}, "
        f"sha256={hashlib.sha256(packet).hexdigest()[:16]}"
    )


def _describe_s8_packet(packet: bytes) -> str:
    return _describe_image_packet(packet, "S8")


def _build_android_s8_job(
    image: Image.Image,
    density: int,
    last_page: bool,
    tail_mode: str,
    tail_feed_dots: int,
) -> bytes:
    job = bytearray()
    if density > 0:
        job += bytes([0x1F, 0x70, 0x01, density & 0xFF])
    job += b"\x00" * 15
    job += bytes.fromhex("10fff103")
    job += _build_s8_image_packet(image)

    if tail_mode == "p50s":
        job += bytes([0x1B, 0x4A, tail_feed_dots & 0xFF])
    if tail_mode in ("position-stop", "android"):
        job += bytes.fromhex("1d0c")
    if tail_mode in ("stop", "position-stop", "android", "p50s"):
        job += bytes.fromhex("10fff145")
    if tail_mode == "android" and last_page:
        job += bytes.fromhex("1f1150")
    return bytes(job)


def _p50_density_command(density: int) -> bytes:
    if density <= 0:
        return b""
    # DeviceManager.p50Print maps the app's three density levels to
    # setDensity(2, 1/8/16). Older probe commands also used 10/14 as UI aliases.
    density_map = {1: 1, 8: 8, 10: 8, 16: 16, 14: 16}
    return bytes([0x1F, 0x70, 0x02, density_map.get(density, density) & 0xFF])


def _build_p50_commandport_job(
    image: Image.Image,
    density: int,
    page_index: int,
    total_pages: int,
    print_num: int,
    zlib_wbits: int,
    include_location_between_pages: bool,
    threshold: int = 126,
) -> bytes:
    job = bytearray()
    if page_index == 0:
        job += _p50_density_command(density)
    job += bytes.fromhex("1fc00100")
    if page_index == 0:
        job += bytes.fromhex("1f1151")
    job += _build_p50_commandport_image_packet(image, zlib_wbits=zlib_wbits, threshold=threshold)
    if include_location_between_pages:
        job += bytes.fromhex("1f122000")
    job += bytes.fromhex("1fc00101")
    if page_index == total_pages - 1:
        job += bytes.fromhex("1f1150")
    return bytes(job)


async def _write_chunks(
    client: BleakClient,
    write_uuid: str,
    payload: bytes,
    delay: float,
    chunk_size: int,
    write_response: bool,
    flow_control: str = "none",
    credit_state: dict[str, int] | None = None,
    credit_event: asyncio.Event | None = None,
    credit_timeout: float = 5.0,
) -> None:
    if chunk_size < 1:
        raise ValueError("chunk_size must be >= 1")
    if flow_control == "credit" and (credit_state is None or credit_event is None):
        raise ValueError("credit flow control needs credit_state and credit_event")
    total = (len(payload) + chunk_size - 1) // chunk_size
    for index, offset in enumerate(range(0, len(payload), chunk_size), start=1):
        chunk = payload[offset : offset + chunk_size]
        print(f"CHUNK {index}/{total}: {len(chunk)} bytes")
        if flow_control == "credit":
            assert credit_state is not None
            assert credit_event is not None
            while credit_state["credits"] <= 0:
                credit_event.clear()
                try:
                    await asyncio.wait_for(credit_event.wait(), timeout=credit_timeout)
                except asyncio.TimeoutError as exc:
                    raise TimeoutError(f"Timed out waiting for BLE credit before chunk {index}/{total}") from exc
            credit_state["credits"] -= 1
            print(f"CREDIT use -> {credit_state['credits']}")
        await client.write_gatt_char(write_uuid, chunk, response=write_response)
        await asyncio.sleep(delay)


async def print_image(
    address: str | None,
    name: str | None,
    timeout: float,
    channel: str,
    pair: bool,
    protocol: str,
    image_path: str | None,
    width_mm: float | None,
    height_mm: float | None,
    copies: int,
    density: int,
    paper_type: str,
    chunk_delay: float,
    chunk_size: int,
    media_delay: float,
    post_job_delay: float,
    write_response: bool,
    flow_control: str,
    initial_credits: int,
    credit_notify: str,
    credit_timeout: float,
    tail_mode: str,
    tail_feed_dots: int,
    pre_mode: str,
    dry_run: bool,
    test_id: str,
    timestamp_text: str | None,
    save_preview: str,
    save_job: str,
    zlib_wbits: int,
    p50_location_between_pages: bool,
    send_media_command: bool,
    x_offset_mm: float,
    y_offset_mm: float,
    threshold: int,
    wait_job_complete: bool,
    job_complete_notify: str,
    job_complete_timeout: float,
) -> int:
    if not dry_run and not address and not name:
        raise SystemExit("print-test needs --address or --name")
    if copies < 1:
        raise SystemExit("--copies must be >= 1")
    if threshold < 1 or threshold > 254:
        raise SystemExit("--threshold must be between 1 and 254")

    paper_map = {
        "continuous": 0x10,
        "gap": 0x30,
        "black": 0x40,
    }
    if paper_type not in paper_map:
        raise SystemExit(f"Unknown paper type: {paper_type}")

    if channel == "p50s":
        notify_uuid = APK_P50S_NOTIFY
        write_uuid = APK_P50S_WRITE
        notify_uuids = [APK_P50S_NOTIFY]
    elif channel == "luckp":
        notify_uuid = APK_LUCKP_NOTIFY
        write_uuid = APK_LUCKP_WRITE
        notify_uuids = [APK_LUCKP_NOTIFY, APK_LUCKP_CONTROL, APK_LUCKP_WRITE]
    else:
        raise SystemExit(f"Unknown channel: {channel}")

    try:
        credit_magic = bytes.fromhex("".join(ch for ch in credit_notify if ch in "0123456789abcdefABCDEF"))
    except ValueError as exc:
        raise SystemExit(f"Invalid --credit-notify hex: {credit_notify}") from exc
    try:
        complete_markers = _parse_hex_list(job_complete_notify)
    except SystemExit as exc:
        raise SystemExit(f"Invalid --job-complete-notify hex list: {job_complete_notify}") from exc

    generated_test_label = not image_path
    if image_path:
        image = Image.open(image_path).convert("L")
        width_mm_text = f"{image.width / DOTS_PER_MM:g}"
        height_mm_text = f"{image.height / DOTS_PER_MM:g}"
    else:
        if width_mm is None or height_mm is None:
            raise SystemExit("Generated test labels need --width-mm and --height-mm")
        image = _make_test_label(width_mm, height_mm, test_id=test_id, timestamp_text=timestamp_text)
        width_mm_text = f"{width_mm:g}"
        height_mm_text = f"{height_mm:g}"
        print(f"Generated test label text: {test_id or 'P50 BLE'}")

    x_offset_dots = int(round(x_offset_mm * DOTS_PER_MM))
    y_offset_dots = int(round(y_offset_mm * DOTS_PER_MM))
    image = _offset_label_image(image, x_offset_dots, y_offset_dots)
    if x_offset_dots or y_offset_dots:
        print(f"Applied image offset: x={x_offset_dots} dots, y={y_offset_dots} dots")

    if protocol == "s8":
        single_job = _build_android_s8_job(
            image,
            density=density,
            last_page=True,
            tail_mode=tail_mode,
            tail_feed_dots=tail_feed_dots,
        )
        image_packet = _build_s8_image_packet(image)
        packet_label = "S8"
    elif protocol == "p50-commandport":
        single_job = _build_p50_commandport_job(
            image,
            density=density,
            page_index=0,
            total_pages=1,
            print_num=1,
            zlib_wbits=zlib_wbits,
            include_location_between_pages=p50_location_between_pages,
            threshold=threshold,
        )
        image_packet = _build_p50_commandport_image_packet(image, zlib_wbits=zlib_wbits, threshold=threshold)
        packet_label = "P50 CommandPort"
    else:
        raise SystemExit(f"Unknown protocol: {protocol}")
    print(f"Label dots: {image.width} x {image.height} ({width_mm_text} x {height_mm_text} mm at 8 dots/mm)")
    print(f"Protocol: {protocol}")
    print(f"{packet_label} image packet: {len(image_packet)} bytes")
    print(f"Single full job: {len(single_job)} bytes")
    print(_describe_image_packet(image_packet, packet_label))
    print(f"Full job sha256: {hashlib.sha256(single_job).hexdigest()}")
    print(f"Zlib preview: {image_packet[:16].hex(' ').upper()} ...")
    planned_jobs: list[bytes] = []
    for copy_index in range(copies):
        if generated_test_label:
            copy_label = test_id or "P50 BLE"
            if copies > 1:
                copy_label = f"{copy_label} #{copy_index + 1}"
            job_image = _make_test_label(float(width_mm_text), float(height_mm_text), test_id=copy_label, timestamp_text=timestamp_text)
            job_image = _offset_label_image(job_image, x_offset_dots, y_offset_dots)
        else:
            job_image = image
        if protocol == "s8":
            job = _build_android_s8_job(
                job_image,
                density=density,
                last_page=(copy_index == copies - 1),
                tail_mode=tail_mode,
                tail_feed_dots=tail_feed_dots,
            )
        else:
            job = _build_p50_commandport_job(
                job_image,
                density=density,
                page_index=copy_index,
                total_pages=copies,
                print_num=copies,
                zlib_wbits=zlib_wbits,
                include_location_between_pages=p50_location_between_pages,
                threshold=threshold,
            )
        planned_jobs.append(job)
        location_offset = job.find(bytes.fromhex("1f122000"))
        print(
            f"Planned job {copy_index + 1}/{copies}: {len(job)} bytes, "
            f"sha256={hashlib.sha256(job).hexdigest()[:16]}, "
            f"locationCmdOffset={location_offset}"
        )
    if save_job:
        with open(save_job, "wb") as f:
            f.write(planned_jobs[0])
        print(f"Saved planned job bytes: {save_job}")
        if copies > 1:
            for copy_index, job in enumerate(planned_jobs):
                copy_path = _copy_job_path(save_job, copy_index)
                with open(copy_path, "wb") as f:
                    f.write(job)
                print(f"Saved planned job {copy_index + 1}/{copies}: {copy_path}")
    if save_preview:
        image.save(save_preview)
        print(f"Saved preview: {save_preview}")
    if dry_run:
        return 0

    label = address or name or ""
    print(f"Finding {label!r} for up to {timeout:g}s...")
    device = await _find_device(address, name, timeout)
    if device is None:
        print("Device was not visible during the scan window.")
        return 1

    received: list[bytes] = []
    credit_state = {"credits": initial_credits}
    credit_event = asyncio.Event()
    job_complete_event = asyncio.Event()
    if initial_credits > 0:
        credit_event.set()

    def on_notify(sender, data: bytearray):
        data_bytes = bytes(data)
        received.append(data_bytes)
        print(f"NOTIFY {sender}: {data_bytes.hex(' ').upper()}")
        if flow_control == "credit" and data_bytes == credit_magic:
            credit_state["credits"] += 1
            print(f"CREDIT +1 -> {credit_state['credits']}")
            credit_event.set()
        if any(data_bytes == marker for marker in complete_markers):
            print("JOB COMPLETE notify matched.")
            job_complete_event.set()

    print(f"Connecting to {device.name or '(no name)'} [{device.address}]...")
    async with BleakClient(device, timeout=timeout, pair=pair) as client:
        print(f"Connected: {client.is_connected}")
        subscribed: list[str] = []
        for candidate_uuid in dict.fromkeys(notify_uuids):
            try:
                await client.start_notify(candidate_uuid, on_notify)
                subscribed.append(candidate_uuid)
                print(f"NOTIFY ON: {candidate_uuid}")
            except Exception as exc:
                print(f"Notify start failed for {candidate_uuid}, continuing: {exc}")

        if send_media_command:
            media_command = bytes([0x1F, 0x80, 0x01, paper_map[paper_type]])
            print(f"SET PAPER {paper_type}: {media_command.hex(' ').upper()}")
            await _write_chunks(
                client,
                write_uuid,
                media_command,
                chunk_delay,
                chunk_size,
                write_response,
                flow_control,
                credit_state,
                credit_event,
                credit_timeout,
            )
            await asyncio.sleep(media_delay)
        else:
            print("SET PAPER skipped.")

        if pre_mode in ("position", "position-adjust80"):
            position_command = bytes.fromhex("1d0c")
            print(f"PRE POSITION: {position_command.hex(' ').upper()}")
            await _write_chunks(
                client,
                write_uuid,
                position_command,
                chunk_delay,
                chunk_size,
                write_response,
                flow_control,
                credit_state,
                credit_event,
                credit_timeout,
            )
            await asyncio.sleep(0.6)
        if pre_mode in ("adjust80", "position-adjust80"):
            adjust_command = bytes.fromhex("1f1150")
            print(f"PRE ADJUST80: {adjust_command.hex(' ').upper()}")
            await _write_chunks(
                client,
                write_uuid,
                adjust_command,
                chunk_delay,
                chunk_size,
                write_response,
                flow_control,
                credit_state,
                credit_event,
                credit_timeout,
            )
            await asyncio.sleep(0.8)

        for copy_index in range(copies):
            job_complete_event.clear()
            job = planned_jobs[copy_index]
            print(f"WRITE JOB {copy_index + 1}/{copies}: {len(job)} bytes")
            await _write_chunks(
                client,
                write_uuid,
                job,
                chunk_delay,
                chunk_size,
                write_response,
                flow_control,
                credit_state,
                credit_event,
                credit_timeout,
            )
            if wait_job_complete:
                marker_text = ", ".join(marker.hex(" ").upper() for marker in complete_markers)
                print(f"WAIT JOB COMPLETE {copy_index + 1}/{copies}: {marker_text}, timeout {job_complete_timeout:g}s")
                try:
                    await asyncio.wait_for(job_complete_event.wait(), timeout=job_complete_timeout)
                except asyncio.TimeoutError:
                    print(f"WARNING: no job-complete notification after {job_complete_timeout:g}s; continuing.")
            await asyncio.sleep(post_job_delay)

        await asyncio.sleep(2.0)
        for candidate_uuid in reversed(subscribed):
            try:
                await client.stop_notify(candidate_uuid)
            except Exception:
                pass

    print("Disconnected.")
    return 0


async def print_test(
    address: str | None,
    name: str | None,
    timeout: float,
    channel: str,
    pair: bool,
    protocol: str,
    width_mm: float,
    height_mm: float,
    copies: int,
    density: int,
    paper_type: str,
    chunk_delay: float,
    chunk_size: int,
    media_delay: float,
    post_job_delay: float,
    write_response: bool,
    flow_control: str,
    initial_credits: int,
    credit_notify: str,
    credit_timeout: float,
    tail_mode: str,
    tail_feed_dots: int,
    pre_mode: str,
    dry_run: bool,
    test_id: str,
    timestamp_text: str | None,
    save_preview: str,
    save_job: str,
    zlib_wbits: int,
    p50_location_between_pages: bool,
    send_media_command: bool,
    x_offset_mm: float,
    y_offset_mm: float,
    threshold: int,
    wait_job_complete: bool,
    job_complete_notify: str,
    job_complete_timeout: float,
) -> int:
    return await print_image(
        address,
        name,
        timeout,
        channel,
        pair,
        protocol,
        None,
        width_mm,
        height_mm,
        copies,
        density,
        paper_type,
        chunk_delay,
        chunk_size,
        media_delay,
        post_job_delay,
        write_response,
        flow_control,
        initial_credits,
        credit_notify,
        credit_timeout,
        tail_mode,
        tail_feed_dots,
        pre_mode,
        dry_run,
        test_id,
        timestamp_text,
        save_preview,
        save_job,
        zlib_wbits,
        p50_location_between_pages,
        send_media_command,
        x_offset_mm,
        y_offset_mm,
        threshold,
        wait_job_complete,
        job_complete_notify,
        job_complete_timeout,
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Probe P50/P50S BLE visibility.")
    sub = parser.add_subparsers(dest="cmd", required=True)
    scan_parser = sub.add_parser("scan", help="Scan nearby BLE advertisements only.")
    scan_parser.add_argument("--timeout", type=float, default=8.0)
    scan_parser.add_argument("--all", action="store_true", help="Show unnamed/unmatched devices too.")
    scan_parser.add_argument("--json", action="store_true", help="Emit machine-readable JSON rows.")
    services_parser = sub.add_parser("services", help="Connect, enumerate GATT services, then disconnect.")
    services_parser.add_argument("--address", help="BLE address from scan output.")
    services_parser.add_argument("--name", help="Substring of device name, for example P50S_xxxx_BLE.")
    services_parser.add_argument("--timeout", type=float, default=12.0)
    services_parser.add_argument("--pair", action="store_true", help="Ask Windows to pair during connect.")
    query_parser = sub.add_parser("query", help="Send one safe information query and print notifications.")
    query_parser.add_argument("--address", help="BLE address from scan output.")
    query_parser.add_argument("--name", help="Substring of device name, for example P50S_xxxx_BLE.")
    query_parser.add_argument("--timeout", type=float, default=12.0)
    query_parser.add_argument("--pair", action="store_true", help="Ask Windows to pair during connect.")
    query_parser.add_argument("--channel", choices=("p50s", "luckp"), default="p50s")
    query_parser.add_argument(
        "--command",
        default="version",
        help="One of model/version/sn/battery/btname/status, or raw hex.",
    )
    print_test_parser = sub.add_parser("print-test", help="Print a generated test label over BLE.")
    print_test_parser.add_argument("--address", help="BLE address from scan output.")
    print_test_parser.add_argument("--name", help="Substring of device name, for example P50S_xxxx_BLE.")
    print_test_parser.add_argument("--timeout", type=float, default=12.0)
    print_test_parser.add_argument("--pair", action="store_true", help="Ask Windows to pair during connect.")
    print_test_parser.add_argument("--channel", choices=("p50s", "luckp"), default="luckp")
    print_test_parser.add_argument("--protocol", choices=("p50-commandport", "s8"), default="p50-commandport")
    print_test_parser.add_argument("--width-mm", type=float, default=30.0)
    print_test_parser.add_argument("--height-mm", type=float, default=15.0)
    print_test_parser.add_argument("--copies", type=int, default=1)
    print_test_parser.add_argument("--density", type=int, default=0)
    print_test_parser.add_argument("--paper-type", choices=("continuous", "gap", "black"), default="gap")
    print_test_parser.add_argument("--chunk-delay", type=float, default=BLE_CHUNK_DELAY)
    print_test_parser.add_argument("--chunk-size", type=int, default=BLE_CHUNK_SIZE)
    print_test_parser.add_argument("--media-delay", type=float, default=0.5)
    print_test_parser.add_argument("--post-job-delay", type=float, default=0.8)
    print_test_parser.add_argument("--write-response", action="store_true")
    print_test_parser.add_argument("--flow-control", choices=("none", "credit"), default="credit")
    print_test_parser.add_argument("--initial-credits", type=int, default=4)
    print_test_parser.add_argument("--credit-notify", default="0101")
    print_test_parser.add_argument("--credit-timeout", type=float, default=5.0)
    print_test_parser.add_argument("--tail-feed-dots", type=int, default=70)
    print_test_parser.add_argument(
        "--tail-mode",
        choices=("none", "stop", "p50s", "position-stop", "android"),
        default="p50s",
        help="Post-image commands. P50S Android path is ESC J 70 + stop.",
    )
    print_test_parser.add_argument(
        "--pre-mode",
        choices=("none", "position", "adjust80", "position-adjust80"),
        default="none",
        help="Optional positioning command before image data.",
    )
    print_test_parser.add_argument("--pre-position", action="store_true", help="Alias for --pre-mode position.")
    print_test_parser.add_argument("--dry-run", action="store_true")
    print_test_parser.add_argument("--test-id", default="", help="Text printed on the test label for identification.")
    print_test_parser.add_argument("--timestamp-text", default=None, help="Override the generated test label timestamp text.")
    print_test_parser.add_argument("--save-preview", default="", help="Save generated test label PNG during dry-run.")
    print_test_parser.add_argument("--save-job", default="", help="Save the generated job bytes for HCI comparison.")
    print_test_parser.add_argument("--zlib-wbits", type=int, choices=(10, 14), default=10)
    print_test_parser.add_argument("--p50-location-between-pages", action="store_true")
    print_test_parser.add_argument("--skip-media-command", action="store_true", help="Do not send the pre-job paper command.")
    print_test_parser.add_argument("--x-offset-mm", type=float, default=0.0, help="Move rendered content right inside the label bitmap.")
    print_test_parser.add_argument("--y-offset-mm", type=float, default=0.0, help="Move rendered content down inside the label bitmap.")
    print_test_parser.add_argument("--threshold", type=int, default=126, help="Black/white threshold, 1-254. Android CommandPort default is 126.")
    print_test_parser.add_argument("--no-wait-job-complete", action="store_true", help="Do not wait for the printer final OK before the next copy.")
    print_test_parser.add_argument("--job-complete-notify", default="AA0D0A,4F4B0D0A", help="Comma-separated final notification bytes.")
    print_test_parser.add_argument("--job-complete-timeout", type=float, default=8.0)
    print_image_parser = sub.add_parser("print-image", help="Print an existing 8 dots/mm label PNG over BLE.")
    print_image_parser.add_argument("--address", help="BLE address from scan output.")
    print_image_parser.add_argument("--name", help="Substring of device name, for example P50S_xxxx_BLE.")
    print_image_parser.add_argument("--timeout", type=float, default=12.0)
    print_image_parser.add_argument("--pair", action="store_true", help="Ask Windows to pair during connect.")
    print_image_parser.add_argument("--channel", choices=("p50s", "luckp"), default="luckp")
    print_image_parser.add_argument("--protocol", choices=("p50-commandport", "s8"), default="p50-commandport")
    print_image_parser.add_argument("--image", required=True, help="PNG/JPG/BMP already rendered at 8 dots/mm.")
    print_image_parser.add_argument("--copies", type=int, default=1)
    print_image_parser.add_argument("--density", type=int, default=0)
    print_image_parser.add_argument("--paper-type", choices=("continuous", "gap", "black"), default="gap")
    print_image_parser.add_argument("--chunk-delay", type=float, default=BLE_CHUNK_DELAY)
    print_image_parser.add_argument("--chunk-size", type=int, default=BLE_CHUNK_SIZE)
    print_image_parser.add_argument("--media-delay", type=float, default=0.5)
    print_image_parser.add_argument("--post-job-delay", type=float, default=0.8)
    print_image_parser.add_argument("--write-response", action="store_true")
    print_image_parser.add_argument("--flow-control", choices=("none", "credit"), default="credit")
    print_image_parser.add_argument("--initial-credits", type=int, default=4)
    print_image_parser.add_argument("--credit-notify", default="0101")
    print_image_parser.add_argument("--credit-timeout", type=float, default=5.0)
    print_image_parser.add_argument("--tail-feed-dots", type=int, default=70)
    print_image_parser.add_argument(
        "--tail-mode",
        choices=("none", "stop", "p50s", "position-stop", "android"),
        default="p50s",
    )
    print_image_parser.add_argument(
        "--pre-mode",
        choices=("none", "position", "adjust80", "position-adjust80"),
        default="none",
    )
    print_image_parser.add_argument("--pre-position", action="store_true", help="Alias for --pre-mode position.")
    print_image_parser.add_argument("--dry-run", action="store_true")
    print_image_parser.add_argument("--save-job", default="", help="Save the generated job bytes for HCI comparison.")
    print_image_parser.add_argument("--zlib-wbits", type=int, choices=(10, 14), default=10)
    print_image_parser.add_argument("--p50-location-between-pages", action="store_true")
    print_image_parser.add_argument("--skip-media-command", action="store_true", help="Do not send the pre-job paper command.")
    print_image_parser.add_argument("--x-offset-mm", type=float, default=0.0, help="Move rendered content right inside the label bitmap.")
    print_image_parser.add_argument("--y-offset-mm", type=float, default=0.0, help="Move rendered content down inside the label bitmap.")
    print_image_parser.add_argument("--threshold", type=int, default=126, help="Black/white threshold, 1-254. Android CommandPort default is 126.")
    print_image_parser.add_argument("--no-wait-job-complete", action="store_true", help="Do not wait for the printer final OK before the next copy.")
    print_image_parser.add_argument("--job-complete-notify", default="AA0D0A,4F4B0D0A", help="Comma-separated final notification bytes.")
    print_image_parser.add_argument("--job-complete-timeout", type=float, default=8.0)
    args = parser.parse_args()

    if args.cmd == "scan":
        return asyncio.run(scan(args.timeout, args.all, args.json))
    if args.cmd == "services":
        return asyncio.run(services(args.address, args.name, args.timeout, args.pair))
    if args.cmd == "query":
        return asyncio.run(query(args.address, args.name, args.timeout, args.command, args.channel, args.pair))
    if args.cmd == "print-test":
        return asyncio.run(
            print_test(
                args.address,
                args.name,
                args.timeout,
                args.channel,
                args.pair,
                args.protocol,
                args.width_mm,
                args.height_mm,
                args.copies,
                args.density,
                args.paper_type,
                args.chunk_delay,
                args.chunk_size,
                args.media_delay,
                args.post_job_delay,
                args.write_response,
                args.flow_control,
                args.initial_credits,
                args.credit_notify,
                args.credit_timeout,
                args.tail_mode,
                args.tail_feed_dots,
                "position" if args.pre_position else args.pre_mode,
                args.dry_run,
                args.test_id,
                args.timestamp_text,
                args.save_preview,
                args.save_job,
                args.zlib_wbits,
                args.p50_location_between_pages or args.copies > 1,
                not args.skip_media_command,
                args.x_offset_mm,
                args.y_offset_mm,
                args.threshold,
                not args.no_wait_job_complete,
                args.job_complete_notify,
                args.job_complete_timeout,
            )
        )
    if args.cmd == "print-image":
        return asyncio.run(
            print_image(
                args.address,
                args.name,
                args.timeout,
                args.channel,
                args.pair,
                args.protocol,
                args.image,
                None,
                None,
                args.copies,
                args.density,
                args.paper_type,
                args.chunk_delay,
                args.chunk_size,
                args.media_delay,
                args.post_job_delay,
                args.write_response,
                args.flow_control,
                args.initial_credits,
                args.credit_notify,
                args.credit_timeout,
                args.tail_mode,
                args.tail_feed_dots,
                "position" if args.pre_position else args.pre_mode,
                args.dry_run,
                "",
                None,
                "",
                args.save_job,
                args.zlib_wbits,
                args.p50_location_between_pages or args.copies > 1,
                not args.skip_media_command,
                args.x_offset_mm,
                args.y_offset_mm,
                args.threshold,
                not args.no_wait_job_complete,
                args.job_complete_notify,
                args.job_complete_timeout,
            )
        )
    raise AssertionError(args.cmd)


if __name__ == "__main__":
    raise SystemExit(main())
