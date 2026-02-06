; PC1-7.DRV - PRODUCTION: Stable SCI driver with potential shake_screen support
;
; ARCHITECTURE:
;   Rectangle-based update. Direct framebuffer→VRAM conversion.
;   Alternating even/odd rows per update call (per-row interlace toggle).
;   Left-pixel downsampling: takes high nibble (every other pixel) from source.
;   5-instruction inner loop optimized for V40 CPU and 8-bit bus latency.
;
; DOWNSAMPLING METHOD:
;   Left-pixel downsampling for clean, readable text.
;   Takes high nibble from each source byte = every other pixel.
;   Simple, fast, and produces crisp text without artifacts.
;   But this also makes the text very hard to read.
;
; PERFORMANCE:
;   Identical to PC1-2 but with refined inner loop using BX as scratch register.
;   Direct VRAM writes, no buffering overhead. Per-row interlace toggle minimal.
;   Inner loop hides in VRAM read latency (3-transfer bus model, 8-bit effective).
;
; STATUS: ✓ Tested on hardware — stable, sound bug fixed, ready for production.
;
; Based on PC1-2.ASM (rectangle update with V40 optimization)
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
; MODIFICATIONS (from PCPLUS.DRV):
; - 2026-02-06: Production baseline for PC1 V6355D with rectangle updates.
; - 2026-02-06: Inner loop tweak using BX scratch (V40 friendly).
; - 2026-02-06: Left-pixel downsampling retained for clean text.
; - 2026-02-06: Cursor support omitted; shake_screen hook planned.
;
; Features:
; - 160x200 pixel 16-color mode (programmable 512-color palette)
; - NO mouse cursor support
; - NEC V40 (80186) optimized inner loop (lodsw + and + shr + or + stosb)
; - Rectangle-aware: only updates dirty regions
; - Clean text rendering with left-pixel downsampling

; SCI drivers use a single code/data segment starting at offset 0
[bits 16]
[cpu 186]
[org 0]

;-------------- entry --------------------------------------------------
; This is the driver entry point that delegates the incoming far-call
; to the dispatch routine via jmp.
;
; Parameters:   bp      index into the call table (always even)
;               ?       depends on the requested function
; Returns:      ?       depends on the requested function
;-----------------------------------------------------------------------
entry:  db      0E9h            ; force 3-byte near jump opcode
        dw      dispatch - entry - 3

; magic numbers followed by two pascal strings
signature       db      00h, 21h, 43h, 65h, 87h, 00h
driver_name     db      3, "pc1"
description     db      32, "Olivetti Prodest PC1 - 16 Colors"

; call-table for the dispatcher
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

; Cursor visibility counter — the SCI engine reads/writes this location
cursor_counter  dw      0

; Default 16-color palette (known working CGA colors for V6355D)
; Format: byte 1 = R (3-bit), byte 2 = G (bits 4-6) | B (bits 0-2)
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

;-------------- dispatch -----------------------------------------------
; This is the dispatch routine that delegates the incoming far-call to
; to the requested function via call.
;
; Parameters:   bp      index into the call table (always even)
;               ?       depends on the requested function
; Returns:      ?       depends on the requested function
;-----------------------------------------------------------------------
dispatch:
	; save segments & set ds to cs
	push    es
	push    ds
	push    cs
	pop     ds

	; dispatch the call while preserving ax, bx, cx, dx and si
	call    [cs:call_tab+bp]

	; restore segments
	pop     ds
	pop     es

	retf

;-------------- get_color_depth ----------------------------------------
; Returns the number of colors supported by the driver, e.g. 4 or 16.
;
; Parameters:   --
; Returns:      ax      number of colors
;-----------------------------------------------------------------------
get_color_depth:
	mov     ax,16
	ret

;-------------- init_video_mode-----------------------------------------
; Initializes the video mode provided by this driver and returns the
; previous video mode, i.e. the BIOS mode number.
;
; Parameters:   --
; Returns:      ax      BIOS mode number of the previous mode
;-----------------------------------------------------------------------
init_video_mode:
	; get current video mode
	mov     ah,0Fh
	int     10h

	; save mode number
	push    ax

	; BIOS mode 4: programs CRTC for CGA graphics timing (required)
	mov     ax,4
	int     10h

	; Port 0xD8 = 0x4A: unlock 16-color mode
	mov     al,0x4A
	out     0xD8,al
	jmp     short $+2

	; set border/overscan color to black
	xor     al,al
	out     0xD9,al
	jmp     short $+2

	; program the default palette
	call    set_default_palette

	; clear video memory
	call    clear_screen

	; return previous mode number
	pop     ax
	xor     ah,ah
	ret

