; PC1-8-old.asm — ARCHIVED early version of PC1-8 palette cycling experiment
;
; This was the first attempt at a 320×200 CGA driver with V6355D palette
; adaptation for SCI0 games. It tried per-scanline palette streaming
; (applying the PC1-BMP3 technique to live games), global per-update_rect
; palette analysis, and various streaming approaches.
;
; All approaches failed due to fundamental timing constraints:
; - Per-scanline streaming blocked 16ms per update_rect call
; - SCI calls update_rect many times per frame → minutes to draw
; - On-the-fly palette build exceeded active display time budget
; - Rate-limited streaming caused visible flickering
;
; This file was superseded by a clean rewrite (PC1-8.asm) that separated
; palette concerns from update_rect entirely. Kept for historical reference.
;
; STATUS: ARCHIVED — replaced by PC1-8.asm
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

; SCI drivers use a single code/data segment starting at offset 0
[bits 16]
[cpu 186]
[org 0]

; =====================================================================
; Constants
; =====================================================================
PORT_STATUS     equ 0xDA        ; CGA status: bit 0=HSYNC, bit 3=VSYNC
PORT_COLOR      equ 0xD9        ; CGA color select (bit 5 = palette flip)
PORT_REG_ADDR   equ 0xDD        ; V6355D register/palette address
PORT_REG_DATA   equ 0xDE        ; V6355D register/palette data
VRAM_SEG        equ 0xB800      ; CGA VRAM segment
PAL_EVEN        equ 0x00        ; Palette 0 (even lines)
PAL_ODD         equ 0x20        ; Palette 1 (odd lines)
SCREEN_HEIGHT   equ 200
SCREEN_WIDTH    equ 320
BYTES_PER_ROW   equ 160         ; SCI framebuffer: 2 pixels per byte
CGA_BYTES_ROW   equ 80          ; CGA VRAM: 4 pixels per byte

; =====================================================================
; Entry point
; =====================================================================
entry:  db      0E9h            ; force 3-byte near jump opcode
        dw      dispatch - entry - 3

; Magic numbers followed by two Pascal strings
signature       db      00h, 21h, 43h, 65h, 87h, 00h
driver_name     db      3, "pc1"
description     db      28, "Olivetti PC1 - Palette Cycle"

; Call-table for the dispatcher
call_tab        dw      get_color_depth         ; bp = 0
                dw      init_video_mode         ; bp = 2
                dw      restore_mode            ; bp = 4
                dw      update_rect             ; bp = 6
                dw      show_cursor             ; bp = 8
                dw      hide_cursor             ; bp = 10
                dw      move_cursor             ; bp = 12
                dw      load_cursor             ; bp = 14
                dw      shake_screen            ; bp = 16
                dw      scroll_rect             ; bp = 18

; Cursor visibility counter
cursor_counter  dw      0

; Default 16-color EGA palette (V6355D format: R byte, G|B byte)
; Also used as v6355_pal[] lookup for palette stream building
default_palette:
    db 0x00, 0x00    ; 0:  Black
    db 0x00, 0x05    ; 1:  Blue
    db 0x00, 0x50    ; 2:  Green
    db 0x00, 0x55    ; 3:  Cyan
    db 0x05, 0x00    ; 4:  Red
    db 0x05, 0x05    ; 5:  Magenta
    db 0x05, 0x20    ; 6:  Brown
    db 0x05, 0x55    ; 7:  Light Gray
    db 0x02, 0x22    ; 8:  Dark Gray
    db 0x02, 0x27    ; 9:  Light Blue
    db 0x02, 0x72    ; 10: Light Green
    db 0x02, 0x77    ; 11: Light Cyan
    db 0x07, 0x22    ; 12: Light Red
    db 0x07, 0x27    ; 13: Light Magenta
    db 0x07, 0x70    ; 14: Yellow
    db 0x07, 0x77    ; 15: White

