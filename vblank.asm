; VBlank handler.
;
; This is called once per frame, even when the LCD is disabled.
; It finishes rendering the current frame and updates palettes and key inputs.
; In addition, it handles frame synchronization and frameskip logic.
;
; Inputs:  None
; Outputs: None
; Destroys AF,HL
vblank_helper:
	; Update VFPS counter
vfps = $+1
	ld a,0
	add a,1
	daa
	ld (vfps),a
	
	; Finish rendering, if applicable
	push de
	 push ix
	  push bc
	   ld a,(render_this_frame)
	   or a
	   jr z,skip_this_frame
	
	   ; Finish rendering the frame
	   ld a,144
	   call render_scanlines
	  
	   ; Display sprites
	   ld a,(hram_base+LCDC)
	   cpl
	   and $82
	   push iy
	    call z,draw_sprites
	   pop iy
	
	   ; Swap buffers
	   call prepare_next_frame
	   
#ifndef DBGNOSCALE
	   ; EXPAND DONG
	   ld a,144/3
	   ex de,hl
	   ld b,e	;B=0
_
	   push de
	   pop hl
	   ld c,160
	   add hl,bc
	   ex de,hl
	   ldir
	   ex de,hl
	   ld c,160
	   add hl,bc
	   push hl
	   pop de
	   add hl,bc
	   ex de,hl
	   ldir
	   dec a
	   jr nz,-_
#else
	   xor a
#endif
	   
fps_display_smc:
	   jr z,NoFPSDisplay
	   
fps = $+1
	   ld a,0
	   add a,1
	   daa
	   ld (fps),a
	   
	   ld a,(mpRtcSecondCount)
last_second = $+1
	   cp -1
	   call nz,update_fps
	   
	   ld de,0
vfps_display_tens = $+1
	   ld c,0
	   call display_digit
	   ld de,4
vfps_display_ones = $+1
	   ld c,0
	   call display_digit
	   ld de,12
fps_display_tens = $+1
	   ld c,0
	   call display_digit
	   ld de,16
fps_display_ones = $+1
	   ld c,0
	   call display_digit
NoFPSDisplay:
	  
	   ; Signify frame was rendered
	   scf
skip_this_frame:

	   ld ix,mpKeypadGrp0
key_smc_turbo:
	   bit 2,(ix+1*2)	;ZOOM
	   ld hl,frame_excess_count
	   jr nz,no_frame_sync
	  
	   ; Handle frame synchronization
	   dec (hl)
	   jp p,no_frame_sync
	   ; If we didn't render, save for later
	   jr nc,frame_sync_later
frame_sync_loop:
	   push hl
	    ld de,$000800
	    call wait_for_interrupt
	    call update_palettes
	    ld hl,mpLcdIcr
	    ld (hl),4
	   pop hl
	   inc (hl)
	   jr nz,frame_sync_loop
frame_sync_later:
	   ; Set Z
	   xor a
no_frame_sync:
	  
	   ; Handle frameskip logic
	   ; At this point A=0, Z holds auto state
	   ex de,hl
	   ld hl,skippable_frames
frameskip_type_smc:
	   jr z,no_frameskip	;JR no_frameskip when off, JR $+2 when manual
	   dec (hl)
	   jr nz,frameskip_end
no_frameskip:
frameskip_value_smc = $+1
	   ld a,1
	   ld (hl),a
	   ex de,hl
	   bit 7,(hl)
	   jr nz,_
	   cp (hl)
	   jr nc,_
	   ld (hl),a
_
	   ld a,1
frameskip_end:
	   ld (render_this_frame),a
	  
	   ; Get keys
	   scf
	   sbc hl,hl
	   ld ix,mpKeypadGrp0

key_smc_right:
	   bit 2,(ix+7*2)	;Right
	   jr z,_
	   dec l
_
key_smc_left:
	   bit 1,(ix+7*2)	;Left
	   jr z,_
	   bit 0,l
	   set 0,l
	   jr z,_
	   res 1,l
_
key_smc_up:
	   bit 3,(ix+7*2)	;Up
	   jr z,_
	   res 2,l
