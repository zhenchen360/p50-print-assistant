# P50 Print Assistant

Windows 桌面端凝优 P50S 热敏标签打印助手，主打快速蓝牙连接、真实标签尺寸预览和所见即所得打印。

它会按标签实际点阵生成预览，再通过持续蓝牙连接发送到打印机，适合需要在 Windows 上稳定打印小标签的场景。

![P50 打印助手运行截图](docs/images/app-screenshot.png)

## 下载

推荐直接使用发布版：

[下载最新 Release](https://github.com/zhenchen360/p50-print-assistant/releases/latest)

下载 zip 后解压，双击：

```text
Start_P50_Print_Assistant.vbs
```

发布版已包含蓝牙运行时，不需要安装 Python。

## 能做什么

- 快速扫描、连接凝优 P50S 热敏标签打印机
- 按真实标签尺寸实时预览打印效果
- 从剪贴板粘贴 EMF 矢量图或位图，适合 ChemDraw 结构式、线稿、图标等内容
- 打开 PNG/JPEG/BMP/GIF/TIFF/EMF/WMF 图片
- 支持 `30 x 15 mm`、`40 x 20 mm`、`40 x 30 mm`
- 按 8 点/mm 渲染预览，匹配约 203 dpi 标签打印
- 调整边距、X/Y 位置、线条阈值、打印浓淡
- 保持蓝牙连接，支持连续打印
- 提供 Windows USB 备用打印入口

## USB 备用与 C-Lodop

蓝牙打印是推荐路径。它直接发送 P50S CommandPort 指令，能保持连接并等待打印机确认，适合日常连续打印。

USB 备用路径用于蓝牙不可用、需要临时走 Windows 打印队列的情况。使用前需要先安装 P50S Windows 打印驱动，并在系统里出现 `P50 Printer` 之类的打印机名称。USB 备用会调用 Windows 打印驱动，实际走纸、边距和定位效果取决于驱动与系统打印设置。

驱动和相关依赖：

- [Marklife Printer Driver P50S win](https://www.marklifeprinter.com/download/download-15-802.html)
- [Marklife Download Center](https://www.marklifeprinter.com/Download.html)
- [Lodop / C-Lodop 下载中心](https://www.lodop.net/download.html)

C-Lodop 只在浏览器网页打印、第三方 Web 模板或旧版 Lodop 方案里需要。本项目当前桌面程序不依赖 C-Lodop；它作为排查和兼容资料保留链接。

## 使用流程

1. 扫描并连接凝优 P50S 蓝牙设备
2. 选择标签尺寸
3. 从剪贴板粘贴，或打开图片文件
4. 调整阈值、浓淡、边距和位置
5. 点击蓝牙打印

未选择标签尺寸时，导入图片和蓝牙打印按钮会保持禁用。

## 从源码运行

开发或自行修改时再使用源码运行。

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

## 适配范围

当前主要面向凝优 P50S 热敏标签打印机，标签宽度按 8 点/mm 渲染。

欢迎提交更多标签尺寸、固件变体适配、阈值算法改进和打包流程优化。

## License

MIT License. See [LICENSE](LICENSE).
