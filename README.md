# Sierra SCI0 Video Driver for Olivetti Prodest PC1

A video driver that lets you play **Sierra SCI0 adventure games** on the **Olivetti Prodest PC1** with **mouse support**. Copy `PC1.DRV` into your game folder, run `INSTALL`, and select the PC1 driver.

By **Retro Erik** — [YouTube: Retro Hardware and Software](https://www.youtube.com/@RetroErik)

![Olivetti Prodest PC1](https://img.shields.io/badge/Platform-Olivetti%20Prodest%20PC1-blue)
![License](https://img.shields.io/badge/License-LGPL-green)

### 📥 [Download SCI-PC1.zip — includes PC1.DRV and PATCHFNT.COM](SCI-PC1.zip)

## What It Does

- Renders SCI0 games in the PC1's **160×200 16-color** hidden graphics mode
- Uses the Yamaha V6355D's programmable 512-color palette (instead of fixed CGA colors)
- Downsamples SCI's 320×200 framebuffer to 160×200 in real time
- **Mouse cursor support** via V6335D hardware sprite — zero CPU overhead
- **17% faster than the original CGA driver** (Police Quest 2 intro: 1:34 vs 1:54)
- Works with all SCI0 titles: King's Quest 4, Police Quest 2, Leisure Suit Larry 2/3, Space Quest 3, etc.

## Text Readability

SCI0 uses two fonts:

- **Font 0** — A bold, blocky system font with **2-pixel-wide vertical strokes**. Used for the **status bar** (score, game title at the top of the screen).
- **Font 1** — A more refined, variable-width font with **1-pixel-wide vertical strokes**. Used for **dialog boxes**, **message windows**, and the **text input line** (parser).

The status bar (Font 0) remains readable after 320→160 downsampling because its 2-pixel-wide strokes always have at least one pixel on an even (surviving) column. Font 1's single-pixel strokes often land entirely on an odd column and vanish. Worse, Font 1 is variable-width — successive characters shift between even/odd alignment, so each letter loses different parts, producing garbled text rather than uniformly thin text.

### The Fix: PATCHFNT.COM

**PATCHFNT.COM** is a DOS utility that patches the SCI0 interpreter binary to force all text to use Font 0 (the bold, readable font). It modifies the internal `SetFont()` function so the font number argument is always zero, regardless of what the game scripts request.

The patch is **signature-based** — it scans for `SetFont()`'s unique machine code prologue, so it works on any SCI0 interpreter build without hardcoded offsets.

#### Usage

```
PATCHFNT [/R] [filename]
```

- **filename** is typically `SIERRA.EXE`, `SCIV.EXE`, or `SIERRA.COM` — whichever contains the SCI0 interpreter for your game
- Default filename is `SIERRA.EXE` if omitted
- **/R** reverts the patch (restores original font selection)
- No backup file is created — use `/R` to undo

#### Examples

```
PATCHFNT                  Patches SIERRA.EXE in current directory
PATCHFNT SCIV.EXE         Patches SCIV.EXE (used by KQ4, LL2, etc.)
PATCHFNT /R SCIV.EXE      Reverts SCIV.EXE to original fonts
```

#### Tested Games

| Game | Interpreter File | SetFont Offset |
|---|---|---|
| Police Quest 2 | SIERRA.EXE | 0x4D5C |
| Leisure Suit Larry 2 | SCIV.EXE | 0x4DA4 |
| Leisure Suit Larry 3 | — | — |
| King's Quest 4 | SCIV.EXE | 0xEE32 |

## Mouse Support

The driver uses the V6335D's built-in 16×16 hardware sprite for mouse cursor rendering. SCI cursor shapes (arrow, hand, hourglass, walk icon, etc.) are uploaded directly to sprite RAM — no CPU overhead for compositing or background save/restore.

Requires an **INT 33h mouse driver**:
- **PC1 MOUSE.COM** (Simone Riminucci) — for the PC1's built-in mouse port
- **CTMOUSE** — for RS-232 serial mouse

Without a mouse driver, games run keyboard-only (same as the original CGA driver without a mouse).

## Screenshots

*SCI0 games running on the Olivetti Prodest PC1 with the PC1.DRV driver and PATCHFNT font patch:*

### King's Quest 4 — Before / After Font Patch

<p>
<em>Without PATCHFNT (thin Font 1 garbled by downsampling)</em><br>
<img src="Screenshots/Without%20patch/KQ4%20pc1.drv.png" width="600" alt="King's Quest 4 - Without font patch">
</p>

<p>
<em>With PATCHFNT (all text uses bold Font 0)</em><br>
<img src="Screenshots/KQ4%20PC1%20driver%20patched.png" width="600" alt="King's Quest 4 - With font patch">
</p>

### Police Quest 2

<p>
<em>Police Quest 2 — Entrance</em><br>
<img src="Screenshots/PQ2%20PC1%20driver%20patched%20-%20entrance.png" width="600" alt="Police Quest 2 - Entrance">
</p>

<p>
<em>Police Quest 2 — Car Park</em><br>
<img src="Screenshots/PQ2%20PC1%20driver%20patched%20-%20carpark.png" width="600" alt="Police Quest 2 - Car Park">
</p>

<p>
<em>Police Quest 2 — Car</em><br>
<img src="Screenshots/PQ2%20PC1%20driver%20patched%20-%20car.png" width="600" alt="Police Quest 2 - Car">
</p>

### Leisure Suit Larry

<p>
<em>Leisure Suit Larry 2</em><br>
<img src="Screenshots/LL2%20PC1%20driver%20patched.png" width="600" alt="Leisure Suit Larry 2">
</p>

<p>
<em>Leisure Suit Larry 3</em><br>
<img src="Screenshots/LL3%20PC1%20driver%20patched.png" width="600" alt="Leisure Suit Larry 3">
</p>

---

---

## How to Use

### Assemble
```bash
nasm -f bin -o PC1.DRV PC1.asm
```

### Install
1. Copy `PC1.DRV` and `PATCHFNT.COM` into the Sierra game folder
2. Run `PATCHFNT SIERRA.EXE` (or `PATCHFNT SCIV.EXE` for KQ4/LL2) to fix font readability
3. Run `INSTALL` and select the PC1 driver

---

## Performance

Benchmark: Police Quest 2 intro sequence (title screen through car scene), timed on real PC1 hardware:

| Driver | Time | vs Original CGA |
|---|---|---|
| Original CGA driver | 1:54 | baseline |
| **PC1.DRV** | **1:34** | **17% faster** |
| PC1TEST.DRV (all diag) | 1:42 | 11% faster |

The speed gain comes from writing half the VRAM bytes per row (80 vs 160) due to 320→160 downsampling. The inner loop operates at the theoretical bus-transfer minimum: 3 transfers per output byte (2 reads + 1 write) on the V40's 8-bit bus.

---

## Test Driver

A separate test/instrumentation build is available for hardware validation.

### Build
```bash
# All test features
nasm -f bin -o PC1TEST.DRV PC1TEST.asm

# Individual features
nasm -f bin -DTEST_OVERLAY -o PC1TEST.DRV PC1.asm
nasm -f bin -DDIAG_PATTERN -o PC1DIAG.DRV PC1.asm
nasm -f bin -DTIMING_PROBE -o PC1TIME.DRV PC1.asm
```

### Compile-time flags

| Flag | What it does |
|---|---|
| `TEST_OVERLAY` | Colored-block debug bar in top 8 rows showing last rect coords, call count, bytes estimate |
| `DIAG_PATTERN` | Replaces framebuffer conversion with green/red interlace stripes + white rect borders |
| `TIMING_PROBE` | Flashes border color white during `update_rect` for oscilloscope timing |
| `OVERLAY_H=N` | Height of overlay band in rows (default 8) |

### Hardware test results (April 2026)

- **Interlace:** ✓ Strictly alternating green/red stripes — no combing artifacts
- **Rectangles:** ✓ White outlines track individual dirty rects (confirmed with PQ2 intro animation)
- **Timing:** ✓ Border pulses at >1 Hz — multiple `update_rect` calls per frame as expected

---

## Architecture Reference

### Hardware Context
- **CPU:** NEC V40 @ 8 MHz (80186 compatible)
- **Display:** Yamaha V6355D LCDC
- **Resolution:** 160×200 pixels, 16 colors
- **VRAM:** 16 KB @ B000:0000
- **Memory layout:** CGA-interlaced (even rows in bank 0, odd rows in bank 1)

### CGA Interlace Memory Map
```
Bank 0 (offset +0):      Bank 1 (offset +2000h):
  Row 0 (160 bytes)        Row 1 (160 bytes)
  Row 2 (160 bytes)        Row 3 (160 bytes)
  ...                      ...
  Row 198 (160 bytes)      Row 199 (160 bytes)
```

Updating requires per-row toggle:
- Write row 0 to bank 0 (DI = 0)
- Write row 1 to bank 1 (DI = 0x2000)
- Write row 2 to bank 0 (DI = 160, then reset on row boundary)
- Write row 3 to bank 1 (DI = 0x2000 + 160, etc.)

### Framebuffer Format
- SCI framebuffer: 320×200, 2 pixels per byte (packed 4-bit nibbles)
- PC1 VRAM: 160×200, 2 pixels per byte (packed 4-bit nibbles, right-pixel downsampled)
- Conversion: Left-pixel-only — for each 2-pixel pair, the left (even) pixel is kept and the right (odd) pixel is dropped

---

## References

- **V6355D_scroll_test.asm:** Reference hardware test for Register 0x64 writes (in Demo Scene/)
- **Demo6.asm:** Reference for `rep movsw` optimization (only works with pre-converted buffers)
- **PCPLUS.DRV:** Original PCPLUS driver (basis for ports, in reference repos)

---

## License

These drivers are published under the GNU LGPL license, following the original PCPLUS.DRV by Benedikt Freisen.

---

## YouTube

For more retro computing content, visit my YouTube channel **Retro Hardware and Software**:
[https://www.youtube.com/@RetroErik](https://www.youtube.com/@RetroErik)
