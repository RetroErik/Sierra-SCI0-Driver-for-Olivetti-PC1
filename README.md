# Sierra SCI0 Video Driver for Olivetti Prodest PC1

A video driver that lets you play **Sierra SCI0 adventure games** on the **Olivetti Prodest PC1**. Just drop `PC1.DRV` into your game folder — no other modifications needed.

By **Retro Erik** — [YouTube: Retro Hardware and Software](https://www.youtube.com/@RetroErik)

![Olivetti Prodest PC1](https://img.shields.io/badge/Platform-Olivetti%20Prodest%20PC1-blue)
![License](https://img.shields.io/badge/License-LGPL-green)

### 📥 [Download PC1.DRV — the only file you need](PC1.DRV)

## What It Does

- Renders SCI0 games in the PC1's **160×200 16-color** hidden graphics mode
- Uses the Yamaha V6355D's programmable 512-color palette (instead of fixed CGA colors)
- Downsamples SCI's 320×200 framebuffer to 160×200 in real time
- Runs at ~4–5 FPS on the NEC V40 @ 8 MHz — playable for adventure games
- Works with all SCI0 titles: King's Quest 4, Police Quest 2, Leisure Suit Larry 2/3, Space Quest 3, etc.

## What It Doesn't Do

- **No mouse support** — keyboard only
- **No 320×200 mode** — the V40's 8-bit bus is too slow for full-resolution SCI rendering (an experimental 320×200 driver exists in `Older versions/` but is impractical for gameplay)
- **No cursor overlay** — simplified driver without mouse cursor rendering
- **Text is poorly readable** — the 320→160 horizontal downsampling loses every other pixel column, making SCI's small fonts hard to read

## Screenshots

*SCI0 games running on the Olivetti Prodest PC1 with the PC1.DRV driver:*

<p>
<em>King's Quest 4 — Intro</em><br>
<img src="Screenshots/KQ4%20intro%20pc1.drv.png" width="60%" alt="King's Quest 4 - Intro">
</p>

<p>
<em>King's Quest 4</em><br>
<img src="Screenshots/KQ4%20pc1.drv.png" width="60%" alt="King's Quest 4">
</p>

<p>
<em>Police Quest 2 — Intro</em><br>
<img src="Screenshots/PQ2%20Intro%20PC1.drv.png" width="60%" alt="Police Quest 2 - Intro">
</p>

<p>
<em>Police Quest 2 — Entrance</em><br>
<img src="Screenshots/PQ2%20entrance%20PC1.drv.png" width="60%" alt="Police Quest 2 - Entrance">
</p>

<p>
<em>Police Quest 2 — Car</em><br>
<img src="Screenshots/PQ2%20car%20PC1.drv.png" width="60%" alt="Police Quest 2 - Car">
</p>

<p>
<em>Police Quest 2</em><br>
<img src="Screenshots/PQ2%20PC1.drv.png" width="60%" alt="Police Quest 2">
</p>

---

## Development History

The driver went through 8 iterations, each teaching lessons about V40/CGA optimization. The older versions (PC1-1 through PC1-6, PC1-8) are preserved as educational material.

📖 **[Read the full development history →](Older%20versions/README.md)**

---

## How to Use

### Assemble
```bash
nasm -f bin PC1-7.asm -o PC1.DRV
```

### Install
1. Copy `PC1.DRV` into the Sierra game folder
2. Run `INSTALL` and select the PC1 driver

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
- Conversion: Take left pixel only (high nibble) from each 2-pixel pair

---

## References

- **OPTIMIZATION-ANALYSIS.md:** Deep dive into Register 0x64 shake_screen, scroll_rect semantics, performance analysis
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
