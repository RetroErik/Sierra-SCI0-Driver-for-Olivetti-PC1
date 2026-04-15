; ============================================================================
; PC1.DRV Version 1.1 - Production SCI0 Video Driver for Olivetti Prodest PC1
; Hidden 160x200x16 Graphics Mode
; Written for NASM - NEC V40 (80186 compatible)
; By Retro Erik - 2026 using VS Code with Co-Pilot
; ============================================================================
;
; ARCHITECTURE:
;   Rectangle-based update. Direct framebuffer→VRAM conversion.
;   Per-row CGA interlace toggle (row 0→bank 0, row 1→bank 1, …).
;   Left-pixel downsampling: keeps the high nibble of each source byte
;   (= every other pixel of the 320-wide SCI framebuffer).
;   5-instruction inner loop from PC1-2 (tightest proven variant on
;   the V40 8-bit bus: 3 byte-fetches for AND AX,imm16 vs 5 for two
;   separate AND AL / AND AH in PC1-7).
;
; MOUSE CURSOR:
;   Uses the V6335D’s single 16×16 hardware sprite for cursor rendering.
;   SCI cursor shapes (arrow, hand, hourglass, etc.) are uploaded directly
;   to sprite RAM via load_cursor.  Show/hide controls the sprite’s
;   visibility attribute (register 0x68).  Zero CPU overhead — the
;   V6335D composites the sprite during raster scan.
;   Requires an INT 33h mouse driver (PC1 MOUSE.COM or CTMOUSE).
;   Without a mouse driver, games run keyboard-only (cursor functions
;   are never called).
;
; PERFORMANCE:
;   Direct VRAM writes. No buffering, no extra memory reads.
;   3-transfer bus model per output byte: read framebuffer → ALU → write VRAM.
;   Inner loop hides ALU work inside 8-bit bus latency.
;
; KNOWN LESSONS RESPECTED:
;   ✓ Rectangle-aware (PC1-3 lesson: full-screen kills performance)
;   ✓ Per-row interlace toggle (PC1-4 lesson: two-pass = combing)
;   ✓ No buffering / no 4-transfer penalty (PC1-5/PC1-6 lesson)
;   ✓ Forced 3-byte entry jump (PC1-1/PC1-1b lesson)
;   ✓ PC1-2 inner loop form: and ax,0xF0F0 (smallest, fastest on V40)
;
; HARDWARE TARGET:
;   Olivetti Prodest PC1 — NEC V40 (80186) @ 8 MHz, 8-bit bus
;   Yamaha V6355D LCDC: 160×200×16 hidden mode, VRAM at B000h
;   CGA-interlaced layout: odd-row bank at offset +2000h
;
; STATUS: Production driver.  Based on PC1-7, hardware-verified April 2026.
;   PQ2 intro benchmark: 1:34 (vs 1:54 original CGA = 17% faster).
;   Interlace correctness and rectangle tracking confirmed via PC1TEST.DRV.
;   Hardware sprite cursor verified on real PC1 with SCI0 games.
;
; Based on PCPLUS.DRV by Benedikt Freisen
; Adapted for Olivetti Prodest PC1 with Yamaha V6355D
;
; Copyright (C) 2026 Dag Erik Hagesaeter
;
; This program is free software; you can redistribute it and/or modify
; it under the terms of the GNU Lesser General Public License as published by
; the Free Software Foundation; either version 2.1 of the License, or
; (at your option) any later version.
;
; This program is distributed in the hope that it will be useful,
; but WITHOUT ANY WARRANTY; without even the implied warranty of
; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
; GNU Lesser General Public License for more details.
;
; You should have received a copy of the GNU Lesser General Public License
; along with this program; if not, write to the Free Software Foundation, Inc.,
; 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
;
; BUILD:
;   Production : nasm -f bin -o PC1.DRV PC1.asm
;   Test (all) : nasm -f bin -o PC1TEST.DRV PC1TEST.asm
;   Test (pick): nasm -f bin -DTEST_OVERLAY -o PC1TEST.DRV PC1.asm
;                nasm -f bin -DDIAG_PATTERN -o PC1DIAG.DRV PC1.asm
;                nasm -f bin -DTIMING_PROBE -o PC1TIME.DRV PC1.asm
;
; COMPILE-TIME FLAGS (set via -D on command line or via PC1TEST.asm):
;   TEST_OVERLAY  — On-screen debug overlay in top OVERLAY_H rows.
;                   Shows last rect coords, call count, bytes estimate
;                   as colored blocks (nibble value = palette color).
;   DIAG_PATTERN  — Draw diagnostic stripe pattern instead of converting
;                   framebuffer.  Even rows = light green, odd = light red,
;                   rect border = white.  Verifies interlace + rect coords.
;   TIMING_PROBE  — Toggle border color (port 0xD9) around update_rect
;                   for oscilloscope / logic-analyzer timing measurement.
;   OVERLAY_H     — Height of the overlay band in rows (default 8).
;
; ======================================================================

