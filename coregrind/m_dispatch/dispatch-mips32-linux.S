
/*--------------------------------------------------------------------*/
/*--- The core dispatch loop, for jumping to a code address.       ---*/
/*---                                        dispatch-mips-linux.S ---*/
/*--------------------------------------------------------------------*/

/*
  This file is part of Valgrind, a dynamic binary instrumentation
  framework.

  Copyright (C) 2000-2017 RT-RK
     mips-valgrind@rt-rk.com 

  This program is free software; you can redistribute it and/or
  modify it under the terms of the GNU General Public License as
  published by the Free Software Foundation; either version 2 of the
  License, or (at your option) any later version.

  This program is distributed in the hope that it will be useful, but
  WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
  General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with this program; if not, write to the Free Software
   Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
   02111-1307, USA.

  The GNU General Public License is contained in the file COPYING.
*/

#include "pub_core_basics_asm.h"

#if defined(VGP_mips32_linux)

#include "pub_core_dispatch_asm.h"
#include "pub_core_transtab_asm.h"
#include "libvex_guest_offsets.h"	/* for OFFSET_mips_PC */


/*------------------------------------------------------------*/
/*---                                                      ---*/
/*--- The dispatch loop.  VG_(disp_run_translations) is    ---*/
/*--- used to run all translations,                        ---*/
/*--- including no-redir ones.                             ---*/
/*---                                                      ---*/
/*------------------------------------------------------------*/

/*----------------------------------------------------*/
/*--- Entry and preamble (set everything up)       ---*/
/*----------------------------------------------------*/

/* signature:
void VG_(disp_run_translations)( UWord* two_words,
                                 void*  guest_state, 
                                 Addr   host_addr );
*/

.text
.globl VG_(disp_run_translations)
VG_(disp_run_translations):
    /* a0 ($4) holds two_words   */
    /* a1 ($5) holds guest_state */
    /* a2 ($6) holds host_addr   */

    /* New stack frame.  Stack must remain 8 aligned (at least) */
    addiu $29, -64

    /* Save ra */
    sw  $31, 16($29)

    /* ... and s0 - s7 */
    sw $16, 20($29)
    sw $17, 24($29)
    sw $18, 28($29)
    sw $19, 32($29)
    sw $20, 36($29)
    sw $21, 40($29)
    sw $22, 44($29)
    sw $23, 48($29)

    /* ... and gp, fp/s8 */
    sw $28, 52($29)
    sw $30, 56($29)

    /* Save a0 ($4) on stack. In postamble it will be restored such that the
       return values can be written */
    sw $4, 60($29)

    /* Load address of guest state into guest state register ($23) */
    move $23, $5

    /* and jump into the code cache.  Chained translations in
           the code cache run, until for whatever reason, they can't
           continue.  When that happens, the translation in question
           will jump (or call) to one of the continuation points
           VG_(cp_...) below. */
    jr $6
    /*NOTREACHED*/

/*----------------------------------------------------*/
/*--- Postamble and exit.                          ---*/
/*----------------------------------------------------*/

postamble:
        /* At this point, $2 and $3 contain two
           words to be returned to the caller.  $2
           holds a TRC value, and $3 optionally may
           hold another word (for CHAIN_ME exits, the
           address of the place to patch.) */

    /* Restore $4 from stack; holds address of two_words */
    lw $4, 60($29)
    sw  $2, 0($4)         /* Store $2 to two_words[0] */
    sw  $3, 4($4)         /* Store $3 to two_words[1] */

    /* Restore callee-saved registers... */

    /* Restore ra */
    lw $31, 16($29)

    /* ... and s0 - s7 */
    lw $16, 20($29)
    lw $17, 24($29)
    lw $18, 28($29)
    lw $19, 32($29)
    lw $20, 36($29)
    lw $21, 40($29)
    lw $22, 44($29)
    lw $23, 48($29)

    /* ... and gp, fp/s8 */
    lw $28, 52($29)
    lw $30, 56($29)

    addiu $29, 64   /* stack_size */
    jr $31
    nop

/*----------------------------------------------------*/
/*--- Continuation points                          ---*/
/*----------------------------------------------------*/

/* ------ Chain me to slow entry point ------ */
.global VG_(disp_cp_chain_me_to_slowEP)
VG_(disp_cp_chain_me_to_slowEP):
        /* We got called.  The return address indicates
           where the patching needs to happen.  Collect
           the return address and, exit back to C land,
           handing the caller the pair (Chain_me_S, RA) */
        li $2, VG_TRC_CHAIN_ME_TO_SLOW_EP
        move $3, $31
        /* 8 = mkLoadImm_EXACTLY2or5
           4 = jalr $9
           4 = nop */
        addiu  $3, $3, -16
        b    postamble

/* ------ Chain me to slow entry point ------ */
.global VG_(disp_cp_chain_me_to_fastEP)
VG_(disp_cp_chain_me_to_fastEP):
        /* We got called.  The return address indicates
           where the patching needs to happen.  Collect
           the return address and, exit back to C land,
           handing the caller the pair (Chain_me_S, RA) */
        li $2, VG_TRC_CHAIN_ME_TO_FAST_EP
        move $3, $31
        /* 8 = mkLoadImm_EXACTLY2or5
           4 = jalr $9
           4 = nop */
        addiu  $3, $3, -16
        b    postamble

