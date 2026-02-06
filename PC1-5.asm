; PC1-5.DRV - An SCI video driver for Olivetti Prodest PC1
;
; ARCHITECTURE:
;   Rectangle-based. Two-pass bank-separated with per-row RAM line buffer.
;   Phase 1: Convert row → 80-byte buffer (RAM speed, no VRAM wait states).
;   Phase 2: Blast buffer → VRAM with rep movsw (16-bit writes).
;   Per-row segment switching (ES=CS, then DS=CS) for each row.
;
; PERFORMANCE:
;   Potential speed: conversion at RAM speed + 16-bit VRAM writes.
;   Overhead: 4 segment loads per row × 100 rows = 400 segment loads.
;   Bus model: 4 transfers/byte (read FB, write buffer, read buffer, write VRAM)
;             vs PC1-2's 3 transfers/byte (read FB, convert, write VRAM).
;   May be slower than PC1-2 on narrow 8-bit bus due to extra traffic.
;
; STATUS: ✗ Tested on hardware — slower or hangs.
;
; Based on PC1-4.ASM (two-pass bank-separated rectangle update)
; Based on PCPLUS.DRV by Benedikt Freisen
; Adapted for Olivetti Prodest PC1 with Yamaha V6355D
;
; This library is free and open-source software published under the
; GNU LGPL license.
;
; Features:
; - 160x200 pixel 16-color mode (programmable 512-color palette)
; - NO mouse cursor support
; - NEC V40 (80186) optimized inner loop (lodsw + shr ah,4)
; - Rectangle-aware with per-row RAM line buffer
; - Fixed: .count_rows now properly handles single-row rectangles

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
; to PC1 VRAM with 320->160 downsampling and CGA interlace.
;
; TWO-PASS + LINE BUFFER (PC1-5 optimization):
;   For each row in the rectangle:
;     Phase 1: Convert the row from SCI framebuffer into an 80-byte
;              RAM line buffer. This runs at full RAM speed — no VRAM
;              bus wait states affect the conversion loop.
;     Phase 2: Blast the line buffer to VRAM using rep movsw.
;              This writes 16 bits per bus cycle and has no instruction
;              fetch overhead between words — the fastest possible
;              VRAM write method.
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