; === Overlay height (configurable, default 8 rows) ====================
%ifndef OVERLAY_H
  %define OVERLAY_H 8
%endif

; === Constants =========================================================
VRAM_SEG        equ 0xB000    ; PC1 video RAM segment
SRC_BPR         equ 160       ; source bytes/row (320 px ÷ 2 px/byte)
DST_BPR         equ 80        ; dest bytes/row   (160 px ÷ 2 px/byte)
ODD_BANK        equ 8192      ; CGA odd-row bank offset (0x2000)
BANK_SIZE       equ 16384     ; 2 banks × 8192 (0x4000)
INTERLACE_WRAP  equ 16304     ; BANK_SIZE − DST_BPR  (row-advance wrap)

; V6355D I/O ports (0xDx aliases of 0x3Dx — same physical register)
PORT_MODE       equ 0xD8      ; mode control register
PORT_BORDER     equ 0xD9      ; border / overscan color
PORT_REG_SEL    equ 0xDD      ; register-bank address
PORT_REG_DATA   equ 0xDE      ; register-bank data

; V6355D mode values
MODE_16COLOR    equ 0x4A      ; unlock hidden 160×200×16 mode
MODE_DISABLE    equ 0x08      ; disable hidden graphics mode

; ======================================================================
;   SCI DRIVER HEADER
; ======================================================================
[bits 16]
[cpu 186]
[org 0]

;-------------- entry --------------------------------------------------
; SCI far-call entry point.  Must be exactly a 3-byte near jump
; (forced opcode 0xE9) so the SCI interpreter can locate the signature.
;-----------------------------------------------------------------------
entry:  db      0E9h                    ; force 3-byte near JMP
        dw      dispatch - entry - 3

; SCI magic signature + Pascal-string name and description
signature       db  00h, 21h, 43h, 65h, 87h, 00h
driver_name     db  3, "pc1"

%ifdef TEST_OVERLAY
description     db  31, "Olivetti PC1 - 16 Colors (TST)"
%elifdef DIAG_PATTERN
description     db  32, "Olivetti PC1 - 16 Colors (DIAG)"
%elifdef TIMING_PROBE
description     db  32, "Olivetti PC1 - 16 Colors (TIME)"
%else
description     db  32, "Olivetti Prodest PC1 - 16 Colors"
%endif

; SCI dispatch table (bp = even index)
call_tab:
        dw      get_color_depth         ; bp =  0
        dw      init_video_mode         ; bp =  2
        dw      restore_mode            ; bp =  4
        dw      update_rect             ; bp =  6
        dw      show_cursor             ; bp =  8
        dw      hide_cursor             ; bp = 10
        dw      move_cursor             ; bp = 12
        dw      load_cursor             ; bp = 14
        dw      shake_screen            ; bp = 16
        dw      scroll_rect             ; bp = 18

; Cursor visibility counter — SCI reads/writes this directly
cursor_counter  dw  0

; Cursor position (SCI 320×200 coordinates)
cursor_x        dw  0
cursor_y        dw  10

; ======================================================================
;   TEST INSTRUMENTATION DATA  (only present when test flags are set)
; ======================================================================
%ifdef TEST_OVERLAY
upd_count       dw  0         ; total update_rect calls
last_left       dw  0         ; last rect left   (X, 0-319)
last_top        dw  0         ; last rect top    (Y, 0-199)
last_right      dw  0         ; last rect right  (X, 0-319)
last_bottom     dw  0         ; last rect bottom (Y, 0-199)
bytes_written   dw  0         ; estimated output bytes for last rect
%endif

%ifdef DIAG_PATTERN
diag_height     dw  0         ; saved initial height countdown
%endif

