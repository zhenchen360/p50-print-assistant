# Protocol Notes

The app prints through BLE using a persistent helper process. The GUI sends JSON-line commands to `p50_ble_session.py`; the helper keeps one GATT connection open so the user flow matches the mobile app pattern:

1. scan
2. connect
3. print one or more labels
4. disconnect

The current P50/P50S path uses the Microchip Transparent UART-style service:

- service: `49535343-fe7d-4ae5-8fa9-9fafd205e455`
- notify: `49535343-1e4d-4bd9-ba61-23c647249616`
- write: `49535343-8841-43f4-a8d4-ecbe34729bb3`

The raster resolution is treated as 8 dots/mm, matching 203 dpi thermal printing.

This repository intentionally omits raw device captures and APK-derived artifacts.
