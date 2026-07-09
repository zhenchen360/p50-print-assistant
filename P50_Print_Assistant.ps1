param(
    [switch]$SelfTest,
    [switch]$ProbeClipboard,
    [string]$ProbeLabelSize = "30 x 15 mm",
    [string]$RenderUiSnapshot = "",
    [switch]$UsbTestPrint,
    [string]$UsbTestSize = "30 x 15 mm",
    [switch]$UsbPrepareDriver,
    [string]$PrinterName = "P50 Printer"
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type -ReferencedAssemblies "System.Drawing.dll" -TypeDefinition @"
using System;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public static class ClipboardMetafileHelper
{
    private const uint CF_ENHMETAFILE = 14;

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool OpenClipboard(IntPtr hWndNewOwner);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool CloseClipboard();

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool IsClipboardFormatAvailable(uint format);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr GetClipboardData(uint uFormat);

    [DllImport("gdi32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr CopyEnhMetaFile(IntPtr hemfSrc, string lpszFile);

    public static bool HasEnhancedMetafile()
    {
        return IsClipboardFormatAvailable(CF_ENHMETAFILE);
    }

    public static Metafile GetEnhancedMetafile()
    {
        if (!OpenClipboard(IntPtr.Zero))
        {
            return null;
        }
        try
        {
            IntPtr clipboardHandle = GetClipboardData(CF_ENHMETAFILE);
            if (clipboardHandle == IntPtr.Zero)
            {
                return null;
            }
            IntPtr copiedHandle = CopyEnhMetaFile(clipboardHandle, null);
            if (copiedHandle == IntPtr.Zero)
            {
                return null;
            }
            return new Metafile(copiedHandle, true);
        }
        finally
        {
            CloseClipboard();
        }
    }
}
"@

[System.Windows.Forms.Application]::EnableVisualStyles()

$state = [ordered]@{
    Image = $null
    ImagePath = ""
    LastBleImagePath = ""
    LastBleLogPath = ""
    ThresholdManuallyAdjusted = $false
}

$script:bleSessionProcess = $null
$script:bleSessionRequestId = 0
$script:bleSessionConnected = $false
$script:bleSessionAddress = ""
$script:bleSessionName = ""
$script:suppressThresholdChanged = $false
$script:bleDevices = @{}

$labelSizes = [ordered]@{
    "30 x 15 mm" = [pscustomobject]@{ Width = 30.0; Height = 15.0 }
    "40 x 20 mm" = [pscustomobject]@{ Width = 40.0; Height = 20.0 }
    "40 x 30 mm" = [pscustomobject]@{ Width = 40.0; Height = 30.0 }
}

function Get-BaseDir {
    if ($PSCommandPath) { return (Split-Path -Parent $PSCommandPath) }
    return (Get-Location).Path
}

function Quote-ProcessArgument([string]$value) {
    if ($null -eq $value) { return '""' }
    return '"' + $value.Replace('"', '\"') + '"'
}

function ConvertTo-HundredthInch([double]$mm) {
    return [int][Math]::Round($mm / 25.4 * 100.0)
}

function Get-UsbDriverGeometry($label) {
    $paperWidth = [double]$label.Width
    $paperHeight = [double]$label.Height
    $drawWidth = [double]$label.Width
    $drawHeight = [double]$label.Height
    $carrierExtraMm = 0.0

    # The P50 Windows driver exposes 58 mm media names, but the actual GDI
    # imageable width is about 48 mm. A 40 mm custom page hits a driver edge;
    # use the driver's 48 mm carrier width and still draw content at true size.
    if ($label.Width -ge 39.9 -and $label.Width -le 48.1) {
        $paperWidth = 48.0
        $carrierExtraMm = $paperWidth - [double]$label.Width
    }

    return [pscustomobject]@{
        PaperWidth = $paperWidth
        PaperHeight = $paperHeight
        DrawWidth = $drawWidth
        DrawHeight = $drawHeight
        CarrierExtraMm = $carrierExtraMm
    }
}

function Read-PrintTicketXml($ticket) {
    if ($null -eq $ticket) { return "" }
    $stream = $ticket.GetXmlStream()
    try {
        $memory = New-Object System.IO.MemoryStream
        try {
            $stream.CopyTo($memory)
            $bytes = $memory.ToArray()
        } finally {
            $memory.Dispose()
        }
        $text = ""
        if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
            $text = [System.Text.Encoding]::Unicode.GetString($bytes)
            return $text.TrimStart([char]0xFEFF)
        }
        if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
            $text = [System.Text.Encoding]::BigEndianUnicode.GetString($bytes)
            return $text.TrimStart([char]0xFEFF)
        }
        $nullBytes = 0
        $sampleLength = [Math]::Min($bytes.Length, 200)
        for ($i = 1; $i -lt $sampleLength; $i += 2) {
            if ($bytes[$i] -eq 0) { $nullBytes++ }
        }
        if ($nullBytes -gt 20) {
            $text = [System.Text.Encoding]::Unicode.GetString($bytes)
            return $text.TrimStart([char]0xFEFF)
        }
        $text = [System.Text.Encoding]::UTF8.GetString($bytes)
        return $text.TrimStart([char]0xFEFF)
    } finally {
        $stream.Dispose()
    }
}

function New-PrintTicketFromXml([string]$xml) {
    $stream = New-Object System.IO.MemoryStream
    $writer = New-Object System.IO.StreamWriter($stream, [System.Text.Encoding]::Unicode, 1024, $true)
    try {
        $writer.Write($xml)
        $writer.Flush()
        $stream.Position = 0
        return New-Object System.Printing.PrintTicket($stream)
    } finally {
        $writer.Dispose()
        $stream.Dispose()
    }
}

function Set-PrintTicketBorderOffXml([string]$xml) {
    if (-not $xml -or $xml.IndexOf("Borders", [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
        return [pscustomobject]@{ Changed = $false; Xml = $xml; Previous = "" }
    }
    $doc = New-Object System.Xml.XmlDocument
    $doc.PreserveWhitespace = $true
    $doc.LoadXml($xml)
    $node = $doc.SelectSingleNode("//*[local-name()='Feature' and @name='ns0000:Borders']/*[local-name()='Option']")
    if ($null -eq $node) {
        return [pscustomobject]@{ Changed = $false; Xml = $xml; Previous = "" }
    }
    $previous = $node.GetAttribute("name")
    if ($previous -eq "ns0000:Off") {
        return [pscustomobject]@{ Changed = $false; Xml = $xml; Previous = $previous }
    }
    $node.SetAttribute("name", "ns0000:Off")
    $writer = New-Object System.IO.StringWriter
    try {
        $doc.Save($writer)
        return [pscustomobject]@{ Changed = $true; Xml = $writer.ToString(); Previous = $previous }
    } finally {
        $writer.Dispose()
    }
}

function Enter-UsbBorderlessPrintMode([string]$printerName) {
    $printConfigurationError = ""
    try {
        $config = Get-PrintConfiguration -PrinterName $printerName -ErrorAction Stop
        $ticketXml = [string]$config.PrintTicketXml
        if (-not $ticketXml -or $ticketXml.IndexOf('Feature name="ns0000:Borders"', [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
            return [pscustomobject]@{ Applied = $false; Printer = $printerName; RestoreXml = ""; Message = "驱动配置里没有找到绘制边框选项。" }
        }
        if ($ticketXml -match 'Feature name="ns0000:Borders"><psf:Option name="ns0000:Off"') {
            return [pscustomobject]@{ Applied = $false; Printer = $printerName; RestoreXml = ""; Message = "绘制边框已经关闭。" }
        }
        $offXml = [regex]::Replace(
            $ticketXml,
            '(<psf:Feature name="ns0000:Borders"><psf:Option name=")ns0000:(On|Off)("/>)',
            '$1ns0000:Off$3',
            1
        )
        Set-PrintConfiguration -PrinterName $printerName -PrintTicketXml $offXml -ErrorAction Stop
        Start-Sleep -Milliseconds 200
        $verifiedXml = [string](Get-PrintConfiguration -PrinterName $printerName -ErrorAction Stop).PrintTicketXml
        if ($verifiedXml -match 'Feature name="ns0000:Borders"><psf:Option name="ns0000:Off"') {
            return [pscustomobject]@{ Applied = $true; Printer = $printerName; RestoreXml = ""; Message = "已关闭 USB 驱动绘制边框。" }
        }
        return [pscustomobject]@{ Applied = $false; Printer = $printerName; RestoreXml = ""; Message = "驱动没有接受关闭绘制边框的配置。" }
    } catch {
        $printConfigurationError = $_.Exception.Message
    }

    try {
        Add-Type -AssemblyName ReachFramework -ErrorAction Stop
        Add-Type -AssemblyName System.Printing -ErrorAction Stop
        $server = New-Object System.Printing.LocalPrintServer
        $queue = $server.GetPrintQueue($printerName)
        $originalTicket = $queue.UserPrintTicket
        if ($null -eq $originalTicket) { $originalTicket = $queue.DefaultPrintTicket }
        $originalXml = Read-PrintTicketXml $originalTicket
        $off = Set-PrintTicketBorderOffXml $originalXml
        if (-not $off.Previous) {
            return [pscustomobject]@{ Applied = $false; Printer = $printerName; RestoreXml = ""; Message = "驱动票据里没有找到绘制边框选项。" }
        }
        if (-not $off.Changed) {
            return [pscustomobject]@{ Applied = $false; Printer = $printerName; RestoreXml = ""; Message = "绘制边框已经关闭。" }
        }
        $requested = New-PrintTicketFromXml $off.Xml
        $validated = $queue.MergeAndValidatePrintTicket($originalTicket, $requested).ValidatedPrintTicket
        $validatedXml = Read-PrintTicketXml $validated
        if ($validatedXml.IndexOf("ns0000:Borders", [System.StringComparison]::OrdinalIgnoreCase) -lt 0 -or
            $validatedXml.IndexOf("ns0000:Off", [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
            return [pscustomobject]@{ Applied = $false; Printer = $printerName; RestoreXml = ""; Message = "驱动没有接受关闭绘制边框的票据。" }
        }
        $queue.UserPrintTicket = $validated
        $queue.Commit()
        return [pscustomobject]@{ Applied = $true; Printer = $printerName; RestoreXml = $originalXml; Message = "已关闭 USB 驱动绘制边框。" }
    } catch {
        $detail = if ($printConfigurationError) { "$printConfigurationError；$($_.Exception.Message)" } else { $_.Exception.Message }
        return [pscustomobject]@{ Applied = $false; Printer = $printerName; RestoreXml = ""; Message = "关闭 USB 驱动绘制边框失败：$detail" }
    }
}

function Exit-UsbBorderlessPrintMode($context) {
    if ($null -eq $context -or -not $context.Applied -or -not $context.RestoreXml) { return }
    try {
        Add-Type -AssemblyName ReachFramework -ErrorAction Stop
        Add-Type -AssemblyName System.Printing -ErrorAction Stop
        $server = New-Object System.Printing.LocalPrintServer
        $queue = $server.GetPrintQueue($context.Printer)
        $queue.UserPrintTicket = New-PrintTicketFromXml $context.RestoreXml
        $queue.Commit()
    } catch {
        if ($null -ne $script:statusLabel) {
            $script:statusLabel.Text = "USB 打印已提交，但恢复驱动边框设置失败：$($_.Exception.Message)"
        }
    }
}

function Get-SelectedLabelSize {
    if ($null -eq $script:sizeCombo -or $null -eq $script:sizeCombo.SelectedItem) {
        return $null
    }
    return $labelSizes[$script:sizeCombo.SelectedItem.ToString()]
}

function Test-LabelSizeSelected {
    return ($null -ne (Get-SelectedLabelSize))
}

function Require-SelectedLabelSize {
    $label = Get-SelectedLabelSize
    if ($null -eq $label) { throw "请先选择标签尺寸。" }
    return $label
}

function Select-LabelSizeByName([string]$sizeName) {
    if (-not $labelSizes.Contains($sizeName)) {
        throw "未知标签尺寸：$sizeName。可选：$($labelSizes.Keys -join ', ')"
    }
    $script:sizeCombo.SelectedItem = $sizeName
}

function Get-BleImageOffsetMm {
    $x = if ($null -ne $script:bleXOffsetSlider) { [double]$script:bleXOffsetSlider.Value / 10.0 } else { 0.0 }
    $y = if ($null -ne $script:bleYOffsetSlider) { [double]$script:bleYOffsetSlider.Value / 10.0 } else { 0.0 }
    return [pscustomobject]@{ X = $x; Y = $y }
}

function Get-MarginMm {
    if ($null -ne $script:marginSlider) {
        return [double]$script:marginSlider.Value / 10.0
    }
    return 0.5
}

function Get-BlePrintDensity {
    if ($null -eq $script:bleDensitySlider) { return 8 }
    switch ([int]$script:bleDensitySlider.Value) {
        0 { return 1 }
        2 { return 16 }
        default { return 8 }
    }
}

function Get-BlePrintDensityName {
    if ($null -eq $script:bleDensitySlider) { return "中" }
    switch ([int]$script:bleDensitySlider.Value) {
        0 { return "低" }
        2 { return "高" }
        default { return "中" }
    }
}

function Update-DensityLabel {
    if ($null -ne $script:bleDensityValueLabel) {
        $script:bleDensityValueLabel.Text = "打印浓淡（仅蓝牙）：$(Get-BlePrintDensityName)"
    }
}

function Update-MarginLabel {
    if ($null -ne $script:marginValueLabel -and $null -ne $script:marginSlider) {
        $script:marginValueLabel.Text = "边距：{0:0.0} mm" -f ([double]$script:marginSlider.Value / 10.0)
    }
}

function Format-OffsetMm([double]$value) {
    if ([Math]::Abs($value) -lt 0.0001) { return "0.0 mm" }
    return "{0:+0.0;-0.0} mm" -f $value
}

function Update-OffsetLabels {
    if ($null -ne $script:bleXOffsetValueLabel -and $null -ne $script:bleXOffsetSlider) {
        $script:bleXOffsetValueLabel.Text = "图像 X 位置：$(Format-OffsetMm ([double]$script:bleXOffsetSlider.Value / 10.0))"
    }
    if ($null -ne $script:bleYOffsetValueLabel -and $null -ne $script:bleYOffsetSlider) {
        $script:bleYOffsetValueLabel.Text = "图像 Y 位置：$(Format-OffsetMm ([double]$script:bleYOffsetSlider.Value / 10.0))"
    }
}

function Update-ThresholdLabel {
    if ($null -ne $script:bleThresholdValueLabel -and $null -ne $script:bleThresholdBox) {
        $script:bleThresholdValueLabel.Text = "线条阈值：$($script:bleThresholdBox.Value)"
    }
}

function Get-OtsuThreshold([System.Drawing.Bitmap]$bitmap) {
    if ($null -eq $bitmap) { return 126 }
    $histogram = New-Object 'int[]' 256
    $total = 0
    for ($y = 0; $y -lt $bitmap.Height; $y++) {
        for ($x = 0; $x -lt $bitmap.Width; $x++) {
            $pixel = $bitmap.GetPixel($x, $y)
            $gray = [int](($pixel.R + $pixel.G + $pixel.B) / 3)
            $histogram[$gray]++
            $total++
        }
    }
    if ($total -le 0) { return 126 }
    $asDouble = New-Object 'double[]' 256
    for ($i = 0; $i -lt 256; $i++) { $asDouble[$i] = [double]$histogram[$i] }
    return Get-OtsuThresholdFromHistogram $asDouble 35 245 126
}

function Get-OtsuThresholdFromHistogram([double[]]$histogram, [int]$minimum, [int]$maximum, [int]$defaultValue) {
    $total = 0.0
    $sum = 0.0
    for ($i = 0; $i -lt $histogram.Length; $i++) {
        $total += $histogram[$i]
        $sum += [double]$i * $histogram[$i]
    }
    if ($total -le 0) { return $defaultValue }

    $sumB = 0.0
    $weightB = 0.0
    $bestVariance = -1.0
    $bestThreshold = $defaultValue
    for ($i = 0; $i -lt $histogram.Length; $i++) {
        $weightB += $histogram[$i]
        if ($weightB -le 0) { continue }
        $weightF = $total - $weightB
        if ($weightF -le 0) { break }
        $sumB += [double]$i * $histogram[$i]
        $meanB = $sumB / $weightB
        $meanF = ($sum - $sumB) / $weightF
        $variance = $weightB * $weightF * [Math]::Pow($meanB - $meanF, 2)
        if ($variance -gt $bestVariance) {
            $bestVariance = $variance
            $bestThreshold = $i
        }
    }
    return [Math]::Min($maximum, [Math]::Max($minimum, [int]$bestThreshold))
}

function Get-HistogramMode([int[]]$histogram) {
    $mode = 255
    $best = -1
    for ($i = 0; $i -lt $histogram.Length; $i++) {
        if ($histogram[$i] -gt $best) {
            $best = $histogram[$i]
            $mode = $i
        }
    }
    return $mode
}

function Get-HistogramMedian([int[]]$histogram, [int]$total, [int]$defaultValue) {
    if ($total -le 0) { return $defaultValue }
    $target = [int][Math]::Ceiling($total / 2.0)
    $seen = 0
    for ($i = 0; $i -lt $histogram.Length; $i++) {
        $seen += $histogram[$i]
        if ($seen -ge $target) { return $i }
    }
    return $defaultValue
}

function Get-BackgroundAwareThreshold([System.Drawing.Bitmap]$bitmap, [int]$otsuThreshold) {
    if ($null -eq $bitmap) { return $otsuThreshold }
    $histogram = New-Object 'int[]' 256
    $borderHistogram = New-Object 'int[]' 256
    $darknessHistogram = New-Object 'double[]' 256
    $total = 0
    $borderTotal = 0
    $candidateTotal = 0
    for ($y = 0; $y -lt $bitmap.Height; $y++) {
        for ($x = 0; $x -lt $bitmap.Width; $x++) {
            $pixel = $bitmap.GetPixel($x, $y)
            $gray = [int](($pixel.R + $pixel.G + $pixel.B) / 3)
            $histogram[$gray]++
            $total++
            if ($x -eq 0 -or $y -eq 0 -or $x -eq ($bitmap.Width - 1) -or $y -eq ($bitmap.Height - 1)) {
                $borderHistogram[$gray]++
                $borderTotal++
            }
        }
    }
    if ($total -le 0) { return $otsuThreshold }

    $modeGray = Get-HistogramMode $histogram
    $borderMedian = Get-HistogramMedian $borderHistogram $borderTotal $modeGray
    $backgroundGray = [Math]::Max($modeGray, $borderMedian)

    for ($y = 0; $y -lt $bitmap.Height; $y++) {
        for ($x = 0; $x -lt $bitmap.Width; $x++) {
            $pixel = $bitmap.GetPixel($x, $y)
            $gray = [int](($pixel.R + $pixel.G + $pixel.B) / 3)
            $darkness = [Math]::Max(0, $backgroundGray - $gray)
            if ($darkness -ge 6) {
                $darknessHistogram[$darkness]++
                $candidateTotal++
            }
        }
    }

    $minimumCandidates = [Math]::Max(20, [int]($total * 0.005))
    $contrastThreshold = 22
    if ($candidateTotal -ge $minimumCandidates) {
        $contrastThreshold = Get-OtsuThresholdFromHistogram $darknessHistogram 14 80 22
    }
    $backgroundLimitedThreshold = [Math]::Min(245, [Math]::Max(35, $backgroundGray - $contrastThreshold))
    return [Math]::Min($otsuThreshold, $backgroundLimitedThreshold)
}

function Test-WhiteBackgroundLineArt([System.Drawing.Bitmap]$bitmap) {
    if ($null -eq $bitmap) { return $false }
    $total = [Math]::Max(1, $bitmap.Width * $bitmap.Height)
    $nearWhite = 0
    $visibleInk = 0
    for ($y = 0; $y -lt $bitmap.Height; $y++) {
        for ($x = 0; $x -lt $bitmap.Width; $x++) {
            $pixel = $bitmap.GetPixel($x, $y)
            $gray = [int](($pixel.R + $pixel.G + $pixel.B) / 3)
            if ($gray -ge 245) { $nearWhite++ }
            if ($gray -lt 238) { $visibleInk++ }
        }
    }
    $whiteRatio = [double]$nearWhite / [double]$total
    $inkRatio = [double]$visibleInk / [double]$total
    return ($whiteRatio -ge 0.70 -and $inkRatio -ge 0.005 -and $inkRatio -le 0.22)
}

function Get-AutoLineThreshold([System.Drawing.Bitmap]$bitmap) {
    $otsuThreshold = Get-OtsuThreshold $bitmap
    $threshold = Get-BackgroundAwareThreshold $bitmap $otsuThreshold
    if (Test-WhiteBackgroundLineArt $bitmap) {
        $threshold = [Math]::Max($threshold, 189)
    }
    return $threshold
}

function Set-AutoThresholdFromCurrentImage {
    if ($null -eq $state.Image -or $null -eq $script:bleThresholdBox) { return }
    if (-not (Test-LabelSizeSelected)) { return }
    if ($state.ThresholdManuallyAdjusted) { return }
    $bitmap = $null
    try {
        $bitmap = New-P50GrayDotBitmap
        $threshold = Get-AutoLineThreshold $bitmap
        $script:suppressThresholdChanged = $true
        $script:bleThresholdBox.Value = [Math]::Min($script:bleThresholdBox.Maximum, [Math]::Max($script:bleThresholdBox.Minimum, $threshold))
    } finally {
        $script:suppressThresholdChanged = $false
        if ($null -ne $bitmap) { $bitmap.Dispose() }
    }
    Update-ThresholdLabel
}

function Copy-ImageForUse([System.Drawing.Image]$image) {
    if ($null -eq $image) { return $null }
    return $image.Clone()
}

function Set-CurrentImage([System.Drawing.Image]$image, [string]$source, [bool]$takeOwnership = $false) {
    if ($null -eq $image) { return }
    $newImage = if ($takeOwnership) { $image } else { Copy-ImageForUse $image }
    if ($null -ne $state.Image) { $state.Image.Dispose() }
    $state.Image = $newImage
    $state.ImagePath = $source
    $state.ThresholdManuallyAdjusted = $false
    Set-AutoThresholdFromCurrentImage
    Update-Preview
}

function Get-ClipboardFormatSummary {
    try {
        $dataObject = [System.Windows.Forms.Clipboard]::GetDataObject()
        if ($null -eq $dataObject) { return "剪贴板没有数据对象" }
        $formats = @($dataObject.GetFormats($false))
        if ($formats.Count -eq 0) { return "没有可识别的格式名称" }
        return ($formats -join ", ")
    } catch {
        return $_.Exception.Message
    }
}

function Get-ClipboardDiagnosticText {
    $emfAvailable = $false
    try { $emfAvailable = [ClipboardMetafileHelper]::HasEnhancedMetafile() } catch {}
    $containsImage = $false
    $containsText = $false
    $containsFiles = $false
    try { $containsImage = [System.Windows.Forms.Clipboard]::ContainsImage() } catch {}
    try { $containsText = [System.Windows.Forms.Clipboard]::ContainsText() } catch {}
    try { $containsFiles = [System.Windows.Forms.Clipboard]::ContainsFileDropList() } catch {}
    $formats = Get-ClipboardFormatSummary
    return @(
        "EMF 矢量图：$emfAvailable",
        "位图/图片：$containsImage",
        "文本：$containsText",
        "文件：$containsFiles",
        "",
        "剪贴板格式：",
        $formats
    ) -join "`r`n"
}

function Try-SetImageFromClipboard([string]$sourcePrefix) {
    $emf = $null
    try { $emf = [ClipboardMetafileHelper]::GetEnhancedMetafile() } catch { $emf = $null }
    if ($null -ne $emf) {
        Set-CurrentImage $emf "$sourcePrefix EMF 矢量图" $true
        return $true
    }
    if ([System.Windows.Forms.Clipboard]::ContainsImage()) {
        $img = [System.Windows.Forms.Clipboard]::GetImage()
        try { Set-CurrentImage $img "$sourcePrefix 位图" } finally { if ($null -ne $img) { $img.Dispose() } }
        return $true
    }
    return $false
}

function Get-ContentRectMm($label, [double]$marginMm) {
    $x = [single]$marginMm
    $y = [single]$marginMm
    $w = [single]([Math]::Max(0.1, $label.Width - 2 * $marginMm))
    $h = [single]([Math]::Max(0.1, $label.Height - 2 * $marginMm))
    return New-Object System.Drawing.RectangleF($x, $y, $w, $h)
}

function Get-ImageRotationDegrees {
    if ($null -eq $script:rotationCombo -or $null -eq $script:rotationCombo.SelectedItem) { return 0 }
    switch ($script:rotationCombo.SelectedIndex) {
        1 { return 90 }
        2 { return 180 }
        3 { return 270 }
        default { return 0 }
    }
}

function Copy-RotatedImage([System.Drawing.Image]$image, [int]$degrees) {
    if ($null -eq $image) { return $null }
    $copy = $image.Clone()
    switch ($degrees) {
        90 { $copy.RotateFlip([System.Drawing.RotateFlipType]::Rotate90FlipNone) }
        180 { $copy.RotateFlip([System.Drawing.RotateFlipType]::Rotate180FlipNone) }
        270 { $copy.RotateFlip([System.Drawing.RotateFlipType]::Rotate270FlipNone) }
    }
    return $copy
}

function Get-DestinationRectMm($label, [double]$marginMm, [bool]$preserveAspect, [bool]$cropToFill, [System.Drawing.Image]$sourceImage) {
    $box = Get-ContentRectMm $label $marginMm
    $x = $box.X
    $y = $box.Y
    $w = $box.Width
    $h = $box.Height
    if (-not $preserveAspect -or $null -eq $sourceImage) {
        return New-Object System.Drawing.RectangleF($x, $y, $w, $h)
    }
    $srcAspect = [double]$sourceImage.Width / [double]$sourceImage.Height
    $boxAspect = [double]$w / [double]$h
    if (($cropToFill -and $srcAspect -gt $boxAspect) -or ((-not $cropToFill) -and $srcAspect -le $boxAspect)) {
        $drawH = $h
        $drawW = [single]($h * $srcAspect)
        $drawX = [single]($x + ($w - $drawW) / 2)
        $drawY = $y
    } else {
        $drawW = $w
        $drawH = [single]($w / $srcAspect)
        $drawX = $x
        $drawY = [single]($y + ($h - $drawH) / 2)
    }
    return New-Object System.Drawing.RectangleF($drawX, $drawY, $drawW, $drawH)
}

function Convert-BitmapToBlackWhite([System.Drawing.Bitmap]$bitmap, [int]$threshold) {
    $threshold = [Math]::Min(254, [Math]::Max(1, $threshold))
    for ($y = 0; $y -lt $bitmap.Height; $y++) {
        for ($x = 0; $x -lt $bitmap.Width; $x++) {
            $pixel = $bitmap.GetPixel($x, $y)
            $gray = [int](($pixel.R + $pixel.G + $pixel.B) / 3)
            if ($gray -lt $threshold) {
                $bitmap.SetPixel($x, $y, [System.Drawing.Color]::Black)
            } else {
                $bitmap.SetPixel($x, $y, [System.Drawing.Color]::White)
            }
        }
    }
}

function New-SyntheticChemDrawImage {
    $bitmap = New-Object System.Drawing.Bitmap(900, 420, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.Clear([System.Drawing.Color]::White)
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::Black, 7)
        $thinPen = New-Object System.Drawing.Pen([System.Drawing.Color]::Black, 4)
        $font = New-Object System.Drawing.Font("Arial", 58, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
        $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::Black)
        try {
            $points = @(
                (New-Object System.Drawing.PointF(160, 210)),
                (New-Object System.Drawing.PointF(220, 110)),
                (New-Object System.Drawing.PointF(340, 110)),
                (New-Object System.Drawing.PointF(400, 210)),
                (New-Object System.Drawing.PointF(340, 310)),
                (New-Object System.Drawing.PointF(220, 310))
            )
            $graphics.DrawPolygon($pen, [System.Drawing.PointF[]]$points)
            $graphics.DrawLine($thinPen, 235, 145, 320, 145)
            $graphics.DrawLine($thinPen, 360, 210, 320, 280)
            $graphics.DrawLine($thinPen, 220, 275, 180, 210)
            $graphics.DrawLine($pen, 400, 210, 515, 210)
            $graphics.DrawLine($pen, 515, 210, 610, 145)
            $graphics.DrawLine($pen, 610, 145, 710, 210)
            $graphics.DrawLine($pen, 710, 210, 805, 170)
            $graphics.DrawString("N", $font, $brush, 520, 166)
            $graphics.DrawString("O", $font, $brush, 785, 118)
            $graphics.DrawString("Cl", $font, $brush, 315, 315)
        } finally {
            $pen.Dispose(); $thinPen.Dispose(); $font.Dispose(); $brush.Dispose()
        }
    } finally {
        $graphics.Dispose()
    }
    return $bitmap
}

function New-P50GrayDotBitmap {
    $label = Require-SelectedLabelSize
    $pxPerMm = 8
    $bitmapWidth = [int][Math]::Max(1, [Math]::Round($label.Width * $pxPerMm))
    $bitmapHeight = [int][Math]::Max(1, [Math]::Round($label.Height * $pxPerMm))
    $renderScale = 8
    $renderPxPerMm = $pxPerMm * $renderScale
    $renderWidth = [int][Math]::Max(1, [Math]::Round($label.Width * $renderPxPerMm))
    $renderHeight = [int][Math]::Max(1, [Math]::Round($label.Height * $renderPxPerMm))
    $renderBitmap = New-Object System.Drawing.Bitmap($renderWidth, $renderHeight, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $bitmap = New-Object System.Drawing.Bitmap($bitmapWidth, $bitmapHeight, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $graphics = [System.Drawing.Graphics]::FromImage($renderBitmap)
    $downsampleGraphics = $null
    $renderImage = $null
    try {
        $graphics.Clear([System.Drawing.Color]::White)
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
        $graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::SingleBitPerPixelGridFit
        $marginMm = Get-MarginMm
        $cropToFill = ($null -ne $script:cropFillCheck -and $script:cropFillCheck.Checked)
        $renderImage = Copy-RotatedImage $state.Image (Get-ImageRotationDegrees)
        $contentMm = Get-ContentRectMm $label $marginMm
        $destMm = Get-DestinationRectMm $label $marginMm $script:aspectCheck.Checked $cropToFill $renderImage
        $offsetMm = Get-BleImageOffsetMm
        $contentPx = New-Object System.Drawing.RectangleF(
            [single]($contentMm.X * $renderPxPerMm),
            [single]($contentMm.Y * $renderPxPerMm),
            [single]($contentMm.Width * $renderPxPerMm),
            [single]($contentMm.Height * $renderPxPerMm)
        )
        $destPx = New-Object System.Drawing.RectangleF(
            [single](($destMm.X + $offsetMm.X) * $renderPxPerMm),
            [single](($destMm.Y + $offsetMm.Y) * $renderPxPerMm),
            [single]($destMm.Width * $renderPxPerMm),
            [single]($destMm.Height * $renderPxPerMm)
        )
        if ($null -ne $renderImage) {
            if ($cropToFill) { $graphics.SetClip($contentPx) }
            try { $graphics.DrawImage($renderImage, $destPx) } finally { if ($cropToFill) { $graphics.ResetClip() } }
        }
        $graphics.Dispose(); $graphics = $null
        $downsampleGraphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $downsampleGraphics.Clear([System.Drawing.Color]::White)
        $downsampleGraphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $downsampleGraphics.DrawImage($renderBitmap, (New-Object System.Drawing.Rectangle(0, 0, $bitmapWidth, $bitmapHeight)))
    } finally {
        if ($null -ne $graphics) { $graphics.Dispose() }
        if ($null -ne $downsampleGraphics) { $downsampleGraphics.Dispose() }
        if ($null -ne $renderImage) { $renderImage.Dispose() }
        $renderBitmap.Dispose()
    }
    return $bitmap
}

function New-P50DotBitmap {
    $bitmap = New-P50GrayDotBitmap
    try {
        Convert-BitmapToBlackWhite $bitmap ([int]$script:bleThresholdBox.Value)
        return $bitmap
    } catch {
        if ($null -ne $bitmap) { $bitmap.Dispose() }
        throw
    }
}

function Copy-Rotated180Bitmap([System.Drawing.Bitmap]$bitmap) {
    $copy = $bitmap.Clone()
    $copy.RotateFlip([System.Drawing.RotateFlipType]::Rotate180FlipNone)
    return $copy
}

function New-UsbDriverBitmap {
    $logicalBitmap = New-P50DotBitmap
    try {
        $driverBitmap = Copy-Rotated180Bitmap $logicalBitmap
        $driverBitmap.SetResolution(203.2, 203.2)
        return $driverBitmap
    } finally {
        if ($null -ne $logicalBitmap) { $logicalBitmap.Dispose() }
    }
}

function Count-BlackPixelsInRect([System.Drawing.Bitmap]$bitmap, [int]$x0, [int]$y0, [int]$width, [int]$height) {
    $count = 0
    $x1 = [Math]::Min($bitmap.Width, $x0 + $width)
    $y1 = [Math]::Min($bitmap.Height, $y0 + $height)
    for ($y = [Math]::Max(0, $y0); $y -lt $y1; $y++) {
        for ($x = [Math]::Max(0, $x0); $x -lt $x1; $x++) {
            $pixel = $bitmap.GetPixel($x, $y)
            if ($pixel.R -lt 128) { $count++ }
        }
    }
    return $count
}

function Get-BitmapEdgeStats([System.Drawing.Bitmap]$bitmap) {
    $bandDots = [Math]::Max(1, [Math]::Min(8, [Math]::Floor([Math]::Min($bitmap.Width, $bitmap.Height) / 4)))
    return [pscustomobject]@{
        Width = $bitmap.Width
        Height = $bitmap.Height
        TotalBlack = Count-BlackPixelsInRect $bitmap 0 0 $bitmap.Width $bitmap.Height
        LeftColumn = Count-BlackPixelsInRect $bitmap 0 0 1 $bitmap.Height
        RightColumn = Count-BlackPixelsInRect $bitmap ($bitmap.Width - 1) 0 1 $bitmap.Height
        TopRow = Count-BlackPixelsInRect $bitmap 0 0 $bitmap.Width 1
        BottomRow = Count-BlackPixelsInRect $bitmap 0 ($bitmap.Height - 1) $bitmap.Width 1
        LeftBand = Count-BlackPixelsInRect $bitmap 0 0 $bandDots $bitmap.Height
        RightBand = Count-BlackPixelsInRect $bitmap ($bitmap.Width - $bandDots) 0 $bandDots $bitmap.Height
        TopBand = Count-BlackPixelsInRect $bitmap 0 0 $bitmap.Width $bandDots
        BottomBand = Count-BlackPixelsInRect $bitmap 0 ($bitmap.Height - $bandDots) $bitmap.Width $bandDots
        BandDots = $bandDots
    }
}

function Format-BitmapEdgeStats($name, $stats) {
    return "{0}: {1}x{2}; totalBlack={3}; col L/R={4}/{5}; row T/B={6}/{7}; {8}-dot band L/R/T/B={9}/{10}/{11}/{12}" -f `
        $name, $stats.Width, $stats.Height, $stats.TotalBlack, $stats.LeftColumn, $stats.RightColumn, `
        $stats.TopRow, $stats.BottomRow, $stats.BandDots, $stats.LeftBand, $stats.RightBand, $stats.TopBand, $stats.BottomBand
}

function New-P50PreviewBitmap {
    $bitmap = New-P50DotBitmap
    try { return $bitmap.Clone() } finally { $bitmap.Dispose() }
}

function Get-PreviewLabelRect([System.Drawing.Rectangle]$bounds, $label) {
    $pad = if ($bounds.Width -lt 520 -or $bounds.Height -lt 360) { 8.0 } else { 18.0 }
    $availableW = [Math]::Max(1.0, [double]$bounds.Width - 2.0 * $pad)
    $availableH = [Math]::Max(1.0, [double]$bounds.Height - 2.0 * $pad)
    $scale = [Math]::Min($availableW / [double]$label.Width, $availableH / [double]$label.Height)
    $drawW = [single]($label.Width * $scale)
    $drawH = [single]($label.Height * $scale)
    $drawX = [single]($bounds.Left + ([double]$bounds.Width - $drawW) / 2.0)
    $drawY = [single]($bounds.Top + ([double]$bounds.Height - $drawH) / 2.0)
    return [pscustomobject]@{ Rect = (New-Object System.Drawing.RectangleF($drawX, $drawY, $drawW, $drawH)); Scale = [single]$scale }
}

function Draw-PreviewCanvas([System.Drawing.Graphics]$graphics, [System.Drawing.Rectangle]$bounds) {
    $graphics.Clear([System.Drawing.Color]::FromArgb(245, 247, 250))
    if ($bounds.Width -le 0 -or $bounds.Height -le 0) { return }
    $label = Get-SelectedLabelSize
    if ($null -eq $label) {
        $font = New-Object System.Drawing.Font("Microsoft YaHei", 15, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
        $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(140, 148, 160))
        $textRect = New-Object System.Drawing.RectangleF([single]$bounds.X, [single]$bounds.Y, [single]$bounds.Width, [single]$bounds.Height)
        $format = New-Object System.Drawing.StringFormat
        $format.Alignment = [System.Drawing.StringAlignment]::Center
        $format.LineAlignment = [System.Drawing.StringAlignment]::Center
        try { $graphics.DrawString("请选择标签尺寸", $font, $brush, $textRect, $format) }
        finally { $font.Dispose(); $brush.Dispose(); $format.Dispose() }
        return
    }
    $plan = Get-PreviewLabelRect $bounds $label
    $labelRect = $plan.Rect
    $scale = [double]$plan.Scale
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $paperBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
    $borderPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(196, 204, 216), 1)
    try {
        $graphics.FillRectangle($paperBrush, $labelRect)
        $graphics.DrawRectangle($borderPen, $labelRect.X, $labelRect.Y, $labelRect.Width, $labelRect.Height)
        if ($null -ne $state.Image) {
            $previewBitmap = $null
            try {
                $previewBitmap = New-P50PreviewBitmap
                $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
                $graphics.DrawImage($previewBitmap, $labelRect)
            } finally {
                if ($null -ne $previewBitmap) { $previewBitmap.Dispose() }
            }
        } else {
            $fontSize = [single][Math]::Max(9.0, [Math]::Min(15.0, $scale * 1.3))
            $font = New-Object System.Drawing.Font("Microsoft YaHei", $fontSize, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
            $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(140, 148, 160))
            $format = New-Object System.Drawing.StringFormat
            $format.Alignment = [System.Drawing.StringAlignment]::Center
            $format.LineAlignment = [System.Drawing.StringAlignment]::Center
            try { $graphics.DrawString("从剪贴板粘贴或打开图片", $font, $brush, $labelRect, $format) }
            finally { $font.Dispose(); $brush.Dispose(); $format.Dispose() }
        }
    } finally {
        $paperBrush.Dispose(); $borderPen.Dispose()
    }
}

function Update-Preview {
    $label = Get-SelectedLabelSize
    if ($null -eq $label) {
        if ($null -ne $script:statusLabel) { $script:statusLabel.Text = "请先选择标签尺寸。" }
        if ($null -ne $script:previewCanvas) { $script:previewCanvas.Invalidate() }
        Update-BleSessionUi
        return
    }
    $deviceW = [int][Math]::Round($label.Width * 8)
    $deviceH = [int][Math]::Round($label.Height * 8)
    $srcText = if ($state.ImagePath) { $state.ImagePath } elseif ($null -ne $state.Image) { "剪贴板图片" } else { "未载入图片" }
    $offsetMm = Get-BleImageOffsetMm
    $densityText = Get-BlePrintDensityName
    $thresholdText = if ($null -ne $script:bleThresholdBox) { $script:bleThresholdBox.Value } else { 126 }
    if ($null -ne $script:statusLabel) {
        $script:statusLabel.Text = "标签：{0} x {1} mm | 点阵：{2} x {3} | 蓝牙浓淡：{4} | 阈值：{5} | 位置 X/Y：{6:g}/{7:g} mm | 来源：{8}" -f $label.Width, $label.Height, $deviceW, $deviceH, $densityText, $thresholdText, $offsetMm.X, $offsetMm.Y, $srcText
    }
    if ($null -ne $script:previewCanvas) { $script:previewCanvas.Invalidate() }
}

function Print-CurrentLabel {
    try { $label = Require-SelectedLabelSize } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "P50 打印助手") | Out-Null
        return
    }
    if ($null -eq $state.Image) {
        [System.Windows.Forms.MessageBox]::Show("请先粘贴或打开图片。", "P50 打印助手") | Out-Null
        return
    }
    $copies = [int]$script:copiesBox.Value
    $printer = $script:printerCombo.Text.Trim()
    if (-not $printer) { $printer = $PrinterName }
    $printerSettings = New-Object System.Drawing.Printing.PrinterSettings
    $printerSettings.PrinterName = $printer
    if (-not $printerSettings.IsValid) {
        [System.Windows.Forms.MessageBox]::Show("找不到打印机：$printer", "P50 打印助手") | Out-Null
        return
    }
    $printBitmap = $null
    try {
        $printBitmap = New-UsbDriverBitmap
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "生成 USB 打印点阵失败") | Out-Null
        return
    }
    $borderContext = Enter-UsbBorderlessPrintMode $printer
    $usbGeometry = Get-UsbDriverGeometry $label
    $doc = New-Object System.Drawing.Printing.PrintDocument
    $doc.DocumentName = "P50 {0}x{1}mm" -f $label.Width, $label.Height
    $doc.PrinterSettings.PrinterName = $printer
    $doc.PrinterSettings.Copies = [int16]$copies
    $doc.PrintController = New-Object System.Drawing.Printing.StandardPrintController
    $doc.OriginAtMargins = $false
    $doc.DefaultPageSettings.Margins = New-Object System.Drawing.Printing.Margins(0, 0, 0, 0)
    $doc.DefaultPageSettings.PaperSize = New-Object System.Drawing.Printing.PaperSize(("P50 USB {0}x{1}mm" -f $usbGeometry.PaperWidth, $usbGeometry.PaperHeight), (ConvertTo-HundredthInch $usbGeometry.PaperWidth), (ConvertTo-HundredthInch $usbGeometry.PaperHeight))
    $doc.DefaultPageSettings.Landscape = $false
    $doc.add_PrintPage({
        param($sender, $eventArgs)
        $g = $eventArgs.Graphics
        $g.PageUnit = [System.Drawing.GraphicsUnit]::Millimeter
        $g.PageScale = 1.0
        $g.Clear([System.Drawing.Color]::White)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::None
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
        $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
        $hardMarginXmm = [single](($eventArgs.PageSettings.HardMarginX / 100.0) * 25.4)
        $hardMarginYmm = [single](($eventArgs.PageSettings.HardMarginY / 100.0) * 25.4)
        if ($hardMarginXmm -ne 0 -or $hardMarginYmm -ne 0) {
            $g.TranslateTransform(-$hardMarginXmm, -$hardMarginYmm)
        }
        $dest = New-Object System.Drawing.Rectangle(0, 0, [int][Math]::Round($usbGeometry.DrawWidth), [int][Math]::Round($usbGeometry.DrawHeight))
        $g.DrawImage($printBitmap, $dest, [single]0, [single]0, [single]$printBitmap.Width, [single]$printBitmap.Height, [System.Drawing.GraphicsUnit]::Pixel)
        $eventArgs.HasMorePages = $false
    })
    try {
        $doc.Print()
        $borderText = if ($borderContext.Applied) { "已保持驱动绘制边框关闭" } else { $borderContext.Message }
        $carrierText = if ($usbGeometry.CarrierExtraMm -gt 0) { "，40mm 标签已使用 $($usbGeometry.PaperWidth)mm USB 承载页" } else { "" }
        $script:statusLabel.Text = "已发送到 ${printer}：$($label.Width) x $($label.Height) mm，$copies 份（Windows 驱动，已做 USB 方向补偿$carrierText，$borderText）。"
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "打印失败") | Out-Null
    } finally {
        if ($null -ne $printBitmap) { $printBitmap.Dispose() }
        $doc.Dispose()
    }
}

function Add-PythonCandidate($list, $seen, [string]$fileName, [string[]]$prefixArguments) {
    if (-not $fileName -or -not (Test-Path -LiteralPath $fileName)) { return }
    $key = ($fileName + " " + ($prefixArguments -join " ")).ToLowerInvariant()
    if ($seen.ContainsKey($key)) { return }
    $seen[$key] = $true
    [void]$list.Add([pscustomobject]@{ FileName = $fileName; PrefixArguments = $prefixArguments })
}

function Test-PythonBleDependenciesForLauncher($python) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $python.FileName
    $allArgs = @($python.PrefixArguments) + @("-c", "import sys; print(sys.executable); import bleak; import PIL")
    $psi.Arguments = ($allArgs | ForEach-Object { Quote-ProcessArgument $_ }) -join " "
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    return [pscustomobject]@{ Ok = ($proc.ExitCode -eq 0); Details = ($stdout + "`r`n" + $stderr).Trim() }
}

function Get-PythonLauncherWithBleDependencies {
    $candidates = New-Object System.Collections.ArrayList
    $seen = @{}
    Get-Command python -All -ErrorAction SilentlyContinue | ForEach-Object { Add-PythonCandidate $candidates $seen $_.Source @() }
    Get-Command py -All -ErrorAction SilentlyContinue | ForEach-Object { Add-PythonCandidate $candidates $seen $_.Source @("-3") }
    $firstError = ""
    foreach ($candidate in $candidates) {
        $check = Test-PythonBleDependenciesForLauncher $candidate
        if ($check.Ok) { return $candidate }
        if (-not $firstError) { $firstError = "Tried: $($candidate.FileName) $($candidate.PrefixArguments -join ' ')`r`n$($check.Details)" }
    }
    throw "缺少 Python 蓝牙依赖。请安装：python -m pip install bleak pillow`r`n`r`n$firstError"
}

function Get-PortableBleHelperPath([string]$exeName) {
    $baseDir = Get-BaseDir
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($exeName)
    $candidatePaths = @(
        (Join-Path (Join-Path (Join-Path $baseDir "portable") "p50_ble_runtime") $exeName),
        (Join-Path (Join-Path $baseDir "portable") $exeName),
        (Join-Path (Join-Path (Join-Path $baseDir "portable") $stem) $exeName),
        (Join-Path (Join-Path $baseDir "dist") $exeName),
        (Join-Path (Join-Path (Join-Path $baseDir "dist") $stem) $exeName)
    )
    foreach ($path in $candidatePaths) {
        if (Test-Path -LiteralPath $path) { return $path }
    }
    return $null
}

function Get-BlePythonScriptPath([string]$scriptName) {
    $baseDir = Get-BaseDir
    $candidatePaths = @(
        (Join-Path $baseDir $scriptName),
        (Join-Path (Join-Path $baseDir "src") $scriptName)
    )
    foreach ($path in $candidatePaths) {
        if (Test-Path -LiteralPath $path) { return $path }
    }
    return $null
}

function Get-BleRuntimeSummary {
    $probeExe = Get-PortableBleHelperPath "p50_ble_probe.exe"
    $sessionExe = Get-PortableBleHelperPath "p50_ble_session.exe"
    if ($probeExe -and $sessionExe) {
        return "便携蓝牙运行时 OK：$sessionExe"
    }
    try {
        $python = Get-PythonLauncherWithBleDependencies
        return "Python 蓝牙运行时 OK：$($python.FileName)"
    } catch {
        return "蓝牙运行时不可用：$($_.Exception.Message)"
    }
}

function Invoke-P50BleProbe([string[]]$Arguments) {
    $baseDir = Get-BaseDir
    $probeExe = Get-PortableBleHelperPath "p50_ble_probe.exe"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    if ($probeExe) {
        $psi.FileName = $probeExe
        $allArgs = @($Arguments)
    } else {
        $probePath = Get-BlePythonScriptPath "p50_ble_probe.py"
        if (-not $probePath) { throw "BLE probe script not found. Expected p50_ble_probe.py in the app folder or src folder." }
        $python = Get-PythonLauncherWithBleDependencies
        $psi.FileName = $python.FileName
        $allArgs = @($python.PrefixArguments) + @($probePath) + $Arguments
    }
    $psi.Arguments = ($allArgs | ForEach-Object { Quote-ProcessArgument $_ }) -join " "
    $psi.WorkingDirectory = $baseDir
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    return [pscustomobject]@{ ExitCode = $proc.ExitCode; StdOut = $stdout; StdErr = $stderr; FileName = $psi.FileName; Arguments = $psi.Arguments }
}

function Start-P50BleSessionHelper {
    if ($null -ne $script:bleSessionProcess -and -not $script:bleSessionProcess.HasExited) { return }
    $baseDir = Get-BaseDir
    $sessionExe = Get-PortableBleHelperPath "p50_ble_session.exe"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    if ($sessionExe) {
        $psi.FileName = $sessionExe
        $allArgs = @()
    } else {
        $sessionPath = Get-BlePythonScriptPath "p50_ble_session.py"
        if (-not $sessionPath) { throw "BLE session helper not found. Expected p50_ble_session.py in the app folder or src folder." }
        $python = Get-PythonLauncherWithBleDependencies
        $psi.FileName = $python.FileName
        $allArgs = @($python.PrefixArguments) + @($sessionPath)
    }
    $psi.Arguments = ($allArgs | ForEach-Object { Quote-ProcessArgument $_ }) -join " "
    $psi.WorkingDirectory = $baseDir
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()
    $script:bleSessionProcess = $proc
    $script:bleSessionConnected = $false
}

function Test-P50BleSessionProcessAlive {
    return ($null -ne $script:bleSessionProcess -and -not $script:bleSessionProcess.HasExited)
}

function Invoke-P50BleSessionCommand([hashtable]$Payload, [int]$TimeoutMs = 45000) {
    Start-P50BleSessionHelper
    if (-not (Test-P50BleSessionProcessAlive)) { throw "BLE session helper is not running." }
    $script:bleSessionRequestId++
    $Payload["id"] = $script:bleSessionRequestId
    $json = $Payload | ConvertTo-Json -Compress -Depth 8
    $script:bleSessionProcess.StandardInput.WriteLine($json)
    $script:bleSessionProcess.StandardInput.Flush()
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($script:bleSessionProcess.HasExited) {
            $stderr = $script:bleSessionProcess.StandardError.ReadToEnd()
            throw "BLE session helper exited unexpectedly.`r`n$stderr"
        }
        $lineTask = $script:bleSessionProcess.StandardOutput.ReadLineAsync()
        while (-not $lineTask.IsCompleted -and [DateTime]::UtcNow -lt $deadline) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 20
        }
        if (-not $lineTask.IsCompleted) { break }
        $line = $lineTask.Result
        if (-not $line) { continue }
        try { $response = $line | ConvertFrom-Json } catch { continue }
        if ([int]$response.id -ne $script:bleSessionRequestId) { continue }
        if (-not $response.ok) {
            $logText = if ($response.logs) { ($response.logs -join "`r`n") } else { "" }
            $traceText = if ($response.traceback) { "`r`n`r`n$($response.traceback)" } else { "" }
            $parts = New-Object System.Collections.ArrayList
            if ($response.error) { [void]$parts.Add($response.error) }
            if ($logText) { [void]$parts.Add($logText) }
            throw (($parts -join "`r`n") + $traceText)
        }
        return $response
    }
    throw "Timed out waiting for BLE session helper response."
}