; ======================================================================
;   DEFAULT 16-COLOR PALETTE  (CGA-standard, V6355D 9-bit RGB)
; ======================================================================
; Each entry: byte 0 = R[2:0], byte 1 = G[6:4] | B[2:0]
default_palette:
        db 0x00, 0x00         ;  0: Black
        db 0x00, 0x05         ;  1: Blue
        db 0x00, 0x50         ;  2: Green
        db 0x00, 0x55         ;  3: Cyan
        db 0x05, 0x00         ;  4: Red
        db 0x05, 0x05         ;  5: Magenta
        db 0x05, 0x20         ;  6: Brown
        db 0x05, 0x55         ;  7: Light Gray
        db 0x02, 0x22         ;  8: Dark Gray
        db 0x02, 0x27         ;  9: Light Blue
        db 0x02, 0x72         ; 10: Light Green
        db 0x02, 0x77         ; 11: Light Cyan
        db 0x07, 0x22         ; 12: Light Red
        db 0x07, 0x27         ; 13: Light Magenta
        db 0x07, 0x70         ; 14: Yellow
        db 0x07, 0x77         ; 15: White

; ======================================================================
;   DISPATCH
; ======================================================================
dispatch:
        push    es
        push    ds
        push    cs
        pop     ds
        call    [cs:call_tab+bp]
        pop     ds
        pop     es
        retf

; ======================================================================
;   VIDEO MODE FUNCTIONS
; ======================================================================

;-------------- get_color_depth ----------------------------------------
get_color_depth:
        mov     ax, 16
        ret

;-------------- init_video_mode ----------------------------------------
; Sets up the V6355D 160×200×16 hidden mode.
; BIOS mode 4 is called first to programme CGA CRTC timing — this is
; required because the V6355D derives its character-clock speed from
; port 0xD8, which must agree with the CRTC register set.  Without it,
; the previous mode's CRTC timing may produce a black screen.
;
; Returns: ax = previous BIOS video mode number
;-----------------------------------------------------------------------
init_video_mode:
        ; save current video mode
        mov     ah, 0x0F
        int     0x10
        push    ax

        ; BIOS mode 4 — sets CRTC for 40-col CGA graphics timing
        mov     ax, 4
        int     0x10

        ; unlock 160×200×16 hidden mode
        mov     al, MODE_16COLOR
        out     PORT_MODE, al
        jmp     short $+2

        ; black border / overscan
        xor     al, al
        out     PORT_BORDER, al
        jmp     short $+2

        call    set_default_palette
        call    clear_screen

        pop     ax
        xor     ah, ah
        ret

;-------------- clear_screen -------------------------------------------
clear_screen:
        push    ax
        push    cx
        push    di
        push    es
        mov     ax, VRAM_SEG
        mov     es, ax
        xor     di, di
        mov     cx, ODD_BANK           ; 8192 words = 16 KB
        xor     ax, ax
        cld
        rep     stosw
        pop     es
        pop     di
        pop     cx
        pop     ax
        ret

;-------------- set_default_palette ------------------------------------
; Writes the 16-entry palette to the V6355D DAC via ports 0xDD/0xDE.
; Interrupts disabled to keep the palette-write state machine atomic.
; NOTE: do NOT write register 0x65 while palette mode (0x40-0x4F) is
; active — it corrupts palette state.
;-----------------------------------------------------------------------
set_default_palette:
        cli
        cld
        mov     al, 0x40                ; enable palette write, start color 0
        out     PORT_REG_SEL, al
        jmp     short $+2
        mov     cx, 32                  ; 16 colors × 2 bytes
        mov     si, default_palette
.loop:
        cs lodsb                        ; CS override: DS may differ after INT
        out     PORT_REG_DATA, al
        jmp     short $+2
        loop    .loop
        mov     al, 0x80                ; end palette write
        out     PORT_REG_SEL, al
        sti
        ret

;-------------- restore_mode -------------------------------------------
; Disables hidden graphics mode, then restores a BIOS video mode.
; Parameters: ax = BIOS mode number to restore
;-----------------------------------------------------------------------
restore_mode:
        push    ax
        mov     al, MODE_DISABLE
        out     PORT_MODE, al
        jmp     short $+2
        pop     ax
        xor     ah, ah
        int     0x10
        ret

