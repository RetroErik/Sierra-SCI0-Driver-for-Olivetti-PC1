; PC1-8.DRV — 320×200 CGA driver with V6355D palette adaptation (EXPERIMENTAL)
;
; STATUS: Incomplete / not production-ready. Archived for reference.
;
; CONCEPT:
;   Uses CGA mode 4 (320×200, 2bpp) to render SCI's 16-color EGA framebuffer
;   at full horizontal resolution (320 pixels vs PC1-7's 160 pixels).
;   Converts 4bpp EGA → 2bpp CGA via a 256-byte XLAT lookup table.
;   The Yamaha V6355D DAC is then reprogrammed with the 3 most-used
;   non-black EGA colors from the scene, overriding CGA's fixed palette.
;
; WHY CGA PALETTE FLIPPING IS NOT PRACTICAL ON THE V6355D:
;   The V6355D has only 4 palette entries in CGA mode (mapped via DAC entries
;   0/3/5/7 for palette 1, or 0/2/4/6 for palette 0). Changing these colors
;   requires writing to all 16 DAC entries (32 bytes via ports 0xDD/0xDE)
;   to cover both palette/intensity combinations. This is fast (~100µs) but
;   creates a synchronization problem: after reprogramming the DAC, the CGA
;   pixel values already in VRAM were written with the OLD color mapping.
;   A full-screen redraw (32KB read + 16KB write) is needed to update VRAM
;   with the new mapping, which takes ~200ms on the V40's 8-bit bus.
;   Per-scanline palette streaming (like PC1-BMP3 does for static images)
;   is not feasible because SCI calls update_rect many times per frame,
;   and each call would need a 16ms VSYNC wait for synchronized streaming.
;
; WHAT WAS TRIED:
;   1. Per-scanline V6355D palette streaming in update_rect → too slow,
;      each update_rect blocked 16ms for VSYNC. SCI calls it dozens of
;      times per frame, making screen draws take minutes.
;   2. On-the-fly palette build during streaming → 68µs per line exceeded
;      the ~52µs active display budget. Only 2 scanlines were visible.
;   3. Global palette analysis in update_rect → palette based on small
;      rectangles (cursor, text) kept overriding the full-scene palette.
;   4. Global palette in show_cursor → show_cursor is not called during
;      loading, so the screen stayed black until the game became interactive.
;   5. Keypress-triggered palette update (this version) → works for testing
;      but not a real solution. Pressing space/enter scans the framebuffer,
;      picks top 3 colors, reprograms V6355D, and redraws the full screen.
;
; WHY DEVELOPMENT STOPPED:
;   The SCI0 games are too slow to be playable on the Olivetti PC1 at
;   320×200 resolution. The V40 CPU at 8MHz with an 8-bit bus cannot
;   convert and transfer 32KB of framebuffer data per frame fast enough.
;   The 160×200 PC1-7 driver (which halves horizontal resolution) provides
;   acceptable frame rates, and the palette adaptation concept works in
;   PC1-BMP3 for static image viewing. For interactive games, the hardware
;   simply isn't fast enough to benefit from 320×200 + palette cycling.
;
; ARCHITECTURE:
;   update_rect: Reads EGA framebuffer directly (no intermediate buffer),
;     converts via cs xlatb (V40/186 segment override), writes CGA VRAM.
;     Zero palette work — pure conversion at maximum speed.
;   show_cursor: On space/enter keypress, scans all 32000 framebuffer bytes,
;     counts 16 EGA colors, picks top 3 non-black, rebuilds XLAT table,
;     reprograms all 16 V6355D DAC entries, and redraws the full screen.
;   program_palette: Writes all 16 DAC entries (32 bytes) placing the 3
;     chosen colors at CGA palette positions 2-7 and 10-15, covering all
;     palette/intensity combinations per PC1PAL.asm's proven technique.
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

[bits 16]
[cpu 186]
[org 0]

; === Constants ===
PORT_REG_ADDR   equ 0xDD
PORT_REG_DATA   equ 0xDE
VRAM_SEG        equ 0xB800
BYTES_PER_ROW   equ 160
CGA_BYTES_ROW   equ 80

; === Entry point ===
entry:  db      0E9h
        dw      dispatch - entry - 3

signature       db      00h, 21h, 43h, 65h, 87h, 00h
driver_name     db      3, "pc1"
description     db      28, "Olivetti PC1 - Palette Cycle"

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

cursor_counter  dw      0

; V6355D palette: 2 bytes per EGA color (R byte, G|B byte)
v6355d_pal:
    db 0x00,0x00, 0x00,0x05, 0x00,0x50, 0x00,0x55 ; 0-3
    db 0x05,0x00, 0x05,0x05, 0x05,0x20, 0x05,0x55 ; 4-7
    db 0x02,0x22, 0x02,0x27, 0x02,0x72, 0x02,0x77 ; 8-11
    db 0x07,0x22, 0x07,0x27, 0x07,0x70, 0x07,0x77 ; 12-15

; === Dispatch ===
dispatch:
        push    es
        push    ds
        push    cs
        pop     ds
        call    [cs:call_tab+bp]
        pop     ds
        pop     es
        retf

; === get_color_depth ===
get_color_depth:
        mov     ax, 16
        ret

; === init_video_mode ===
init_video_mode:
        mov     ah, 0x0F
        int     0x10
        push    ax

        ; CGA mode 4 — BIOS sets palette, clears VRAM, programs CRTC
        mov     ax, 4
        int     0x10

        ; Precompute lookup tables for color matching
        call    extract_rgb
        call    compute_dist_matrix

        ; Initial XLAT assumes standard CGA palette 1: cyan(3), magenta(5), white(15)
        ; This matches what BIOS already set — no V6355D reprogramming needed
        mov     byte [top3_a], 3
        mov     byte [top3_b], 5
        mov     byte [top3_c], 15
        call    build_remap16
        call    build_nibble_remap

        pop     ax
        xor     ah, ah
        ret

; === restore_mode ===
restore_mode:
        push    ax

        ; Reset V6355D palette to standard 16-color CGA defaults
        call    reset_v6355d_palette

        ; Restore BIOS video mode
        pop     ax
        xor     ah, ah
        int     0x10
        ret

; === update_rect — pure copy + XLAT ===
; ax=topY, bx=leftX, cx=bottomY, dx=rightX, si=fb_segment
; V40 optimized: reads framebuffer directly (no row_buffer copy),
; uses cs xlatb for segment-overridden table lookup.
update_rect:
        push    bp
        cld
        mov     [fb_segment], si
        mov     bp, ax          ; bp = current row
        sub     cx, ax          ; cx = row count

.row:   push    cx
        push    ds
        push    es

        ; SI = framebuffer offset for this row (row * 160)
        mov     ax, bp
        mov     cl, BYTES_PER_ROW
        mul     cl
        mov     si, ax

        ; DI = CGA VRAM offset (interlaced: odd rows at +0x2000)
        mov     ax, VRAM_SEG
        mov     es, ax
        mov     ax, bp
        xor     di, di
        shr     ax, 1
        jnc     .even
        mov     di, 0x2000
.even:  mov     cl, CGA_BYTES_ROW
        mul     cl
        add     di, ax

        ; DS = framebuffer segment for lodsw
        mov     ds, [cs:fb_segment]
        ; BX = nibble_remap table (in CS) for cs xlatb
        mov     bx, nibble_remap
        mov     cx, CGA_BYTES_ROW

        ; Inner loop: 2 EGA bytes → 1 CGA byte
        ; lodsw reads from DS:SI (framebuffer)
        ; cs xlatb reads from CS:BX+AL (nibble_remap)
.xlat:  lodsw
        cs xlatb
        shl     al, 4
        xchg    al, ah
        cs xlatb
        or      al, ah
        stosb
        dec     cx
        jnz     .xlat

        pop     es
        pop     ds
        pop     cx
        inc     bp
        dec     cx
        jns     .row

        pop     bp
        ret

; === show_cursor — poll keyboard port, recalc palette on space/enter ===
show_cursor:
        inc     word [cursor_counter]
        cmp     word [fb_segment], 0
        je      .ret

        ; Read keyboard port directly (no BIOS needed)
        in      al, 0x60
        cmp     al, 0x39        ; space scancode
        je      .go
        cmp     al, 0x1C        ; enter scancode
        je      .go
        jmp     .ret

.go:    push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    ds

        ; Clear counts
        mov     di, color_count
        mov     cx, 16
.clr:   mov     word [di], 0
        add     di, 2
        loop    .clr

        ; Count all pixels
        mov     ds, [cs:fb_segment]
        xor     si, si
        mov     cx, 32000
.cnt:   lodsb
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
        loop    .cnt

        push    cs
        pop     ds

        ; Exclude black
        mov     word [color_count], 0

        ; Find top 3
        call    find_max_color
        mov     cl, al
        or      cl, cl
        jz      .skip           ; all black
        xor     bx, bx
        mov     bl, al
        shl     bx, 1
        mov     word [color_count + bx], 0

        call    find_max_color
        mov     ch, al
        or      ch, ch
        jnz     .got2
        mov     ch, 3           ; default cyan if only 1 color found
.got2:  xor     bx, bx
        mov     bl, ch
        shl     bx, 1
        mov     word [color_count + bx], 0

        call    find_max_color
        mov     dl, al
        or      dl, dl
        jnz     .got3
        mov     dl, 5           ; default magenta if only 2 colors found
.got3:
        mov     [top3_a], cl
        mov     [top3_b], ch
        mov     [top3_c], dl
        call    build_remap16
        call    build_nibble_remap
        call    program_palette

        ; Redraw entire screen with new XLAT table
        call    full_redraw

.skip:  pop     ds
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
.ret:   ret

; === hide_cursor ===
hide_cursor:
        dec     word [cursor_counter]
        ret

; === move_cursor ===
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

; === load_cursor ===
load_cursor:
        mov     ax, [cursor_counter]
        ret

; === shake_screen ===
shake_screen:
        ret

; === scroll_rect ===
scroll_rect:
        mov     si, di
        jmp     update_rect

; =================================================================
; full_redraw — redraw entire screen with current XLAT table
; =================================================================
full_redraw:
        pusha
        push    ds
        push    es

        mov     ds, [cs:fb_segment]
        mov     ax, VRAM_SEG
        mov     es, ax
        mov     bx, nibble_remap
        xor     si, si
        xor     bp, bp

.row:   mov     ax, bp
        xor     di, di
        shr     ax, 1
        jnc     .ev
        mov     di, 0x2000
.ev:    mov     cl, CGA_BYTES_ROW
        mul     cl
        add     di, ax

        mov     cx, CGA_BYTES_ROW
.pix:   lodsw
        cs xlatb
        shl     al, 4
        xchg    al, ah
        cs xlatb
        or      al, ah
        stosb
        dec     cx
        jnz     .pix

        inc     bp
        cmp     bp, 200
        jb      .row

        pop     es
        pop     ds
        popa
        ret

; =================================================================
; program_palette — write all 16 V6355D DAC entries
;
; CGA mode 4 pixel values 0-3 map to DAC entries depending on
; which BIOS palette/intensity is active:
;   Palette 1 High: 0, 11, 13, 15
;   Palette 1 Low:  0,  3,  5,  7
;   Palette 0 High: 0, 10, 12, 14
;   Palette 0 Low:  0,  2,  4,  6
;
; We write our 3 colors to ALL color 1/2/3 positions so it works
; regardless of which CGA palette the game uses.
; =================================================================
program_palette:
        push    ax
        push    bx
        push    cx
        push    si
        push    di

        ; Build 32-byte palette buffer
        ; Start: copy default CGA palette as base
        mov     si, v6355d_pal
        mov     di, pal_buffer
        mov     cx, 32
.cp:    mov     al, [cs:si]
        mov     [di], al
        inc     si
        inc     di
        loop    .cp

        ; Entry 0 = black (always)
        xor     ax, ax
        mov     [pal_buffer + 0*2], ax

        ; Get V6355D color words for top3
        xor     bx, bx
        mov     bl, [top3_a]
        shl     bx, 1
        mov     ax, [v6355d_pal + bx]
        mov     [pal_col1], ax

        xor     bx, bx
        mov     bl, [top3_b]
        shl     bx, 1
        mov     ax, [v6355d_pal + bx]
        mov     [pal_col2], ax

        xor     bx, bx
        mov     bl, [top3_c]
        shl     bx, 1
        mov     ax, [v6355d_pal + bx]
        mov     [pal_col3], ax

        ; Palette 1 Low: entries 3, 5, 7
        mov     ax, [pal_col1]
        mov     [pal_buffer + 3*2], ax
        mov     ax, [pal_col2]
        mov     [pal_buffer + 5*2], ax
        mov     ax, [pal_col3]
        mov     [pal_buffer + 7*2], ax

        ; Palette 1 High: entries 11, 13, 15
        mov     ax, [pal_col1]
        mov     [pal_buffer + 11*2], ax
        mov     ax, [pal_col2]
        mov     [pal_buffer + 13*2], ax
        mov     ax, [pal_col3]
        mov     [pal_buffer + 15*2], ax

        ; Palette 0 Low: entries 2, 4, 6
        mov     ax, [pal_col1]
        mov     [pal_buffer + 2*2], ax
        mov     ax, [pal_col2]
        mov     [pal_buffer + 4*2], ax
        mov     ax, [pal_col3]
        mov     [pal_buffer + 6*2], ax

        ; Palette 0 High: entries 10, 12, 14
        mov     ax, [pal_col1]
        mov     [pal_buffer + 10*2], ax
        mov     ax, [pal_col2]
        mov     [pal_buffer + 12*2], ax
        mov     ax, [pal_col3]
        mov     [pal_buffer + 14*2], ax

        ; Write all 32 bytes to V6355D
        cli
        cld

        mov     al, 0x40
        out     PORT_REG_ADDR, al
        jmp     short $+2

        mov     si, pal_buffer
        mov     cx, 32
.wr:    lodsb
        out     PORT_REG_DATA, al
        jmp     short $+2
        loop    .wr

        mov     al, 0x80
        out     PORT_REG_ADDR, al

        sti
        pop     di
        pop     si
        pop     cx
        pop     bx
        pop     ax
        ret

; =================================================================
; reset_v6355d_palette — restore all 16 V6355D colors to defaults
; =================================================================
reset_v6355d_palette:
        push    ax
        push    cx
        push    si
        cli
        cld

        ; Open palette at entry 0, write all 32 bytes
        mov     al, 0x40
        out     PORT_REG_ADDR, al
        jmp     short $+2

        mov     cx, 32
        mov     si, v6355d_pal
.rlp:   cs lodsb
        out     PORT_REG_DATA, al
        jmp     short $+2
        loop    .rlp

        mov     al, 0x80
        out     PORT_REG_ADDR, al

        sti
        pop     si
        pop     cx
        pop     ax
        ret

; =================================================================
; extract_rgb
; =================================================================
extract_rgb:
        push    ax
        push    bx
        push    cx
        push    si
        mov     si, v6355d_pal
        xor     bx, bx
        mov     cx, 16
.lp:    mov     al, [si]
        and     al, 0x07
        mov     [pal_r + bx], al
        mov     al, [si+1]
        mov     ah, al
        shr     al, 4
        and     al, 0x07
        mov     [pal_g + bx], al
        mov     al, ah
        and     al, 0x07
        mov     [pal_b + bx], al
        add     si, 2
        inc     bx
        loop    .lp
        pop     si
        pop     cx
        pop     bx
        pop     ax
        ret

; =================================================================
; compute_dist_matrix — 16×16 Manhattan distance
; =================================================================
compute_dist_matrix:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        mov     di, dist_matrix
        xor     si, si
.row:   xor     bx, bx
.col:   xor     dx, dx
        mov     al, [pal_r+si]
        sub     al, [pal_r+bx]
        jns     .rp
        neg     al
.rp:    xor     ah, ah
        add     dx, ax
        mov     al, [pal_g+si]
        sub     al, [pal_g+bx]
        jns     .gp
        neg     al
.gp:    xor     ah, ah
        add     dx, ax
        mov     al, [pal_b+si]
        sub     al, [pal_b+bx]
        jns     .bp
        neg     al
.bp:    xor     ah, ah
        add     dx, ax
        mov     [di], dl
        inc     di
        inc     bx
        cmp     bx, 16
        jb      .col
        inc     si
        cmp     si, 16
        jb      .row
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; =================================================================
; find_max_color
; =================================================================
find_max_color:
        push    bx
        push    cx
        push    dx
        xor     ax, ax
        xor     dx, dx
        xor     bx, bx
        mov     cx, 16
.lp:    cmp     [color_count + bx], dx
        jbe     .sk
        mov     dx, [color_count + bx]
        mov     ax, bx
        shr     ax, 1
.sk:    add     bx, 2
        loop    .lp
        pop     dx
        pop     cx
        pop     bx
        ret

; =================================================================
; build_remap16 — EGA index → CGA value (0-3)
; =================================================================
build_remap16:
        push    ax
        push    bx
        push    cx
        xor     cx, cx
.lp:    or      cl, cl
        jz      .c0
        cmp     cl, [top3_a]
        je      .c1
        cmp     cl, [top3_b]
        je      .c2
        cmp     cl, [top3_c]
        je      .c3
        call    find_nearest
        jmp     .st
.c0:    xor     al, al
        jmp     .st
.c1:    mov     al, 1
        jmp     .st
.c2:    mov     al, 2
        jmp     .st
.c3:    mov     al, 3
.st:    xor     bx, bx
        mov     bl, cl
        mov     [remap16 + bx], al
        inc     cl
        cmp     cl, 16
        jb      .lp
        pop     cx
        pop     bx
        pop     ax
        ret

; =================================================================
; find_nearest — closest top3 for EGA color CL → AL
; =================================================================
find_nearest:
        push    bx
        push    dx
        push    si
        xor     bh, bh
        mov     bl, cl
        mov     si, bx
        shl     si, 4
        mov     dl, 0xFF        ; start with max distance (not dist-to-black!)
        mov     dh, 1           ; default = CGA 1 (top3_a)
        xor     bx, bx
        mov     bl, [top3_a]
        mov     al, [dist_matrix + si + bx]
        cmp     al, dl
        jae     .tb
        mov     dl, al
        mov     dh, 1
.tb:    mov     bl, [top3_b]
        mov     al, [dist_matrix + si + bx]
        cmp     al, dl
        jae     .tc
        mov     dl, al
        mov     dh, 2
.tc:    mov     bl, [top3_c]
        mov     al, [dist_matrix + si + bx]
        cmp     al, dl
        jae     .fd
        mov     dh, 3
.fd:    mov     al, dh
        pop     si
        pop     dx
        pop     bx
        ret

; =================================================================
; build_nibble_remap — 256-byte XLAT table
; =================================================================
build_nibble_remap:
        push    ax
        push    bx
        push    cx
        push    di
        mov     di, nibble_remap
        xor     cx, cx
.lp:    mov     al, cl
        shr     al, 4
        xor     bx, bx
        mov     bl, al
        mov     al, [remap16 + bx]
        shl     al, 2
        mov     ah, al
        mov     al, cl
        and     al, 0x0F
        mov     bl, al
        mov     al, [remap16 + bx]
        or      al, ah
        mov     [di], al
        inc     di
        inc     cl
        jnz     .lp
        pop     di
        pop     cx
        pop     bx
        pop     ax
        ret

; =================================================================
; Data
; =================================================================
fb_segment:     dw 0
top3_a:         db 0
top3_b:         db 0
top3_c:         db 0
pal_r:          times 16 db 0
pal_g:          times 16 db 0
pal_b:          times 16 db 0
dist_matrix:    times 256 db 0
color_count:    times 16 dw 0
remap16:        times 16 db 0
nibble_remap:   times 256 db 0
pal_buffer:     times 32 db 0
pal_col1:       dw 0
pal_col2:       dw 0
pal_col3:       dw 0
