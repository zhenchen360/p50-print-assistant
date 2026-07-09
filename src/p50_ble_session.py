#!/usr/bin/env python
"""Persistent BLE session helper for the P50 ChemDraw GUI.

The PowerShell GUI speaks JSON lines to this helper over stdin/stdout. Keeping
one Python process alive lets Bleak keep one GATT connection open across many
print jobs, matching the app flow: scan, connect, print, disconnect.
"""

from __future__ import annotations

import asyncio
import json
import sys
import traceback
from typing import Any

from bleak import BleakClient
from PIL import Image

from p50_ble_probe import (
    APK_LUCKP_CONTROL,
    APK_LUCKP_NOTIFY,
    APK_LUCKP_WRITE,
    APK_P50S_NOTIFY,
    APK_P50S_WRITE,
    BLE_CHUNK_DELAY,
    BLE_CHUNK_SIZE,
    DOTS_PER_MM,
    _build_p50_commandport_job,
    _copy_job_path,
    _find_device,
    _image_to_p50_raster,
    _offset_label_image,
    _parse_hex_list,
)


def _response(request_id: Any, ok: bool, **payload: Any) -> str:
    data = {"id": request_id, "ok": ok}
    data.update(payload)
    return json.dumps(data, ensure_ascii=False, separators=(",", ":"))


def _read_line() -> str:
    return sys.stdin.readline()


def _job_summary(job: bytes) -> dict[str, Any]:
    return {
        "bytes": len(job),
        "locationCmdOffset": job.find(bytes.fromhex("1f122000")),
        "prefix": job[:16].hex(" ").upper(),
    }