; ======================================================================
;   UPDATE_RECT — Hot Path
; ======================================================================
; Transfer the specified rectangle from the SCI engine's 320×200
; framebuffer to PC1 VRAM with 320→160 left-pixel downsampling
; and per-row CGA interlace.
;
; SCI framebuffer: 320×200, packed nibbles (2 px/byte), 160 bytes/row
; PC1 VRAM:        160×200, packed nibbles, 80 bytes/row, CGA interlaced
;
; Downsampling: keeps the HIGH nibble of each source byte (= left pixel
; of each 2-pixel pair).  Result: pix0|pix2 from source bytes [p0|p1][p2|p3].
;
; Parameters:   ax = rect top  (Y, 0-199)
;               bx = rect left (X, 0-319)
;               cx = rect bottom (Y, 0-199)
;               dx = rect right  (X, 0-319)
;               si = framebuffer segment
; Returns:      --
;-----------------------------------------------------------------------
update_rect:

; --- Test instrumentation: save raw rect params (DS = CS here) --------
%ifdef TEST_OVERLAY
        mov     [last_left], bx
        mov     [last_top], ax
        mov     [last_right], dx
        mov     [last_bottom], cx
        inc     word [upd_count]
%endif

; --- Timing probe: flash border white ---------------------------------
%ifdef TIMING_PROBE
        push    ax
        mov     al, 0x0F                ; bright white
        out     PORT_BORDER, al
        pop     ax
%endif

        push    ds
        push    bp
        cld

        ; Align X to 4-pixel (1-output-byte) boundary
        shr     bx, 1
        shr     bx, 1                   ; bx = left / 4
        add     dx, 3
        shr     dx, 1
        shr     dx, 1                   ; dx = ceil(right / 4)

        ; Dimensions
        sub     cx, ax                   ; cx = height − 1  (row count for JNS)
        sub     dx, bx                   ; dx = width in output bytes

        mov     bp, ax                   ; bp = top Y

        ; VRAM destination segment
        push    si                       ; save framebuffer segment
        mov     ax, VRAM_SEG
        mov     es, ax

        ; Source offset = Y × SRC_BPR + bx×2
        mov     ax, bp                   ; AL = Y  (0-199 fits in byte)
        mov     ah, SRC_BPR             ; AH = 160
        mul     ah                       ; AX = Y × 160  (8-bit mul, DX safe)
        add     ax, bx
        add     ax, bx                   ; AX = Y×160 + X/2
        push    ax                       ; save source offset

        ; Dest offset with CGA interlace
        mov     ax, bp                   ; AX = Y
        xor     di, di
        shr     ax, 1                    ; AX = Y/2, CF = 1 if Y odd
        rcr     di, 1                    ; DI bit 15 ← CF
        shr     di, 1
        shr     di, 1                    ; DI = ODD_BANK if Y odd, else 0
        mov     ah, DST_BPR             ; AH = 80
        mul     ah                       ; AX = (Y/2) × 80
        add     di, ax                   ; DI += row offset within bank
        add     di, bx                   ; DI += column byte offset

        ; Loop setup
        mov     bp, dx                   ; bp = width in output bytes
        mov     dx, cx                   ; dx = height countdown (for JNS)

%ifdef DIAG_PATTERN
        mov     [cs:diag_height], dx     ; save for first-row detection
%endif

        ; DS:SI ← framebuffer
        pop     si                       ; SI = source byte offset
        pop     ax                       ; AX = framebuffer segment
        mov     ds, ax

; ------ Per-row loop ---------------------------------------------------
.y_loop:
        mov     cx, bp                   ; CX = width (output bytes this row)
        push    si
        push    di

%ifdef DIAG_PATTERN
; ======================================================================
;   DIAGNOSTIC PATTERN  (replaces framebuffer conversion)
; ======================================================================
; Border rows (first & last) = white (0xFF).
; Interior even-bank rows = light green (0xAA = color 10 both nibbles).
; Interior odd-bank  rows = light red   (0xCC = color 12 both nibbles).
; Left/right edge columns (interior) = white.
;
; Visually: alternating green/red stripes with white outline.  Any
; combing artifact (wrong interlace order) shows as stripes in the
; wrong sequence.
; ----------------------------------------------------------------------
        ; Is this the first or last row?
        cmp     dx, [cs:diag_height]
        je      .diag_border_row         ; first row → white
        test    dx, dx
        jz      .diag_border_row         ; last row  → white

        ; Interior row: pick color from bank
        cmp     di, ODD_BANK
        jae     .diag_odd
        mov     ah, 0xAA                 ; even bank → light green
        jmp     short .diag_interior
.diag_odd:
        mov     ah, 0xCC                 ; odd bank  → light red
