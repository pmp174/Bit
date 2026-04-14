// SPDX-FileCopyrightText: 2002-2026 PCSX2 Dev Team
// SPDX-License-Identifier: GPL-3.0+

// ARM64 IOP Recompiler — Core dispatcher and block compilation (Phase 0: interpreter fallback)

#include "Common.h"
#include "Host.h"
#include "R3000A.h"
#include "IopBios.h"
#include "IopHw.h"
#include "IopMem.h"
#include "VMManager.h"

#include "x86/BaseblockEx.h"
#include "arm64/iR3000A.h"
#include "arm64/AsmHelpers.h"

#include "common/AlignedMalloc.h"
#include "common/FastJmp.h"
#include "common/HeapArray.h"
#include "common/Perf.h"
#include "DebugTools/Breakpoints.h"

namespace a64 = vixl::aarch64;

// Diagnostic logging — writes directly to log file
static void iopRecLog(const char* fmt, ...) __attribute__((format(printf, 1, 2)));
static void iopRecLog(const char* fmt, ...) {
	static FILE* s_logFile = nullptr;
	if (!s_logFile) {
		s_logFile = fopen("/tmp/pcsx2_openemu.log", "a");
		if (!s_logFile) return;
	}
	time_t now = time(nullptr);
	struct tm* tm_info = localtime(&now);
	char timebuf[32];
	strftime(timebuf, sizeof(timebuf), "%I:%M:%S %p", tm_info);
	fprintf(s_logFile, "[%s] [IOP-REC] ", timebuf);
	va_list args;
	va_start(args, fmt);
	vfprintf(s_logFile, fmt, args);
	va_end(args);
	fprintf(s_logFile, "\n");
	fflush(s_logFile);
}

extern void psxBREAK();

// ========================================================================
// Global state
// ========================================================================

u32 g_psxMaxRecMem = 0;
uptr psxRecLUT[0x10000];
u32 psxhwLUT[0x10000];

static __fi u32 HWADDR(u32 mem) { return psxhwLUT[mem >> 16] + mem; }

static BASEBLOCK* recRAM = nullptr;
static BASEBLOCK* recROM = nullptr;
static BASEBLOCK* recROM1 = nullptr;
static BASEBLOCK* recROM2 = nullptr;
static BaseBlocks recBlocks;
static u8* recPtr = nullptr;
static u8* recPtrEnd = nullptr;

u32 psxpc;
int psxbranch;
u32 g_iopCyclePenalty;

static EEINST* s_pInstCache = nullptr;
static u32 s_nInstCacheSize = 0;
static BASEBLOCK* s_pCurBlock = nullptr;
static BASEBLOCKEX* s_pCurBlockEx = nullptr;
static u32 s_nEndBlock = 0;
static u32 s_branchTo;
static bool s_nBlockFF;

// g_psxConstRegs, g_psxHasConstReg, g_psxFlushedConstReg defined in R3000A.cpp

static u32 s_saveConstRegs[32];
static u32 s_saveHasConstReg = 0, s_saveFlushedConstReg = 0;
static EEINST* s_psaveInstInfo = nullptr;

u32 s_psxBlockCycles = 0;
static u32 s_savenBlockCycles = 0;
static bool s_recompilingDelaySlot = false;
static bool extraRam = false;

static ArmConstantPool s_iopConstPool;
static u32 s_iopExecCount = 0;
static fastjmp_buf s_iopJmpBuf;
static bool s_iopJmpBufValid = false;

// Dedicated IOP register: points to psxRegs
#define RPSXREGS a64::x19

// IOP LUT pointer register
#define RPSXLUT a64::x21

#define PSX_GETBLOCK(x) PC_GETBLOCK_(x, psxRecLUT)

#define PSXREC_CLEARM(mem) \
	(((mem) < g_psxMaxRecMem && (psxRecLUT[(mem) >> 16] + (mem))) ? \
			psxRecClearMem(mem) : \
			4)

// ========================================================================
// Dispatcher function pointers
// ========================================================================

static const void* iopDispatcherEvent = nullptr;
static const void* iopDispatcherReg = nullptr;
static const void* iopJITCompile = nullptr;
static const void* iopEnterRecompiledCode = nullptr;
static const void* iopExitRecompiledCode = nullptr;
static const void* iopUnmappedRecLUTPage = nullptr;

// ========================================================================
// Forward declarations
// ========================================================================

static void iopRecRecompile(u32 startpc);
static int iopHandleUnmappedPage();
static void iopRecError(int err);
static void iopClearRecLUT(BASEBLOCK* base, int count);
static u32 psxRecClearMem(u32 pc);

extern void (*rpsxBSC[64])();
void rpsxpropBSC(EEINST* prev, EEINST* pinst);

// ========================================================================
// Event test
// ========================================================================

static void iopRecEventTest()
{
	static u32 s_iopEventTestCount = 0;
	s_iopEventTestCount++;
	if (s_iopEventTestCount <= 10 || (s_iopEventTestCount % 10000) == 0)
		iopRecLog("iopRecEventTest #%u: iopPC=0x%08X iopCycle=%llu",
			s_iopEventTestCount, psxRegs.pc, (unsigned long long)psxRegs.cycle);

	// NOTE: Must call iopEventTest (IOP-specific), NOT _cpuEventTest_Shared (EE).
	// _cpuEventTest_Shared calls psxCpu->ExecuteBlock which would recursively
	// re-enter the IOP recompiler.
	iopEventTest();
}

static void iopRecExitExecution()
{
	if (!s_iopJmpBufValid)
	{
		iopRecLog("ERROR: iopRecExitExecution called with INVALID jmpbuf! Ignoring stale exit.");
		return;  // Return normally — the brk 0 trap in the JIT will catch this
	}
	s_iopJmpBufValid = false;
	fastjmp_jmp(&s_iopJmpBuf, 1);
}