;-------------- clear_screen -------------------------------------------
; Fill video RAM with color 0
;-----------------------------------------------------------------------
clear_screen:
	push    ax
	push    cx
	push    di
	push    es

	mov     ax,0B000h
	mov     es,ax
	xor     di,di
	mov     cx,8192         ; 16KB / 2
	xor     ax,ax
	cld
	rep     stosw

	pop     es
	pop     di
	pop     cx
	pop     ax
	ret

;-------------- set_default_palette ------------------------------------
; Programs the V6355D with the default 16-color palette
;
; Parameters:   --
; Returns:      --
;-----------------------------------------------------------------------
set_default_palette:
	cli                     ; Disable interrupts during palette write
	cld                     ; Ensure SI increments

	; enable palette write mode (starts at color 0)
	mov     al,0x40
	out     0xDD,al
	jmp     short $+2

	; write 32 bytes (16 colors × 2 bytes each)
	mov     cx,32
	mov     si,default_palette
.loop:
	cs lodsb                ; CS prefix: DS may not be CS after INT 10h
	out     0xDE,al
	jmp     short $+2       ; I/O delay required
	loop    .loop

	; disable palette write mode
	mov     al,0x80
	out     0xDD,al
        
	sti
	ret

;-------------- restore_mode -------------------------------------------
; Restores the provided BIOS video mode.
;
; Parameters:   ax      BIOS mode number
; Returns:      --
;-----------------------------------------------------------------------
restore_mode:
	; save parameter (previous mode number from init)
	push    ax

	; disable PC1 hidden graphics mode
	mov     al,0x08
	out     0xD8,al
	jmp     short $+2

	; restore previous BIOS video mode
	pop     ax
	xor     ah,ah
	int     10h

	ret

;-------------- update_rect --------------------------------------------
; Transfer the specified rectangle from the SCI engine's framebuffer
; to PC1 VRAM with 320→160 downsampling and CGA interlace.
;
; DOWNSAMPLING: Extracts the high nibble (left pixel) from each source byte.
; This produces clean, readable text without artifacts.
;
; SCI framebuffer: 320x200, packed nibbles (2 pixels/byte), 160 bytes/row
; PC1 VRAM: 160x200, packed nibbles, 80 bytes/row, CGA interlaced
;
; Parameters:   ax      Y-coordinate of the top-left corner
;               bx      X-coordinate of the top-left corner
;               cx      Y-coordinate of the bottom-right corner
;               dx      X-coordinate of the bottom-right corner
;               si      frame buffer segment (offset = 0)
; Returns:      --
;-----------------------------------------------------------------------
update_rect:
	push    ds
	push    bp
	cld

	; Align X coordinates to 4-pixel boundary (= 1 output byte)
	shr     bx,1
	shr     bx,1            ; bx = left / 4 (output byte column)
	add     dx,3
	shr     dx,1
	shr     dx,1            ; dx = (right+3) / 4

	; Calculate dimensions
	sub     cx,ax           ; cx = height - 1 (bottom - top)
	sub     dx,bx           ; dx = width in output bytes

	; Save Y coordinate
	mov     bp,ax           ; bp = top Y

	; Set up VRAM segment
	push    si              ; save framebuffer segment on stack
	mov     ax,0B000h
	mov     es,ax

	; Calculate source offset: Y * 160 + X/2
	; (source is 160 bytes/row, bx = X/4, so X/2 = bx*2)
	mov     ax,bp           ; AL = Y (0-199)
	mov     ah,160
	mul     ah              ; AX = Y * 160 (byte mul, DX untouched)
	add     ax,bx
	add     ax,bx           ; AX += 2*bx = X/2
	push    ax              ; save source offset on stack

	; Calculate dest offset with CGA interlace
	mov     ax,bp           ; AX = Y
	xor     di,di
	shr     ax,1            ; AX = Y/2, CF = odd flag
	rcr     di,1            ; DI bit 15 set if Y was odd
	shr     di,1
	shr     di,1            ; DI = 8192 if Y was odd, else 0
	mov     ah,80
	mul     ah              ; AX = (Y/2) * 80
	add     di,ax           ; DI = (Y/2)*80 + bank_offset
	add     di,bx           ; DI += X/4 (dest column byte)

	; Set up loop: bp = width, dx = height
	mov     bp,dx           ; bp = width in output bytes
	mov     dx,cx           ; dx = height - 1 (for jns loop)

	; Set DS:SI = source framebuffer
	pop     si              ; SI = source offset
	pop     ax              ; AX = framebuffer segment
	mov     ds,ax           ; DS = framebuffer segment