function Stop-P50BleSessionHelper {
    if (-not (Test-P50BleSessionProcessAlive)) {
        $script:bleSessionConnected = $false
        return
    }
    try {
        [void](Invoke-P50BleSessionCommand @{ cmd = "disconnect" } 15000)
        [void](Invoke-P50BleSessionCommand @{ cmd = "exit" } 5000)
    } catch {
        try { $script:bleSessionProcess.Kill() } catch {}
    } finally {
        $script:bleSessionConnected = $false
        $script:bleSessionAddress = ""
        $script:bleSessionName = ""
        $script:bleSessionProcess = $null
    }
}

function Set-PrimaryButton($button, [System.Drawing.Color]$color) {
    $button.BackColor = $color
    $button.ForeColor = [System.Drawing.Color]::White
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $button.FlatAppearance.BorderSize = 0
}

function Set-ButtonEnabledVisual($button, [bool]$enabled, [System.Drawing.Color]$enabledColor) {
    $button.Enabled = $enabled
    if ($enabled) {
        $button.BackColor = $enabledColor
        $button.ForeColor = [System.Drawing.Color]::White
    } else {
        $button.BackColor = [System.Drawing.Color]::FromArgb(232, 235, 239)
        $button.ForeColor = [System.Drawing.Color]::FromArgb(145, 150, 158)
    }
}