.diag_interior:
        ; Left edge — white
        cmp     cx, 2
        jb      .diag_border_row         ; 1-byte-wide rect → all white
        mov     al, 0xFF
        stosb
        dec     cx
        ; Middle — stripe color
        mov     al, ah
        dec     cx                       ; reserve 1 byte for right edge
        jcxz    .diag_right
        rep     stosb
.diag_right:
        ; Right edge — white
        mov     al, 0xFF
        stosb
        jmp     short .diag_after

.diag_border_row:
        mov     al, 0xFF
        rep     stosb

.diag_after:

%else
; ======================================================================
;   NORMAL FRAMEBUFFER CONVERSION  (production hot path)
; ======================================================================
; Inner loop: read 2 source bytes (4 pixels) → 1 output byte (2 pixels).
; Uses PC1-2 form: AND AX,imm16  (3-byte fetch on 8-bit bus, vs 5 bytes
; for two separate AND instructions in PC1-7).
; ----------------------------------------------------------------------
.x_loop:
        lodsw                            ; AL=[pix0|pix1] AH=[pix2|pix3]
        and     ax, 0xF0F0               ; keep high nibble of each byte
        shr     ah, 4                    ; shift pix2 to low nibble
        or      al, ah                   ; AL = [pix0 | pix2]
        stosb
        loop    .x_loop
%endif

; ------ Row advance (common to both paths) ----------------------------
        pop     di
        pop     si
        add     si, SRC_BPR              ; next source row

        ; CGA interlace toggle: alternate even/odd bank per row
        add     di, ODD_BANK
        cmp     di, BANK_SIZE
        jb      .next_row
        sub     di, INTERLACE_WRAP       ; wrap → next even-bank row
.next_row:
        dec     dx
        jns     .y_loop

        pop     bp
        pop     ds

; --- Test overlay redraw (DS = CS again here) -------------------------
%ifdef TEST_OVERLAY
        call    maybe_redraw_overlay
%endif

; --- Timing probe: restore border to black ----------------------------
%ifdef TIMING_PROBE
        push    ax
        xor     al, al
        out     PORT_BORDER, al
        pop     ax
%endif

        ret

; ======================================================================
;   HARDWARE SPRITE CURSOR  (V6335D direct port I/O)
; ======================================================================
; The V6335D has a single 16×16 hardware sprite with AND/XOR masking.
; It composites during raster scan — zero CPU overhead for rendering.
; The SCI engine polls INT 33h for mouse position/buttons (requires a
; mouse driver TSR: PC1 MOUSE.COM or CTMOUSE).  If no mouse driver is
; loaded, the engine never calls these functions — keyboard-only play.
;
; Visibility control:
;   Register 0x68 (sprite color attribute) via ports 0xDD/0xDE.
;   show_cursor writes 0xF0 (opaque), hide_cursor writes 0x0F
;   (transparent).  This matches Simone Riminucci’s mouse driver.
;
; Coordinate mapping:
;   SCI works in 320×200.  Hardware sprite X/Y offset by +15 each
;   (CenterX/CenterY from the mouse driver convention).
;
; Shape upload:
;   load_cursor writes 16 AND-mask + 16 XOR-mask words to sprite RAM
;   via ports 0xDD/0xDE.  AND mask is inverted (SCI 1=preserve,
;   V6335D 0=preserve).  Register 0x64 bits 1-2 enable AND/XOR masking.
;
; Port safety:
;   Ports 0xDD/0xDE (register bank) must NOT be written during
;   init_video_mode or restore_mode — doing so corrupts the LCDC
;   state machine and can prevent hidden mode from initializing or
;   hang the machine on exit.  All 0xDD/0xDE writes are confined to
;   show_cursor, hide_cursor, and load_cursor (gameplay only).
;
; Sprite ports:
;   0DDh / 0DEh — register bank (shape upload, attributes)
;   3DDh / 3DEh — sprite position + enable
; ======================================================================

;-------------- show_cursor --------------------------------------------
; Show the hardware sprite when counter transitions 0→1.
; SCI nests show/hide calls; only the outermost transition matters.
;-----------------------------------------------------------------------
show_cursor:
        pushf
        cli
        inc     word [cursor_counter]
        cmp     word [cursor_counter], 1
        jne     .done
        ; Make sprite opaque (register 68h = 0xF0)
        push    ax
        push    dx
        mov     al, 0x68 | 0x80
        out     0xDD, al
        mov     al, 0xF0
        out     0xDE, al
        ; Show sprite: write register 60h with enable bit + position
        mov     dx, 0x3DD
        mov     al, 0x60 | 0x80         ; register 60h + enable
        out     dx, al
        inc     dx                      ; DX = 3DEh
        ; Write current X position (SCI X + screen offset)
        mov     ax, [cursor_x]
        add     ax, 15                  ; screen left offset
        xchg    al, ah                  ; big-endian for V6335D
        out     dx, al
        xchg    al, ah
        out     dx, al
        ; Write current Y position
        mov     ax, [cursor_y]
        add     ax, 15                  ; screen top offset
        xchg    al, ah
        out     dx, al
        xchg    al, ah
        out     dx, al
        pop     dx
        pop     ax