class P50BleSession:
    def __init__(self) -> None:
        self.client: BleakClient | None = None
        self.address = ""
        self.name = ""
        self.channel = ""
        self.write_uuid = ""
        self.subscribed: list[str] = []
        self.logs: list[str] = []
        self.flow_control = "none"
        self.credit_state = {"credits": 4}
        self.credit_event = asyncio.Event()
        self.complete_event = asyncio.Event()
        self.complete_markers = _parse_hex_list("AA0D0A,4F4B0D0A")
        self.credit_magic = bytes.fromhex("0101")
        self.credit_event.set()

    def log(self, message: str) -> None:
        self.logs.append(message)

    def take_logs(self) -> list[str]:
        logs = self.logs
        self.logs = []
        return logs

    def connected(self) -> bool:
        return bool(self.client and self.client.is_connected)

    async def disconnect(self) -> None:
        if self.client is not None:
            for uuid in reversed(self.subscribed):
                try:
                    await self.client.stop_notify(uuid)
                except Exception as exc:
                    self.log(f"Notify stop failed for {uuid}: {exc}")
            try:
                await self.client.disconnect()
            except Exception as exc:
                self.log(f"Disconnect failed: {exc}")
        self.client = None
        self.address = ""
        self.name = ""
        self.channel = ""
        self.write_uuid = ""
        self.subscribed = []
        self.flow_control = "none"
        self.credit_state["credits"] = 4
        self.credit_event.set()
        self.complete_event.clear()

    def on_notify(self, sender: Any, data: bytearray) -> None:
        data_bytes = bytes(data)
        self.log(f"NOTIFY {sender}: {data_bytes.hex(' ').upper()}")
        if data_bytes == self.credit_magic:
            self.credit_state["credits"] += 1
            self.log(f"CREDIT +1 -> {self.credit_state['credits']}")
            self.credit_event.set()
        if any(data_bytes == marker for marker in self.complete_markers):
            self.log("JOB COMPLETE notify matched.")
            self.complete_event.set()

    async def _subscribe_candidates(self, candidates: list[str]) -> list[str]:
        subscribed: list[str] = []
        assert self.client is not None
        for uuid in candidates:
            try:
                await self.client.start_notify(uuid, self.on_notify)
                subscribed.append(uuid)
                self.log(f"NOTIFY ON: {uuid}")
            except Exception as exc:
                self.log(f"Notify start failed for {uuid}: {exc}")
        return subscribed

    async def _prepare_connected_client(self) -> bool:
        assert self.client is not None
        self.log(f"Connected: {self.client.is_connected}")
        try:
            mtu = getattr(self.client, "mtu_size", None)
            if mtu:
                self.log(f"MTU reported by backend: {mtu}")
        except Exception:
            pass

        luckp = await self._subscribe_candidates([APK_LUCKP_NOTIFY, APK_LUCKP_CONTROL, APK_LUCKP_WRITE])
        if luckp:
            self.channel = "luckp"
            self.write_uuid = APK_LUCKP_WRITE
            self.subscribed = luckp
            self.flow_control = "credit"
            self.log(f"Session ready: channel={self.channel}; write={self.write_uuid}")
            return True

        p50s = await self._subscribe_candidates([APK_P50S_NOTIFY])
        if p50s:
            self.channel = "p50s"
            self.write_uuid = APK_P50S_WRITE
            self.subscribed = p50s
            self.flow_control = "none"
            self.log(f"Session ready: channel={self.channel}; write={self.write_uuid}")
            return True

        return False

    def _connected_result(self) -> dict[str, Any]:
        return {
            "connected": True,
            "address": self.address,
            "name": self.name,
            "channel": self.channel,
            "writeUuid": self.write_uuid,
            "flowControl": self.flow_control,
            "subscribed": self.subscribed,
        }

    async def connect(self, address: str | None, name: str | None, timeout: float, pair: bool) -> dict[str, Any]:
        await self.disconnect()
        label = address or name or ""
        direct_error = ""
        if address:
            direct_timeout = min(timeout, 4.0)
            self.log(f"Trying cached direct connect to {address!r} for up to {direct_timeout:g}s...")
            try:
                self.client = BleakClient(address, timeout=direct_timeout, pair=pair)
                await self.client.connect()
                self.address = address
                self.name = name or ""
                if await self._prepare_connected_client():
                    self.credit_state["credits"] = 4
                    self.credit_event.set()
                    self.complete_event.clear()
                    return self._connected_result()
                direct_error = "direct connect did not expose a known P50 notification characteristic"
                self.log("Direct connect reached the device but GATT notifications were unavailable; falling back to discovery.")
                await self.disconnect()
            except Exception as exc:
                direct_error = str(exc)
                self.log(f"Direct connect failed; falling back to short discovery: {direct_error}")
                await self.disconnect()

        self.log(f"Finding {label!r} for up to {timeout:g}s...")
        device = await _find_device(address, name, timeout)
        if device is None:
            suffix = f" Direct connect error: {direct_error}" if direct_error else ""
            raise RuntimeError("Device was not visible during the scan window." + suffix)

        self.log(f"Connecting to {device.name or '(no name)'} [{device.address}]...")
        self.client = BleakClient(device, timeout=timeout, pair=pair)
        await self.client.connect()
        self.address = device.address
        self.name = device.name or ""
        if not await self._prepare_connected_client():
            await self.disconnect()
            suffix = f" Direct connect error: {direct_error}" if direct_error else ""
            raise RuntimeError("Connected, but no known P50 notification characteristic was available." + suffix)

        self.credit_state["credits"] = 4
        self.credit_event.set()
        self.complete_event.clear()
        return self._connected_result()

    async def wait_for_credit(self, timeout: float) -> None:
        while self.credit_state["credits"] <= 0:
            self.credit_event.clear()
            try:
                await asyncio.wait_for(self.credit_event.wait(), timeout=timeout)
            except asyncio.TimeoutError as exc:
                raise TimeoutError("Timed out waiting for BLE credit.") from exc
        self.credit_state["credits"] -= 1
        self.log(f"CREDIT use -> {self.credit_state['credits']}")

    async def write_chunks(
        self,
        payload: bytes,
        delay: float,
        chunk_size: int,
        write_response: bool,
        credit_timeout: float,
    ) -> None:
        if self.client is None or not self.client.is_connected or not self.write_uuid:
            raise RuntimeError("BLE session is not connected.")
        total = (len(payload) + chunk_size - 1) // chunk_size
        for index, offset in enumerate(range(0, len(payload), chunk_size), start=1):
            chunk = payload[offset : offset + chunk_size]
            if self.flow_control == "credit":
                await self.wait_for_credit(credit_timeout)
            await self.client.write_gatt_char(self.write_uuid, chunk, response=write_response)
            self.log(f"CHUNK {index}/{total}: {len(chunk)} bytes")
            await asyncio.sleep(delay)

    def build_jobs(
        self,
        image_path: str,
        copies: int,
        density: int,
        threshold: int,
        x_offset_mm: float,
        y_offset_mm: float,
        zlib_wbits: int,
        include_location_between_pages: bool,
        save_job: str,
    ) -> list[bytes]:
        image = Image.open(image_path).convert("L")
        x_offset_dots = int(round(x_offset_mm * DOTS_PER_MM))
        y_offset_dots = int(round(y_offset_mm * DOTS_PER_MM))
        image = _offset_label_image(image, x_offset_dots, y_offset_dots)
        if x_offset_dots or y_offset_dots:
            self.log(f"Applied image offset: x={x_offset_dots} dots, y={y_offset_dots} dots")
        _raw, width_bytes, height = _image_to_p50_raster(image, threshold=threshold)
        self.log(f"Label dots: {image.width} x {image.height}; widthBytes={width_bytes}; heightDots={height}")

        jobs: list[bytes] = []
        for copy_index in range(copies):
            job = _build_p50_commandport_job(
                image,
                density=density,
                page_index=copy_index,
                total_pages=copies,
                print_num=copies,
                zlib_wbits=zlib_wbits,
                include_location_between_pages=include_location_between_pages,
                threshold=threshold,
            )
            jobs.append(job)
            summary = _job_summary(job)
            self.log(
                f"Planned job {copy_index + 1}/{copies}: {summary['bytes']} bytes, "
                f"locationCmdOffset={summary['locationCmdOffset']}"
            )

        if save_job:
            with open(save_job, "wb") as handle:
                handle.write(jobs[0])
            self.log(f"Saved planned job bytes: {save_job}")
            if copies > 1:
                for copy_index, job in enumerate(jobs):
                    copy_path = _copy_job_path(save_job, copy_index)
                    with open(copy_path, "wb") as handle:
                        handle.write(job)
                    self.log(f"Saved planned job {copy_index + 1}/{copies}: {copy_path}")
        return jobs

    async def print_image(self, payload: dict[str, Any]) -> dict[str, Any]:
        if self.client is None or not self.client.is_connected:
            raise RuntimeError("BLE session is not connected. Click Connect Bluetooth first.")

        self.log(f"PRINT SESSION: channel={self.channel}; write={self.write_uuid}; flowControl={self.flow_control}")
        if self.flow_control == "credit":
            self.credit_state["credits"] = 4
            self.credit_event.set()
            self.log("CREDIT reset -> 4")

        copies = max(1, int(payload.get("copies", 1)))
        density = int(payload.get("density", 0))
        threshold = int(payload.get("threshold", 126))
        if threshold < 1 or threshold > 254:
            raise RuntimeError("threshold must be between 1 and 254")

        jobs = self.build_jobs(
            image_path=str(payload["image"]),
            copies=copies,
            density=density,
            threshold=threshold,
            x_offset_mm=float(payload.get("xOffsetMm", 0.0)),
            y_offset_mm=float(payload.get("yOffsetMm", 0.0)),
            zlib_wbits=int(payload.get("zlibWbits", 10)),
            include_location_between_pages=bool(payload.get("includeLocationBetweenPages", copies > 1)),
            save_job=str(payload.get("saveJob", "")),
        )

        chunk_delay = float(payload.get("chunkDelay", BLE_CHUNK_DELAY))
        chunk_size = int(payload.get("chunkSize", BLE_CHUNK_SIZE))
        credit_timeout = float(payload.get("creditTimeout", 5.0))
        write_response = bool(payload.get("writeResponse", False))
        job_timeout = float(payload.get("jobCompleteTimeout", 8.0))
        post_job_delay = float(payload.get("postJobDelay", 0.05))

        if bool(payload.get("sendStatusQuery", True)):
            status_query = bytes.fromhex("10ff50f1")
            self.log(f"STATUS/BATTERY QUERY: {status_query.hex(' ').upper()}")
            await self.write_chunks(status_query, chunk_delay, chunk_size, write_response, credit_timeout)
            await asyncio.sleep(float(payload.get("statusDelay", 0.05)))

        if bool(payload.get("sendMediaCommand", False)):
            media_command = bytes([0x1F, 0x80, 0x01, 0x30])
            self.log(f"SET PAPER gap: {media_command.hex(' ').upper()}")
            await self.write_chunks(media_command, chunk_delay, chunk_size, write_response, credit_timeout)
            await asyncio.sleep(float(payload.get("mediaDelay", 0.5)))
        else:
            self.log("SET PAPER skipped to match Android P50 print flow.")

        for copy_index, job in enumerate(jobs):
            self.complete_event.clear()
            self.log(f"WRITE JOB {copy_index + 1}/{copies}: {len(job)} bytes")
            await self.write_chunks(job, chunk_delay, chunk_size, write_response, credit_timeout)
            self.log(f"WAIT JOB COMPLETE {copy_index + 1}/{copies}: timeout {job_timeout:g}s")
            try:
                await asyncio.wait_for(self.complete_event.wait(), timeout=job_timeout)
            except asyncio.TimeoutError:
                self.log(f"WARNING: no job-complete notification after {job_timeout:g}s; continuing.")
            if self.flow_control == "credit":
                self.credit_state["credits"] = 4
                self.credit_event.set()
                self.log("CREDIT reset after job OK/timeout -> 4")
            await asyncio.sleep(post_job_delay)

        return {"printed": True, "copies": copies, "jobs": [_job_summary(job) for job in jobs]}


