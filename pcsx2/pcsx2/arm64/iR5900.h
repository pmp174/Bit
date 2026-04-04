// SPDX-FileCopyrightText: 2002-2026 PCSX2 Dev Team
// SPDX-License-Identifier: GPL-3.0+

#pragma once

#include "Config.h"
#include "R5900.h"
#include "x86/R5900_Profiler.h"
#include "VU.h"
#include "arm64/iCore.h"
#include "arm64/AsmHelpers.h"

// Dedicated registers during JIT execution
#define RCPUSTATE     vixl::aarch64::x19
#define RFASTMEMBASE  vixl::aarch64::x20
#define RECLUTPTR     vixl::aarch64::x21
#define RCYCLES       vixl::aarch64::x22

// 32-bit versions of dedicated registers
#define WCPUSTATE     vixl::aarch64::w19
#define WFASTMEMBASE  vixl::aarch64::w20

// Helper to create a MemOperand accessing a cpuRegs member via RCPUSTATE
#define MEMBASE_PTR(member) \
	vixl::aarch64::MemOperand(RCPUSTATE, (s64)offsetof(cpuRegisters, member))

extern u32 maxrecmem;
extern u32 pc;             // recompiler pc
extern int g_branch;       // set for branch
extern u32 target;         // branch target
extern u32 s_nBlockCycles; // cycles of current block recompiling
extern bool s_nBlockInterlocked; // Current block has VU0 interlocking

//////////////////////////////////////////////////////////////////////////////////////////
// Interpreter-fallback macros

// REC_FUNC: Flush registers and call interpreter function
#define REC_FUNC(f) \
	void rec##f() \
	{ \
		recCall(Interp::f); \
	}

#define REC_FUNC_DEL(f, delreg) \
	void rec##f() \
	{ \
		if ((delreg) > 0) \
			_deleteEEreg(delreg, 1); \
		recCall(Interp::f); \
	}

#define REC_SYS(f) \
	void rec##f() \
	{ \
		recBranchCall(Interp::f); \
	}

#define REC_SYS_DEL(f, delreg) \
	void rec##f() \
	{ \
		if ((delreg) > 0) \
			_deleteEEreg(delreg, 1); \
		recBranchCall(Interp::f); \
	}

extern bool g_recompilingDelaySlot;

// Used for generating backpatch thunks for fastmem.
u8* recBeginThunk();
u8* recEndThunk();

// used when processing branches
bool TrySwapDelaySlot(u32 rs, u32 rt, u32 rd, bool allow_loadstore);
void SaveBranchState();
void LoadBranchState();

void recompileNextInstruction(bool delayslot, bool swapped_delay_slot);
void SetBranchReg();
void SetBranchImm(u32 imm);

void iFlushCall(int flushtype);
void recBranchCall(void (*func)());
void recCall(void (*func)());
u32 scaleblockcycles_clear();

namespace R5900
{
	namespace Dynarec
	{
		extern void recDoBranchImm(u32 branchTo, u32* jmpSkip, bool isLikely = false, bool swappedDelaySlot = false);
	} // namespace Dynarec
} // namespace R5900

////////////////////////////////////////////////////////////////////
// Constant Propagation

#define GPR_IS_CONST1(reg) (EE_CONST_PROP && (reg) < 32 && (g_cpuHasConstReg & (1 << (reg))))
#define GPR_IS_CONST2(reg1, reg2) (EE_CONST_PROP && (g_cpuHasConstReg & (1 << (reg1))) && (g_cpuHasConstReg & (1 << (reg2))))
#define GPR_IS_DIRTY_CONST(reg) (EE_CONST_PROP && (reg) < 32 && (g_cpuHasConstReg & (1 << (reg))) && (!(g_cpuFlushedConstReg & (1 << (reg)))))
#define GPR_SET_CONST(reg) \
	{ \
		if ((reg) < 32) \
		{ \
			g_cpuHasConstReg |= (1 << (reg)); \
			g_cpuFlushedConstReg &= ~(1 << (reg)); \
		} \
	}

#define GPR_DEL_CONST(reg) \
	{ \
		if ((reg) < 32) \
			g_cpuHasConstReg &= ~(1 << (reg)); \
	}

alignas(16) extern GPR_reg64 g_cpuConstRegs[32];
extern u32 g_cpuHasConstReg, g_cpuFlushedConstReg;

// Move a MIPS GPR value to an ARM64 register (handles const, cached, or memory)
void _eeMoveGPRtoR(const vixl::aarch64::Register& to, int fromgpr);

void _eeFlushAllDirty();
void _eeOnWriteReg(int reg, int signext);

void _deleteEEreg(int reg, int flush);
void _deleteEEreg128(int reg);

void _flushEEreg(int reg, bool clear = false);

int _eeTryRenameReg(int to, int from, int fromhost, int other, int xmminfo);

//////////////////////////////////////
// Templates for code recompilation //
//////////////////////////////////////

typedef void (*R5900FNPTR)();
typedef void (*R5900FNPTR_INFO)(int info);

#define EERECOMPILE_CODE0(fn, xmminfo) \
	void rec##fn(void) \
	{ \
		EE::Profiler.EmitOp(eeOpcode::fn); \
		eeRecompileCode0(rec##fn##_const, rec##fn##_consts, rec##fn##_constt, rec##fn##_, (xmminfo)); \
	}
#define EERECOMPILE_CODERC0(fn, xmminfo) \
	void rec##fn(void) \
	{ \
		EE::Profiler.EmitOp(eeOpcode::fn); \
		eeRecompileCodeRC0(rec##fn##_const, rec##fn##_consts, rec##fn##_constt, rec##fn##_, (xmminfo)); \
	}

#define EERECOMPILE_CODEX(codename, fn, xmminfo) \
	void rec##fn(void) \
	{ \
		EE::Profiler.EmitOp(eeOpcode::fn); \
		codename(rec##fn##_const, rec##fn##_, (xmminfo)); \
	}

#define EERECOMPILE_CODEI(codename, fn, xmminfo) \
	void rec##fn(void) \
	{ \
		EE::Profiler.EmitOp(eeOpcode::fn); \
		codename(rec##fn##_const, rec##fn##_, (xmminfo)); \
	}

// rd = rs op rt
void eeRecompileCodeRC0(R5900FNPTR constcode, R5900FNPTR_INFO constscode, R5900FNPTR_INFO consttcode, R5900FNPTR_INFO noconstcode, int xmminfo);
// rt = rs op imm16
void eeRecompileCodeRC1(R5900FNPTR constcode, R5900FNPTR_INFO noconstcode, int xmminfo);
// rd = rt op sa
void eeRecompileCodeRC2(R5900FNPTR constcode, R5900FNPTR_INFO noconstcode, int xmminfo);

// rd = rs op rt (all regs need to be in NEON)
int eeRecompileCodeNEON(int xmminfo);
void eeFPURecompileCode(R5900FNPTR_INFO neoncode, R5900FNPTR fpucode, int xmminfo);

#define FPURECOMPILE_CONSTCODE(fn, xmminfo) \
	void rec##fn(void) \
	{ \
		eeFPURecompileCode(rec##fn##_neon, R5900::Interpreter::OpcodeImpl::COP1::fn, xmminfo); \
	}

// Compatibility alias
static __fi int eeRecompileCodeXMM(int xmminfo) { return eeRecompileCodeNEON(xmminfo); }

extern bool g_cpuFlushedPC;
extern bool g_cpuFlushedCode;
extern bool g_maySignalException;