static void iopDispatcherLog()
{
	// Intentionally empty — hot path, logging confirmed working
}

static void iopExitLog()
{
	// Intentionally empty — hot path, logging confirmed working
}

// ========================================================================
// ARM64 Dispatcher Generation
// ========================================================================

static const void* _DynGen_DispatcherReg()
{
	const void* entry = armGetCurrentCodePointer();

	// w0 = psxRegs.pc
	armAsm->Ldr(RWARG1, a64::MemOperand(RPSXREGS, (s64)offsetof(psxRegisters, pc)));

	// x1 = psxRecLUT[pc >> 16]
	armAsm->Lsr(RWARG2, RWARG1, 16);
	armAsm->Ldr(RXARG2, a64::MemOperand(RPSXLUT, RXARG2, a64::LSL, 3));

	// x2 = base + pc * 2 (BASEBLOCK = 8 bytes, pc in 4-byte units)
	armAsm->Add(RXARG2, RXARG2, a64::Operand(RXARG1, a64::UXTW, 1));

	// x2 = block fnptr
	armAsm->Ldr(RXARG2, a64::MemOperand(RXARG2));

	armAsm->Br(RXARG2);

	return entry;
}

static const void* _DynGen_DispatcherEvent()
{
	const void* entry = armGetCurrentCodePointer();
	armEmitCall((const void*)iopRecEventTest);
	// Fall through to DispatcherReg (generated immediately after)
	return entry;
}

static const void* _DynGen_JITCompile()
{
	const void* entry = armGetCurrentCodePointer();

	// w0 = psxRegs.pc
	armAsm->Ldr(RWARG1, a64::MemOperand(RPSXREGS, (s64)offsetof(psxRegisters, pc)));

	// Call iopRecRecompile(pc)
	armEmitCall((const void*)iopRecRecompile);

	// After compilation, look up the block again
	armAsm->Ldr(RWARG1, a64::MemOperand(RPSXREGS, (s64)offsetof(psxRegisters, pc)));
	armAsm->Lsr(RWARG2, RWARG1, 16);
	armAsm->Ldr(RXARG2, a64::MemOperand(RPSXLUT, RXARG2, a64::LSL, 3));
	armAsm->Add(RXARG2, RXARG2, a64::Operand(RXARG1, a64::UXTW, 1));
	armAsm->Ldr(RXARG2, a64::MemOperand(RXARG2));
	armAsm->Br(RXARG2);

	return entry;
}

static const void* _DynGen_EnterRecompiledCode()
{
	const void* entry = armGetCurrentCodePointer();

	// Save callee-saved GPRs and FPRs
	armBeginStackFrame(true);

	// RPSXREGS (x19) = &psxRegs
	armMoveAddressToReg(RPSXREGS, &psxRegs);

	// RPSXLUT (x21) = &psxRecLUT
	armMoveAddressToReg(RPSXLUT, psxRecLUT);

	// Jump to dispatcher
	armEmitJmp(iopDispatcherReg);

	return entry;
}

static const void* _DynGen_ExitRecompiledCode()
{
	const void* entry = armGetCurrentCodePointer();

	armEmitCall((const void*)iopExitLog);
	// Exit via fastjmp_jmp back to recExecuteBlock's fastjmp_set.
	armEmitCall((const void*)iopRecExitExecution);
	// If iopRecExitExecution returns (guard prevented stale fastjmp_jmp),
	// cleanly unwind the JIT stack frame and return to C code.
	armEndStackFrame(true);
	armAsm->Ret();
	return entry;
}

static const void* _DynGen_UnmappedRecLUTPage()
{
	const void* entry = armGetCurrentCodePointer();
	armEmitCall((const void*)iopHandleUnmappedPage);
	// If return value is nonzero, an interrupt changed the PC — dispatch to new block
	armEmitCbnz(RWRET, iopDispatcherReg);
	// Otherwise budget exhausted — exit IOP
	armEmitJmp(iopExitRecompiledCode);
	return entry;
}

static void _DynGen_Dispatchers()
{
	armStartBlock();

	// DispatcherEvent falls through to DispatcherReg
	iopDispatcherEvent = _DynGen_DispatcherEvent();
	iopDispatcherReg = _DynGen_DispatcherReg();

	iopJITCompile = _DynGen_JITCompile();

	iopEnterRecompiledCode = _DynGen_EnterRecompiledCode();
	iopExitRecompiledCode = _DynGen_ExitRecompiledCode();

	iopUnmappedRecLUTPage = _DynGen_UnmappedRecLUTPage();

	armEndBlock();

	recBlocks.SetJITCompile(iopJITCompile);

	iopRecLog("IOP Dispatchers generated: Event=%p, Reg=%p, JITCompile=%p, Enter=%p, Exit=%p, Unmapped=%p",
		iopDispatcherEvent, iopDispatcherReg, iopJITCompile,
		iopEnterRecompiledCode, iopExitRecompiledCode, iopUnmappedRecLUTPage);

	// NOTE: Must use armGetAsmPtr() here, NOT armGetCurrentCodePointer(),
	// because armEndBlock() sets armAsm=nullptr.
	Perf::any.Register(iopDispatcherReg,
		static_cast<u32>((const u8*)armGetAsmPtr() - (const u8*)iopDispatcherReg),
		"IOP Dispatcher");
}

// ========================================================================
// Error handler
// ========================================================================