_
key_smc_down:
	   bit 0,(ix+7*2)	;Down
	   jr z,_
	   bit 2,l
	   set 2,l
	   jr z,_
	   res 3,l
_
key_smc_a:
	   bit 5,(ix+1*2)	;2ND
	   jr z,_
	   dec h
_
key_smc_b:
	   bit 7,(ix+2*2)	;ALPHA
	   jr z,_
	   res 1,h
_
key_smc_select:
	   bit 7,(ix+3*2)	;X,T,0,n
	   jr z,_
	   res 2,h
_
key_smc_start:
	   bit 6,(ix+1*2)	;MODE
	   jr z,_
	   res 3,h
_
	   ld.sis (keys),hl

key_smc_menu:
	   bit 6,(ix+6*2)	;CLEAR
	   jr z,_
	   ACALL(emulator_menu)
	   ld hl,(curr_palettes)
	   call update_palettes_always
_
	  pop bc
	 pop ix
	pop de

	; Trigger VBLANK
	ld hl,hram_base+LCDC
	bit 7,(hl)
	jr z,_
	inc hl
	bit 4,(hl)
	ld l,IF & $FF
	set 0,(hl)
	jr z,_
	set 1,(hl)
_
	ei
	jp.sis vblank_handler_ret
	
	
; Acknowledges one or more interrupt sources and then waits on them.
; Interrupt is neither acknowledged nor handled once it triggers.
;
; Inputs:  DE = interrupt source mask to wait on
;          Interrupts are disabled
; Outputs: Original interrupt mask is restored
; Destroys IX,DE,HL
ack_and_wait_for_interrupt:
	ld (mpIntAcknowledge),de
	
; Waits on one or more interrupt sources. May return immediately.
; Interrupt is neither acknowledged nor handled once it triggers.
;
; Inputs:  DE = interrupt source mask to wait on
;          Interrupts are disabled
; Outputs: Original interrupt mask is restored
; Destroys IX,DE,HL
wait_for_interrupt:
	ld hl,mpIntEnable
	ld ix,(hl)
	ld (hl),de
	ex de,hl
	ld hl,z80codebase+rst38h
	ld (hl),$C9	;RET
	call.is wait_for_interrupt_stub
	ld (hl),$F5	;PUSH AF
	ex de,hl
	ld (hl),ix
	ret
	
frame_interrupt:
	ld (mpLcdIcr),a
	push hl
	 push de
	  push bc
	   push ix
	    call update_palettes
	   pop ix
	  pop bc
	 pop de
	pop hl
frame_excess_count = $+1
	ld a,0
	inc a
	ld (frame_excess_count),a
	jp.sis frame_interrupt_return
	
; Prepares to render the next frame.
; This swaps the current buffer and resets internal render variables.
;
; Inputs:  None
; Outputs: HL = old framebuffer
;          A = 0
prepare_next_frame:
	ld hl,(scanlineLUT_ptr)
	ld a,l
	cp scanlineLUT_2 & $FF
	jr z,_
	ld hl,scanlineLUT_1
	ld (scanlineLUT_ptr),hl
_
	ld (scanlineLUT_sprite_ptr),hl
	ld (scanlineLUT_palette_ptr),hl
	ld hl,(hram_base+BGP)
	ld (curr_palettes),hl
	ld hl,(mpLcdBase)
	ld (current_buffer),hl
	ld a,h
	xor (gb_frame_buffer_1 ^ gb_frame_buffer_2)>>8
	ld h,a
	ld a,(hram_base+LCDC)
	rrca
	and $20
	add a,(vram_tiles_start >> 8) & $FF
	ld (window_tile_ptr+1),a
	xor a
	ld (window_tile_offset),a
	ld (myLY),a
	ld (myspriteLY),a
	ld (mypaletteLY),a
	ld (mpLcdBase),hl
	ret
	
