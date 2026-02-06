; PC1-1.DRV - EDUCATIONAL: Initial PCPLUS port (broken prototype)
;
; FAILURE MODE:
;   * Graphics rendering broken — framebuffer not properly converted to VRAM
;   * Mouse cursor non-functional
;   * Entry point uses simple 'jmp dispatch' (violates SCI entry convention)
;   * Functions incomplete
;
; VALUE:
;   Shows why the port from PCPLUS failed. PC1's V6355D and memory layout
;   require different framebuffer handling than PCPLUS's CGA/EGA. This version
;   was the first attempt, attempting full cursor support (bloated). Simplified
;   in PC1-1b by removing cursor; graphics fixed but keyboard broke.
;
; Based on PCPLUS.DRV by Benedikt Freisen
; Adapted for Olivetti Prodest PC1 with Yamaha V6355D
;
; This library is free and open-source software published under the
; GNU LGPL license.
;
; Features (intended, but not working):
; - 160x200 pixel 16-color mode (programmable 512-color palette)
; - Full mouse cursor support
; - 8088 compatibility

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
entry:  jmp     dispatch

; magic numbers followed by two pascal strings
signature       db      00h, 21h, 43h, 65h, 87h, 00h
driver_name     db      3, "pc1"
description     db      34, "Olivetti Prodest PC1 - 16 Colors"

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

; active mouse cursor in the internal pixel format
; five bytes per line (two bytes mask data + two bytes color + one padding)
cursor_and      times   80 db 0                 ; inverted and-mask
cursor_or       times   80 db 0                 ; or-mask

; saved background pixels overwritten by the cursor
cursor_bg       times   160 db 0
cursor_ofs      dw      0
cursor_hbytes   db      0
cursor_rows     db      0

cursor_counter  dw      0
cursor_x        dw      0
cursor_y        dw      0
cursor_new_x    dw      0
cursor_new_y    dw      0

cursor_lock     dw      0

; Default 16-color palette (CGA-compatible colors in 512-color format)
; Format: R (3-bit), G|B (3-bit green in bits 4-6, 3-bit blue in bits 0-2)
default_palette:
    ; Color 0: Black (R=0, G=0, B=0)
    db 0x00, 0x00
    ; Color 1: Blue (R=0, G=0, B=7)
    db 0x00, 0x07
    ; Color 2: Green (R=0, G=7, B=0)
    db 0x00, 0x70
    ; Color 3: Cyan (R=0, G=7, B=7)
    db 0x00, 0x77
    ; Color 4: Red (R=7, G=0, B=0)
    db 0x07, 0x00
    ; Color 5: Magenta (R=7, G=0, B=7)
    db 0x07, 0x07
    ; Color 6: Brown (R=5, G=3, B=0)
    db 0x05, 0x30
    ; Color 7: Light Gray (R=5, G=5, B=5)
    db 0x05, 0x55
    ; Color 8: Dark Gray (R=3, G=3, B=3)
    db 0x03, 0x33
    ; Color 9: Light Blue (R=3, G=3, B=7)
    db 0x03, 0x37
    ; Color 10: Light Green (R=3, G=7, B=3)
    db 0x03, 0x73
    ; Color 11: Light Cyan (R=3, G=7, B=7)
    db 0x03, 0x77
    ; Color 12: Light Red (R=7, G=3, B=3)
    db 0x07, 0x33
    ; Color 13: Light Magenta (R=7, G=3, B=7)
    db 0x07, 0x37
    ; Color 14: Yellow (R=7, G=7, B=3)
    db 0x07, 0x73
    ; Color 15: White (R=7, G=7, B=7)
    db 0x07, 0x77

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
	mov     ah,0fh
	int     10h

	; save mode number
	push    ax

	; set video mode 4 (320x200 graphics mode for CRTC initialization)
	mov     ax,4
	int     10h

	; enable PC1 hidden 160x200 16-color mode
	mov     al,0x4A         ; Magic value: bit 6 enables 16-color mode
	out     0xD8,al         ; Write to Mode Control Register
	jmp     short $+2       ; I/O delay

	; set border color to black
	xor     al,al
	out     0xD9,al
	jmp     short $+2

	; program the default palette
	call    set_default_palette

	; clear video memory
	mov     ax,0B000h       ; PC1 uses B000h, not B800h
	mov     es,ax
	xor     di,di
	mov     cx,8192         ; 16KB / 2
	xor     ax,ax
	rep     stosw

	; restore mode number
	pop     ax
	xor     ah,ah

	ret