static int iopHandleUnmappedPage()
{
	// When the IOP hits an unmapped recLUT page, simulate NOP execution by advancing
	// the cycle counter WITHOUT advancing the PC. On real PS2 hardware, instruction
	// fetches from unmapped memory return 0 (NOP), so the CPU stays at the same
	// address while time passes. Eventually, iopEventTest delivers an interrupt that
	// redirects psxRegs.pc to the exception handler (0x80) in mapped memory.
	static u32 s_unmappedCount = 0;
	s_unmappedCount++;
	if (s_unmappedCount <= 20 || (s_unmappedCount % 100000) == 0)
		iopRecLog("IOP unmapped page #%u: PC=0x%08X iopCycleEE=%d iopCycle=%llu nextEvent=%llu",
			s_unmappedCount, psxRegs.pc, psxRegs.iopCycleEE,
			(unsigned long long)psxRegs.cycle,
			(unsigned long long)psxRegs.iopNextEventCycle);

	const u32 savedPC = psxRegs.pc;

	while (psxRegs.iopCycleEE > 0)
	{
		// Advance 1 IOP cycle = 8 EE cycles per NOP (do NOT advance PC)
		psxRegs.cycle += 1;
		psxRegs.iopCycleEE -= 8;

		// Check for IOP events (timers, SIF interrupts, etc.)
		if (psxRegs.cycle >= psxRegs.iopNextEventCycle)
		{
			iopEventTest();
			// If iopEventTest delivered an interrupt, psxRegs.pc changed
			if (psxRegs.pc != savedPC)
			{
				if (s_unmappedCount <= 20 || (s_unmappedCount % 100000) == 0)
					iopRecLog("IOP unmapped: interrupt redirected PC from 0x%08X to 0x%08X at cycle=%llu",
						savedPC, psxRegs.pc, (unsigned long long)psxRegs.cycle);
				return 1;  // PC changed — caller should dispatch to new block
			}
		}
	}

	return 0;  // Budget exhausted, PC unchanged — caller should exit IOP
}

static void iopRecError(int err)
{
	switch (err)
	{
		case 0:
			iopRecLog("IOP recError: Jump to unmapped recLUT page (PC: 0x%08x)", psxRegs.pc);
			break;
		case 1:
			iopRecLog("IOP recError: Jump to unaligned address (PC: 0x%08x)", psxRegs.pc);
			break;
	}
	// Match x86 behavior: don't modify iopCycleEE.
	// The IOP exits via iopExitRecompiledCode and returns its remaining budget to the EE.
}

// ========================================================================
// Constant propagation helpers
// ========================================================================

void _psxFlushConstReg(int reg)
{
	if (PSX_IS_CONST1(reg) && !(g_psxFlushedConstReg & (1 << reg)))
	{
		armAsm->Mov(RWARG1, g_psxConstRegs[reg]);
		armAsm->Str(RWARG1, a64::MemOperand(RPSXREGS, (s64)offsetof(psxRegisters, GPR.r[0]) + reg * 4));
		g_psxFlushedConstReg |= (1 << reg);
	}
}

void _psxFlushConstRegs()
{
	for (int i = 1; i < 32; ++i)
	{
		if (g_psxHasConstReg & (1 << i))
		{
			if (!(g_psxFlushedConstReg & (1 << i)))
			{
				armAsm->Mov(RWARG1, g_psxConstRegs[i]);
				armAsm->Str(RWARG1, a64::MemOperand(RPSXREGS, (s64)offsetof(psxRegisters, GPR.r[0]) + i * 4));
				g_psxFlushedConstReg |= 1 << i;
			}
			if (g_psxHasConstReg == g_psxFlushedConstReg)
				break;
		}
	}
}

void _psxDeleteReg(int reg, int flush)
{
	if (!reg)
		return;
	if (flush && PSX_IS_CONST1(reg))
		_psxFlushConstReg(reg);
	PSX_DEL_CONST(reg);
	_deletePSXtoArmGPR(reg, flush ? DELETE_REG_FREE : DELETE_REG_FREE_NO_WRITEBACK);
}

void _psxMoveGPRtoR(const a64::Register& to, int fromgpr)
{
	if (fromgpr == 0)
	{
		armAsm->Mov(to.IsX() ? to : to.X(), 0);
	}
	else if (PSX_IS_CONST1(fromgpr))
	{
		armAsm->Mov(to.IsX() ? to : to.X(), g_psxConstRegs[fromgpr]);
	}
	else
	{
		armAsm->Ldr(to.IsX() ? a64::Register(to.GetCode(), 32) : to,
			a64::MemOperand(RPSXREGS, (s64)offsetof(psxRegisters, GPR.r[0]) + fromgpr * 4));
	}
}

void _psxFlushCall(int flushtype)
{
	// Flush ARM GPR allocator
	if (flushtype & FLUSH_ALL_X86)
		_flushArmGPRregs();

	if (flushtype & FLUSH_CONSTANT_REGS)
		_psxFlushConstRegs();

	if (flushtype & FLUSH_PC)
	{
		armAsm->Mov(RWARG1, psxpc);
		armAsm->Str(RWARG1, a64::MemOperand(RPSXREGS, (s64)offsetof(psxRegisters, pc)));
	}
}

void _psxFlushAllDirty()
{
	for (u32 i = 1; i < 32; ++i)
	{
		if (PSX_IS_CONST1(i))
			_psxFlushConstReg(i);
	}
	_flushArmGPRregs();
}

void _psxOnWriteReg(int reg)
{
	PSX_DEL_CONST(reg);
}

void psxSaveBranchState()
{
	s_savenBlockCycles = s_psxBlockCycles;
	memcpy(s_saveConstRegs, g_psxConstRegs, sizeof(g_psxConstRegs));
	s_saveHasConstReg = g_psxHasConstReg;
	s_saveFlushedConstReg = g_psxFlushedConstReg;
	s_psaveInstInfo = g_pCurInstInfo;
	memcpy(s_saveArmGPRregs, armGPRregs, sizeof(armGPRregs));
}

