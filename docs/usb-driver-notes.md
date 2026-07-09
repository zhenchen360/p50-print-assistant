# USB Driver Notes

The USB path is a fallback for Windows systems where BLE is unavailable or not
desired. It uses the vendor's Windows printer driver and the Windows print
queue, not the BLE CommandPort transport described in `protocol-notes.md`.

The current implementation is intentionally narrow: it renders the same label
bitmap used by the preview/BLE path, adapts it for the P50 Windows driver, and
submits it through `System.Drawing.Printing.PrintDocument`.

## Driver capability observed on Windows

For the tested `P50 Printer` driver, Windows reports:

```text
DriverName:      P50 Printer
PortName:        USB002
Datatype:        RAW
PrintProcessor:  winprint
Resolution:      203 x 203 dpi
```

The driver exposes paper names such as `58 x 40mm`, but the GDI paper sizes
reported to Windows are about 48 mm wide:

| Driver paper name | GDI size reported by Windows |
|---|---:|
| `58 x 40mm` | `48.01 x 39.88 mm` |
| `58 x 210mm` | `48.01 x 210.31 mm` |
| `58 x 297mm` | `48.01 x 297.18 mm` |
| `58 x 3276mm` | `48.01 x 3275.84 mm` |

`Get-PrintConfiguration` also reports the current media as roughly:

```text
48.047 x 40.039 mm
```

This means the driver label names should not be treated as exact printable
image dimensions. The practical GDI imageable width is about 48 mm.

## Rendering path

The app renders label content at 8 dots/mm, matching approximately 203 dpi:

| Label | Raster size |
|---|---:|
| `30 x 15 mm` | `240 x 120 dots` |
| `40 x 20 mm` | `320 x 160 dots` |
| `40 x 30 mm` | `320 x 240 dots` |

The USB path then:

1. Builds the same 1-bit preview bitmap used by the main print path.
2. Rotates it by 180 degrees for the Windows driver feed direction.
3. Submits it with zero margins through `PrintDocument`.
4. Keeps the driver `Borders` option disabled.

The border option is changed through `Set-PrintConfiguration -PrintTicketXml`
first, because changing only the `System.Printing` user print ticket can report
success while the effective Windows printer configuration remains unchanged.

## 40 mm custom page edge

During testing, a `40 x 20 mm` GDI custom page produced a fixed vertical edge:

- the edge did not move when the image X offset changed;
- image content beyond the edge was clipped;
- `30 x 15 mm` did not show the edge;
- disabling the driver `Borders` option alone did not remove it.

This points to a P50 Windows driver/GDI custom-page boundary rather than an
image-raster problem.

The current workaround is to use the driver's observed 48 mm carrier width for
40 mm labels while still drawing the actual content at the real label width:

```text
paper width submitted to driver: 48 mm
content width drawn:             40 mm
```

This keeps the visible content at the intended label size while moving the
driver edge outside the printed 40 mm content area.

## Difference from BLE printing

BLE printing sends the raster directly through the printer protocol. It does
not use Windows paper sizes, GDI margins, print tickets, or the P50 Windows
driver's custom-page handling.

The USB path is therefore a compatibility fallback. If precise positioning or
continuous label handling matters, the BLE path should remain the reference
implementation.
