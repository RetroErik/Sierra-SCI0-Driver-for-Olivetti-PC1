; ======================================================================
; PC1TEST.DRV — Test/instrumentation build of the PC1 SCI0 driver
; ======================================================================
;
; This file enables ALL test/debug features and includes the main
; driver source.  Assemble with:
;
;   nasm -f bin -o PC1TEST.DRV PC1TEST.asm
;
; To enable individual features independently, assemble PC1.asm
; directly with -D flags:
;
;   nasm -f bin -DTEST_OVERLAY              -o PC1OVL.DRV  PC1.asm
;   nasm -f bin -DDIAG_PATTERN              -o PC1DIAG.DRV PC1.asm
;   nasm -f bin -DTIMING_PROBE              -o PC1TIME.DRV PC1.asm
;   nasm -f bin -DTEST_OVERLAY -DTIMING_PROBE -o PC1OT.DRV PC1.asm
;
; OVERLAY_H controls the height (in rows) of the on-screen debug bar.
; Default is 8.  Override with -DOVERLAY_H=12 etc.
;
; ======================================================================
; WHAT THIS BUILD ENABLES:
;
; TEST_OVERLAY  — A colored-block overlay in the top OVERLAY_H rows
;   that displays the last update_rect parameters, the call counter,
;   and a bytes-written estimate.  Reading guide:
;
;     Col  0-3   4-7  |  9-12  13-16 | 18-21  | 23-26
;      Left  Top  |  Right  Bot  | Count  | Bytes
;
;   Each hex nibble is shown as a solid block of the corresponding
;   palette color (0=black … F=white).  Background is dark gray
;   (color 8), separators are white.  Overlay redraws only when the
;   rect overlaps the top band or every 16 update_rect calls.
;
; DIAG_PATTERN  — Replaces framebuffer conversion with a diagnostic
;   fill pattern:
;     • First & last row of the rect: white (0xFF)
;     • Even-bank (even Y) interior: light green (color 10)
;     • Odd-bank  (odd  Y) interior: light red   (color 12)
;     • Left & right edge columns:   white
;   This makes rectangle boundaries and interlace row order visible.
;   Any combing (wrong bank assignment) shows as green/red out-of-
;   sequence stripes.
;
; TIMING_PROBE  — Sets the border/overscan color to white (0x0F)
;   at the start of update_rect and restores it to black at the end.
;   Connect an oscilloscope or logic analyzer to the video output to
;   measure the pulse width = update_rect execution time.
;   Note: when TEST_OVERLAY is also active, the pulse includes overlay
;   rendering time (shows total driver cost per call).
;
; ======================================================================

%define TEST_OVERLAY  1
%define DIAG_PATTERN  1
%define TIMING_PROBE  1

; Overlay height — set here or override on the command line with -DOVERLAY_H=N
%ifndef OVERLAY_H
  %define OVERLAY_H 8
%endif

%include "PC1.asm"