; Updates the FPS digits for the last second and prepares the next second.
;
; Inputs:  A = current RTC second
; Outputs: None
update_fps:
	ld (last_second),a
	
	ld a,(vfps)
	ld e,a
	and $0F
	ld (vfps_display_ones),a
	xor e
	rrca
	rrca
	rrca
	rrca
	ld (vfps_display_tens),a
	
	ld a,(fps)
	ld e,a
	and $0F
	ld (fps_display_ones),a
	xor e
	rrca
	rrca
	rrca
	rrca
	ld (fps_display_tens),a
	
	xor a
	ld (vfps),a
	ld (fps),a
	ret
	
; Displays a digit onscreen at the given framebuffer offset in bytes.
; Draws to the old buffer.
;
; Inputs:  C = digit (0-9)
;          DE = offset
; Outputs: A = 0
; Destroys AF,BC,DE,HL
display_digit:
	ld hl,(current_buffer)
	ld a,h
	xor (gb_frame_buffer_1 ^ gb_frame_buffer_2)>>8
	ld h,a
	add hl,de
	ex de,hl
	ld hl,digits
	ld b,40
	mlt bc
	add hl,bc
	ld a,10
_
	ld bc,160
	ldi
	ldi
	ldi
	ldi
	ex de,hl
	add hl,bc
	ex de,hl
	dec a
	jr nz,-_
	ret

; Update the host LCD palettes based on the currently set GB palettes.
; No operation if the GB palettes have not changed since this was last called.
;
; Uses the palette_XXX_colors arrays as the source colors for each type.
;
; Destroys AF,DE,HL,IX
update_palettes:
curr_palettes = $+1
	ld hl,$FFFFFF
old_palettes = $+1
	ld de,$FFFFFF
	or a
	sbc hl,de
	ret z
	add hl,de
	ld (old_palettes),hl
	; Input: Palettes in HL
update_palettes_always:
	ld de,mpLcdPalette + (9*2)-1
	ld ix,palette_obj1_colors+1+8
	ld c,(9*2) + 3
update_palettes_next_loop:
	lea ix,ix-8
	ld b,4
update_palettes_loop:
	xor a
	add hl,hl
	adc a,a
	add hl,hl
	adc a,a
	add a,a
	djnz _
	dec c
	jr nz,update_palettes_next_loop
	inc de
	ld e,16*2-1
	scf
_
	ld (update_palettes_smc),a
	push hl
update_palettes_smc = $+2
	 lea hl,ix
	 ldd
	 ldd
	pop hl
	jr nc,update_palettes_loop
	ret
	
convert_palette:
	ld c,a
	call convert_palette_setup
convert_palette_row_loop:
	ld hl,(ix)
convert_palette_any_row:
	ld b,160 / 4
convert_palette_pixel_loop:
	ld e,(hl)
	ld a,(de)
	ld (hl),a
	inc hl
	ld e,(hl)
	ld a,(de)
	ld (hl),a
	inc hl
	ld e,(hl)
	ld a,(de)
	ld (hl),a
	inc hl
	ld e,(hl)
	ld a,(de)
	ld (hl),a
	inc hl
	djnz convert_palette_pixel_loop
	lea ix,ix+3
	dec c
	jr nz,convert_palette_row_loop
	ret
	
convert_palette_setup:
	ld hl,convert_palette_LUT + $23
	ld a,(hram_base+BGP)
	ld b,4
_
	rlca
	rlca
	ld d,a
	and 3
	add a,BG_COLOR_0
	ld e,a
	ld a,d
	ld d,$11
	mlt de
	dec l
	ld (hl),e
	jr z,_
	ld de,-$10
	add hl,de
_
	djnz --_
	ex de,hl
	ret
	
setup_menu_palette:
	call convert_palette_setup
	
	ld hl,(mpLcdBase)
	ld bc,240*256+1
_
	push bc
	 call convert_palette_any_row
	pop bc
	djnz -_
	 
	; (MAG)ENTA | BLUE
	ld hl,($EA56 << 16) | $2882
	ld (mpLcdPalette),hl
	; OLIVE | MAG(ENTA)
	ld hl,($CA8B << 8) | ($EA56 >> 8)
	ld (mpLcdPalette+3),hl
	ret