void psxLoadBranchState()
{
	s_psxBlockCycles = s_savenBlockCycles;
	memcpy(g_psxConstRegs, s_saveConstRegs, sizeof(g_psxConstRegs));
	g_psxHasConstReg = s_saveHasConstReg;
	g_psxFlushedConstReg = s_saveFlushedConstReg;
	g_pCurInstInfo = s_psaveInstInfo;
	memcpy(armGPRregs, s_saveArmGPRregs, sizeof(armGPRregs));
}

// ========================================================================
// Branch handling
// ========================================================================

static __fi u32 psxScaleBlockCycles()
{
	return s_psxBlockCycles;
}

static void iPsxBranchTest(u32 newpc, u32 cpuBranch)
{
	u32 blockCycles = psxScaleBlockCycles();

	// Update cycle counter
	armAsm->Ldr(RXARG3, a64::MemOperand(RPSXREGS, (s64)offsetof(psxRegisters, cycle)));
	if (blockCycles < 4096)
		armAsm->Add(RXARG3, RXARG3, blockCycles);
	else
	{
		armAsm->Mov(RWARG4, blockCycles);
		armAsm->Add(RXARG3, RXARG3, RXARG4);
	}
	armAsm->Str(RXARG3, a64::MemOperand(RPSXREGS, (s64)offsetof(psxRegisters, cycle)));

	// Subtract from iopCycleEE (blockCycles * 8 for normal mode)
	armAsm->Ldr(RWARG1, a64::MemOperand(RPSXREGS, (s64)offsetof(psxRegisters, iopCycleEE)));
	if (blockCycles * 8 < 4096)
		armAsm->Sub(RWARG1, RWARG1, blockCycles * 8);
	else
	{
		armAsm->Mov(RWARG2, blockCycles * 8);
		armAsm->Sub(RWARG1, RWARG1, RWARG2);
	}
	armAsm->Str(RWARG1, a64::MemOperand(RPSXREGS, (s64)offsetof(psxRegisters, iopCycleEE)));

	// If iopCycleEE <= 0, exit (timeslice expired)
	armAsm->Cmp(RWARG1, 0);
	armEmitCondBranch(a64::le, iopExitRecompiledCode);

	// Check if event pending: cycle >= iopNextEventCycle
	armAsm->Ldr(RXARG4, a64::MemOperand(RPSXREGS, (s64)offsetof(psxRegisters, iopNextEventCycle)));
	armAsm->Cmp(RXARG3, RXARG4);

	a64::Label noEvent;
	armAsm->B(a64::lo, &noEvent);

	// Event pending — call event test
	armEmitCall((const void*)iopEventTest);

	if (newpc != 0xffffffff)
	{
		armAsm->Ldr(RWARG1, a64::MemOperand(RPSXREGS, (s64)offsetof(psxRegisters, pc)));
		armAsm->Cmp(RWARG1, newpc);
		// If PC changed (exception?), go to dispatcher
		armEmitCondBranch(a64::ne, iopDispatcherReg);
	}

	armAsm->Bind(&noEvent);
}

void psxSetBranchReg()
{
	psxbranch = 1;

	// Store the branch target (in w0) to psxRegs.pc
	armAsm->Str(RWRET, a64::MemOperand(RPSXREGS, (s64)offsetof(psxRegisters, pc)));

	// Check alignment
	armAsm->Tst(RWRET, 3);
	a64::Label aligned;
	armAsm->B(a64::eq, &aligned);

	// Unaligned — error
	armAsm->Mov(RWARG1, 1);
	armEmitCall((const void*)iopRecError);
	armEmitJmp(iopExitRecompiledCode);

	armAsm->Bind(&aligned);

	_psxFlushCall(FLUSH_EVERYTHING);
	iPsxBranchTest(0xffffffff, 1);
	armEmitJmp(iopDispatcherReg);
}

void psxSetBranchImm(u32 imm)
{
	psxbranch = 1;
	pxAssert(imm);

	armAsm->Mov(RWARG1, imm);
	armAsm->Str(RWARG1, a64::MemOperand(RPSXREGS, (s64)offsetof(psxRegisters, pc)));

	_psxFlushCall(FLUSH_EVERYTHING);
	iPsxBranchTest(imm, imm <= psxpc);

	// NOTE: recBlocks.Link removed — it writes x86-style 32-bit relative offsets
	// which corrupt the ARM64 MOVZ/BR jump sequence generated by armEmitJmp.
	armEmitJmp(iopDispatcherReg);
}

// ========================================================================
// SYSCALL / BREAK
// ========================================================================