function Update-BleSessionUi {
    $connectColor = [System.Drawing.Color]::FromArgb(31, 96, 152)
    $printColor = [System.Drawing.Color]::FromArgb(19, 121, 95)
    $hasDevice = ($null -ne $script:bleDeviceCombo -and $script:bleDeviceCombo.SelectedItem -ne $null)
    if ($null -ne $script:bleConnectButton) { Set-ButtonEnabledVisual $script:bleConnectButton ($hasDevice -and -not $script:bleSessionConnected) $connectColor }
    if ($null -ne $script:bleDisconnectButton) { Set-ButtonEnabledVisual $script:bleDisconnectButton $script:bleSessionConnected ([System.Drawing.Color]::FromArgb(102, 112, 128)) }
    if ($null -ne $script:blePrintButton) { Set-ButtonEnabledVisual $script:blePrintButton ($script:bleSessionConnected -and (Test-LabelSizeSelected)) $printColor }
    if ($null -ne $script:bleDeviceCombo) { $script:bleDeviceCombo.Enabled = (-not $script:bleSessionConnected) }
    if ($null -ne $script:bleScanButton) { Set-ButtonEnabledVisual $script:bleScanButton (-not $script:bleSessionConnected) $connectColor }
    if ($null -ne $script:blePairCheck) { $script:blePairCheck.Enabled = (-not $script:bleSessionConnected) }
}