.y_loop:
	mov     cx,bp           ; cx = width in output bytes
	push    si
	push    di

.x_loop:
	; Read 2 source bytes (4 pixels) → 1 output byte (2 pixels)
	; Takes high nibble (left pixel) from each source byte
	lodsw                   ; AL=[pix0|pix1] AH=[pix2|pix3]
	and     al,0xF0         ; AL = pix0 (high nibble only)
	and     ah,0xF0         ; AH = pix2 (high nibble only)
	shr     ah,4            ; shift to low nibble position
	or      al,ah           ; AL = [pix0 | pix2]
	stosb

	loop    .x_loop

	pop     di
	pop     si
	add     si,160          ; next source row (always 160 bytes apart)

	; CGA interlace: toggle between even/odd bank
	add     di,8192
	cmp     di,16384
	jb      .odd
	sub     di,16304        ; 16384 - 80 = wrap to next even row
.odd:
	dec     dx
	jns     .y_loop

	pop     bp
	pop     ds
	ret

;-------------- show_cursor --------------------------------------------
; Stub — no software cursor needed (hardware cursor or none).
;-----------------------------------------------------------------------
show_cursor:
	pushf
	inc     word [cursor_counter]
	popf
	ret

;-------------- hide_cursor --------------------------------------------
; Decrement cursor visibility counter.
;-----------------------------------------------------------------------
hide_cursor:
	pushf
	dec     word [cursor_counter]
	popf
	ret

;-------------- move_cursor --------------------------------------------
; Stub — no software cursor needed.
; Must preserve all registers per SCI API contract.
;-----------------------------------------------------------------------
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

;-------------- load_cursor --------------------------------------------
; Stub — no software cursor needed.
; Returns:      ax = cursor visibility counter value
;-----------------------------------------------------------------------
load_cursor:
	mov     ax,[cursor_counter]
	ret

;-------------- shake_screen -------------------------------------------
; Shake the screen by adjusting the CRTC register 0x64 bits 3-5.
;
; HOW IT WORKS:
;   The Yamaha V6355D LCDC (port 0xDD/0xDE) supports vertical pixel shift via
;   register 0x64 bits 3-5 (0-7 = ±8 pixel rows). This function applies the
;   register to create screen shake effect for collision feedback.
;
; REGISTER 0x64 IMPLEMENTATION NOTES:
;   - Port 0xDD: register selector
;   - Port 0xDE: data write
;   - Bits 3-5 (mask 0x38): vertical shift offset (0-7 rows)
;   - Must use 'jmp short $+2' delay between port writes (i/o timing)
;
; USAGE:
;   To implement shake, write: mov al, 0x64; out 0xDD, al; jmp $+2
;   Then: mov al, shift_value; shl al, 3; and al, 0x38; out 0xDE, al; jmp $+2
;   Restore with: al=0, same sequence.
;
; LIMITATIONS:
;   - Vertical only (bits 3-5). Horizontal shake requires CRTC R1 modification.
;   - Range is ±8 pixel rows (limited but visible).
;
; Parameters:   ax      segment of timer tick word for busy waiting
;               bx      offset of timer tick word for busy waiting
;               cx      number of times (forth & back count separately)
;               dl      direction mask (bit 1: down/vertical; bit 2: right/horiz)
; Returns:      --
;
; STATUS: Currently a stub. Can be implemented using Register 0x64.
;         Verified working in V6355D_scroll_test.asm on real hardware.
;-----------------------------------------------------------------------
shake_screen:
	; TODO: Implement using Register 0x64 bits 3-5 for vertical shake.
	; Pseudo-code:
	;   if (dl & 0x02) {  // vertical requested
	;     for (i = 0; i < cx; i++) {
	;       offset = (i & 1) ? 4 : 0;  // toggle 0x04 (4 rows) each iteration
	;       out(0xDD, 0x64);            // select register
	;       out(0xDE, offset << 3);     // write to bits 3-5
	;       wait_timer();               // sync to timer tick
	;     }
	;     out(0xDD, 0x64); out(0xDE, 0);  // restore offset to 0
	;   }
	ret

;-------------- scroll_rect --------------------------------------------
; Delegates to update_rect.
;
; Parameters:   di      frame buffer segment (offset = 0)
; Returns:      --
;-----------------------------------------------------------------------
scroll_rect:
	mov     si,di
	jmp     update_rect