void rpsxSYSCALL()
{
	armAsm->Mov(RWARG1, psxRegs.code);
	armAsm->Str(RWARG1, a64::MemOperand(RPSXREGS, (s64)offsetof(psxRegisters, code)));

	armAsm->Mov(RWARG1, psxpc - 4);
	armAsm->Str(RWARG1, a64::MemOperand(RPSXREGS, (s64)offsetof(psxRegisters, pc)));

	_psxFlushCall(FLUSH_NODESTROY);

	armAsm->Mov(RWARG1, 0x20);
	armAsm->Mov(RWARG2, psxbranch == 1 ? 1 : 0);
	armEmitCall((const void*)psxException);

	// Check if PC changed
	armAsm->Ldr(RWARG1, a64::MemOperand(RPSXREGS, (s64)offsetof(psxRegisters, pc)));
	armAsm->Cmp(RWARG1, psxpc - 4);
	a64::Label noChange;
	armAsm->B(a64::eq, &noChange);

	// PC changed — add cycles and dispatch
	armAsm->Ldr(RXARG3, a64::MemOperand(RPSXREGS, (s64)offsetof(psxRegisters, cycle)));
	u32 bc = psxScaleBlockCycles();
	if (bc < 4096)
		armAsm->Add(RXARG3, RXARG3, bc);
	else
	{
		armAsm->Mov(RWARG4, bc);
		armAsm->Add(RXARG3, RXARG3, RXARG4);
	}
	armAsm->Str(RXARG3, a64::MemOperand(RPSXREGS, (s64)offsetof(psxRegisters, cycle)));

	armAsm->Ldr(RWARG1, a64::MemOperand(RPSXREGS, (s64)offsetof(psxRegisters, iopCycleEE)));
	if (bc * 8 < 4096)
		armAsm->Sub(RWARG1, RWARG1, bc * 8);
	else
	{
		armAsm->Mov(RWARG2, bc * 8);
		armAsm->Sub(RWARG1, RWARG1, RWARG2);
	}
	armAsm->Str(RWARG1, a64::MemOperand(RPSXREGS, (s64)offsetof(psxRegisters, iopCycleEE)));

	armEmitJmp(iopDispatcherReg);

	armAsm->Bind(&noChange);
}

void rpsxBREAK()
{
	armAsm->Mov(RWARG1, psxRegs.code);
	armAsm->Str(RWARG1, a64::MemOperand(RPSXREGS, (s64)offsetof(psxRegisters, code)));

	armAsm->Mov(RWARG1, psxpc - 4);
	armAsm->Str(RWARG1, a64::MemOperand(RPSXREGS, (s64)offsetof(psxRegisters, pc)));

	_psxFlushCall(FLUSH_NODESTROY);

	armAsm->Mov(RWARG1, 0x24);
	armAsm->Mov(RWARG2, psxbranch == 1 ? 1 : 0);
	armEmitCall((const void*)psxException);

	armAsm->Ldr(RWARG1, a64::MemOperand(RPSXREGS, (s64)offsetof(psxRegisters, pc)));
	armAsm->Cmp(RWARG1, psxpc - 4);
	a64::Label noChange;
	armAsm->B(a64::eq, &noChange);

	u32 bc = psxScaleBlockCycles();
	armAsm->Ldr(RXARG3, a64::MemOperand(RPSXREGS, (s64)offsetof(psxRegisters, cycle)));
	if (bc < 4096)
		armAsm->Add(RXARG3, RXARG3, bc);
	else
	{
		armAsm->Mov(RWARG4, bc);
		armAsm->Add(RXARG3, RXARG3, RXARG4);
	}
	armAsm->Str(RXARG3, a64::MemOperand(RPSXREGS, (s64)offsetof(psxRegisters, cycle)));

	armAsm->Ldr(RWARG1, a64::MemOperand(RPSXREGS, (s64)offsetof(psxRegisters, iopCycleEE)));
	if (bc * 8 < 4096)
		armAsm->Sub(RWARG1, RWARG1, bc * 8);
	else
	{
		armAsm->Mov(RWARG2, bc * 8);
		armAsm->Sub(RWARG1, RWARG1, RWARG2);
	}
	armAsm->Str(RWARG1, a64::MemOperand(RPSXREGS, (s64)offsetof(psxRegisters, iopCycleEE)));

	armEmitJmp(iopDispatcherReg);

	armAsm->Bind(&noChange);
}

// ========================================================================
// Instruction compilation (Phase 0 — interpreter fallback for all)
// ========================================================================

// Generic interpreter call: flush everything, store PC, call interpreter function
static void psxRecCall(void (*func)())
{
	_psxFlushCall(FLUSH_EVERYTHING);

	// Store current psxRegs.code and psxpc
	armAsm->Mov(RWARG1, psxRegs.code);
	armAsm->Str(RWARG1, a64::MemOperand(RPSXREGS, (s64)offsetof(psxRegisters, code)));

	armAsm->Mov(RWARG1, psxpc - 4);
	armAsm->Str(RWARG1, a64::MemOperand(RPSXREGS, (s64)offsetof(psxRegisters, pc)));

	armEmitCall(reinterpret_cast<const void*>(func));
}

void psxRecompileNextInstruction(bool delayslot, bool swapped_delayslot)
{
	const int old_code = psxRegs.code;
	EEINST* old_inst_info = g_pCurInstInfo;
	s_recompilingDelaySlot = delayslot;

	if (delayslot)
		_clearNeededArmGPRs();

	psxRegs.code = iopMemRead32(psxpc);
	s_psxBlockCycles++;
	psxpc += 4;

	g_pCurInstInfo++;

	g_iopCyclePenalty = 0;
	rpsxBSC[psxRegs.code >> 26]();
	s_psxBlockCycles += g_iopCyclePenalty;

	if (!swapped_delayslot)
		_clearNeededArmGPRs();

	if (swapped_delayslot)
	{
		psxRegs.code = old_code;
		g_pCurInstInfo = old_inst_info;
	}
}

// ========================================================================
// LUT and Memory Management
// ========================================================================

static DynamicHeapArray<BASEBLOCK, 4096> recLutReserve;
static DynamicHeapArray<BASEBLOCK, 4096> recLutUnmapped;
static size_t recLutEntries;

static void iopClearRecLUT(BASEBLOCK* base, int count)
{
	for (int i = 0; i < count / 4; i++)
		base[i].SetFnptr((uptr)iopJITCompile);
}