async def main() -> int:
    session = P50BleSession()
    while True:
        line = await asyncio.to_thread(_read_line)
        if not line:
            await session.disconnect()
            return 0
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
            request_id = request.get("id")
            command = request.get("cmd")
            session.logs = []
            if command == "connect":
                result = await session.connect(
                    request.get("address"),
                    request.get("name"),
                    float(request.get("timeout", 15.0)),
                    bool(request.get("pair", False)),
                )
            elif command == "status":
                result = {
                    "connected": session.connected(),
                    "address": session.address,
                    "name": session.name,
                    "channel": session.channel,
                    "writeUuid": session.write_uuid,
                }
            elif command == "print-image":
                result = await session.print_image(request)
            elif command == "disconnect":
                await session.disconnect()
                result = {"connected": False}
            elif command == "exit":
                await session.disconnect()
                print(_response(request_id, True, result={"exiting": True}, logs=session.take_logs()), flush=True)
                return 0
            else:
                raise RuntimeError(f"Unknown command: {command}")
            print(_response(request_id, True, result=result, logs=session.take_logs()), flush=True)
        except Exception as exc:
            print(
                _response(
                    locals().get("request_id", None),
                    False,
                    error=str(exc),
                    traceback=traceback.format_exc(),
                    logs=session.take_logs(),
                ),
                flush=True,
            )


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
