// SPDX-FileCopyrightText: 2002-2026 PCSX2 Dev Team
// SPDX-License-Identifier: GPL-3.0+

#pragma once

#include "R3000A.h"
#include "arm64/iCore.h"
#include "arm64/AsmHelpers.h"

// Cycle penalties for slow instructions
static const int psxInstCycles_Mult = 7;
static const int psxInstCycles_Div = 40;

#define PSX_HI XMMGPR_HI
#define PSX_LO XMMGPR_LO

extern uptr psxRecLUT[];

void _psxFlushConstReg(int reg);
void _psxFlushConstRegs();

void _psxDeleteReg(int reg, int flush);
void _psxFlushCall(int flushtype);
void _psxFlushAllDirty();

void _psxOnWriteReg(int reg);

void _psxMoveGPRtoR(const vixl::aarch64::Register& to, int fromgpr);

extern u32 psxpc;
extern int psxbranch;
extern u32 g_iopCyclePenalty;

void psxSaveBranchState();
void psxLoadBranchState();

extern void psxSetBranchReg();
extern void psxSetBranchImm(u32 imm);
extern void psxRecompileNextInstruction(bool delayslot, bool swapped_delayslot);

////////////////////////////////////////////////////////////////////
// IOP Constant Propagation

#define PSX_IS_CONST1(reg) ((reg) < 32 && (g_psxHasConstReg & (1 << (reg))))
#define PSX_IS_CONST2(reg1, reg2) ((g_psxHasConstReg & (1 << (reg1))) && (g_psxHasConstReg & (1 << (reg2))))
#define PSX_IS_DIRTY_CONST(reg) ((reg) < 32 && (g_psxHasConstReg & (1 << (reg))) && (!(g_psxFlushedConstReg & (1 << (reg)))))
#define PSX_SET_CONST(reg) \
	{ \
		if ((reg) < 32) \
		{ \
			g_psxHasConstReg |= (1u << (reg)); \
			g_psxFlushedConstReg &= ~(1u << (reg)); \
		} \
	}

#define PSX_DEL_CONST(reg) \
	{ \
		if ((reg) < 32) \
			g_psxHasConstReg &= ~(1 << (reg)); \
	}

extern u32 g_psxConstRegs[32];
extern u32 g_psxHasConstReg, g_psxFlushedConstReg;

typedef void (*R3000AFNPTR)();
typedef void (*R3000AFNPTR_INFO)(int info);

// IOP instruction table (all interpreter fallback for Phase 0)
extern void (*rpsxBSC[64])();
void rpsxpropBSC(EEINST* prev, EEINST* pinst);