static void recReserveRAM()
{
	recLutEntries =
		((Ps2MemSize::ExposedIopRam + Ps2MemSize::Rom + Ps2MemSize::Rom1 + Ps2MemSize::Rom2) / 4);

	if (recLutReserve.size() != recLutEntries)
		recLutReserve.resize(recLutEntries);

	recLutUnmapped.resize(_64kb / 4);

	BASEBLOCK* curpos = recLutReserve.data();
	recRAM = curpos;
	curpos += (Ps2MemSize::ExposedIopRam / 4);
	recROM = curpos;
	curpos += (Ps2MemSize::Rom / 4);
	recROM1 = curpos;
	curpos += (Ps2MemSize::Rom1 / 4);
	recROM2 = curpos;
}

static __fi u32 psxRecClearMem(u32 pc)
{
	BASEBLOCK* pblock = PSX_GETBLOCK(pc);
	if (pblock->GetFnptr() == (uptr)iopJITCompile)
		return 4;

	pc = HWADDR(pc);

	u32 lowerextent = pc, upperextent = pc + 4;
	int blockidx = recBlocks.Index(pc);
	pxAssert(blockidx != -1);

	while (BASEBLOCKEX* pexblock = recBlocks[blockidx - 1])
	{
		if (pexblock->startpc + pexblock->size * 4 <= lowerextent)
			break;
		lowerextent = std::min(lowerextent, pexblock->startpc);
		blockidx--;
	}

	int toRemoveFirst = blockidx;

	while (BASEBLOCKEX* pexblock = recBlocks[blockidx])
	{
		if (pexblock->startpc >= upperextent)
			break;
		lowerextent = std::min(lowerextent, pexblock->startpc);
		upperextent = std::max(upperextent, pexblock->startpc + pexblock->size * 4);
		blockidx++;
	}

	if (toRemoveFirst != blockidx)
		recBlocks.Remove(toRemoveFirst, (blockidx - 1));

	iopClearRecLUT(PSX_GETBLOCK(lowerextent), upperextent - lowerextent);

	return upperextent - pc;
}

// ========================================================================
// Recompiler Lifecycle
// ========================================================================

static void recReserve()
{
	recPtr = SysMemory::GetIOPRec();
	recPtrEnd = SysMemory::GetIOPRecEnd() - _64kb;

	const u32 poolSize = _64kb;
	s_iopConstPool.Init(recPtrEnd, poolSize);

	recReserveRAM();

	pxAssertRel(!s_pInstCache, "IOP InstCache not allocated");
	s_nInstCacheSize = 128;
	s_pInstCache = (EEINST*)malloc(sizeof(EEINST) * s_nInstCacheSize);
	if (!s_pInstCache)
		pxFailRel("Failed to allocate R3000A InstCache.");
}

static void recResetIOP()
{
	s_iopJmpBufValid = false;
	iopRecLog("recResetIOP() called");
	DevCon.WriteLn("ARM64 iR3000A Recompiler reset.");

	if (CHECK_EXTRAMEM != extraRam)
	{
		recReserveRAM();
		extraRam = !extraRam;
	}

	armSetAsmPtr(SysMemory::GetIOPRec(), SysMemory::GetIOPRecEnd() - SysMemory::GetIOPRec(), &s_iopConstPool);
	_DynGen_Dispatchers();
	recPtr = armGetAsmPtr(); // armEndBlock() in _DynGen_Dispatchers sets armAsm=nullptr

	iopClearRecLUT(reinterpret_cast<BASEBLOCK*>(recLutReserve.data()),
		Ps2MemSize::ExposedIopRam + Ps2MemSize::Rom + Ps2MemSize::Rom1 + Ps2MemSize::Rom2);

	BASEBLOCK* unmapped = recLutUnmapped.data();

	for (int i = 0; i < 0x10000; i++)
		recLUT_SetPage(psxRecLUT, psxhwLUT, unmapped, i, 0, 0);

	for (int i = 0; i < _64kb / 4; i++)
		unmapped[i].SetFnptr((uptr)iopUnmappedRecLUTPage);

	// Map IOP RAM (0x80 pages for 2MB, mirrored at kuseg/kseg0/kseg1)
	for (int i = 0; i < 0x80; i++)
	{
		u32 mask = (Ps2MemSize::ExposedIopRam / _64kb) - 1;
		recLUT_SetPage(psxRecLUT, psxhwLUT, recRAM, 0x0000, i, i & mask);
		recLUT_SetPage(psxRecLUT, psxhwLUT, recRAM, 0x8000, i, i & mask);
		recLUT_SetPage(psxRecLUT, psxhwLUT, recRAM, 0xa000, i, i & mask);
	}

	// Map ROM
	for (int i = 0x1fc0; i < 0x2000; i++)
	{
		recLUT_SetPage(psxRecLUT, psxhwLUT, recROM, 0x0000, i, i - 0x1fc0);
		recLUT_SetPage(psxRecLUT, psxhwLUT, recROM, 0x8000, i, i - 0x1fc0);
		recLUT_SetPage(psxRecLUT, psxhwLUT, recROM, 0xa000, i, i - 0x1fc0);
	}

	// Map ROM1
	for (int i = 0x1e00; i < 0x1e40; i++)
	{
		recLUT_SetPage(psxRecLUT, psxhwLUT, recROM1, 0x0000, i, i - 0x1e00);
		recLUT_SetPage(psxRecLUT, psxhwLUT, recROM1, 0x8000, i, i - 0x1e00);
		recLUT_SetPage(psxRecLUT, psxhwLUT, recROM1, 0xa000, i, i - 0x1e00);
	}

	// Map ROM2
	for (int i = 0x1e40; i < 0x1e48; i++)
	{
		recLUT_SetPage(psxRecLUT, psxhwLUT, recROM2, 0x0000, i, i - 0x1e40);
		recLUT_SetPage(psxRecLUT, psxhwLUT, recROM2, 0x8000, i, i - 0x1e40);
		recLUT_SetPage(psxRecLUT, psxhwLUT, recROM2, 0xa000, i, i - 0x1e40);
	}

	if (s_pInstCache)
		memset(s_pInstCache, 0, sizeof(EEINST) * s_nInstCacheSize);

	recBlocks.Reset();
	g_psxMaxRecMem = 0;
	psxbranch = 0;
}