;-------------- set_default_palette ------------------------------------
; Programs the V6355D with the default 16-color palette
;
; Parameters:   --
; Returns:      --
;-----------------------------------------------------------------------
set_default_palette:
	cli                     ; Disable interrupts during palette write
        
	; enable palette write mode (starts at color 0)
	mov     al,0x40
	out     0xDD,al
	jmp     short $+2

	; write 32 bytes (16 colors × 2 bytes each)
	mov     cx,32
	mov     si,default_palette
.loop:
	lodsb
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
	; save parameter
	push    ax

	; disable PC1 hidden graphics mode
	mov     al,0x08         ; Standard CGA mode
	out     0xD8,al
	jmp     short $+2

	; restore parameter
	pop     ax

	; set video mode
	xor     ah,ah
	int     10h

	ret

;-------------- update_rect --------------------------------------------
; Transfer the specified rectangle from the engine's internal linear
; frame buffer of IRGB pixels to the screen.
;
; Parameters:   ax      Y-coordinate of the top-left corner
;               bx      X-coordinate of the top-left corner
;               cx      Y-coordinate of the bottom-right corner
;               dx      X-coordinate of the bottom-right corner
;               si      frame buffer segment (offset = 0)
; Returns:      --
; Notes:        The implementation may expand the rectangle as needed
;               and may assume that all parameters are valid.
;               It has to hide the mouse cursor if it intersects with
;               the rectangle and has to lock it, otherwise.
;-----------------------------------------------------------------------
update_rect:
	; convert X coordinates from 320-width to 160-width
	shr     bx,1            ; left edge / 2
	inc     dx
	shr     dx,1            ; right edge / 2
        
	; load and convert cursor x
	mov     bp,[cursor_x]
	shr     bp,1            ; cursor is in 320-width coordinates
        
	; compare to right edge
	cmp     dx,bp
	jl      .just_lock
	; compare to left edge (a bit generously)
	add     bp,5
	sub     bp,bx
	jl      .just_lock
	; load cursor y
	mov     bp,[cursor_y]
	; compare to bottom edge
	cmp     cx,bp
	jl      .just_lock
	; compare to top edge
	add     bp,16
	sub     bp,ax
	jl      .just_lock

	; locking the cursor is not enough -> hide it
	push    ax
	push    bx
	push    cx
	push    dx
	push    si
	call    hide_cursor
	pop     si
	pop     dx
	pop     cx
	pop     bx
	pop     ax
	clc
	jmp     .just_hide

.just_lock:
	call    lock_cursor
	stc