; =====================================================================
; Dispatch
; =====================================================================
dispatch:
        push    es
        push    ds
        push    cs
        pop     ds
        call    [cs:call_tab+bp]
        pop     ds
        pop     es
        retf

; =====================================================================
; get_color_depth — returns 16 (SCI expects 16-color EGA framebuffer)
; =====================================================================
get_color_depth:
        mov     ax, 16
        ret

; =====================================================================
; init_video_mode — CGA mode 4 + palette init
; =====================================================================
init_video_mode:
        ; Save current video mode
        mov     ah, 0x0F
        int     0x10
        push    ax

        ; Set BIOS mode 4 (CGA 320×200×4, programs CRTC timing)
        mov     ax, 4
        int     0x10

        ; Set border to black
        mov     ah, 0x0B
        xor     bh, bh
        xor     bl, bl
        int     0x10

        ; Extract RGB channels from default_palette
        call    extract_rgb

        ; Precompute distance matrix for nearest-color matching
        call    compute_dist_matrix

        ; Initial global palette: cyan(3)/magenta(5)/white(15)
        mov     byte [top3_a], 3
        mov     byte [top3_b], 5
        mov     byte [top3_c], 15
        call    build_remap16
        call    build_nibble_remap
        call    program_global_palette

        ; Clear CGA VRAM
        call    clear_screen

        ; Return previous mode number
        pop     ax
        xor     ah, ah
        ret

; =====================================================================
; restore_mode
; =====================================================================
restore_mode:
        push    ax

        ; Reset palette to even (clean state for BIOS)
        xor     al, al
        out     PORT_COLOR, al

        pop     ax
        xor     ah, ah
        int     0x10
        ret

; =====================================================================
; clear_screen — fill CGA VRAM with 0
; =====================================================================
clear_screen:
        push    ax
        push    cx
        push    di
        push    es

        mov     ax, VRAM_SEG
        mov     es, ax
        xor     di, di
        mov     cx, 8192        ; 16KB / 2
        xor     ax, ax
        cld
        rep     stosw

        pop     es
        pop     di
        pop     cx
        pop     ax
        ret

; =====================================================================
; program_black_palette — set V6355D entries E0-E7 to black
; =====================================================================
program_black_palette:
        push    ax
        push    cx
        cli

        mov     al, 0x40
        out     PORT_REG_ADDR, al
        jmp     short $+2

        mov     cx, 16          ; 8 entries × 2 bytes
        xor     al, al
.loop:
        out     PORT_REG_DATA, al
        jmp     short $+2
        loop    .loop

        mov     al, 0x80
        out     PORT_REG_ADDR, al

        sti
        pop     cx
        pop     ax
        ret

; =====================================================================
; extract_rgb — extract R, G, B channels from default_palette
; =====================================================================
extract_rgb:
        push    ax
        push    bx
        push    cx
        push    si

        mov     si, default_palette
        xor     bx, bx
        mov     cx, 16

.ext_loop:
        mov     al, [si]            ; Byte 0: R (bits 2-0)
        and     al, 0x07
        mov     [pal_r + bx], al

        mov     al, [si + 1]       ; Byte 1: G (bits 6-4) | B (bits 2-0)
        mov     ah, al
        shr     al, 4
        and     al, 0x07
        mov     [pal_g + bx], al

        mov     al, ah
        and     al, 0x07
        mov     [pal_b + bx], al

        add     si, 2
        inc     bx
        loop    .ext_loop

        pop     si
        pop     cx
        pop     bx
        pop     ax
        ret

; =====================================================================
; compute_dist_matrix — precompute 16×16 Manhattan distance table
; =====================================================================
; dist_matrix[i*16+j] = |R_i - R_j| + |G_i - G_j| + |B_i - B_j|
; =====================================================================
compute_dist_matrix:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di

        mov     di, dist_matrix
        xor     si, si              ; SI = row index i

.cdm_row:
        xor     bx, bx              ; BX = column index j