static void recShutdown()
{
	s_iopConstPool.Destroy();
	recLutReserve.deallocate();

	safe_free(s_pInstCache);
	s_nInstCacheSize = 0;

	recPtr = nullptr;
	recPtrEnd = nullptr;
}

static __fi void recClearIOP(u32 Addr, u32 Size)
{
	u32 pc = Addr;
	while (pc < Addr + Size * 4)
		pc += PSXREC_CLEARM(pc);
}

// ========================================================================
// Block Execution Entry Point
// ========================================================================

static __noinline s32 recExecuteBlock(s32 eeCycles)
{
	s_iopExecCount++;
	if (s_iopExecCount <= 10 || (s_iopExecCount % 10000) == 0)
		iopRecLog("recExecuteBlock #%u: eeCycles=%d iopPC=0x%08X iopCycle=%llu iopNextEvent=%llu",
			s_iopExecCount, eeCycles, psxRegs.pc,
			(unsigned long long)psxRegs.cycle, (unsigned long long)psxRegs.iopNextEventCycle);

	psxRegs.iopBreak = 0;
	psxRegs.iopCycleEE = eeCycles;

	// Use fastjmp for IOP exit. iopExitRecompiledCode calls
	// iopRecExitExecution → fastjmp_jmp, which returns here with ret=1.
	// This is immune to stack corruption from unbalanced exits.
	s_iopJmpBufValid = true;
	if (!fastjmp_set(&s_iopJmpBuf))
	{
		((void (*)())iopEnterRecompiledCode)();
		// Should never reach here — JIT exits via fastjmp_jmp.
		iopRecLog("WARNING: iopEnterRecompiledCode returned unexpectedly");
	}
	s_iopJmpBufValid = false;

	s32 remaining = psxRegs.iopBreak + psxRegs.iopCycleEE;
	if (s_iopExecCount <= 10 || (s_iopExecCount % 10000) == 0)
		iopRecLog("recExecuteBlock #%u EXIT: iopPC=0x%08X remaining=%d iopBreak=%d iopCycleEE=%d",
			s_iopExecCount, psxRegs.pc, remaining, psxRegs.iopBreak, psxRegs.iopCycleEE);

	return remaining;
}

// ========================================================================
// Block Recompilation
// ========================================================================

static u32 s_iopBlocksCompiled = 0;

