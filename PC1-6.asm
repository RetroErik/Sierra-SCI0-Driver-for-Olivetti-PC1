; PC1-6.DRV - An SCI video driver for Olivetti Prodest PC1
;
; ARCHITECTURE:
;   Rectangle-based. Full-rectangle RAM buffer + two-phase blitter.
;   Phase 1: Convert entire rectangle → 8000-byte buffer (RAM speed).
;   Phase 2: Blast buffer → VRAM row-by-row with rep movsw.
;   Segment switching: 3 loads per pass (not per-row).
;
; PERFORMANCE:
;   Worst case on 8-bit bus: 4 transfers/byte vs PC1-2's 3.
;   Phase 1 (RAM-only) is fast, but Phase 2 pays for Phase 1 overhead.
;   Inefficient on V40's narrow bus.
;   8000-byte buffer acceptable for driver RAM.
;
; STATUS: ✗ Tested on hardware — slow or hung (even with count_rows fix).
;
; Root cause: PC1-2's direct 3-transfer model (read→convert→write)
;             is faster than buffering's 4-transfer model on 8-bit bus.
;             Buffering only wins for PURE moves (like demo5's rep movsw).
;
; Based on PC1-5.ASM (line buffer + rep movsw)
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
; - Rectangle-aware with full-rectangle RAM buffer
; - Fixed: .count_rows now properly handles single-row rectangles
; - WARNING: Slower than PC1-2 on this hardware — buffering not beneficial

; SCI drivers use a single code/data segment starting at offset 0
[bits 16]
[cpu 186]
[org 0]

;-------------- entry --------------------------------------------------
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

; Cursor visibility counter
cursor_counter  dw      0

; Default 16-color palette (V6355D format: R, G|B)
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
dispatch:
	push    es
	push    ds
	push    cs
	pop     ds

	call    [cs:call_tab+bp]

	pop     ds
	pop     es
	retf

;-------------- get_color_depth ----------------------------------------
get_color_depth:
	mov     ax,16
	ret

;-------------- init_video_mode-----------------------------------------
init_video_mode:
	mov     ah,0Fh
	int     10h
	push    ax

	mov     ax,4
	int     10h

	mov     al,0x4A
	out     0xD8,al
	jmp     short $+2

	xor     al,al
	out     0xD9,al
	jmp     short $+2

	call    set_default_palette
	call    clear_screen

	pop     ax
	xor     ah,ah
	ret

;-------------- clear_screen -------------------------------------------
clear_screen:
	push    ax
	push    cx
	push    di
	push    es

	mov     ax,0B000h
	mov     es,ax
	xor     di,di
	mov     cx,8192
	xor     ax,ax
	cld
	rep     stosw

	pop     es
	pop     di
	pop     cx
	pop     ax
	ret

;-------------- set_default_palette ------------------------------------
set_default_palette:
	cli
	cld

	mov     al,0x40
	out     0xDD,al
	jmp     short $+2

	mov     cx,32
	mov     si,default_palette
.loop:
	cs lodsb
	out     0xDE,al
	jmp     short $+2
	loop    .loop

	mov     al,0x80
	out     0xDD,al
	sti
	ret

;-------------- restore_mode -------------------------------------------
restore_mode:
	push    ax

	mov     al,0x08
	out     0xD8,al
	jmp     short $+2

	pop     ax
	xor     ah,ah
	int     10h
	ret

;-------------- update_rect --------------------------------------------
; Transfer the specified rectangle from the SCI engine's framebuffer
; to PC1 VRAM with 320->160 downsampling and CGA interlace.
;
; FULL-RECTANGLE BUFFER (PC1-6 optimization):
;   Phase 1: Convert ENTIRE rectangle from SCI framebuffer into a RAM
;            buffer. Pure ALU + RAM, zero VRAM bus stalls, no segment
;            switching between rows.
;   Phase 2: Blast the RAM buffer to VRAM row by row using rep movsw.
;            Pure bus writes, no conversion overhead, CPU prefetch
;            queue stays full during rep movsw.
;
; Parameters:   ax      Y top-left
;               bx      X top-left
;               cx      Y bottom-right
;               dx      X bottom-right
;               si      frame buffer segment (offset = 0)
;-----------------------------------------------------------------------

; Saved parameters
ur_fb_seg       dw      0       ; framebuffer segment
ur_left         dw      0       ; left column (output bytes)
ur_width        dw      0       ; width (output bytes)
ur_top          dw      0       ; top Y
ur_bottom       dw      0       ; bottom Y
ur_vram_off     dw      0       ; VRAM offset for Phase 2
ur_rows         dw      0       ; row count for Phase 2

update_rect:
	push    ds
	push    bp
	cld

	; Save framebuffer segment
	mov     [cs:ur_fb_seg],si

	; Align X coordinates to 4-pixel boundary (= 1 output byte)
	shr     bx,1
	shr     bx,1            ; bx = left / 4
	add     dx,3
	shr     dx,1
	shr     dx,1            ; dx = ceil(right / 4)

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
	inc     ax
.even_ok:
	mov     bp,ax           ; BP = first even row
	call    .setup_pass
	call    .count_rows
	jl      .skip_even
	call    .copy_pass
.skip_even:

	; Restore DS=CS for parameter access
	push    cs
	pop     ds

	; === PASS 2: Odd rows (bank 1, base 8192) ===
	mov     ax,[cs:ur_top]
	test    al,1
	jnz     .odd_ok
	inc     ax
.odd_ok:
	mov     bp,ax           ; BP = first odd row
	call    .setup_pass
	add     di,8192         ; shift dest into bank 1
	call    .count_rows
	jl      .skip_odd
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
	; ============================================================
.setup_pass:
	mov     bx,[cs:ur_left]

	; Source offset: row * 160 + bx*2
	push    ax
	mov     ah,160
	mul     ah              ; AX = row * 160
	add     ax,bx
	add     ax,bx           ; AX += bx*2
	mov     si,ax

	; Dest offset: (row/2) * 80 + bx
	pop     ax
	shr     ax,1
	mov     ah,80
	mul     ah              ; AX = (row/2) * 80
	mov     di,ax
	add     di,bx

	; Set DS = framebuffer segment
	mov     ax,[cs:ur_fb_seg]
	mov     ds,ax
	ret

	; ============================================================
	; .count_rows — Count rows for this pass
	; Input:  BP = first row Y, CS:ur_bottom = bottom Y
	; Output: DX = row_count - 1 (for jns loop), flags set
	;         jl condition true when no rows to copy
	; ============================================================
.count_rows:
	mov     dx,[cs:ur_bottom]
	sub     dx,bp           ; dx = bottom - first_row
	jl      .no_rows        ; if first_row > bottom → no rows (keep SF=1)
	shr     dx,1            ; dx = (bottom - first) / 2 = count - 1
.no_rows:
	ret

	; ============================================================
	; .copy_pass — Two-phase rectangle copy for one bank
	;
	; Phase 1: Convert entire rect → rect_buffer (RAM speed)
	; Phase 2: Blast rect_buffer → VRAM (rep movsw)
	;
	; Input:  SI = source offset (DS = framebuffer)
	;         DI = VRAM dest offset
	;         DX = row count - 1
	;         CS:ur_width = width in bytes
	; ============================================================
.copy_pass:
	mov     [cs:ur_vram_off],di     ; save VRAM offset for Phase 2
	mov     bp,[cs:ur_width]        ; BP = width in output bytes
	inc     dx
	mov     [cs:ur_rows],dx         ; save row count for Phase 2

	; === Phase 1: Convert entire rectangle into rect_buffer ===
	; Source: DS:SI (framebuffer, already set)
	; Dest:   ES:DI (rect_buffer in CS segment)
	push    cs
	pop     es
	lea     di,[rect_buffer]

.convert_loop:
	push    si                      ; save source row start
	mov     cx,bp                   ; CX = width in output bytes
.convert_row:
	lodsw                           ; AL=[p0|p1] AH=[p2|p3]
	and     ax,0xF0F0               ; keep high nibbles
	shr     ah,4                    ; pix2 → low nibble (V40/186)
	or      al,ah                   ; AL = [p0 | p2]
	stosb                           ; → rect_buffer (RAM, no wait states!)
	loop    .convert_row
	pop     si
	add     si,320                  ; next source row (skip 2 rows)
	dec     dx
	jnz     .convert_loop

	; === Phase 2: Blast rect_buffer to VRAM row by row ===
	; Source: DS:SI (rect_buffer in CS segment)
	; Dest:   ES:DI (VRAM at B000h)
	push    cs
	pop     ds                      ; DS = CS (buffer is source)
	lea     si,[rect_buffer]

	mov     ax,0xB000
	mov     es,ax                   ; ES = VRAM
	mov     di,[cs:ur_vram_off]     ; DI = VRAM destination

	mov     dx,[cs:ur_rows]         ; reload row count

.vram_loop:
	mov     cx,bp                   ; CX = width in output bytes
	shr     cx,1                    ; CX = word count
	rep     movsw                   ; blast one row (16-bit, fast!)
	adc     cx,cx                   ; CX = 1 if odd width, else 0
	rep     movsb                   ; handle trailing byte

	; SI is already at next buffer row (rows are packed contiguously)
	; DI needs to advance to next VRAM row: skip remaining bytes
	sub     di,bp                   ; undo width advance
	add     di,80                   ; advance one full VRAM row

	dec     dx
	jnz     .vram_loop
	ret

;-------------- show_cursor --------------------------------------------
show_cursor:
	pushf
	inc     word [cursor_counter]
	popf
	ret

;-------------- hide_cursor --------------------------------------------
hide_cursor:
	pushf
	dec     word [cursor_counter]
	popf
	ret

;-------------- move_cursor --------------------------------------------
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
load_cursor:
	mov     ax,[cursor_counter]
	ret

;-------------- shake_screen -------------------------------------------
shake_screen:
	ret

;-------------- scroll_rect --------------------------------------------
scroll_rect:
	mov     si,di
	jmp     update_rect

; =====================================================================
; Rectangle buffer — holds one full pass of converted pixels
; Max size: 80 bytes/row × 100 rows = 8000 bytes
; Placed at end to keep code compact above
; =====================================================================
rect_buffer:    times 8000 db 0