; Saved parameters (in driver's own data area)
ur_fb_seg       dw      0       ; framebuffer segment
ur_left         dw      0       ; left column (output bytes)
ur_width        dw      0       ; width (output bytes)
ur_top          dw      0       ; top Y
ur_bottom       dw      0       ; bottom Y
ur_vram_off     dw      0       ; saved VRAM offset during line buffer ops

; Line buffer: holds one converted output row (max 80 bytes = 160 pixels)
line_buffer:    times 80 db 0

update_rect:
	push    ds
	push    bp
	cld

	; Save framebuffer segment
	mov     [cs:ur_fb_seg],si

	; Align X coordinates to 4-pixel boundary (= 1 output byte)
	shr     bx,1
	shr     bx,1            ; bx = left / 4 (output byte column)
	add     dx,3
	shr     dx,1
	shr     dx,1            ; dx = (right+3) / 4

	; Save parameters
	sub     dx,bx           ; dx = width in output bytes
	mov     [cs:ur_left],bx
	mov     [cs:ur_width],dx
	mov     [cs:ur_top],ax
	mov     [cs:ur_bottom],cx

	; === PASS 1: Even rows (bank 0) ===
	mov     ax,[cs:ur_top]
	test    al,1
	jz      .even_ok
	inc     ax              ; round up to next even row
.even_ok:
	mov     bp,ax           ; BP = first even row (for .count_rows)
	call    .setup_pass     ; SI = source offset, DI = dest offset (bank 0)
	call    .count_rows     ; DX = number of rows - 1
	jl      .skip_even      ; no even rows in rectangle
	call    .copy_pass
.skip_even:

	; Restore DS=CS for parameter access
	push    cs
	pop     ds

	; === PASS 2: Odd rows (bank 1, base 8192) ===
	mov     ax,[cs:ur_top]
	test    al,1
	jnz     .odd_ok
	inc     ax              ; round up to next odd row
.odd_ok:
	mov     bp,ax           ; BP = first odd row (for .count_rows)
	call    .setup_pass     ; SI = source offset, DI = dest offset
	add     di,8192         ; shift dest into bank 1
	call    .count_rows     ; DX = number of rows - 1
	jl      .skip_odd       ; no odd rows in rectangle
	call    .copy_pass
.skip_odd:

	pop     bp
	pop     ds
	ret

	; ============================================================
	; .setup_pass — Calculate source and dest offsets
	; Input:  AX = first row Y for this pass
	; Output: SI = source offset, DI = dest offset (bank 0 base)
	;         DS = framebuffer segment
	; Clobbers: AX, BX
	; ============================================================
.setup_pass:
	mov     bx,[cs:ur_left]

	; Source offset: row * 160 + bx*2
	push    ax              ; save row Y
	mov     ah,160
	mul     ah              ; AX = row * 160
	add     ax,bx
	add     ax,bx           ; AX += 2*bx (X/2 in source)
	mov     si,ax

	; Dest offset: (row/2) * 80 + bx  (bank 0)
	pop     ax              ; AX = row Y
	shr     ax,1            ; AX = row/2
	mov     ah,80
	mul     ah              ; AX = (row/2) * 80
	mov     di,ax
	add     di,bx           ; DI += left column

	; Set DS = framebuffer segment
	mov     ax,[cs:ur_fb_seg]
	mov     ds,ax
	ret

	; ============================================================
	; .count_rows — Count rows for this pass
	; Input:  BP = first row Y for this pass
	;         CS:ur_bottom = bottom Y
	; Output: DX = number of rows - 1 (for jns loop)
	;         jl condition true when no rows to copy
	; ============================================================
.count_rows:
	mov     dx,[cs:ur_bottom]
	sub     dx,bp           ; dx = bottom - first_row
	jl      .no_rows        ; if first_row > bottom → no rows (keep SF=1)
	shr     dx,1            ; dx = (bottom - first) / 2 = row_count - 1
.no_rows:
	ret
	ret

	; ============================================================
	; .copy_pass — Copy rows for one bank using line buffer
	;
	; For each row:
	;   Phase 1: Convert SCI framebuffer -> line_buffer (RAM speed)
	;   Phase 2: Blast line_buffer -> VRAM (rep movsw)
	;
	; Input:  SI = source offset, DI = dest offset
	;         DX = row count - 1, CS:ur_width = width in bytes
	;         DS = framebuffer segment, ES = (don't care, will set)
	; ============================================================
.copy_pass:
	mov     bp,[cs:ur_width]

.y_loop:
	; Save positions for this row
	mov     [cs:ur_vram_off],di     ; VRAM destination for this row
	push    si                      ; framebuffer source for this row

	; --- Phase 1: Convert row into line_buffer (RAM -> RAM) ---
	; Read from DS:SI (framebuffer), write to ES:DI (line_buffer in CS)
	push    cs
	pop     es                      ; ES = CS (line buffer lives here)
	lea     di,[line_buffer]
	mov     cx,bp                   ; CX = width in output bytes

.convert:
	lodsw                           ; AL=[pix0|pix1] AH=[pix2|pix3]
	and     ax,0xF0F0               ; keep high nibble of each byte
	shr     ah,4                    ; move pix2 to low nibble
	or      al,ah                   ; AL = [pix0 | pix2]
	stosb                           ; store to line_buffer (RAM, fast!)
	loop    .convert

	; --- Phase 2: Blast line_buffer to VRAM (RAM -> VRAM, rep movsw) ---
	; Switch DS:SI to line_buffer, ES:DI to VRAM
	push    cs
	pop     ds                      ; DS = CS (line buffer is source)
	lea     si,[line_buffer]

	mov     ax,0xB000
	mov     es,ax                   ; ES = VRAM segment
	mov     di,[cs:ur_vram_off]     ; DI = saved VRAM destination

	mov     cx,bp                   ; CX = width in output bytes
	shr     cx,1                    ; CX = word count
	rep     movsw                   ; bulk write to VRAM (16-bit, fast!)
	adc     cx,cx                   ; CX = 1 if odd width, 0 if even
	rep     movsb                   ; handle trailing byte if any

	; --- Advance to next row ---
	pop     si                      ; restore framebuffer source offset
	add     si,320                  ; skip 2 source rows (stride × 2)

	mov     di,[cs:ur_vram_off]
	add     di,80                   ; next row in same VRAM bank

	; Restore DS = framebuffer for next iteration
	mov     ax,[cs:ur_fb_seg]
	mov     ds,ax

	dec     dx
	jns     .y_loop
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
; Quickly shake the screen horizontally and/or vertically by a few
; pixels to visualize collisions etc.
;
; Parameters:   ax      segment of timer tick word for busy waiting
;               bx      offset of timer tick word for busy waiting
;               cx      number of times (forth & back count separately)
;               dl      direction mask (bit 1: down; bit 2: right)
; Returns:      --
;-----------------------------------------------------------------------
shake_screen:
	; this dummy implementation returns right away
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