static void iopRecRecompile(const u32 startpc)
{
	s_iopBlocksCompiled++;
	if (s_iopBlocksCompiled <= 50 || (s_iopBlocksCompiled % 10000) == 0)
		iopRecLog("Compiling block #%u at PC=0x%08X", s_iopBlocksCompiled, startpc);

	u32 i;
	u32 link_next_block = 0;

	// SYSMEM module clearing hack
	if (startpc == 0x890)
		R3000SymbolGuardian.ClearIrxModules();

	// Override IOP boot memory size
	if (startpc == 0xbfc4a000)
		psxRegs.GPR.n.a0 = Ps2MemSize::ExposedIopRam >> 20;

	pxAssert(startpc);

	// If we're running out of code cache, reset
	if (recPtr >= recPtrEnd)
		recResetIOP();

	armSetAsmPtr(recPtr, recPtrEnd - recPtr, &s_iopConstPool);
	u8* block_start = armStartBlock();

	s_pCurBlock = PSX_GETBLOCK(startpc);
	pxAssert(s_pCurBlock->GetFnptr() == (uptr)iopJITCompile);

	s_pCurBlockEx = recBlocks.Get(HWADDR(startpc));
	if (!s_pCurBlockEx || s_pCurBlockEx->startpc != HWADDR(startpc))
		s_pCurBlockEx = recBlocks.New(HWADDR(startpc), (uptr)block_start);

	psxbranch = 0;

	s_pCurBlock->SetFnptr((uptr)block_start);
	s_psxBlockCycles = 0;

	// Reset recomp state
	psxpc = startpc;
	g_psxHasConstReg = g_psxFlushedConstReg = 1;
	_initArmGPRregs();

	// BIOS call interception
	if ((psxHu32(HW_ICFG) & 8) && (HWADDR(startpc) == 0xa0 || HWADDR(startpc) == 0xb0 || HWADDR(startpc) == 0xc0))
	{
		armEmitCall((const void*)psxBiosCall);
		// If bios handled it (returned nonzero), dispatch to next block
		armEmitCbnz(RWRET, iopDispatcherReg);
	}

	// --- Scan ahead to find block end ---
	i = startpc;
	s_nEndBlock = 0xffffffff;
	s_branchTo = -1;

	while (1)
	{
		BASEBLOCK* pblock = PSX_GETBLOCK(i);
		if (i != startpc && pblock->GetFnptr() != (uptr)iopJITCompile)
		{
			link_next_block = 1;
			s_nEndBlock = i;
			break;
		}

		psxRegs.code = iopMemRead32(i);

		switch (psxRegs.code >> 26)
		{
			case 0: // SPECIAL
				if (_Funct_ == 8 || _Funct_ == 9) // JR, JALR
				{
					s_nEndBlock = i + 8;
					goto StartRecomp;
				}
				break;

			case 1: // REGIMM
				if (_Rt_ == 0 || _Rt_ == 1 || _Rt_ == 16 || _Rt_ == 17)
				{
					s_branchTo = _Imm_ * 4 + i + 4;
					if (s_branchTo > startpc && s_branchTo < i)
						s_nEndBlock = s_branchTo;
					else
						s_nEndBlock = i + 8;
					goto StartRecomp;
				}
				break;

			case 2: // J
			case 3: // JAL
				s_branchTo = (_InstrucTarget_ << 2) | ((i + 4) & 0xf0000000);
				s_nEndBlock = i + 8;
				goto StartRecomp;

			case 4: case 5: case 6: case 7: // BEQ, BNE, BLEZ, BGTZ
				s_branchTo = _Imm_ * 4 + i + 4;
				if (s_branchTo > startpc && s_branchTo < i)
					s_nEndBlock = s_branchTo;
				else
					s_nEndBlock = i + 8;
				goto StartRecomp;
		}

		i += 4;
	}

StartRecomp:

	// Fast-forward detection (tight loops)
	s_nBlockFF = false;
	if (s_branchTo == startpc)
	{
		s_nBlockFF = true;
		for (i = startpc; i < s_nEndBlock; i += 4)
		{
			if (i != s_nEndBlock - 8)
			{
				if (iopMemRead32(i) != 0) // non-NOP
					s_nBlockFF = false;
			}
		}
	}

	// --- Instruction analysis pass ---
	{
		EEINST* pcur;
		if (s_nInstCacheSize < (s_nEndBlock - startpc) / 4 + 1)
		{
			free(s_pInstCache);
			s_nInstCacheSize = (s_nEndBlock - startpc) / 4 + 10;
			s_pInstCache = (EEINST*)malloc(sizeof(EEINST) * s_nInstCacheSize);
			pxAssert(s_pInstCache != NULL);
		}

		pcur = s_pInstCache + (s_nEndBlock - startpc) / 4;
		_recClearInst(pcur);
		pcur->info = 0;

		for (i = s_nEndBlock; i > startpc; i -= 4)
		{
			psxRegs.code = iopMemRead32(i - 4);
			pcur[-1] = pcur[0];
			rpsxpropBSC(pcur - 1, pcur);
			pcur--;
		}
	}

	// --- Code generation loop ---
	g_pCurInstInfo = s_pInstCache;
	while (!psxbranch && psxpc < s_nEndBlock)
	{
		psxRecompileNextInstruction(false, false);
	}

	pxAssert((psxpc - startpc) >> 2 <= 0xffff);
	s_pCurBlockEx->size = (psxpc - startpc) >> 2;

	if (!(psxpc & 0x10000000))
		g_psxMaxRecMem = std::max((psxpc & ~0xa0000000), g_psxMaxRecMem);

	if (psxbranch == 2)
	{
		// Indirect branch (JR/JALR) — already handled by psxSetBranchReg
		_psxFlushCall(FLUSH_EVERYTHING);
		iPsxBranchTest(0xffffffff, 1);
		armEmitJmp(iopDispatcherReg);
	}
	else
	{
		if (psxbranch)
			pxAssert(!link_next_block);
		else
		{
			// Fall-through: add cycles
			armAsm->Ldr(RXARG3, a64::MemOperand(RPSXREGS, (s64)offsetof(psxRegisters, cycle)));
			u32 bc = psxScaleBlockCycles();
			if (bc < 4096)
				armAsm->Add(RXARG3, RXARG3, bc);
			else
			{
				armAsm->Mov(RWARG4, bc);
				armAsm->Add(RXARG3, RXARG3, RXARG4);
			}
			armAsm->Str(RXARG3, a64::MemOperand(RPSXREGS, (s64)offsetof(psxRegisters, cycle)));

			armAsm->Ldr(RWARG1, a64::MemOperand(RPSXREGS, (s64)offsetof(psxRegisters, iopCycleEE)));
			if (bc * 8 < 4096)
				armAsm->Sub(RWARG1, RWARG1, bc * 8);
			else
			{
				armAsm->Mov(RWARG2, bc * 8);
				armAsm->Sub(RWARG1, RWARG1, RWARG2);
			}
			armAsm->Str(RWARG1, a64::MemOperand(RPSXREGS, (s64)offsetof(psxRegisters, iopCycleEE)));
		}

		if (link_next_block || !psxbranch)
		{
			pxAssert(psxpc == s_nEndBlock);
			_psxFlushCall(FLUSH_EVERYTHING);
			armAsm->Mov(RWARG1, psxpc);
			armAsm->Str(RWARG1, a64::MemOperand(RPSXREGS, (s64)offsetof(psxRegisters, pc)));
			// NOTE: recBlocks.Link removed — x86-style patching corrupts ARM64 code
			armEmitJmp(iopDispatcherReg);
			psxbranch = 3;
		}
	}

	// Finalize code block — resolves labels, flushes I-cache
	u8* block_end = armEndBlock();

	pxAssert(block_end < SysMemory::GetIOPRecEnd());

	s_pCurBlockEx->x86size = (u32)(block_end - block_start);

	Perf::iop.RegisterPC((void*)s_pCurBlockEx->fnptr, s_pCurBlockEx->x86size, s_pCurBlockEx->startpc);

	// NOTE: Use armGetAsmPtr() here, NOT armGetCurrentCodePointer(),
	// because armEndBlock() sets armAsm=nullptr.
	recPtr = armGetAsmPtr();

	pxAssert((g_psxHasConstReg & g_psxFlushedConstReg) == g_psxHasConstReg);

	s_pCurBlock = NULL;
	s_pCurBlockEx = NULL;
}

// ========================================================================
// R3000Acpu interface
// ========================================================================

R3000Acpu psxRec = {
	recReserve,
	recResetIOP,
	recExecuteBlock,
	recClearIOP,
	recShutdown,
};
