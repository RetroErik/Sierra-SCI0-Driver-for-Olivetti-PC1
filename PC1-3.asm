; PC1-3.DRV - An SCI video driver for Olivetti Prodest PC1
;
; ARCHITECTURE:
;   Full-frame copy (ignores rectangle parameters). Two-pass even/odd.
;   All 100 even rows copied first, then all 100 odd rows.
;   Sequential within each bank but no rectangle awareness.
;
; PERFORMANCE:
;   Slower than PC1-2 for partial updates (always copies full 200 rows).
;   Better for full-screen redraws but wastes bandwidth on small updates.
;   Less complex than PC1-2 (no rectangle clipping math).
;
; STATUS: ✓ Tested on hardware — works but slower than PC1-2.
;
; Based on PCPLUS.DRV by Benedikt Freisen
; Adapted for Olivetti Prodest PC1 with Yamaha V6355D
;
; This library is free and open-source software published under the
; GNU LGPL license.
;
; Features:
; - 160x200 pixel 16-color mode (programmable 512-color palette)
; - NO mouse cursor support
; - Full-frame copy (not rectangle-aware)
; - Two-pass even/odd bank copy for sequential VRAM writes

; SCI drivers use a single code/data segment starting at offset 0
[bits 16]
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
; Full-screen copy from the SCI engine's packed framebuffer to VRAM.
; Ignores rectangle parameters — always copies the entire 320×200
; framebuffer, downsampling 320→160 (take every other pixel).
; Two-pass: even scanlines first (bank 0), then odd (bank 1).
;
; Parameters:   si      frame buffer segment (offset = 0)
;               (ax, bx, cx, dx ignored — always full screen)
; Returns:      --
;-----------------------------------------------------------------------
update_rect:
	push    ds
	cld

	mov     ds,si           ; DS = source framebuffer segment
	mov     ax,0B000h
	mov     es,ax           ; ES = VRAM at B000h

	; === Even scanlines (0, 2, 4, ... 198) → VRAM bank 0 ===
	xor     si,si           ; source starts at row 0, offset 0
	xor     di,di           ; dest starts at bank 0, offset 0
	mov     dx,100          ; 100 even rows

.even_loop:
	mov     cx,80           ; 80 output bytes per row (160 pixels)
.even_inner:
	lodsb                   ; source byte: [pixel0 | pixel1]
	and     al,0xF0         ; keep pixel0 in high nibble
	mov     ah,al
	lodsb                   ; source byte: [pixel2 | pixel3]
	shr     al,1            ; move pixel2 to low nibble (8088-safe)
	shr     al,1
	shr     al,1
	shr     al,1
	or      al,ah           ; pack: [pixel0 | pixel2]
	stosb
	loop    .even_inner

	add     si,160          ; skip odd row in source (160 bytes/row)
	dec     dx
	jnz     .even_loop

	; === Odd scanlines (1, 3, 5, ... 199) → VRAM bank 1 ===
	mov     si,160          ; source starts at row 1 (offset 160)
	mov     di,8192         ; dest starts at bank 1 (offset 8192)
	mov     dx,100          ; 100 odd rows

.odd_loop:
	mov     cx,80           ; 80 output bytes per row
.odd_inner:
	lodsb                   ; source byte: [pixel0 | pixel1]
	and     al,0xF0         ; keep pixel0 in high nibble
	mov     ah,al
	lodsb                   ; source byte: [pixel2 | pixel3]
	shr     al,1            ; move pixel2 to low nibble (8088-safe)
	shr     al,1
	shr     al,1
	shr     al,1
	or      al,ah           ; pack: [pixel0 | pixel2]
	stosb
	loop    .odd_inner

	add     si,160          ; skip even row in source
	dec     dx
	jnz     .odd_loop

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
; Returns:      ax = 0 (cursor visibility counter)
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
; Delegates to update_rect (full-screen copy).
;
; Parameters:   di      frame buffer segment (offset = 0)
; Returns:      --
;-----------------------------------------------------------------------
scroll_rect:
	mov     si,di
	jmp     update_rect