.cdm_col:
        xor     dx, dx

        ; |R[si] - R[bx]|
        mov     al, [pal_r + si]
        sub     al, [pal_r + bx]
        jns     .cdm_r_pos
        neg     al
.cdm_r_pos:
        xor     ah, ah
        add     dx, ax

        ; |G[si] - G[bx]|
        mov     al, [pal_g + si]
        sub     al, [pal_g + bx]
        jns     .cdm_g_pos
        neg     al
.cdm_g_pos:
        xor     ah, ah
        add     dx, ax

        ; |B[si] - B[bx]|
        mov     al, [pal_b + si]
        sub     al, [pal_b + bx]
        jns     .cdm_b_pos
        neg     al
.cdm_b_pos:
        xor     ah, ah
        add     dx, ax

        mov     [di], dl            ; Store distance (max 21, fits byte)
        inc     di

        inc     bx
        cmp     bx, 16
        jb      .cdm_col

        inc     si
        cmp     si, 16
        jb      .cdm_row

        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; =====================================================================
; program_global_palette — set V6355D E0-E7 from top3 (both banks same)
; =====================================================================
; Programs both palette banks identically so no flipping is needed.
; E0,E1 = black. E2,E3 = top3_a. E4,E5 = top3_b. E6,E7 = top3_c.
; Takes ~100µs. No VSYNC synchronization needed.
; =====================================================================
program_global_palette:
        push    ax
        push    bx
        push    cx
        push    si
        cli

        ; Wait for VSYNC before programming (avoid mid-frame flicker)
.gp_wait_not_vs:
        in      al, PORT_STATUS
        test    al, 0x08
        jnz     .gp_wait_not_vs
.gp_wait_vs:
        in      al, PORT_STATUS
        test    al, 0x08
        jz      .gp_wait_vs

        ; Open palette at E0
        mov     al, 0x40
        out     PORT_REG_ADDR, al
        jmp     short $+2

        ; E0 = black (R=0, GB=0)
        xor     al, al
        out     PORT_REG_DATA, al
        jmp     short $+2
        out     PORT_REG_DATA, al
        jmp     short $+2

        ; E1 = black
        out     PORT_REG_DATA, al
        jmp     short $+2
        out     PORT_REG_DATA, al
        jmp     short $+2

        ; E2 = top3_a
        xor     bx, bx
        mov     bl, [top3_a]
        shl     bx, 1
        mov     ax, [default_palette + bx]
        out     PORT_REG_DATA, al        ; R byte
        jmp     short $+2
        mov     al, ah
        out     PORT_REG_DATA, al        ; GB byte
        jmp     short $+2

        ; E3 = top3_a (same — both banks)
        mov     ax, [default_palette + bx]
        out     PORT_REG_DATA, al
        jmp     short $+2
        mov     al, ah
        out     PORT_REG_DATA, al
        jmp     short $+2

        ; E4 = top3_b
        xor     bx, bx
        mov     bl, [top3_b]
        shl     bx, 1
        mov     ax, [default_palette + bx]
        out     PORT_REG_DATA, al
        jmp     short $+2
        mov     al, ah
        out     PORT_REG_DATA, al
        jmp     short $+2

        ; E5 = top3_b (same)
        mov     ax, [default_palette + bx]
        out     PORT_REG_DATA, al
        jmp     short $+2
        mov     al, ah
        out     PORT_REG_DATA, al
        jmp     short $+2

        ; E6 = top3_c
        xor     bx, bx
        mov     bl, [top3_c]
        shl     bx, 1
        mov     ax, [default_palette + bx]
        out     PORT_REG_DATA, al
        jmp     short $+2
        mov     al, ah
        out     PORT_REG_DATA, al
        jmp     short $+2

        ; E7 = top3_c (same)
        mov     ax, [default_palette + bx]
        out     PORT_REG_DATA, al
        jmp     short $+2
        mov     al, ah
        out     PORT_REG_DATA, al

        ; Close palette
        mov     al, 0x80
        out     PORT_REG_ADDR, al

        sti
        pop     si
        pop     cx
        pop     bx
        pop     ax
        ret

