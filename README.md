# P50 Print Assistant

P50 Print Assistant 是一个面向 Windows 的 P50/P50S 蓝牙标签打印助手。它的目标很直接：让你把 ChemDraw 这类软件里的化学结构式、线稿图片或普通图片，可靠地渲染成 203 dpi 标签点阵，并通过蓝牙发送到 P50/P50S 标签打印机。

它不是浏览器打印、不是系统打印页面排版，而是围绕小标签打印重新做了一套流程：选择标签尺寸、导入图片、实时预览点阵效果、调整阈值/浓淡/边距/位置，然后通过持续蓝牙连接打印。

English summary: a Windows label-printing assistant for P50/P50S-style BLE printers, designed for ChemDraw-style line art, live bitmap preview, and persistent Bluetooth printing.

This project is not affiliated with Marklife, Feioou, Deli, ChemDraw, or PerkinElmer/Revvity.

## Why This Exists

P50 这类小型标签打印机通常有手机 App，但 Windows 端体验不稳定：验证码登录、游客模式限制、系统打印排版异常、浏览器打印水印或页面缩放问题都会影响实际使用。

这个项目尝试绕开“网页/系统打印页面”的思路，直接生成打印机需要的标签位图，并复用接近手机 App 的 BLE 打印流程。

## Features

- Windows PowerShell WinForms GUI.
- Paste EMF/vector or bitmap images from the clipboard.
- Open PNG/JPEG/BMP/GIF/TIFF/EMF/WMF image files.
- Label sizes: `30 x 15 mm`, `40 x 20 mm`, `40 x 30 mm`.
- Live preview at 8 dots/mm, matching 203 dpi thermal printing.
- Adjustable margin, X/Y image offset, line threshold, and three print-density levels.
- Persistent BLE workflow: scan, connect, print repeatedly, disconnect.
- Optional Windows USB print fallback for troubleshooting.
- Portable BLE runtime build script, so target PCs do not need Python after packaging.

## Current Workflow

1. Scan and connect the P50 Bluetooth device.
2. Select the label size.
3. Paste from clipboard or open an image file.
4. Adjust threshold, density, margin, and position while watching the preview.
5. Print by Bluetooth.

The label size is intentionally blank at startup. Image import and Bluetooth printing stay disabled until a label size is selected, so the app cannot silently render with the wrong paper size.

## Quick Start From Source

Requirements:

- Windows 10/11
- Python 3.10+
- Bluetooth enabled

Install dependencies:

```powershell
python -m pip install -r requirements.txt
```

Run the GUI:

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

For a portable copy, include:

- `P50_Print_Assistant.ps1`
- `Start_P50_Print_Assistant.vbs`
- `portable\p50_ble_runtime\`

Double-click `Start_P50_Print_Assistant.vbs` to launch without a console window.

## Project Layout

```text
.
├── P50_Print_Assistant.ps1          # Windows GUI
├── Start_P50_Print_Assistant.vbs    # no-console launcher
├── src/
│   ├── p50_ble_probe.py             # BLE scan/probe helper
│   └── p50_ble_session.py           # persistent BLE print session helper
├── scripts/
│   └── build_portable_ble.ps1       # PyInstaller portable runtime build
├── docs/
│   └── protocol-notes.md            # BLE protocol notes
└── requirements.txt
```

## Supported And Tested Scope

Known-good target:

- P50/P50S-style BLE label printers using the observed P50S BLE service path.
- Label widths rendered at 8 dots/mm.
- Windows desktop use with ChemDraw-style line art copied as EMF/vector or bitmap.

May need further work:

- Other firmware variants.
- Other label sizes.
- Printers that expose only USB or a different BLE service.

## Privacy

Raw Android bugreports, BLE captures, APK extracts, local print jobs, device addresses, serial numbers, and generated preview images are intentionally not included in this repository.

The repository contains only source code, build scripts, documentation, and protocol constants needed for the open-source implementation.

## Contributing

Issues and pull requests are welcome, especially for:

- Additional label sizes.
- More P50/P50S firmware variants.
- Better line-art thresholding.
- Cleaner packaging and release automation.
- More complete protocol documentation.

If you report a device issue, please remove personal data such as Bluetooth MAC addresses, serial numbers, phone identifiers, and raw bugreports before posting.

## License

MIT License. See [LICENSE](LICENSE).