.done:
        popf
        ret

;-------------- hide_cursor --------------------------------------------
; Hide the hardware sprite when counter transitions 1→0.
;-----------------------------------------------------------------------
hide_cursor:
        pushf
        cli
        cmp     word [cursor_counter], 0
        je      .done                   ; already zero, don't underflow
        dec     word [cursor_counter]
        jnz     .done                   ; still nested, stay visible
        ; Make sprite transparent (register 68h = 0x0F)
        ; Same write pattern as load_cursor uses (port 0xDD/0xDE)
        push    ax
        mov     al, 0x68 | 0x80
        out     0xDD, al
        mov     al, 0x0F                ; transparent
        out     0xDE, al
        pop     ax
.done:
        popf
        ret

;-------------- move_cursor --------------------------------------------
; Move the hardware sprite to a new position.
; SCI engine calls this whenever the mouse moves.
;
; Parameters:   ax = X (0-319, SCI coordinates)
;               bx = Y (0-199)
; Returns:      -- (all registers preserved)
;-----------------------------------------------------------------------
move_cursor:
        push    ax
        push    bx
        push    dx
        pushf
        cli

        ; Save position for show_cursor to use
        mov     [cursor_x], ax
        mov     [cursor_y], bx

        ; Only move if sprite is currently visible
        cmp     word [cursor_counter], 0
        jle     .done

        ; Write register 60h + enable + position
        mov     dx, 0x3DD
        mov     al, 0x60 | 0x80
        out     dx, al
        inc     dx                      ; DX = 3DEh

        ; X: SCI X + screen offset (no doubling — SCI 0-319 maps directly)
        mov     ax, [cursor_x]
        add     ax, 15                  ; screen left offset
        xchg    al, ah
        out     dx, al
        xchg    al, ah
        out     dx, al

        ; Y: SCI Y + screen offset
        mov     ax, [cursor_y]
        add     ax, 15                  ; screen top offset
        xchg    al, ah
        out     dx, al
        xchg    al, ah
        out     dx, al

.done:
        popf
        pop     dx
        pop     bx
        pop     ax
        ret

;-------------- load_cursor --------------------------------------------
; Upload a new SCI cursor bitmap to the V6335D hardware sprite.
;
; SCI cursor format (at segment:offset):
;   [2 words header (ignored)]
;   [16 words AND-mask]  — 0 = transparent, 1 = preserve background
;   [16 words XOR-mask]  — 1 = draw/invert, 0 = transparent
;   MSB of each word = leftmost pixel (big-endian bit order)
;   Words stored little-endian in memory.
;
; V6335D sprite format:
;   16 words screen mask (AND) + 16 words cursor mask (XOR)
;   Written big-endian byte order to port 0DEh.
;   Screen mask convention is inverted vs SCI (NOT required).
;
; Parameters:   ax = segment of cursor data
;               bx = offset of cursor data
; Returns:      ax = cursor visibility counter
;-----------------------------------------------------------------------
load_cursor:
        push    ds
        push    si
        push    cx
        push    dx
        pushf
        cli

        ; Point DS:SI at cursor data, skip 4-byte header
        mov     ds, ax
        lea     si, [bx + 4]

        ; Select sprite shape memory (register 00h)
        mov     al, 0x00
        out     0xDD, al

        ; Upload 16 AND-mask words (V6335D convention is inverted vs SCI)
        mov     cx, 16
.and_loop:
        lodsw                           ; load SCI AND-mask word
        not     ax                      ; invert: SCI 1=preserve → V6335D 0=preserve
        xchg    al, ah                  ; big-endian byte order for port
        out     0xDE, al
        xchg    al, ah
        out     0xDE, al
        loop    .and_loop

        ; Upload 16 XOR-mask words (no inversion needed)
        mov     cx, 16