function Update-ImportUi {
    $canImport = Test-LabelSizeSelected
    if ($null -ne $script:pasteButton) {
        Set-ButtonEnabledVisual $script:pasteButton $canImport ([System.Drawing.Color]::FromArgb(19, 121, 95))
    }
    if ($null -ne $script:openButton) {
        $script:openButton.Enabled = $canImport
    }
}

function Convert-JsonRows([string]$jsonText) {
    if (-not $jsonText -or -not $jsonText.Trim()) { return @() }
    $parsed = $jsonText | ConvertFrom-Json
    if ($null -eq $parsed) { return @() }
    if ($parsed -is [System.Array]) { return @($parsed) }
    return @($parsed)
}

function Scan-P50BleDevices {
    if ($null -eq $script:bleDeviceCombo) { return }
    $script:bleScanButton.Enabled = $false
    $script:bleConnectButton.Enabled = $false
    $script:statusLabel.Text = "正在扫描 P50 蓝牙设备..."
    [System.Windows.Forms.Application]::DoEvents()
    try {
        $result = Invoke-P50BleProbe @("scan", "--timeout", "3", "--json")
        if ($result.ExitCode -ne 0 -and -not $result.StdOut.Trim()) { throw ($result.StdErr.Trim()) }
        $rows = if ($result.StdOut.Trim()) { Convert-JsonRows $result.StdOut } else { @() }
        $script:bleDevices = @{}
        $script:bleDeviceCombo.Items.Clear()
        foreach ($row in $rows) {
            if (-not $row.name -or $row.name -eq "(no name)") { continue }
            $hit = if ($row.matched) { "*" } else { " " }
            $item = "{0} {1} [{2}] RSSI {3}" -f $hit, $row.name, $row.address, $row.rssi
            $script:bleDevices[$item] = $row.address
            [void]$script:bleDeviceCombo.Items.Add($item)
        }
        if ($script:bleDeviceCombo.Items.Count -gt 0) {
            $script:bleDeviceCombo.SelectedIndex = 0
            $script:statusLabel.Text = "找到 $($script:bleDeviceCombo.Items.Count) 个蓝牙设备，* 表示疑似 P50 打印机。"
        } else {
            $script:statusLabel.Text = "没有找到可显示名称的蓝牙设备。"
        }
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "蓝牙扫描失败") | Out-Null
        $script:statusLabel.Text = "蓝牙扫描失败。"
    } finally {
        Update-BleSessionUi
    }
}