; =====================================================================
; update_rect — convert + write pixels (fast path, no analysis)
; =====================================================================
; Parameters:   ax = top Y,  bx = left X,  cx = bottom Y
;               dx = right X, si = framebuffer segment
;
; Pure pixel conversion using current XLAT table. No color analysis,
; no palette changes, no VSYNC waits. Same speed as Phase 1 CGA.
; =====================================================================
update_rect:
        push    bp
        cld

        ; Save framebuffer segment
        mov     [fb_segment], si

        ; Save top Y for row iteration
        mov     bp, ax              ; BP = current Y

        ; Calculate height (inclusive)
        sub     cx, ax              ; CX = height - 1

.ur_row_loop:
        push    cx                  ; save height counter

        ; === Copy full framebuffer row to row_buffer ===
        push    ds
        push    es

        ; Source: fb_segment:(row * 160)
        mov     ax, bp
        mov     cl, BYTES_PER_ROW   ; 160
        mul     cl                  ; AX = Y * 160
        mov     si, ax              ; SI = source offset

        ; Set up segments: DS = framebuffer, ES = CS
        mov     ax, cs
        mov     es, ax              ; ES = CS (destination)
        mov     ax, [cs:fb_segment]
        mov     ds, ax              ; DS = framebuffer

        mov     di, row_buffer
        mov     cx, BYTES_PER_ROW / 2   ; 80 words
        rep     movsw               ; Copy 160 bytes to row_buffer

        pop     es
        pop     ds                  ; DS = CS again

        ; === Write full row to CGA VRAM ===
        push    es
        mov     ax, VRAM_SEG
        mov     es, ax              ; ES = CGA VRAM

        ; Calculate VRAM offset for this row (CGA interlace)
        mov     ax, bp              ; AX = row Y
        xor     di, di
        shr     ax, 1               ; AX = Y/2, CF = odd
        jnc     .ur_even_bank
        mov     di, 0x2000          ; Odd bank offset
.ur_even_bank:
        mov     cl, CGA_BYTES_ROW   ; 80
        mul     cl                  ; AX = (Y/2) * 80
        add     di, ax              ; DI = VRAM offset

        ; Convert with XLAT: row_buffer → CGA VRAM
        mov     si, row_buffer
        mov     bx, nibble_remap    ; BX = XLAT table base
        mov     cx, CGA_BYTES_ROW   ; 80 output bytes

.ur_x_loop:
        lodsw                       ; AL=[p0|p1], AH=[p2|p3]
        xlat                        ; AL = (cga0<<2)|cga1
        shl     al, 4              ; shift to high nibble
        xchg    al, ah
        xlat                        ; AL = (cga2<<2)|cga3
        or      al, ah             ; combine
        stosb                       ; write to CGA VRAM
        loop    .ur_x_loop

        pop     es

        ; Next row
        pop     cx                  ; restore height counter
        inc     bp
        dec     cx
        jns     .ur_row_loop

        pop     bp
        ret

; =====================================================================
; find_max_color — find palette index with highest count
; =====================================================================
; Returns: AL = best index (0 if none)
; =====================================================================
find_max_color:
        push    bx
        push    cx
        push    dx

        xor     ax, ax              ; Best index = 0
        xor     dx, dx              ; Best count = 0
        xor     bx, bx              ; Start at color_count[0]
        mov     cx, 16

.fmc_loop:
        cmp     [color_count + bx], dx
        jbe     .fmc_not_better
        mov     dx, [color_count + bx]
        mov     ax, bx
        shr     ax, 1               ; Convert word offset → index

.fmc_not_better:
        add     bx, 2
        loop    .fmc_loop

        pop     dx
        pop     cx
        pop     bx
        ret

