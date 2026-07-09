# Protocol Notes

The app prints through BLE using a persistent helper process. The GUI sends
JSON-line commands to `p50_ble_session.py`; the helper keeps one GATT connection
open so the user flow matches the mobile app pattern:

1. scan
2. connect
3. print one or more labels
4. disconnect

The raster resolution is treated as 8 dots/mm, matching 203 dpi thermal
printing.

This repository intentionally omits raw device captures, APK-derived artifacts,
and per-device identifiers.

## BLE transport

The current P50S path prefers the LuckP-style GATT channel when available,
because Android print logs use this path and return one credit notification per
write chunk:

- service: `0000ff00-0000-1000-8000-00805f9b34fb`
- notify/data: `0000ff01-0000-1000-8000-00805f9b34fb`
- write: `0000ff02-0000-1000-8000-00805f9b34fb`
- credit/control: `0000ff03-0000-1000-8000-00805f9b34fb`

Fallback P50S Microchip Transparent UART-style channel:

- service: `49535343-fe7d-4ae5-8fa9-9fafd205e455`
- notify: `49535343-1e4d-4bd9-ba61-23c647249616`
- write: `49535343-8841-43f4-a8d4-ecbe34729bb3`

Android writes print data in 97-byte BLE chunks. On the LuckP channel, the
printer returns `01 01` credits and final job completion as `4F 4B 0D 0A`
(`OK\r\n`). Some Windows tests also observed `AA 0D 0A` as a completion marker.

## CommandPort compressed bitmap

P50/P50S printing uses the CommandPort compressed image command, not a Windows
printer-driver page stream.

The image command is:

```text
1F 10 WH WL HH HL L3 L2 L1 L0 <compressed raster bytes>
```

Fields are big-endian:

- `WH WL`: bytes per raster row, `ceil(pixelWidth / 8)`
- `HH HL`: image height in printer dots
- `L3..L0`: compressed raster byte length

The raster is 1 bit per pixel:

- scanline order, top to bottom
- leftmost pixel stored in bit 7
- `1` means black, `0` means white
- each row is padded to a full byte

The Android `CommandPort.imageProcess(...)` path thresholds pixels with:

```text
gray = (red + green + blue) / 3
black = gray < 126
```

The compressed payload matches zlib/deflate level 6. For the tested P50S path,
APK reverse engineering showed `DFunction.code(raw)` delegating to:

```text
YxqZLib.code(raw, 10, 16384, 6)
```

So the Windows helper uses `zlib.compressobj(level=6, wbits=10)`. Some related
Marklife/Pristar CommandPort implementations use `wbits=14`; that is kept as a
development switch, but the tested P50S default is `10`.

## Print job envelope

A P50S job is assembled as:

```text
optional density:        1F 70 02 <value>
start job:               1F C0 01 00
first page only:         1F 11 51
bitmap:                  1F 10 ...
locate next label:       1F 12 20 00
stop job:                1F C0 01 01
last page only:          1F 11 50
```

The current helper sends `1F 12 20 00` even for single-copy GUI prints. That
matches the observed need to let the printer locate the next gap label before a
later print starts.

Density values exposed by the GUI map to:

```text
Low:    1F 70 02 01
Medium: 1F 70 02 08
High:   1F 70 02 10
```

For continuous printing, the next copy is not sent after a fixed delay. The
helper waits for the printer's final completion notification, then sends the
next job, matching the Android app's behavior.