function Connect-P50BleSession {
    if ($null -eq $script:bleDeviceCombo -or $script:bleDeviceCombo.SelectedItem -eq $null) {
        [System.Windows.Forms.MessageBox]::Show("请先扫描并选择 P50 蓝牙设备。", "P50 打印助手") | Out-Null
        return
    }
    $item = $script:bleDeviceCombo.SelectedItem.ToString()
    $address = $script:bleDevices[$item]
    if (-not $address) {
        [System.Windows.Forms.MessageBox]::Show("所选蓝牙设备没有地址。", "P50 打印助手") | Out-Null
        return
    }
    $script:bleConnectButton.Enabled = $false
    $script:statusLabel.Text = "正在连接蓝牙设备，并保持连接..."
    [System.Windows.Forms.Application]::DoEvents()
    try {
        $payload = @{ cmd = "connect"; address = $address; timeout = 6; pair = [bool]$script:blePairCheck.Checked }
        $response = Invoke-P50BleSessionCommand $payload 60000
        $result = $response.result
        $script:bleSessionConnected = [bool]$result.connected
        $script:bleSessionAddress = [string]$result.address
        $script:bleSessionName = [string]$result.name
        $logText = if ($response.logs) { ($response.logs -join " | ") } else { "" }
        $script:statusLabel.Text = "已连接：$($script:bleSessionName) [$($script:bleSessionAddress)]，通道：$($result.channel)。$logText"
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "蓝牙连接失败") | Out-Null
        Stop-P50BleSessionHelper
        $script:statusLabel.Text = "蓝牙连接失败。"
    } finally {
        Update-BleSessionUi
    }
}

function New-P50BleRunPaths($label) {
    $baseDir = Get-BaseDir
    $runRoot = Join-Path $baseDir "p50_ble_runs"
    if (-not (Test-Path -LiteralPath $runRoot)) { New-Item -ItemType Directory -Path $runRoot | Out-Null }
    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $sizeText = "{0:g}x{1:g}mm" -f $label.Width, $label.Height
    $prefix = "ble_{0}_{1}" -f $stamp, $sizeText
    return [pscustomobject]@{
        Stamp = $stamp
        Directory = $runRoot
        ImagePath = Join-Path $runRoot "$prefix.png"
        JobPath = Join-Path $runRoot "$prefix.job.bin"
        LogPath = Join-Path $runRoot "$prefix.log.txt"
    }
}

function Save-P50BleRunLog($paths, $result) {
    $lines = @(
        "stamp=$($paths.Stamp)",
        "image=$($paths.ImagePath)",
        "job=$($paths.JobPath)",
        "command=$($result.FileName) $($result.Arguments)",
        "exitCode=$($result.ExitCode)",
        "",
        "STDOUT:",
        $result.StdOut,
        "",
        "STDERR:",
        $result.StdErr
    )
    $lines | Out-File -LiteralPath $paths.LogPath -Encoding UTF8
}