; =====================================================================
; build_remap16 — build 16-entry EGA→CGA remap table
; =====================================================================
; CGA 0 = black, CGA 1 = top3_a, CGA 2 = top3_b, CGA 3 = top3_c
; Non-matching colors → nearest by precomputed distance matrix
; =====================================================================
build_remap16:
        push    ax
        push    bx
        push    cx

        xor     cx, cx              ; CL = EGA color index

.br_loop:
        ; Black → CGA 0
        or      cl, cl
        jz      .br_cga0

        ; Direct match with chosen colors?
        cmp     cl, [top3_a]
        je      .br_cga1
        cmp     cl, [top3_b]
        je      .br_cga2
        cmp     cl, [top3_c]
        je      .br_cga3

        ; No match: find nearest
        call    find_nearest        ; CL = color, returns AL = CGA value
        jmp     .br_store

.br_cga0:
        xor     al, al
        jmp     .br_store
.br_cga1:
        mov     al, 1
        jmp     .br_store
.br_cga2:
        mov     al, 2
        jmp     .br_store
.br_cga3:
        mov     al, 3

.br_store:
        xor     bx, bx
        mov     bl, cl
        mov     [remap16 + bx], al

        inc     cl
        cmp     cl, 16
        jb      .br_loop

        pop     cx
        pop     bx
        pop     ax
        ret

; =====================================================================
; find_nearest — map non-top3 color to nearest CGA value via distance
; =====================================================================
; Input:  CL = EGA color index
; Output: AL = CGA value (0-3)
; Uses precomputed dist_matrix[16×16]
; =====================================================================
find_nearest:
        push    bx
        push    dx
        push    si

        ; Row offset into distance matrix
        xor     bh, bh
        mov     bl, cl
        mov     si, bx
        shl     si, 4               ; SI = CL * 16

        ; Distance to black (index 0) → CGA 0
        mov     dl, [dist_matrix + si]  ; dist(CL, 0)
        xor     dh, dh              ; best CGA = 0

        ; Distance to Color A → CGA 1
        xor     bx, bx
        mov     bl, [top3_a]
        mov     al, [dist_matrix + si + bx]
        cmp     al, dl
        jae     .fn_try_b
        mov     dl, al
        mov     dh, 1

.fn_try_b:
        mov     bl, [top3_b]
        mov     al, [dist_matrix + si + bx]
        cmp     al, dl
        jae     .fn_try_c
        mov     dl, al
        mov     dh, 2

.fn_try_c:
        mov     bl, [top3_c]
        mov     al, [dist_matrix + si + bx]
        cmp     al, dl
        jae     .fn_done
        mov     dh, 3

.fn_done:
        mov     al, dh              ; AL = best CGA value

        pop     si
        pop     dx
        pop     bx
        ret

; =====================================================================
; build_nibble_remap — build 256-byte XLAT table from remap16
; =====================================================================
; For each byte value 0x00-0xFF (2 packed EGA pixels):
;   hi = byte >> 4, lo = byte & 0x0F
;   result = (remap16[hi] << 2) | remap16[lo]
; =====================================================================
build_nibble_remap:
        push    ax
        push    bx
        push    cx
        push    di

        mov     di, nibble_remap
        xor     cx, cx              ; CL = input byte 0x00-0xFF

.bnr_loop:
        ; Hi pixel
        mov     al, cl
        shr     al, 4
        xor     bx, bx
        mov     bl, al
        mov     al, [remap16 + bx]
        shl     al, 2              ; Shift to bits 3-2
        mov     ah, al              ; Save in AH

        ; Lo pixel
        mov     al, cl
        and     al, 0x0F
        mov     bl, al
        mov     al, [remap16 + bx]

        ; Combine
        or      al, ah
        mov     [di], al
        inc     di

        inc     cl
        jnz     .bnr_loop           ; Loop until CL wraps (256 iterations)

        pop     di
        pop     cx
        pop     bx
        pop     ax
        ret