.xor_loop:
        lodsw                           ; load SCI XOR-mask word
        xchg    al, ah                  ; big-endian byte order
        out     0xDE, al
        xchg    al, ah
        out     0xDE, al
        loop    .xor_loop

        ; Set sprite masking mode (register 0x64 via port 0x3DD)
        ; Value 0x06: bits 1-2 = enable AND/XOR masking
        ; Without this, the sprite renders as a solid box.
        mov     dx, 0x3DD
        mov     al, 0x64 | 0x80         ; register 64h + write enable
        out     dx, al
        inc     dx
        mov     al, 0x06                ; enable AND/XOR masking
        out     dx, al

        popf
        pop     dx
        pop     cx
        pop     si
        pop     ds

        ; Return cursor visibility counter (SCI API contract)
        mov     ax, [cursor_counter]
        ret

; ======================================================================
;   SHAKE_SCREEN — V6355D Register 0x64 vertical shift
; ======================================================================
; Shakes the display vertically by toggling V6355D register 0x64
; bits 3-5 (vertical pixel offset, 0-7 rows).  Alternating iterations
; shift by 4 rows; in-between iterations reset to 0.  After all
; iterations, register 0x64 is restored to 0.
;
; NOTE: horizontal shake (bit 2 of dl) is not supported on the V6355D
; without CRTC R1 modification; vertical shake is applied for any
; non-zero direction mask.
;
; Parameters:   ax = segment of timer-tick word (for busy wait)
;               bx = offset  of timer-tick word
;               cx = iteration count (forth & back count separately)
;               dl = direction mask (any non-zero → shake)
; Returns:      --
;-----------------------------------------------------------------------
shake_screen:
        test    dl, dl
        jz      .shake_done
        jcxz    .shake_done

        push    es
        push    bx                       ; save caller's BX
        mov     es, ax                   ; ES:BX → timer tick word

.shake_loop:
        ; Alternate: even CX → shift 4 rows, odd CX → shift 0
        mov     al, cl
        and     al, 1
        xor     al, 1                    ; flip: first iter → shifted
        shl     al, 5                    ; 0x00 or 0x20  (bits 3-5 = 0 or 4)

        ; Write V6355D register 0x64
        push    ax
        mov     al, 0x64
        out     PORT_REG_SEL, al
        jmp     short $+2
        pop     ax
        out     PORT_REG_DATA, al
        jmp     short $+2

        ; Busy-wait for next timer tick
        mov     ah, [es:bx]
.shake_wait:
        cmp     ah, [es:bx]
        je      .shake_wait

        loop    .shake_loop

        ; Restore register 0x64 to 0 (no vertical shift)
        mov     al, 0x64
        out     PORT_REG_SEL, al
        jmp     short $+2
        xor     al, al
        out     PORT_REG_DATA, al
        jmp     short $+2

        pop     bx
        pop     es

.shake_done:
        ret

; ======================================================================
;   SCROLL_RECT  (delegates to update_rect)
; ======================================================================
; Parameters:   di = framebuffer segment
;               ax,bx,cx,dx = rect as for update_rect
;-----------------------------------------------------------------------
scroll_rect:
        mov     si, di
        jmp     update_rect

; ######################################################################
;   TEST OVERLAY  (assembled only when TEST_OVERLAY is defined)
; ######################################################################
%ifdef TEST_OVERLAY

;-------------- maybe_redraw_overlay -----------------------------------
; Called after every update_rect.  Redraws the debug overlay if:
;   (a) the current rect overlaps the overlay band (top < OVERLAY_H), OR
;   (b) the call count is a multiple of 16 (periodic refresh).
; This avoids the cost of per-call overlay rendering during gameplay.
;
; NOTE: if TIMING_PROBE is also enabled the border-color pulse includes
; overlay render time.  This is intentional — it shows total driver cost.
;-----------------------------------------------------------------------
maybe_redraw_overlay:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    es

        ; (a) Does the rect overlap the overlay?
        cmp     word [last_top], OVERLAY_H
        jb      .ovl_do_redraw

        ; (b) Periodic: redraw every 16 calls
        test    word [upd_count], 0x0F
        jnz     .ovl_skip

.ovl_do_redraw:
        ; Calculate bytes estimate: width_out × height
        mov     ax, [last_right]
        add     ax, 3
        shr     ax, 1
        shr     ax, 1
        mov     bx, [last_left]
        shr     bx, 1
        shr     bx, 1
        sub     ax, bx                   ; AX = output width (bytes)
        jle     .ovl_skip                ; degenerate rect → skip

        mov     bx, [last_bottom]
        sub     bx, [last_top]
        inc     bx                       ; BX = height (rows)
        mul     bx                       ; AX = estimated bytes
        mov     [bytes_written], ax

        call    render_overlay