function Print-CurrentLabelBle {
    try { $label = Require-SelectedLabelSize } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "P50 打印助手") | Out-Null
        Update-BleSessionUi
        return
    }
    if ($null -eq $state.Image) {
        [System.Windows.Forms.MessageBox]::Show("请先粘贴或打开图片。", "P50 打印助手") | Out-Null
        return
    }
    if (-not $script:bleSessionConnected -or -not (Test-P50BleSessionProcessAlive)) {
        [System.Windows.Forms.MessageBox]::Show("请先连接 P50 蓝牙设备。推荐流程：扫描 -> 连接 -> 打印 -> 断开。", "P50 打印助手") | Out-Null
        Update-BleSessionUi
        return
    }
    $copies = [int]$script:copiesBox.Value
    $runPaths = New-P50BleRunPaths $label
    $bitmap = $null
    $script:blePrintButton.Enabled = $false
    $script:statusLabel.Text = "正在生成 $($label.Width) x $($label.Height) mm 蓝牙打印点阵..."
    [System.Windows.Forms.Application]::DoEvents()
    try {
        $bitmap = New-P50DotBitmap
        $bitmap.Save($runPaths.ImagePath, [System.Drawing.Imaging.ImageFormat]::Png)
        $bitmap.Dispose(); $bitmap = $null
        $script:statusLabel.Text = "正在通过当前蓝牙连接发送打印任务到 $($script:bleSessionAddress)..."
        [System.Windows.Forms.Application]::DoEvents()
        $payload = @{
            cmd = "print-image"
            image = $runPaths.ImagePath
            copies = $copies
            density = (Get-BlePrintDensity)
            chunkDelay = 0.03
            postJobDelay = 0.05
            zlibWbits = 10
            xOffsetMm = 0.0
            yOffsetMm = 0.0
            threshold = [int]$script:bleThresholdBox.Value
            sendStatusQuery = $true
            sendMediaCommand = $false
            includeLocationBetweenPages = $true
            jobCompleteTimeout = 8
            saveJob = $runPaths.JobPath
        }
        $response = Invoke-P50BleSessionCommand $payload 90000
        $stdout = if ($response.logs) { ($response.logs -join "`r`n") } else { "" }
        $result = [pscustomobject]@{ ExitCode = 0; StdOut = $stdout; StdErr = ""; FileName = "p50_ble_session.py"; Arguments = ($payload | ConvertTo-Json -Compress -Depth 8) }
        Save-P50BleRunLog $runPaths $result
        $state.LastBleImagePath = $runPaths.ImagePath
        $state.LastBleLogPath = $runPaths.LogPath
        $script:statusLabel.Text = "蓝牙打印已发送：$($label.Width) x $($label.Height) mm，$copies 份，已等待打印机确认。日志：$($runPaths.LogPath)"
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "蓝牙打印失败") | Out-Null
        try {
            $statusResponse = Invoke-P50BleSessionCommand @{ cmd = "status" } 5000
            $script:bleSessionConnected = [bool]$statusResponse.result.connected
        } catch {
            $script:bleSessionConnected = $false
        }
        $script:statusLabel.Text = "蓝牙打印失败。日志：$($runPaths.LogPath)"
    } finally {
        if ($null -ne $bitmap) { $bitmap.Dispose() }
        Update-BleSessionUi
    }
}

function Disconnect-P50BleSession {
    try {
        Stop-P50BleSessionHelper
        $script:statusLabel.Text = "蓝牙已断开。"
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "蓝牙断开失败") | Out-Null
        $script:statusLabel.Text = "蓝牙断开失败。"
    } finally {
        Update-BleSessionUi
    }
}

function Add-Section($text) {
    $group = New-Object System.Windows.Forms.GroupBox
    $group.Text = $text
    $group.Dock = [System.Windows.Forms.DockStyle]::Top
    $group.AutoSize = $true
    $group.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $group.Padding = New-Object System.Windows.Forms.Padding(10, 18, 10, 10)
    $group.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 10)
    $group.ForeColor = [System.Drawing.Color]::FromArgb(55, 63, 72)
    $inner = New-Object System.Windows.Forms.TableLayoutPanel
    $inner.Dock = [System.Windows.Forms.DockStyle]::Top
    $inner.ColumnCount = 1
    $inner.RowCount = 0
    $inner.AutoSize = $true
    $inner.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $inner.GrowStyle = [System.Windows.Forms.TableLayoutPanelGrowStyle]::AddRows
    [void]$inner.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $group.Controls.Add($inner)
    [void]$layout.Controls.Add($group)
    return $inner
}

function Add-Label($parent, $text) {
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $text
    $label.Height = 22
    $label.Dock = [System.Windows.Forms.DockStyle]::Top
    $label.ForeColor = [System.Drawing.Color]::FromArgb(80, 88, 96)
    [void]$parent.Controls.Add($label)
}

function Add-Control($parent, $control, [int]$height = 34) {
    $control.Height = $height
    $control.Dock = [System.Windows.Forms.DockStyle]::Top
    $control.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)
    [void]$parent.Controls.Add($control)
}

function Add-CompactControl($parent, $control, [int]$height = 26, [int]$bottom = 3) {
    $control.Height = $height
    $control.Dock = [System.Windows.Forms.DockStyle]::Top
    $control.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, $bottom)
    [void]$parent.Controls.Add($control)
}

function New-EqualRow([int]$columns) {
    $row = New-Object System.Windows.Forms.TableLayoutPanel
    $row.Dock = [System.Windows.Forms.DockStyle]::Fill
    $row.ColumnCount = $columns
    $row.RowCount = 1
    $row.AutoSize = $false
    $row.Padding = New-Object System.Windows.Forms.Padding(0)
    $row.Margin = New-Object System.Windows.Forms.Padding(0)
    [void]$row.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $percent = 100.0 / [double]$columns
    for ($i = 0; $i -lt $columns; $i++) {
        [void]$row.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, $percent)))
    }
    return $row
}

function Add-RowItem($row, $control, [int]$column, [int]$rightMargin = 6) {
    $control.Dock = [System.Windows.Forms.DockStyle]::Fill
    $control.Margin = New-Object System.Windows.Forms.Padding(0, 0, $rightMargin, 0)
    [void]$row.Controls.Add($control, $column, 0)
}

function New-FieldBlock([string]$labelText, $control) {
    $block = New-Object System.Windows.Forms.TableLayoutPanel
    $block.Dock = [System.Windows.Forms.DockStyle]::Fill
    $block.ColumnCount = 1
    $block.RowCount = 2
    $block.AutoSize = $false
    $block.Margin = New-Object System.Windows.Forms.Padding(0)
    $block.Padding = New-Object System.Windows.Forms.Padding(0)
    [void]$block.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$block.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 22)))
    [void]$block.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $labelText
    $label.Dock = [System.Windows.Forms.DockStyle]::Fill
    $label.ForeColor = [System.Drawing.Color]::FromArgb(80, 88, 96)
    $control.Dock = [System.Windows.Forms.DockStyle]::Fill
    $control.Margin = New-Object System.Windows.Forms.Padding(0)
    [void]$block.Controls.Add($label, 0, 0)
    [void]$block.Controls.Add($control, 0, 1)
    return $block
}

function New-TuningBlock($valueLabel, $slider) {
    $block = New-Object System.Windows.Forms.TableLayoutPanel
    $block.Dock = [System.Windows.Forms.DockStyle]::Fill
    $block.ColumnCount = 1
    $block.RowCount = 2
    $block.AutoSize = $false
    $block.Margin = New-Object System.Windows.Forms.Padding(0)
    $block.Padding = New-Object System.Windows.Forms.Padding(0)
    [void]$block.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$block.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 20)))
    [void]$block.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $valueLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $valueLabel.Margin = New-Object System.Windows.Forms.Padding(0)
    $slider.Dock = [System.Windows.Forms.DockStyle]::Fill
    $slider.Margin = New-Object System.Windows.Forms.Padding(0)
    [void]$block.Controls.Add($valueLabel, 0, 0)
    [void]$block.Controls.Add($slider, 0, 1)
    return $block
}

function New-TuningValueLabel {
    $label = New-Object System.Windows.Forms.Label
    $label.Height = 19
    $label.Dock = [System.Windows.Forms.DockStyle]::Top
    $label.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $label.ForeColor = [System.Drawing.Color]::FromArgb(80, 88, 96)
    return $label
}

function New-CompactSlider([int]$minimum, [int]$maximum, [int]$value, [int]$tickFrequency, [int]$smallChange = 1, [int]$largeChange = 5) {
    $slider = New-Object System.Windows.Forms.TrackBar
    $slider.AutoSize = $false
    $slider.Minimum = $minimum
    $slider.Maximum = $maximum
    $slider.TickFrequency = $tickFrequency
    $slider.SmallChange = $smallChange
    $slider.LargeChange = $largeChange
    $slider.Value = $value
    return $slider
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "P50 打印助手"
$form.StartPosition = "CenterScreen"
$form.Size = New-Object System.Drawing.Size(1160, 980)
$form.MinimumSize = New-Object System.Drawing.Size(860, 560)
$form.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)

$splitContainer = New-Object System.Windows.Forms.SplitContainer
$splitContainer.Dock = [System.Windows.Forms.DockStyle]::Fill
$splitContainer.Orientation = [System.Windows.Forms.Orientation]::Vertical
$splitContainer.SplitterWidth = 6
$splitContainer.Panel1MinSize = 300
$form.Controls.Add($splitContainer)

$previewPanel = New-Object System.Windows.Forms.Panel
$previewPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$previewPanel.Padding = New-Object System.Windows.Forms.Padding(12)
$previewPanel.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)
$splitContainer.Panel2.Controls.Add($previewPanel)

$leftPanel = New-Object System.Windows.Forms.Panel
$leftPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$leftPanel.AutoScroll = $false
$leftPanel.Padding = New-Object System.Windows.Forms.Padding(14, 14, 10, 14)
$splitContainer.Panel1.Controls.Add($leftPanel)

$script:previewCanvas = New-Object System.Windows.Forms.Panel
$script:previewCanvas.Dock = [System.Windows.Forms.DockStyle]::Fill
$script:previewCanvas.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)
$script:previewCanvas.Add_Paint({ param($sender, $eventArgs) Draw-PreviewCanvas $eventArgs.Graphics $sender.ClientRectangle })
$script:previewCanvas.Add_Resize({ if ($null -ne $script:previewCanvas) { $script:previewCanvas.Invalidate() } })
$previewPanel.Controls.Add($script:previewCanvas)

$script:statusLabel = New-Object System.Windows.Forms.Label
$script:statusLabel.Dock = [System.Windows.Forms.DockStyle]::Bottom
$script:statusLabel.Height = 38
$script:statusLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$script:statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(80, 88, 96)
$script:statusLabel.AutoEllipsis = $true
$previewPanel.Controls.Add($script:statusLabel)

$leftScrollPanel = New-Object System.Windows.Forms.Panel
$leftScrollPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$leftScrollPanel.AutoScroll = $true
$leftPanel.Controls.Add($leftScrollPanel)
$leftScrollPanel.Add_MouseEnter({ $leftScrollPanel.Focus() })

$layout = New-Object System.Windows.Forms.TableLayoutPanel
$layout.Dock = [System.Windows.Forms.DockStyle]::Top
$layout.ColumnCount = 1
$layout.RowCount = 0
$layout.AutoSize = $true
$layout.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
$layout.AutoScroll = $false
$layout.GrowStyle = [System.Windows.Forms.TableLayoutPanelGrowStyle]::AddRows
[void]$layout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$leftScrollPanel.Controls.Add($layout)
$leftScrollPanel.Add_Resize({ if ($null -ne $layout) { $layout.Width = [Math]::Max(1, $leftScrollPanel.ClientSize.Width - 2) } })
$layout.Width = [Math]::Max(1, $leftScrollPanel.ClientSize.Width - 2)
$splitContainer.Add_SplitterMoved({ if ($null -ne $script:previewCanvas) { $script:previewCanvas.Invalidate() } })

$deviceSection = Add-Section "1. 设备连接"
Add-Label $deviceSection "P50 蓝牙设备"
$script:bleDeviceCombo = New-Object System.Windows.Forms.ComboBox
$script:bleDeviceCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
Add-Control $deviceSection $script:bleDeviceCombo

$script:bleScanButton = New-Object System.Windows.Forms.Button
$script:bleScanButton.Text = "扫描 P50 蓝牙"
Set-PrimaryButton $script:bleScanButton ([System.Drawing.Color]::FromArgb(31, 96, 152))
$script:bleConnectButton = New-Object System.Windows.Forms.Button
$script:bleConnectButton.Text = "连接蓝牙"
$script:bleConnectButton.Enabled = $false
Set-PrimaryButton $script:bleConnectButton ([System.Drawing.Color]::FromArgb(31, 96, 152))
$script:bleDisconnectButton = New-Object System.Windows.Forms.Button
$script:bleDisconnectButton.Text = "断开蓝牙"
$script:bleDisconnectButton.Enabled = $false
Set-PrimaryButton $script:bleDisconnectButton ([System.Drawing.Color]::FromArgb(102, 112, 128))
$bleButtonRow = New-EqualRow 3
Add-RowItem $bleButtonRow $script:bleScanButton 0 6
Add-RowItem $bleButtonRow $script:bleConnectButton 1 6
Add-RowItem $bleButtonRow $script:bleDisconnectButton 2 0
Add-Control $deviceSection $bleButtonRow 38
$script:blePairCheck = New-Object System.Windows.Forms.CheckBox
$script:blePairCheck.Text = "连接时请求配对"
$script:blePairCheck.Checked = $false
Add-Control $deviceSection $script:blePairCheck 28