; =====================================================================
; show_cursor — scan framebuffer for top 3 colors, update palette
; =====================================================================
; Called by SCI after hide→update×N→show. Scans entire framebuffer
; (32000 bytes), finds global top 3 non-black colors, and updates
; V6355D palette + XLAT table if colors changed.
; =====================================================================
show_cursor:
        pushf
        inc     word [cursor_counter]

        ; Skip if no framebuffer yet
        cmp     word [fb_segment], 0
        je      .sc_done

        ; === Count all colors in entire framebuffer ===
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    ds

        ; Clear color counts
        mov     di, color_count
        mov     cx, 16
.sc_clr:
        mov     word [di], 0
        add     di, 2
        loop    .sc_clr

        ; Scan framebuffer: 32000 bytes = 64000 pixels
        mov     ds, [cs:fb_segment]
        xor     si, si              ; DS:SI = framebuffer start
        mov     cx, 32000           ; 200 rows × 160 bytes

.sc_count:
        lodsb                       ; AL = [hi|lo]
        mov     ah, al

        shr     al, 4
        xor     bx, bx
        mov     bl, al
        shl     bx, 1
        inc     word [cs:color_count + bx]

        mov     al, ah
        and     al, 0x0F
        xor     bx, bx
        mov     bl, al
        shl     bx, 1
        inc     word [cs:color_count + bx]

        loop    .sc_count

        ; Restore DS = CS
        push    cs
        pop     ds

        ; Exclude black
        mov     word [color_count], 0

        ; Find top 3
        call    find_max_color
        mov     cl, al
        xor     bx, bx
        mov     bl, al
        shl     bx, 1
        mov     word [color_count + bx], 0

        call    find_max_color
        mov     ch, al
        xor     bx, bx
        mov     bl, al
        shl     bx, 1
        mov     word [color_count + bx], 0

        call    find_max_color
        mov     dl, al

        ; Check if changed
        cmp     cl, [top3_a]
        jne     .sc_changed
        cmp     ch, [top3_b]
        jne     .sc_changed
        cmp     dl, [top3_c]
        je      .sc_no_change

.sc_changed:
        mov     [top3_a], cl
        mov     [top3_b], ch
        mov     [top3_c], dl

        ; VSYNC-synced palette update (wait at most 16ms)
        call    program_global_palette
        call    build_remap16
        call    build_nibble_remap

.sc_no_change:
        pop     ds
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax

.sc_done:
        popf
        ret

; =====================================================================
; hide_cursor
; =====================================================================
hide_cursor:
        pushf
        dec     word [cursor_counter]
        popf
        ret

; =====================================================================
; move_cursor — stub (preserve all registers)
; =====================================================================
move_cursor:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; =====================================================================
; load_cursor
; =====================================================================
load_cursor:
        mov     ax, [cursor_counter]
        ret

; =====================================================================
; shake_screen — stub
; =====================================================================
shake_screen:
        ret

; =====================================================================
; scroll_rect — delegates to update_rect
; =====================================================================
scroll_rect:
        mov     si, di
        jmp     update_rect

; =====================================================================
; Data Section
; =====================================================================

; Framebuffer info
fb_segment:     dw 0                ; SCI framebuffer segment

; Global palette selection
top3_a:         db 0                ; Global Color A (most frequent)
top3_b:         db 0                ; Color B
top3_c:         db 0                ; Color C

; Extracted RGB channels (3 bits each, 0-7)
pal_r:          times 16 db 0
pal_g:          times 16 db 0
pal_b:          times 16 db 0

; Precomputed 16×16 Manhattan distance matrix
dist_matrix:    times 256 db 0

; Color frequency counts (16 words)
color_count:    times 16 dw 0

; 16-entry EGA→CGA remap table
remap16:        times 16 db 0

; 256-entry nibble-pair XLAT table
nibble_remap:   times 256 db 0

; Row buffer (copy of one SCI framebuffer row)
row_buffer:     times 160 db 0