.ovl_skip:
        pop     es
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

;-------------- render_overlay -----------------------------------------
; Draw the debug info bar in the top OVERLAY_H rows of VRAM.
;
; Layout (VRAM byte columns, each hex digit = 2 pixels = 1 byte):
;   Col  0- 3  last_left    (4 hex digits as colored blocks)
;   Col  4- 7  last_top
;   Col  8     white separator
;   Col  9-12  last_right
;   Col 13-16  last_bottom
;   Col 17     white separator
;   Col 18-21  upd_count
;   Col 22     white separator
;   Col 23-26  bytes_written
;
; Color-block encoding: each hex nibble N is drawn as a solid OVERLAY_H-
; tall column where both pixels in every byte = color N.  Value 0 appears
; black against the dark-gray (color 8) background.
;-----------------------------------------------------------------------
render_overlay:
        mov     ax, VRAM_SEG
        mov     es, ax
        cld
        call    .clear_overlay

        ; Left & top (rect origin)
        mov     ax, [last_left]
        xor     bx, bx                   ; column 0
        call    .render_hex_word
        mov     ax, [last_top]
        mov     bx, 4
        call    .render_hex_word

        ; White separator
        mov     bx, 8
        call    .render_sep

        ; Right & bottom (rect extent)
        mov     ax, [last_right]
        mov     bx, 9
        call    .render_hex_word
        mov     ax, [last_bottom]
        mov     bx, 13
        call    .render_hex_word

        ; White separator
        mov     bx, 17
        call    .render_sep

        ; Call count
        mov     ax, [upd_count]
        mov     bx, 18
        call    .render_hex_word

        ; White separator
        mov     bx, 22
        call    .render_sep

        ; Bytes estimate
        mov     ax, [bytes_written]
        mov     bx, 23
        call    .render_hex_word

        ret

; --- clear_overlay: fill top OVERLAY_H interlaced rows with dark gray -
.clear_overlay:
        xor     di, di                   ; row 0, bank 0
        mov     cx, OVERLAY_H
.clr_row:
        push    cx
        push    di
        mov     cx, DST_BPR             ; 80 bytes per row
        mov     al, 0x88                 ; dark gray (color 8 both nibbles)
        rep     stosb
        pop     di
        pop     cx
        ; interlace toggle
        add     di, ODD_BANK
        cmp     di, BANK_SIZE
        jb      .clr_ok
        sub     di, INTERLACE_WRAP
.clr_ok:
        loop    .clr_row
        ret

; --- render_hex_word: draw 16-bit AX as 4 color columns at column BX --
.render_hex_word:
        push    ax
        push    bx
        push    dx
        mov     dx, ax                   ; DX = value to render

        mov     al, dh
        shr     al, 4                    ; nibble 3 (MSB)
        call    .render_nibble
        inc     bx

        mov     al, dh
        and     al, 0x0F                 ; nibble 2
        call    .render_nibble
        inc     bx

        mov     al, dl
        shr     al, 4                    ; nibble 1
        call    .render_nibble
        inc     bx

        mov     al, dl
        and     al, 0x0F                 ; nibble 0 (LSB)
        call    .render_nibble

        pop     dx
        pop     bx
        pop     ax
        ret

; --- render_sep: white separator column at BX -------------------------
.render_sep:
        push    ax
        mov     al, 0x0F                 ; nibble = 15 (white)
        call    .render_nibble
        pop     ax
        ret

; --- render_nibble: draw a solid OVERLAY_H-tall column of color AL ----
; AL = nibble value (0-F), BX = VRAM byte column offset
.render_nibble:
        push    cx
        push    di
        ; build solid-color byte: both pixels = AL
        mov     ah, al
        shl     al, 4
        or      al, ah                   ; AL = (N<<4)|N
        mov     di, bx                   ; start at column BX, row 0 bank 0
        mov     cx, OVERLAY_H
.nib_row:
        mov     [es:di], al
        add     di, ODD_BANK
        cmp     di, BANK_SIZE
        jb      .nib_ok
        sub     di, INTERLACE_WRAP
.nib_ok:
        loop    .nib_row
        pop     di
        pop     cx
        ret

%endif ; TEST_OVERLAY