.just_hide:
	pushf

	mov     bp,0B000h       ; PC1 uses B000h segment
	mov     es,bp
	push    ds
	mov     ds,si

	; calculate source address (engine's 320-width framebuffer)
	sub     cx,ax           ; height
	sub     dx,bx           ; width in 160-width coords
	mov     bp,ax           ; save Y
	mov     ah,160          ; 320 pixels/row in engine (2 pixels = 1 160-width pixel)
	mul     ah
	mov     si,ax
	shl     bx,1            ; convert 160-width X to 320-width for source
	add     si,bx
        
	; calculate destination address
	mov     ax,bp           ; restore Y
	xor     di,di
	shr     ax,1            ; Y/2 for interlacing
	rcr     di,1            ; odd row flag to di
	shr     di,1
	shr     di,1
	mov     ah,80           ; 80 bytes per row
	mul     ah
	add     di,ax
	shr     bx,1            ; back to 160-width coordinate
	add     di,bx           ; add X offset (in bytes, since 2 pixels/byte)

	mov     bp,dx           ; width (in 160-width coords = bytes to write)
	mov     dx,cx           ; height
        
.y_loop:
	mov     cx,bp           ; width
	push    si
	push    di
.x_loop:
	; load two pixels from engine's frame buffer (160-width = 2 pixels from 320-width)
	lodsb                   ; first pixel (left)
	mov     ah,al
	lodsb                   ; second pixel (right, skip this for 160-width)
	lodsb                   ; third pixel (left of next pair - this is our right pixel)
        
	; pack into nibbles: high nibble = first pixel, low nibble = second pixel
	shl     ah,4            ; move first pixel to high nibble
	and     al,0x0F         ; keep only low nibble of second pixel
	or      al,ah           ; combine
        
	stosb
	lodsb                   ; skip fourth pixel
	loop    .x_loop

	pop     di
	pop     si
	add     si,160          ; next row in 320-width framebuffer
        
	; handle scanline interleacing
	add     di,8192
	cmp     di,16384
	jb      .odd
	sub     di,16304        ; wrap to next line in first bank
.odd:

	dec     dx
	jnz     .y_loop

	pop     ds
	; unlock/show cursor
	popf
	jnc     .show
	call    unlock_cursor
	ret
.show:  call    show_cursor

	ret

;-------------- show_cursor --------------------------------------------
; Increment the mouse cursor visibility counter and draw the cursor if
; the counter reaches one.
;
; Parameters:   --
; Returns:      --
;-----------------------------------------------------------------------
show_cursor:
	; hard synchronization
	pushf
	cli

	or      word [cursor_counter],0
	jne     .skip
	call    draw_cursor

.skip:  inc     word [cursor_counter]
	popf

	ret

;-------------- hide_cursor --------------------------------------------
; Decrement the mouse cursor visibility counter and restore the
; background if the counter reaches zero.
;
; Parameters:   --
; Returns:      --
;-----------------------------------------------------------------------
hide_cursor:
	; hard synchronization
	pushf
	cli

	dec     word [cursor_counter]
	jnz     .skip
	call    restore_background

.skip:  popf

	ret

;-------------- move_cursor --------------------------------------------
; Moves the mouse cursor, unless it is locked, in which case it will be
; moved when unlocked.
;
; Parameters:   ax      new X-coordinate
;               bx      new Y-coordinate
; Returns:      --
; Note:         This function has to preserve all registers not
;               otherwise preserved.
;-----------------------------------------------------------------------
move_cursor:
	; save everything
	push    ax
	push    bx
	push    cx
	push    dx
	push    si
	push    di
	pushf

	; move the cursor, unless it is locked
	cli
	push    bx
	push    ax
	cmp     word [cursor_lock],0
	jnz     .skip
	call    hide_cursor
	pop     word [cursor_x]
	pop     word [cursor_y]
	call    show_cursor
	jmp     .end
.skip:
	; if locked, save coordinates for later
	pop     word [cursor_new_x]
	pop     word [cursor_new_y]
.end:

	; restore everything
	popf
	pop     di
	pop     si
	pop     dx
	pop     cx
	pop     bx
	pop     ax

	ret

;-------------- load_cursor --------------------------------------------
; Loads a new graphical mouse cursor.
;
; Parameters:   ax      segment of the new cursor
;               bx      offset of the new cursor
; Returns:      ax      the current cursor visibility
; Notes:        Source cursor format expected by load_cursor:
;               Two unused words followed by an AND- and an OR-matrix,
;               each consisting of sixteen 16-bit little-endian words.
;               The most significant bit is the left-most pixel.
;-----------------------------------------------------------------------
load_cursor:
	; copy the new cursor to the internal cursor data structure
	push    ds
	mov     ds,ax
	lea     si,[bx+4]
	mov     di,cursor_and
	mov     ax,cs
	mov     es,ax

	; Convert 16-bit monochrome cursor to PC1 packed pixel format
	; Each source word has 16 pixels (1 bit each)
	; We need to convert to 8 bytes (2 pixels per byte)
        
	mov     dx,16           ; 16 rows
.loop_y_and:
	lodsw                   ; load 16-bit AND mask
	xchg    al,ah
	not     ax              ; invert for AND mask
        
	; convert 16 bits to 8 bytes (2 pixels per byte at 4bpp)
	mov     cx,4            ; 4 bytes per half (8 bytes total)
.convert_and:
	mov     bx,ax
	and     bx,0xC000       ; get top 2 bits
	shr     bx,12           ; move to low nibble positions
	or      bl,bl
	jz      .and_00
	cmp     bl,3
	je      .and_11
	mov     bl,0x0F         ; one bit set = half mask
	jmp     .and_store
.and_00:
	mov     bl,0x00
	jmp     .and_store
.and_11:
	mov     bl,0xFF
.and_store:
	mov     [es:di],bl
	inc     di
	shl     ax,1
	shl     ax,1
	loop    .convert_and
        
	xor     al,al
	stosb                   ; padding byte
	dec     dx
	jnz     .loop_y_and

	; OR mask
	mov     dx,16
.loop_y_or:
	lodsw
	xchg    al,ah
        
	mov     cx,4
.convert_or:
	mov     bx,ax
	and     bx,0xC000
	shr     bx,12
	or      bl,bl
	jz      .or_00
	cmp     bl,3
	je      .or_11
	mov     bl,0x0F
	jmp     .or_store
.or_00:
	mov     bl,0x00
	jmp     .or_store
.or_11:
	mov     bl,0xFF
.or_store:
	mov     [es:di],bl
	inc     di
	shl     ax,1
	shl     ax,1
	loop    .convert_or
        
	xor     al,al
	stosb
	dec     dx
	jnz     .loop_y_or

	pop     ds

	; make sure that the on-screen cursor changes, as well
	call    hide_cursor
	call    show_cursor

	; return the cursor visibility counter
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
; Scroll out the content of the specified rectangle while filling it
; with the new content.
;
; Parameters:   ax      Y-coordinate of the top-left corner
;               bx      X-coordinate of the top-left corner
;               cx      Y-coordinate of the bottom-right corner
;               dx      X-coordinate of the bottom-right corner
;               di      frame buffer segment (offset = 0)
;               ?       potentially further parameters for
;                       implementations that actually scroll
; Returns:      --
; Notes:        Simple implementations may omit the scrolling and
;               delegate the call to update_rect, adjusting the
;               parameters as needed.
;-----------------------------------------------------------------------
scroll_rect:
	; update_rect expects the target frame buffer segment in si
	mov     si,di
	; tail call to update_rect
	jmp     update_rect

;***********************************************************************
; The helper functions below are not part of the API.
;***********************************************************************

;-------------- draw_cursor --------------------------------------------
; Draws the mouse cursor after saving the screen content at its
; position to a buffer.
;
; Parameters:   --
; Returns:      --
;-----------------------------------------------------------------------
draw_cursor:
	; calculate on-screen cursor dimensions
	mov     ax,200
	sub     ax,[cursor_y]
	cmp     ax,16
	jl      .nocrop_v
	mov     ax,16
.nocrop_v:
	mov     [cursor_rows],al

	mov     ax,[cursor_x]
	shr     ax,1            ; convert to 160-width coordinate
	mov     bx,ax
	sub     ax,80
	neg     ax
	cmp     ax,5
	jl      .nocrop_h
	mov     ax,5
.nocrop_h:
	mov     [cursor_hbytes],al

	; calculate cursor offset in video ram
	mov     ax,[cursor_y]
	xor     si,si
	shr     ax,1
	rcr     si,1
	shr     si,1
	shr     si,1
	mov     ah,80
	mul     ah
	add     si,ax
	add     si,bx
	mov     [cursor_ofs],si

	; save screen content that will be overwritten
	push    ds
	mov     ax,ds
	mov     es,ax
	mov     ax,0B000h       ; PC1 uses B000h
	mov     ds,ax
	mov     di,cursor_bg

	xor     bx,bx
	mov     bl,[cs:cursor_hbytes]
	mov     dl,[cs:cursor_rows]
	xor     cx,cx
.save_y_loop:
	mov     cl,bl
	rep     movsb
	sub     si,bx
	; handle scanline interleaving
	add     si,8192
	cmp     si,16384
	jb      .save_odd
	sub     si,16304
.save_odd:
	dec     dl
	jnz     .save_y_loop

	pop     ds

	; draw cursor
	mov     ax,0B000h
	mov     es,ax
	mov     di,[cursor_ofs]
	mov     si,cursor_and
        
	; calculate X-offset in pixels (for pixel-level cursor positioning)
	mov     cx,[cursor_x]
	and     cx,1            ; 0 or 1 (even/odd pixel within byte)
	shl     cl,2            ; multiply by 4 for nibble shifts
	mov     ch,[cursor_rows]

.draw_y_loop:
	xor     bx,bx

	; handle first byte in line
	mov     ax,[si]         ; load AND mask word
	xchg    al,ah
	shr     ax,cl           ; shift for pixel alignment
	not     ax              ; invert back for AND
	mov     al,ah           ; we only need high byte
	and     al,[es:di]      ; apply AND mask
	mov     dl,al           ; save AND result in DL
	mov     ax,[si+80]      ; load OR mask word
	xchg    al,ah
	shr     ax,cl
	mov     al,ah
	or      al,dl           ; combine OR mask with AND result
	mov     [es:di+bx],al
	inc     bl

	; handle rest of line
.draw_x_loop:
	cmp     bl,[cursor_hbytes]
	je      .draw_x_loop_end
        
	mov     ax,[si+bx]
	xchg    al,ah
	shr     ax,cl
	not     ax
	xchg    al,ah
	and     al,[es:di+bx]
	mov     bp,ax
	mov     ax,[si+bx+80]
	xchg    al,ah
	shr     ax,cl
	xchg    al,ah
	or      ax,bp
	mov     [es:di+bx],al
	inc     bl
	jmp     .draw_x_loop
        
.draw_x_loop_end:
	add     si,5            ; next cursor row (4 bytes + 1 padding)
	; handle scanline interleaving
	add     di,8192
	cmp     di,16384
	jb      .draw_odd
	sub     di,16304
.draw_odd:
	dec     ch
	jnz     .draw_y_loop

	ret

;-------------- restore_background -------------------------------------
; Restore the screen content previously saved and overwritten by
; draw_cursor.
;
; Parameters:   --
; Returns:      --
;-----------------------------------------------------------------------
restore_background:
	push    ds
	mov     ax,ds
	mov     es,ax
	mov     ax,0B000h
	mov     ds,ax
        
	mov     si,cursor_bg
	mov     di,[cursor_ofs]
	xor     bx,bx
	mov     bl,[cursor_hbytes]
	mov     dl,[cursor_rows]
	xor     cx,cx
        
.y_loop:
	mov     cl,bl
	rep     movsb
	sub     di,bx
	; handle scanline interleaving
	add     di,8192
	cmp     di,16384
	jb      .odd
	sub     di,16304
.odd:
	dec     dl
	jnz     .y_loop

	pop     ds
	ret

;-------------- lock_cursor --------------------------------------------
; Locks the cursor in its current position without changing its
; visibility.
;
; Parameters:   --
; Returns:      --
; Notes:        Has to preserve all registers
;-----------------------------------------------------------------------
lock_cursor:
	pushf
	cli
	inc     word [cursor_lock]
	popf
	ret

;-------------- unlock_cursor ------------------------------------------
; Unlocks the cursor and updates its position, if it has changed since
; the cursor has been locked.
;
; Parameters:   --
; Returns:      --
;-----------------------------------------------------------------------
unlock_cursor:
	pushf
	cli
	dec     word [cursor_lock]
	jnz     .end
        
	mov     ax,[cursor_new_x]
	cmp     ax,[cursor_x]
	jne     .move
	mov     ax,[cursor_new_y]
	cmp     ax,[cursor_y]
	je      .end
        
.move:  
	mov     ax,[cursor_new_x]
	mov     bx,[cursor_new_y]
	popf
	call    move_cursor
	ret
        
.end:   
	popf
	ret