$importSection = Add-Section "2. 标签与图片"
$script:sizeCombo = New-Object System.Windows.Forms.ComboBox
$script:sizeCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
[void]$script:sizeCombo.Items.Add("30 x 15 mm")
[void]$script:sizeCombo.Items.Add("40 x 20 mm")
[void]$script:sizeCombo.Items.Add("40 x 30 mm")
$script:sizeCombo.SelectedIndex = -1
$script:rotationCombo = New-Object System.Windows.Forms.ComboBox
$script:rotationCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
[void]$script:rotationCombo.Items.Add("不旋转")
[void]$script:rotationCombo.Items.Add("顺时针 90 度")
[void]$script:rotationCombo.Items.Add("顺时针 180 度")
[void]$script:rotationCombo.Items.Add("顺时针 270 度")
$script:rotationCombo.SelectedIndex = 0
$labelImageRow = New-EqualRow 2
Add-RowItem $labelImageRow (New-FieldBlock "标签尺寸" $script:sizeCombo) 0 6
Add-RowItem $labelImageRow (New-FieldBlock "图片旋转" $script:rotationCombo) 1 0
Add-Control $importSection $labelImageRow 54
$script:pasteButton = New-Object System.Windows.Forms.Button
$script:pasteButton.Text = "从剪贴板粘贴"
Set-PrimaryButton $script:pasteButton ([System.Drawing.Color]::FromArgb(19, 121, 95))
$script:openButton = New-Object System.Windows.Forms.Button
$script:openButton.Text = "打开图片文件"
$importButtonRow = New-EqualRow 2
Add-RowItem $importButtonRow $script:pasteButton 0 6
Add-RowItem $importButtonRow $script:openButton 1 0
Add-Control $importSection $importButtonRow 42

$tuningSection = Add-Section "3. 打印微调"
$script:bleDensityValueLabel = New-TuningValueLabel
$script:bleDensitySlider = New-CompactSlider 0 2 1 1 1 1
$script:bleThresholdValueLabel = New-TuningValueLabel
$script:bleThresholdBox = New-CompactSlider 1 254 126 25 1 5
$densityThresholdRow = New-EqualRow 2
Add-RowItem $densityThresholdRow (New-TuningBlock $script:bleDensityValueLabel $script:bleDensitySlider) 0 8
Add-RowItem $densityThresholdRow (New-TuningBlock $script:bleThresholdValueLabel $script:bleThresholdBox) 1 0
Add-Control $tuningSection $densityThresholdRow 50
$script:bleXOffsetValueLabel = New-TuningValueLabel
$script:bleXOffsetSlider = New-CompactSlider -100 100 0 20 1 5
$script:bleYOffsetValueLabel = New-TuningValueLabel
$script:bleYOffsetSlider = New-CompactSlider -100 100 0 20 1 5
$offsetRow = New-EqualRow 2
Add-RowItem $offsetRow (New-TuningBlock $script:bleXOffsetValueLabel $script:bleXOffsetSlider) 0 8
Add-RowItem $offsetRow (New-TuningBlock $script:bleYOffsetValueLabel $script:bleYOffsetSlider) 1 0
Add-Control $tuningSection $offsetRow 50
$script:marginValueLabel = New-TuningValueLabel
$script:marginSlider = New-CompactSlider 0 80 10 10 1 5
$script:aspectCheck = New-Object System.Windows.Forms.CheckBox
$script:aspectCheck.Text = "保持比例"
$script:aspectCheck.Checked = $true
$script:cropFillCheck = New-Object System.Windows.Forms.CheckBox
$script:cropFillCheck.Text = "裁切铺满"
$script:cropFillCheck.Checked = $false
$fitOptionRow = New-EqualRow 2
Add-RowItem $fitOptionRow $script:aspectCheck 0 8
Add-RowItem $fitOptionRow $script:cropFillCheck 1 0
$marginAspectRow = New-EqualRow 2
Add-RowItem $marginAspectRow (New-TuningBlock $script:marginValueLabel $script:marginSlider) 0 8
Add-RowItem $marginAspectRow $fitOptionRow 1 0
Add-Control $tuningSection $marginAspectRow 50

$printSection = Add-Section "4. 打印"
$script:copiesBox = New-Object System.Windows.Forms.NumericUpDown
$script:copiesBox.Minimum = 1
$script:copiesBox.Maximum = 99
$script:copiesBox.Value = 1
Add-Control $printSection (New-FieldBlock "打印份数" $script:copiesBox) 54
$script:blePrintButton = New-Object System.Windows.Forms.Button
$script:blePrintButton.Text = "蓝牙打印"
Set-PrimaryButton $script:blePrintButton ([System.Drawing.Color]::FromArgb(31, 96, 152))
$script:blePrintButton.Enabled = $false
Add-Control $printSection $script:blePrintButton 38

$diagnosticSection = Add-Section "5. USB 备用与诊断"
Add-Label $diagnosticSection "Windows USB 打印机"
$script:printerCombo = New-Object System.Windows.Forms.ComboBox
$script:printerCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDown
[System.Drawing.Printing.PrinterSettings]::InstalledPrinters | ForEach-Object { [void]$script:printerCombo.Items.Add($_) }
$script:printerCombo.Text = $PrinterName
Add-Control $diagnosticSection $script:printerCombo
$printButton = New-Object System.Windows.Forms.Button
$printButton.Text = "用 Windows USB 驱动打印"
Add-Control $diagnosticSection $printButton 38
$clipCheckButton = New-Object System.Windows.Forms.Button
$clipCheckButton.Text = "检查剪贴板格式"
$savePreviewButton = New-Object System.Windows.Forms.Button
$savePreviewButton.Text = "导出预览 PNG"
$diagnosticButtonRow = New-EqualRow 2
Add-RowItem $diagnosticButtonRow $clipCheckButton 0 6
Add-RowItem $diagnosticButtonRow $savePreviewButton 1 0
Add-Control $diagnosticSection $diagnosticButtonRow 36

$script:sizeCombo.Add_SelectedIndexChanged({ Set-AutoThresholdFromCurrentImage; Update-Preview; Update-BleSessionUi; Update-ImportUi })
$script:rotationCombo.Add_SelectedIndexChanged({ Set-AutoThresholdFromCurrentImage; Update-Preview })
$script:marginSlider.Add_ValueChanged({ Update-MarginLabel; Update-Preview })
$script:aspectCheck.Add_CheckedChanged({ Update-Preview })
$script:cropFillCheck.Add_CheckedChanged({ Update-Preview })
$script:bleDensitySlider.Add_ValueChanged({ Update-DensityLabel; Update-Preview })
$script:bleXOffsetSlider.Add_ValueChanged({ Update-OffsetLabels; Update-Preview })
$script:bleYOffsetSlider.Add_ValueChanged({ Update-OffsetLabels; Update-Preview })
$script:bleThresholdBox.Add_ValueChanged({
    if (-not $script:suppressThresholdChanged) { $state.ThresholdManuallyAdjusted = $true }
    Update-ThresholdLabel
    Update-Preview
})
$script:bleDeviceCombo.Add_SelectedIndexChanged({ Update-BleSessionUi })
$script:bleScanButton.Add_Click({ Scan-P50BleDevices })
$script:bleConnectButton.Add_Click({ Connect-P50BleSession })
$script:bleDisconnectButton.Add_Click({ Disconnect-P50BleSession })
$script:pasteButton.Add_Click({
    if (-not (Test-LabelSizeSelected)) {
        [System.Windows.Forms.MessageBox]::Show("请先选择标签尺寸。", "P50 打印助手") | Out-Null
        return
    }
    if (-not (Try-SetImageFromClipboard "剪贴板")) {
        $diagnostic = Get-ClipboardDiagnosticText
        [System.Windows.Forms.MessageBox]::Show("剪贴板里没有直接可用的 EMF 矢量图或位图。请在 ChemDraw 中复制结构图，或先导出图片后用打开图片文件导入。`r`n`r`n$diagnostic", "P50 打印助手") | Out-Null
    }
})
$clipCheckButton.Add_Click({ [System.Windows.Forms.MessageBox]::Show((Get-ClipboardDiagnosticText), "剪贴板诊断") | Out-Null })
$script:openButton.Add_Click({
    if (-not (Test-LabelSizeSelected)) {
        [System.Windows.Forms.MessageBox]::Show("请先选择标签尺寸。", "P50 打印助手") | Out-Null
        return
    }
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Filter = "矢量图或图片|*.emf;*.wmf;*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.tif;*.tiff|所有文件|*.*"
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        try {
            $img = [System.Drawing.Image]::FromFile($dialog.FileName)
            Set-CurrentImage $img $dialog.FileName
            $img.Dispose()
        } catch {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "无法打开图片") | Out-Null
        }
    }
    $dialog.Dispose()
})
$printButton.Add_Click({ Print-CurrentLabel })
$script:blePrintButton.Add_Click({ Print-CurrentLabelBle })
$savePreviewButton.Add_Click({
    try { $bitmap = New-P50PreviewBitmap } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "P50 打印助手") | Out-Null
        return
    }
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Filter = "PNG 图片|*.png"
    $dialog.FileName = "p50-preview.png"
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $bitmap.Save($dialog.FileName, [System.Drawing.Imaging.ImageFormat]::Png)
        $script:statusLabel.Text = "预览已导出：$($dialog.FileName)"
    }
    $bitmap.Dispose()
    $dialog.Dispose()
})

$form.Add_FormClosed({
    Stop-P50BleSessionHelper
    if ($null -ne $state.Image) { $state.Image.Dispose() }
})
$form.Add_Load({
    $splitContainer.Panel1MinSize = 300
    $splitContainer.Panel2MinSize = 240
    if ($splitContainer.Width -gt 560) {
        $splitContainer.SplitterDistance = [Math]::Min(400, $splitContainer.Width - $splitContainer.Panel2MinSize - $splitContainer.SplitterWidth)
    }
    if ($null -ne $script:previewCanvas) { $script:previewCanvas.Invalidate() }
})

Update-MarginLabel
Update-DensityLabel
Update-OffsetLabels
Update-ThresholdLabel
Update-Preview
Update-BleSessionUi
Update-ImportUi

if ($ProbeClipboard) {
    Select-LabelSizeByName $ProbeLabelSize
    $sizeTag = ($script:sizeCombo.SelectedItem.ToString() -replace '[^0-9]+', 'x').Trim('x')
    Write-Output ("ProbeLabelSize: {0}" -f $script:sizeCombo.SelectedItem)
    Write-Output (Get-ClipboardDiagnosticText)
    $probeMetafile = $null
    try {
        $probeMetafile = [ClipboardMetafileHelper]::GetEnhancedMetafile()
        if ($null -ne $probeMetafile) {
            Write-Output ("GetEnhancedMetafile: OK width={0}, height={1}, hres={2}, vres={3}" -f $probeMetafile.Width, $probeMetafile.Height, $probeMetafile.HorizontalResolution, $probeMetafile.VerticalResolution)
        } else {
            Write-Output "GetEnhancedMetafile: NULL"
        }
    } catch {
        Write-Output ("GetEnhancedMetafile: ERROR {0}" -f $_.Exception.Message)
    } finally {
        if ($null -ne $probeMetafile) { $probeMetafile.Dispose() }
    }
    try {
        $pastePathOk = Try-SetImageFromClipboard "检查"
        Write-Output ("PasteButtonPath: {0}" -f $pastePathOk)
        if ($pastePathOk -and $null -ne $state.Image) {
            Write-Output ("LoadedImage: source={0}, width={1}, height={2}" -f $state.ImagePath, $state.Image.Width, $state.Image.Height)
            Write-Output ("AutoThreshold: {0}" -f $script:bleThresholdBox.Value)
            $probePreviewPath = Join-Path (Get-BaseDir) "p50_probe_clipboard_${sizeTag}_preview.png"
            $probeUsbRotatedPath = Join-Path (Get-BaseDir) "p50_probe_clipboard_${sizeTag}_usb_rot180_reference.png"
            $probePreview = $null
            $probeUsbRotated = $null
            try {
                $probePreview = New-P50PreviewBitmap
                $probePreview.Save($probePreviewPath, [System.Drawing.Imaging.ImageFormat]::Png)
                Write-Output ("ProbePreview: {0}" -f $probePreviewPath)
                Write-Output (Format-BitmapEdgeStats "PreviewDotBitmap" (Get-BitmapEdgeStats $probePreview))
                $probeUsbRotated = Copy-Rotated180Bitmap $probePreview
                $probeUsbRotated.Save($probeUsbRotatedPath, [System.Drawing.Imaging.ImageFormat]::Png)
                Write-Output ("UsbRot180Reference: {0}" -f $probeUsbRotatedPath)
                Write-Output (Format-BitmapEdgeStats "UsbRot180Reference" (Get-BitmapEdgeStats $probeUsbRotated))
            } finally {
                if ($null -ne $probeUsbRotated) { $probeUsbRotated.Dispose() }
                if ($null -ne $probePreview) { $probePreview.Dispose() }
            }
        }
    } catch {
        Write-Output ("PasteButtonPath: ERROR {0}" -f $_.Exception.Message)
    } finally {
        if ($null -ne $state.Image) { $state.Image.Dispose() }
        $form.Dispose()
    }
    exit 0
}

