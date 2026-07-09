# P50 Print Assistant

Windows label-printing assistant for P50/P50S-style BLE label printers. It is designed around a practical workflow for pasting line-art images such as chemical structure drawings, previewing the 203 dpi label bitmap, and printing through a persistent Bluetooth connection.

This project is not affiliated with Marklife, Feioou, Deli, ChemDraw, or PerkinElmer/Revvity.

## Features

- Windows PowerShell WinForms GUI.
- Paste EMF/vector or bitmap images from the clipboard.
- Open PNG/JPEG/BMP/GIF/TIFF/EMF/WMF image files.
- Label sizes: `30 x 15 mm`, `40 x 20 mm`, `40 x 30 mm`.
- Live preview at 8 dots/mm.
- Adjustable margin, X/Y image offset, line threshold, and three print-density levels.
- Persistent BLE workflow: scan, connect, print repeatedly, disconnect.
- Windows USB print fallback for troubleshooting.

## Quick Start From Source

1. Install Python 3.10+ on Windows.
2. Install dependencies:

   ```powershell
   python -m pip install -r requirements.txt
   ```

3. Run the GUI:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -STA -File .\P50_Print_Assistant.ps1
   ```

The app will use `portable\p50_ble_runtime` if it exists. Otherwise it falls back to the Python scripts in `src`.

## Build A Portable Runtime

To bundle the BLE helpers so another Windows PC does not need Python:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\build_portable_ble.ps1
```

The build creates:

```text
portable\p50_ble_runtime\
  p50_ble_probe.exe
  p50_ble_session.exe
  _internal\
```

Then copy the repository folder or package it with:

- `P50_Print_Assistant.ps1`
- `Start_P50_Print_Assistant.vbs`
- `portable\p50_ble_runtime\`

## Recommended Workflow

1. Scan and connect the P50 Bluetooth device.
2. Select the label size.
3. Paste from clipboard or open an image file.
4. Adjust threshold, density, margin, and position while watching the preview.
5. Print by Bluetooth.

## Privacy And Development Notes

Raw Android bugreports, BLE captures, APK extracts, local print jobs, device addresses, and generated preview images are intentionally not included in this repository.

The implementation is based on observed BLE behavior for P50/P50S-style printers and may need adjustment for other firmware variants.