/* ------ Indirect but boring jump ------ */
.global VG_(disp_cp_xindir)
VG_(disp_cp_xindir):
        /* Where are we going? */
        lw    $10, OFFSET_mips32_PC($23)

        /* stats only */
        lw    $15, VG_(stats__n_xIndirs_32)
        addiu $15, $15, 1
        sw    $15, VG_(stats__n_xIndirs_32)

        // LIVE: r23 (guest state ptr), r10 (guest address to go to).
        // We use 6 temporaries:
        //   r16 (to point at the relevant FastCacheSet),
        //   r11, r12, r13 (scratch, for swapping entries within a set)
        //   r14, r15 (other scratch)

        /* Try a fast lookup in the translation cache.  This is pretty much
           a handcoded version of VG_(lookupInFastCache). */

        // Compute r16 = VG_TT_FAST_HASH(guest)
        srl   $16, $10, 2                      // g2 = guest >> 2
        srl   $15, $10, (VG_TT_FAST_BITS + 2)  // (g2 >> VG_TT_FAST_BITS)
        xor   $16, $16, $15                    // (g2 >> VG_TT_FAST_BITS) ^ g2
        li    $15, VG_TT_FAST_MASK
        and   $16, $16, $15                    // setNo

        // Compute r16 = &VG_(tt_fast)[r16]
	la    $15, VG_(tt_fast)
        sll   $16, $16, VG_FAST_CACHE_SET_BITS
        addu  $16, $16, $15

        // LIVE: r23 (guest state ptr), r10 (guest addr), r16 (cache set)
        // try way 0
        lw    $14, FCS_g0($16)   // .guest0
        lw    $15, FCS_h0($16)   // .host0
        bne   $14, $10, 1f  // cmp against .guest0
        // hit at way 0
        // goto .host0
        jr    $15
        /*NOTREACHED*/
	.long 0x0

1:      // try way 1
        lw    $14, FCS_g1($16)
        bne   $14, $10, 2f  // cmp against .guest1
        // hit at way 1; swap upwards
        lw    $11, FCS_g0($16)   // $11 = old .guest0
        lw    $12, FCS_h0($16)   // $12 = old .host0
        lw    $13, FCS_h1($16)   // $13 = old .host1
        sw    $10, FCS_g0($16)   // new .guest0 = guest
        sw    $13, FCS_h0($16)   // new .host0 = old .host1
        sw    $11, FCS_g1($16)   // new .guest1 = old .guest0
        sw    $12, FCS_h1($16)   // new .host1 = old .host0
        // stats only
        lw    $15, VG_(stats__n_xIndir_hits1_32)
        addiu $15, $15, 1
        sw    $15, VG_(stats__n_xIndir_hits1_32)
        // goto old .host1 a.k.a. new .host0
        jr    $13
        /*NOTREACHED*/
	.long 0x0

2:      // try way 2
        lw    $14, FCS_g2($16)
        bne   $14, $10, 3f   // cmp against .guest2
        // hit at way 2; swap upwards
        lw    $11, FCS_g1($16)
        lw    $12, FCS_h1($16)
        lw    $13, FCS_h2($16)
        sw    $10, FCS_g1($16)
        sw    $13, FCS_h1($16)
        sw    $11, FCS_g2($16)
        sw    $12, FCS_h2($16)
        // stats only
        lw    $15, VG_(stats__n_xIndir_hits2_32)
        addiu $15, $15, 1
        sw    $15, VG_(stats__n_xIndir_hits2_32)
        // goto old .host2 a.k.a. new .host1
        jr    $13
        /*NOTREACHED*/
	.long 0x0

3:      // try way 3
        lw    $14, FCS_g3($16)
        bne   $14, $10, 4f   // cmp against .guest3
        // hit at way 3; swap upwards
        lw    $11, FCS_g2($16)
        lw    $12, FCS_h2($16)
        lw    $13, FCS_h3($16)
        sw    $10, FCS_g2($16)
        sw    $13, FCS_h2($16)
        sw    $11, FCS_g3($16)
        sw    $12, FCS_h3($16)
        // stats only
        lw    $15, VG_(stats__n_xIndir_hits3_32)
        addiu $15, $15, 1
        sw    $15, VG_(stats__n_xIndir_hits3_32)
        // goto old .host3 a.k.a. new .host2
        jr    $13
        /*NOTREACHED*/
	.long 0x0

4:      // fast lookup failed:
        /* stats only */
        lw    $15, VG_(stats__n_xIndir_misses_32)
        addiu $15, $15, 1
        sw    $15, VG_(stats__n_xIndir_misses_32)

        li    $2, VG_TRC_INNER_FASTMISS
        li    $3, 0
        b     postamble
	/*NOTREACHED*/
	.long 0x0

/* ------ Assisted jump ------ */
        .global VG_(disp_cp_xassisted)
VG_(disp_cp_xassisted):
        /* guest-state-pointer contains the TRC. Put the value into the
           return register */
        move    $2, $23
        move    $3, $0
        b       postamble

/* ------ Event check failed ------ */
        .global VG_(disp_cp_evcheck_fail)
VG_(disp_cp_evcheck_fail):
        li      $2, VG_TRC_INNER_COUNTERZERO
        move    $3, $0
        b       postamble

.size VG_(disp_run_translations), .-VG_(disp_run_translations)

#endif // defined(VGP_mips32_linux)

/* Let the linker know we don't need an executable stack */
MARK_STACK_NO_EXEC

/*--------------------------------------------------------------------*/
/*--- end                                                          ---*/
/*--------------------------------------------------------------------*/
