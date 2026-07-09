# P50 Print Assistant

Windows 桌面端 P50/P50S 蓝牙标签打印助手，适合打印 ChemDraw 化学结构式、线稿图片和普通图片。

## 下载

直接使用打包版：

[下载最新 Release](https://github.com/zhenchen360/p50-print-assistant/releases/latest)

下载 zip 后解压，双击：

```text
Start_P50_Print_Assistant.vbs
```

## 能做什么

- 从剪贴板粘贴 EMF 矢量图或位图
- 打开 PNG/JPEG/BMP/GIF/TIFF/EMF/WMF 图片
- 支持 `30 x 15 mm`、`40 x 20 mm`、`40 x 30 mm`
- 按 8 点/mm 渲染预览，匹配约 203 dpi 标签打印
- 调整边距、X/Y 位置、线条阈值、打印浓淡
- 蓝牙流程：扫描、连接、连续打印、断开
- 提供 Windows USB 备用打印入口

## 使用流程

1. 扫描并连接 P50 蓝牙设备
2. 选择标签尺寸
3. 从剪贴板粘贴，或打开图片文件
4. 调整阈值、浓淡、边距和位置
5. 点击蓝牙打印

未选择标签尺寸时，导入图片和蓝牙打印按钮会保持禁用。

## 从源码运行

需要：

- Windows 10/11
- Python 3.10+
- 已开启蓝牙

安装依赖：

```powershell
python -m pip install -r requirements.txt
```

运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -STA -File .\P50_Print_Assistant.ps1
```

## 打包便携版

生成不依赖目标电脑 Python 环境的 BLE 运行时：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\build_portable_ble.ps1
```

生成后会出现：

```text
portable\p50_ble_runtime\
  p50_ble_probe.exe
  p50_ble_session.exe
  _internal\
```

便携包至少需要：

- `P50_Print_Assistant.ps1`
- `Start_P50_Print_Assistant.vbs`
- `portable\p50_ble_runtime\`

## 项目结构

```text
.
├── P50_Print_Assistant.ps1
├── Start_P50_Print_Assistant.vbs
├── src/
│   ├── p50_ble_probe.py
│   └── p50_ble_session.py
├── scripts/
│   └── build_portable_ble.ps1
├── docs/
│   └── protocol-notes.md
└── requirements.txt
```

## 适配范围

当前主要面向 P50/P50S 风格 BLE 标签打印机，标签宽度按 8 点/mm 渲染。

欢迎提交更多标签尺寸、固件变体适配、阈值算法改进和打包流程优化。

## License

MIT License. See [LICENSE](LICENSE).