if ($SelfTest) {
    $bleRuntimeSummary = Get-BleRuntimeSummary
    $syntheticImage = $null
    $dotBitmap = $null
    try {
        $uiText = New-Object System.Collections.Generic.List[string]
        function Add-ControlTextForSelfTest($control) {
            if ($control.Text) { [void]$uiText.Add($control.Text) }
            foreach ($child in $control.Controls) { Add-ControlTextForSelfTest $child }
        }
        Add-ControlTextForSelfTest $form
        $allText = ($uiText -join "`n")
        $requiredTexts = @(
            "1. 设备连接", "2. 标签与图片", "3. 打印微调", "4. 打印",
            "扫描 P50 蓝牙", "连接蓝牙", "断开蓝牙", "从剪贴板粘贴",
            "打开图片文件", "标签尺寸", "图片旋转", "打印份数", "蓝牙打印",
            "打印浓淡（仅蓝牙）", "线条阈值", "5. USB 备用与诊断"
        )
        foreach ($requiredText in $requiredTexts) {
            if ($allText -notmatch [regex]::Escape($requiredText)) {
                throw "UI self-test is missing expected text: $requiredText"
            }
        }
        if ($script:sizeCombo.SelectedIndex -ne -1) {
            throw "UI self-test expected the label size to be blank by default."
        }
        if ($script:pasteButton.Enabled -or $script:openButton.Enabled) {
            throw "UI self-test expected image import to be disabled until a label size is selected."
        }
        if ($script:blePrintButton.Enabled) {
            throw "UI self-test expected Bluetooth print to be disabled until a label size is selected."
        }
        if ($script:bleDensitySlider.Minimum -ne 0 -or $script:bleDensitySlider.Maximum -ne 2 -or $script:bleDensitySlider.Value -ne 1) {
            throw "UI self-test expected a three-position density slider defaulting to Medium."
        }
        if ($script:marginSlider.Minimum -ne 0 -or $script:marginSlider.Maximum -ne 80 -or $script:marginSlider.Value -ne 10) {
            throw "UI self-test expected a margin slider covering 0.0 to 8.0 mm and defaulting to 1.0 mm."
        }
        if ($script:bleXOffsetSlider.Minimum -ne -100 -or $script:bleXOffsetSlider.Maximum -ne 100 -or $script:bleYOffsetSlider.Minimum -ne -100 -or $script:bleYOffsetSlider.Maximum -ne 100) {
            throw "UI self-test expected X/Y offset sliders to cover -10.0 to +10.0 mm."
        }
        if ($script:cropFillCheck.Text -ne "裁切铺满" -or $script:cropFillCheck.Checked) {
            throw "UI self-test expected crop-fill to be available and disabled by default."
        }
        if ($script:rotationCombo.SelectedIndex -ne 0 -or $script:rotationCombo.Items.Count -ne 4) {
            throw "UI self-test expected a four-position image rotation selector defaulting to no rotation."
        }
        $forbiddenTexts = @("2. 导入图片", "Connect, list, disconnect", "Disconnect BLE", "Print to P50 BLE", "Test Bluetooth services", "auto-connects", "USB continuous feed mode", "USB driver gap-label mode", "通过 Word 渲染粘贴", "Word 渲染", "从 ChemDraw 粘贴", "打开上次预览", "打开上次日志")
        foreach ($forbiddenText in $forbiddenTexts) {
            if ($allText -match [regex]::Escape($forbiddenText)) {
                throw "UI self-test found obsolete text: $forbiddenText"
            }
        }
        $groupCount = @($layout.Controls | Where-Object { $_ -is [System.Windows.Forms.GroupBox] }).Count
        if ($groupCount -lt 5) { throw "UI self-test expected grouped product sections; found $groupCount" }
        Write-Output ("UI self-test OK: groups={0}, primary='{1}'" -f $groupCount, $script:blePrintButton.Text)
        $script:sizeCombo.SelectedItem = "30 x 15 mm"
        if (-not $script:pasteButton.Enabled -or -not $script:openButton.Enabled) {
            throw "UI self-test expected image import to become enabled after selecting a label size."
        }
        $syntheticImage = New-SyntheticChemDrawImage
        Set-CurrentImage $syntheticImage "selftest synthetic ChemDraw-like image" $true
        $syntheticImage = $null
        $autoThreshold = [int]$script:bleThresholdBox.Value
        if ($autoThreshold -lt 35 -or $autoThreshold -gt 245) { throw "Auto threshold self-test produced an out-of-range value: $autoThreshold" }
        if ($state.ThresholdManuallyAdjusted) { throw "Auto threshold self-test incorrectly marked the threshold as manually adjusted." }
        Write-Output ("Auto threshold self-test OK: threshold={0}" -f $autoThreshold)
        $dotBitmap = New-P50DotBitmap
        if ($dotBitmap.Width -ne 240 -or $dotBitmap.Height -ne 120) {
            throw "BLE render self-test produced unexpected size: $($dotBitmap.Width) x $($dotBitmap.Height)"
        }
        $blackPixels = 0
        for ($y = 0; $y -lt $dotBitmap.Height; $y++) {
            for ($x = 0; $x -lt $dotBitmap.Width; $x++) {
                $pixel = $dotBitmap.GetPixel($x, $y)
                if ($pixel.R -lt 128) { $blackPixels++ }
            }
        }
        if ($blackPixels -lt 50) { throw "BLE render self-test produced too few black pixels: $blackPixels" }
        Write-Output ("BLE render self-test OK: {0} x {1}, blackPixels={2}" -f $dotBitmap.Width, $dotBitmap.Height, $blackPixels)
        if ($null -ne $dotBitmap) { $dotBitmap.Dispose(); $dotBitmap = $null }

        $squareImage = New-Object System.Drawing.Bitmap(300, 300, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
        $squareGraphics = [System.Drawing.Graphics]::FromImage($squareImage)
        try { $squareGraphics.Clear([System.Drawing.Color]::Black) } finally { $squareGraphics.Dispose() }
        Set-CurrentImage $squareImage "selftest square fill image" $true
        $squareImage = $null
        $script:bleThresholdBox.Value = 126
        $script:cropFillCheck.Checked = $false
        $containBitmap = New-P50DotBitmap
        $script:cropFillCheck.Checked = $true
        $coverBitmap = New-P50DotBitmap
        $containEdgePixel = $containBitmap.GetPixel(10, 60)
        $coverEdgePixel = $coverBitmap.GetPixel(10, 60)
        if ($containEdgePixel.R -lt 128) { throw "Crop-fill self-test expected contain mode to preserve side whitespace." }
        if ($coverEdgePixel.R -ge 128) { throw "Crop-fill self-test expected fill mode to crop and cover the content area." }
        Write-Output "Crop-fill self-test OK"

        $rotationImage = New-Object System.Drawing.Bitmap(10, 20, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
        $script:rotationCombo.SelectedIndex = 1
        $rotatedImage = Copy-RotatedImage $rotationImage (Get-ImageRotationDegrees)
        if ($rotatedImage.Width -ne 20 -or $rotatedImage.Height -ne 10) {
            throw "Image rotation self-test expected 90 degree rotation to swap dimensions; got $($rotatedImage.Width) x $($rotatedImage.Height)."
        }
        Write-Output "Image rotation self-test OK"
    } finally {
        if ($null -ne $syntheticImage) { $syntheticImage.Dispose() }
        if ($null -ne $dotBitmap) { $dotBitmap.Dispose() }
        if ($null -ne $squareImage) { $squareImage.Dispose() }
        if ($null -ne $containBitmap) { $containBitmap.Dispose() }
        if ($null -ne $coverBitmap) { $coverBitmap.Dispose() }
        if ($null -ne $rotationImage) { $rotationImage.Dispose() }
        if ($null -ne $rotatedImage) { $rotatedImage.Dispose() }
    }
    Write-Output $bleRuntimeSummary
    Write-Output "SelfTest OK"
    if ($null -ne $state.Image) { $state.Image.Dispose() }
    $form.Dispose()
    exit 0
}

if ($RenderUiSnapshot) {
    $form.StartPosition = "Manual"
    $form.Location = New-Object System.Drawing.Point(100, 100)
    $form.Show()
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 250
    [System.Windows.Forms.Application]::DoEvents()
    $bitmap = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
    $form.DrawToBitmap($bitmap, (New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
    $bitmap.Save($RenderUiSnapshot, [System.Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
    if ($null -ne $state.Image) { $state.Image.Dispose() }
    $form.Close()
    $form.Dispose()
    Write-Output "UI snapshot saved: $RenderUiSnapshot"
    exit 0
}

if ($UsbTestPrint) {
    Select-LabelSizeByName $UsbTestSize
    $script:copiesBox.Value = 1
    $script:printerCombo.Text = $PrinterName
    $syntheticImage = New-SyntheticChemDrawImage
    Set-CurrentImage $syntheticImage "USB test synthetic image" $true
    $syntheticImage = $null
    $usbSizeTag = ($script:sizeCombo.SelectedItem.ToString() -replace '[^0-9]+', 'x').Trim('x')
    $usbLogicalPath = Join-Path (Get-BaseDir) "p50_usb_test_${usbSizeTag}_logical_preview.png"
    $usbDiagnosticPath = Join-Path (Get-BaseDir) "p50_usb_test_${usbSizeTag}_driver_input.png"
    $usbLogical = $null
    $usbDiagnostic = $null
    try {
        $usbLogical = New-P50DotBitmap
        $usbLogical.Save($usbLogicalPath, [System.Drawing.Imaging.ImageFormat]::Png)
        Write-Output ("UsbLogicalPreview: {0}" -f $usbLogicalPath)
        Write-Output (Format-BitmapEdgeStats "UsbLogicalPreview" (Get-BitmapEdgeStats $usbLogical))
        $usbDiagnostic = Copy-Rotated180Bitmap $usbLogical
        $usbDiagnostic.Save($usbDiagnosticPath, [System.Drawing.Imaging.ImageFormat]::Png)
        Write-Output ("UsbDriverInput: {0}" -f $usbDiagnosticPath)
        Write-Output (Format-BitmapEdgeStats "UsbDriverInput" (Get-BitmapEdgeStats $usbDiagnostic))
    } finally {
        if ($null -ne $usbDiagnostic) { $usbDiagnostic.Dispose() }
        if ($null -ne $usbLogical) { $usbLogical.Dispose() }
    }
    Print-CurrentLabel
    Write-Output $script:statusLabel.Text
    if ($null -ne $state.Image) { $state.Image.Dispose() }
    $form.Dispose()
    exit 0
}

if ($UsbPrepareDriver) {
    $context = Enter-UsbBorderlessPrintMode $PrinterName
    Write-Output $context.Message
    if ($null -ne $state.Image) { $state.Image.Dispose() }
    $form.Dispose()
    exit 0
}

[void]$form.ShowDialog()
