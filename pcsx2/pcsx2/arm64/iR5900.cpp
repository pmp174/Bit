// SPDX-FileCopyrightText: 2002-2026 PCSX2 Dev Team
// SPDX-License-Identifier: GPL-3.0+

// ARM64 EE Recompiler — Core dispatcher and block compilation
// Ported from x86/ix86-32/iR5900.cpp

#include "Common.h"

#include "CDVD/CDVD.h"
#include "DebugTools/Breakpoints.h"
#include "Elfheader.h"
#include "GS.h"
#include "Host.h"
#include "Memory.h"
#include "Patch.h"
#include "R3000A.h"
#include "R5900OpcodeTables.h"
#include "VMManager.h"
#include "vtlb.h"

#include "x86/BaseblockEx.h"
#include "arm64/iR5900.h"
#include "arm64/iR5900Analysis.h"
#include "x86/R5900_Profiler.h"

#include "common/AlignedMalloc.h"
#include "common/FastJmp.h"
#include "common/HeapArray.h"
#include "common/Perf.h"

using namespace R5900;

namespace a64 = vixl::aarch64;

// ========================================================================
// Global state
// ========================================================================

static bool eeRecNeedsReset = false;
static bool eeCpuExecuting = false;
static bool eeRecExitRequested = false;
static bool g_resetEeScalingStats = false;
static bool extraRam = false;

alignas(16) uptr recLUT[_64kb];
u32 hwLUT[_64kb];

// Convert virtual address to physical/hardware address via LUT
static __fi u32 HWADDR(u32 mem) { return hwLUT[mem >> 16] + mem; }

u32 s_nBlockCycles = 0;
bool s_nBlockInterlocked = false;

u32 pc;          // recompiler pc
int g_branch;    // set for branch
u32 target;      // branch target

alignas(16) GPR_reg64 g_cpuConstRegs[32];
u32 g_cpuHasConstReg, g_cpuFlushedConstReg;

bool g_cpuFlushedPC, g_cpuFlushedCode, g_recompilingDelaySlot, g_maySignalException;

u32 maxrecmem = 0;

static DynamicHeapArray<u8> recRAMCopy;
static DynamicHeapArray<BASEBLOCK, 4096> recLutReserve_RAM;
static BASEBLOCK* recRAM = nullptr;
static BASEBLOCK* recROM = nullptr;
static BASEBLOCK* recROM1 = nullptr;
static BASEBLOCK* recROM2 = nullptr;
static BASEBLOCK* recLutUnmapped = nullptr;
static BaseBlocks recBlocks;
static u8* recPtr = nullptr;
static u8* recPtrEnd = nullptr;
static EEINST* s_pInstCache = nullptr;
static u32 s_nInstCacheSize = 0;

static BASEBLOCK* s_pCurBlock = nullptr;
static BASEBLOCKEX* s_pCurBlockEx = nullptr;
static u32 s_nEndBlock = 0;
static u32 s_branchTo;
static bool s_nBlockFF;

// Saved state for branch compilation
static GPR_reg64 s_saveConstRegs[32];
static u32 s_saveHasConstReg = 0, s_saveFlushedConstReg = 0;
static bool s_savenBlockInterlocked = false;
static EEINST* s_saveInstInfo = nullptr;

// Profiler instance
namespace EE { eeProfiler Profiler; }

// Constant pool for the recompiler
static ArmConstantPool s_recConstPool;

// ========================================================================
// Dispatcher function pointers (generated at init)
// ========================================================================

static const void* DispatcherEvent = nullptr;
static const void* DispatcherReg = nullptr;
static const void* JITCompile = nullptr;
static const void* EnterRecompiledCode = nullptr;
static const void* ExitRecompiledCode = nullptr;
static const void* DispatchBlockDiscard = nullptr;
static const void* DispatchPageReset = nullptr;
static const void* UnmappedRecLUTPage = nullptr;

// ========================================================================
// Forward declarations
// ========================================================================

static void recRecompile(const u32 startpc);
static void recResetRaw();
static void recExitExecution();
static void recSafeExitExecution();
static void dyna_block_discard(u32 start, u32 sz);
static void dyna_page_reset(u32 start, u32 sz);

// ========================================================================
// Event test (called from DispatcherEvent)
// ========================================================================

static void recEventTest()
{
	_cpuEventTest_Shared();

	// Check both the standard exit flag (set by ExitExecution/SetState)
	// and the VM state directly (belt-and-suspenders for OpenEmu shutdown)
	if (eeRecExitRequested ||
		VMManager::GetState() != VMState::Running)
	{
		eeRecExitRequested = false;
		recExitExecution();
	}
}

// ========================================================================
// Error handler
// ========================================================================

static void recError(int errcode)
{
	Console.Error("EE Rec Error: %d (pc=0x%08X)", errcode, cpuRegs.pc);
	recExitExecution();
}

// ========================================================================
// ARM64 Dispatcher Generation
// ========================================================================

// Generate the JITCompile stub — called when a block hasn't been compiled yet.
// Calls recRecompile(cpuRegs.pc), then looks up the newly compiled block and jumps to it.
static const void* _DynGen_JITCompile()
{
	const void* entry = armGetCurrentCodePointer();

	// Load cpuRegs.pc into w0 (first arg)
	armAsm->Ldr(RWARG1, a64::MemOperand(RCPUSTATE, (s64)offsetof(cpuRegisters, pc)));

	// Call recRecompile(pc)
	armEmitCall((const void*)recRecompile);

	// After compilation, look up the block:
	// w0 = cpuRegs.pc
	armAsm->Ldr(RWARG1, a64::MemOperand(RCPUSTATE, (s64)offsetof(cpuRegisters, pc)));

	// x1 = recLUT[pc >> 16]
	armAsm->Lsr(RWARG2, RWARG1, 16);
	armAsm->Ldr(RXARG2, a64::MemOperand(RECLUTPTR, RXARG2, a64::LSL, 3));

	// x2 = base[pc / 4] (each BASEBLOCK is 8 bytes = pc * 2)
	armAsm->Add(RXARG2, RXARG2, a64::Operand(RXARG1, a64::UXTW, 1));

	// x2 = block->GetFnptr() (first field of BASEBLOCK)
	armAsm->Ldr(RXARG2, a64::MemOperand(RXARG2));

	// Jump to the compiled block
	armAsm->Br(RXARG2);

	return entry;
}

// Generate DispatcherReg — main dispatch loop.
// Looks up recLUT for the current PC and jumps to the block.
static const void* _DynGen_DispatcherReg()
{
	const void* entry = armGetCurrentCodePointer();

	// w0 = cpuRegs.pc
	armAsm->Ldr(RWARG1, a64::MemOperand(RCPUSTATE, (s64)offsetof(cpuRegisters, pc)));

	// x1 = recLUT[pc >> 16]
	armAsm->Lsr(RWARG2, RWARG1, 16);
	armAsm->Ldr(RXARG2, a64::MemOperand(RECLUTPTR, RXARG2, a64::LSL, 3));

	// x2 = base + pc * 2 (BASEBLOCK is 8 bytes, pc is in 4-byte units)
	armAsm->Add(RXARG2, RXARG2, a64::Operand(RXARG1, a64::UXTW, 1));

	// x2 = block fnptr
	armAsm->Ldr(RXARG2, a64::MemOperand(RXARG2));

	// Jump to block
	armAsm->Br(RXARG2);

	return entry;
}

// Generate DispatcherEvent — calls event test, then jumps to DispatcherReg.
static const void* _DynGen_DispatcherEvent()
{
	const void* entry = armGetCurrentCodePointer();

	// Call recEventTest
	armEmitCall((const void*)recEventTest);

	// Jump to DispatcherReg
	armEmitJmp(DispatcherReg);

	return entry;
}

// Generate EnterRecompiledCode — entry point from C++ into JIT code.
// Saves callee-saved registers, loads dedicated registers, jumps to DispatcherReg.
static const void* _DynGen_EnterRecompiledCode()
{
	const void* entry = armGetCurrentCodePointer();

	// Save callee-saved GPRs (x19-x28) and FPR (d8-d15)
	armBeginStackFrame(true);

	// Load dedicated registers
	// RCPUSTATE (x19) = &cpuRegs
	armMoveAddressToReg(RCPUSTATE, &cpuRegs);

	// RECLUTPTR (x21) = &recLUT
	armMoveAddressToReg(RECLUTPTR, recLUT);

	// RFASTMEMBASE (x20) = vtlb_private::vtlbdata.fastmem_base
	armMoveAddressToReg(RSCRATCHADDR, &vtlb_private::vtlbdata.fastmem_base);
	armAsm->Ldr(RFASTMEMBASE, a64::MemOperand(RSCRATCHADDR));

	// Jump to DispatcherReg
	armEmitJmp(DispatcherReg);

	return entry;
}

// Generate ExitRecompiledCode — restores callee-saved registers and returns.
static const void* _DynGen_ExitRecompiledCode()
{
	const void* entry = armGetCurrentCodePointer();

	// Restore callee-saved regs and return
	armEndStackFrame(true);
	armAsm->Ret();

	return entry;
}

// Generate DispatchBlockDiscard
static const void* _DynGen_DispatchBlockDiscard()
{
	const void* entry = armGetCurrentCodePointer();
	armEmitCall((const void*)dyna_block_discard);
	armEmitJmp(DispatcherReg);
	return entry;
}

// Generate DispatchPageReset
static const void* _DynGen_DispatchPageReset()
{
	const void* entry = armGetCurrentCodePointer();
	armEmitCall((const void*)dyna_page_reset);
	armEmitJmp(DispatcherReg);
	return entry;
}

// Generate UnmappedRecLUTPage — error handler for jumps to unmapped memory.
static const void* _DynGen_UnmappedRecLUTPage()
{
	const void* entry = armGetCurrentCodePointer();
	armAsm->Mov(RWARG1, 0);
	armEmitCall((const void*)recError);
	return entry;
}

// Master function: generate all dispatchers.
static void _DynGen_Dispatchers()
{
	// Start code block using the recompiler memory
	armStartBlock();

	// Hot paths first — DispatcherEvent and DispatcherReg
	DispatcherEvent = _DynGen_DispatcherEvent();
	DispatcherReg = _DynGen_DispatcherReg();

	// JIT compile stub
	JITCompile = _DynGen_JITCompile();

	// Entry/exit points
	EnterRecompiledCode = _DynGen_EnterRecompiledCode();
	ExitRecompiledCode = _DynGen_ExitRecompiledCode();

	// Block invalidation handlers
	DispatchBlockDiscard = _DynGen_DispatchBlockDiscard();
	DispatchPageReset = _DynGen_DispatchPageReset();
	UnmappedRecLUTPage = _DynGen_UnmappedRecLUTPage();

	// End the code block, flush I-cache
	armEndBlock();

	// Tell the block manager where JITCompile is
	recBlocks.SetJITCompile(JITCompile);

	// Register dispatchers with perf profiler
	Perf::any.Register(DispatcherReg, static_cast<u32>((const u8*)armGetCurrentCodePointer() - (const u8*)DispatcherReg), "EE Dispatcher");
}

// ========================================================================
// LUT Setup
// ========================================================================

static void ClearRecLUT(BASEBLOCK* base, int memsize)
{
	for (int i = 0; i < memsize / 4; i++)
		base[i].SetFnptr((uptr)JITCompile);
}

static DynamicHeapArray<BASEBLOCK, 4096> recLutUnmappedArr;
static size_t recLutEntries;

static void recReserveRAM()
{
	// One entry per possible call target
	recLutEntries = (Ps2MemSize::ExposedRam + Ps2MemSize::Rom + Ps2MemSize::Rom1 + Ps2MemSize::Rom2) / 4;

	if (recRAMCopy.size() != Ps2MemSize::ExposedRam)
		recRAMCopy.resize(Ps2MemSize::ExposedRam);

	if (recLutReserve_RAM.size() != recLutEntries)
		recLutReserve_RAM.resize(recLutEntries);

	// Allocate one LUT page of memory for unmapped pages to reference
	recLutUnmappedArr.resize(_64kb / 4);

	BASEBLOCK* basepos = recLutReserve_RAM.data();
	recRAM = basepos;
	basepos += (Ps2MemSize::ExposedRam / 4);
	recROM = basepos;
	basepos += (Ps2MemSize::Rom / 4);
	recROM1 = basepos;
	basepos += (Ps2MemSize::Rom1 / 4);
	recROM2 = basepos;

	BASEBLOCK* unmapped = recLutUnmappedArr.data();
	recLutUnmapped = unmapped;

	// Fill all LUT entries with unmapped page
	for (int i = 0; i < 0x10000; i++)
	{
		recLUT_SetPage(recLUT, hwLUT, unmapped, i, 0, 0);
	}

	// Map RAM (kuseg, kseg0, kseg1)
	for (int i = 0x0000; i < (int)(Ps2MemSize::ExposedRam / 0x10000); i++)
	{
		recLUT_SetPage(recLUT, hwLUT, recRAM, 0x0000, i, i);
		recLUT_SetPage(recLUT, hwLUT, recRAM, 0x2000, i, i);
		recLUT_SetPage(recLUT, hwLUT, recRAM, 0x3000, i, i);
		recLUT_SetPage(recLUT, hwLUT, recRAM, 0x8000, i, i);
		recLUT_SetPage(recLUT, hwLUT, recRAM, 0xa000, i, i);
	}

	// Map ROM
	for (int i = 0; i < (int)(Ps2MemSize::Rom / 0x10000); i++)
	{
		recLUT_SetPage(recLUT, hwLUT, recROM, 0x1fc0, i, i);
		recLUT_SetPage(recLUT, hwLUT, recROM, 0x9fc0, i, i);
		recLUT_SetPage(recLUT, hwLUT, recROM, 0xbfc0, i, i);
	}

	// Map ROM1
	for (int i = 0; i < (int)(Ps2MemSize::Rom1 / 0x10000); i++)
	{
		recLUT_SetPage(recLUT, hwLUT, recROM1, 0x1e00, i, i);
		recLUT_SetPage(recLUT, hwLUT, recROM1, 0x9e00, i, i);
		recLUT_SetPage(recLUT, hwLUT, recROM1, 0xbe00, i, i);
	}

	// Map ROM2
	for (int i = 0; i < (int)(Ps2MemSize::Rom2 / 0x10000); i++)
	{
		recLUT_SetPage(recLUT, hwLUT, recROM2, 0x1e40, i, i);
		recLUT_SetPage(recLUT, hwLUT, recROM2, 0x9e40, i, i);
		recLUT_SetPage(recLUT, hwLUT, recROM2, 0xbe40, i, i);
	}
}

// ========================================================================
// Recompiler Lifecycle
// ========================================================================

static void recReserve()
{
	recPtr = SysMemory::GetEERec();
	recPtrEnd = SysMemory::GetEERecEnd() - _64kb;

	// Set up constant pool at the end of the recompiler memory
	const u32 poolSize = _64kb;
	s_recConstPool.Init(recPtrEnd, poolSize);

	recReserveRAM();

	s_nInstCacheSize = 128;
	s_pInstCache = (EEINST*)malloc(sizeof(EEINST) * s_nInstCacheSize);
}

static void recResetRaw()
{
	if (!recRAM || CHECK_EXTRAMEM != extraRam)
	{
		recReserveRAM();
		extraRam = CHECK_EXTRAMEM;
	}

	EE::Profiler.Reset();

	// Reset code pointers and regenerate dispatchers
	recPtr = SysMemory::GetEERec();
	armSetAsmPtr(recPtr, recPtrEnd - recPtr, &s_recConstPool);

	_DynGen_Dispatchers();

	// Update recPtr to past the dispatchers
	recPtr = armGetAsmPtr();

	// Clear all LUT entries (set to JITCompile)
	ClearRecLUT(recLutReserve_RAM.data(),
		Ps2MemSize::ExposedRam + Ps2MemSize::Rom + Ps2MemSize::Rom1 + Ps2MemSize::Rom2);

	// Set unmapped pages
	for (int i = 0; i < (int)(_64kb / 4); i++)
		recLutUnmappedArr.data()[i].SetFnptr((uptr)UnmappedRecLUTPage);

	// Clear RAM copy and state
	if (recRAMCopy.data())
		std::memset(recRAMCopy.data(), 0, recRAMCopy.size());

	if (s_pInstCache)
		std::memset(s_pInstCache, 0, sizeof(EEINST) * s_nInstCacheSize);

	recBlocks.Reset();
	s_recConstPool.Reset();

	maxrecmem = 0;
	g_branch = 0;
	g_resetEeScalingStats = true;

	DevCon.WriteLn("ARM64 EE Recompiler reset");
}

static void recShutdown()
{
	recRAMCopy.deallocate();
	recLutReserve_RAM.deallocate();
	recLutUnmappedArr.deallocate();
	s_recConstPool.Destroy();

	recBlocks.Reset();
	recRAM = recROM = recROM1 = recROM2 = nullptr;

	safe_free(s_pInstCache);
	s_nInstCacheSize = 0;
	recPtr = nullptr;
	recPtrEnd = nullptr;

	DevCon.WriteLn("ARM64 EE Recompiler shutdown");
}

// ========================================================================
// Execution Control
// ========================================================================

static fastjmp_buf m_SetJmp_StateCheck;

static void recExitExecution()
{
	fastjmp_jmp(&m_SetJmp_StateCheck, 1);
}

static void recSafeExitExecution()
{
	eeRecExitRequested = true;
	if (!eeCpuExecuting)
		return;

	// Force an event test at the end of the current block
	cpuRegs.nextEventCycle = 0;
}

static void recResetEE()
{
	if (eeCpuExecuting)
	{
		eeRecNeedsReset = true;
		recSafeExitExecution();
	}
	else
	{
		recResetRaw();
	}
}

static void recStep()
{
	// Recompiler operates on blocks, not single instructions.
	// The debugger uses interpreter mode for single stepping.
}

static void recExecute()
{
	// Handle pending reset
	if (eeRecNeedsReset)
	{
		eeRecNeedsReset = false;
		recResetRaw();
	}

	// Set up the longjmp return point
	if (!fastjmp_set(&m_SetJmp_StateCheck))
	{
		eeCpuExecuting = true;

		// Enter the ARM64 JIT dispatcher
		((void(*)())EnterRecompiledCode)();

		// We should never get here — exit is via longjmp
		pxFailRel("EE Recompiler: EnterRecompiledCode returned unexpectedly");
	}

	// Control returns here via recExitExecution() / longjmp
	eeCpuExecuting = false;
	eeRecExitRequested = false;
	EE::Profiler.Print();
}

static void recCancelInstruction()
{
	// Similar to recSafeExitExecution but used during instruction execution
	recSafeExitExecution();
}

// ========================================================================
// Block Clear
// ========================================================================

static void recClear(u32 addr, u32 size)
{
	addr = HWADDR(addr);

	if ((addr) >= maxrecmem || !(recLUT[(addr) >> 16] + (addr & ~0xFFFFUL)))
		return;

	addr /= 4;
	u32 blockidx = recBlocks.LastIndex(addr);

	if (blockidx == (u32)-1)
		return;

	u32 lowerextent = (u32)-1, upperextent = 0;

	int found = 0;
	while (blockidx != (u32)-1)
	{
		BASEBLOCKEX* block = recBlocks[blockidx];
		if (!block)
			break;

		u32 blockstart = block->startpc / 4;
		u32 blockend = blockstart + block->size;

		if (blockend <= addr)
			break;

		if (blockstart < addr + size && blockend > addr)
		{
			if (block == s_pCurBlockEx)
			{
				blockidx--;
				continue;
			}

			lowerextent = std::min(lowerextent, blockstart);
			upperextent = std::max(upperextent, blockend);
			found++;
		}
		blockidx--;
	}

	if (!found)
		return;

	// Remove overlapping blocks and clear LUT
	blockidx = recBlocks.LastIndex(addr);
	int first = -1, last = -1;
	while (blockidx != (u32)-1)
	{
		BASEBLOCKEX* block = recBlocks[blockidx];
		if (!block)
			break;

		u32 blockstart = block->startpc / 4;
		u32 blockend = blockstart + block->size;

		if (blockend <= lowerextent)
			break;

		if (blockstart >= lowerextent && blockend <= upperextent)
		{
			if (block != s_pCurBlockEx)
			{
				if (first == -1 || (int)blockidx < first)
					first = blockidx;
				if (last == -1 || (int)blockidx > last)
					last = blockidx;
			}
		}
		blockidx--;
	}

	if (first != -1)
	{
		recBlocks.Remove(first, last);
	}

	for (u32 i = lowerextent; i < upperextent; i++)
	{
		BASEBLOCK* pblock = PC_GETBLOCK_(i * 4, recLUT);
		pblock->SetFnptr((uptr)JITCompile);
	}
}

// ========================================================================
// SYSCALL / BREAK
// ========================================================================

void R5900::Dynarec::OpcodeImpl::recSYSCALL()
{
	EE::Profiler.EmitOp(eeOpcode::SYSCALL);

	// Optimization: skip FlushCache / iFlushCache syscalls (no cache on JIT)
	if (GPR_IS_CONST1(3))
	{
		if (g_cpuConstRegs[3].UC[0] == 0x64 || g_cpuConstRegs[3].UC[0] == 0x68)
		{
			s_nBlockCycles += 5650;
			return;
		}
	}

	recCall(R5900::Interpreter::OpcodeImpl::SYSCALL);
	g_branch = 2;
}

void R5900::Dynarec::OpcodeImpl::recBREAK()
{
	EE::Profiler.EmitOp(eeOpcode::BREAK);
	recCall(R5900::Interpreter::OpcodeImpl::BREAK);
	g_branch = 2;
}

// ========================================================================
// Branch helpers
// ========================================================================

void SaveBranchState()
{
	memcpy(s_saveConstRegs, g_cpuConstRegs, sizeof(g_cpuConstRegs));
	s_saveHasConstReg = g_cpuHasConstReg;
	s_saveFlushedConstReg = g_cpuFlushedConstReg;
	s_savenBlockInterlocked = s_nBlockInterlocked;
	s_saveInstInfo = g_pCurInstInfo;

	memcpy(s_saveArmGPRregs, armGPRregs, sizeof(armGPRregs));
	memcpy(s_saveNeonregs, neonregs, sizeof(neonregs));
}

void LoadBranchState()
{
	memcpy(g_cpuConstRegs, s_saveConstRegs, sizeof(g_cpuConstRegs));
	g_cpuHasConstReg = s_saveHasConstReg;
	g_cpuFlushedConstReg = s_saveFlushedConstReg;
	s_nBlockInterlocked = s_savenBlockInterlocked;
	g_pCurInstInfo = s_saveInstInfo;

	memcpy(armGPRregs, s_saveArmGPRregs, sizeof(armGPRregs));
	memcpy(neonregs, s_saveNeonregs, sizeof(neonregs));
}

// ========================================================================
// Flush and call helpers
// ========================================================================

void iFlushCall(int flushtype)
{
	// Flush VU0 regs
	if (flushtype & FLUSH_FREE_VU0)
		_flushCOP2regs();

	// Free temp GPRs
	if (flushtype & FLUSH_FREE_TEMP_X86)
	{
		for (u32 i = 0; i < ARMGPR_COUNT; i++)
		{
			if (armGPRregs[i].inuse && armGPRregs[i].type == ARMTYPE_TEMP)
				_freeArmGPR(i);
		}
	}

	// Free non-temp GPRs
	if (flushtype & FLUSH_FREE_NONTEMP_X86)
	{
		for (u32 i = 0; i < ARMGPR_COUNT; i++)
		{
			if (armGPRregs[i].inuse && armGPRregs[i].type != ARMTYPE_TEMP)
				_freeArmGPR(i);
		}
	}

	// Flush all GPRs
	if (flushtype & FLUSH_ALL_X86)
		_flushArmGPRregs();

	// Flush or free NEON regs
	if (flushtype & FLUSH_FREE_XMM)
	{
		// Free implies flush + free
		for (u32 i = 0; i < ARMNEON_COUNT; i++)
		{
			if (neonregs[i].inuse)
				_freeNeonreg(i);
		}
	}
	else if (flushtype & FLUSH_FLUSH_XMM)
	{
		_flushNeonregs();
	}

	// Flush constants
	if (flushtype & FLUSH_CONSTANT_REGS)
		_flushConstRegs(false);

	// Flush PC
	if (flushtype & FLUSH_PC)
	{
		if (!g_cpuFlushedPC)
		{
			armAsm->Mov(RWARG1, pc);
			armAsm->Str(RWARG1, a64::MemOperand(RCPUSTATE, (s64)offsetof(cpuRegisters, pc)));
			g_cpuFlushedPC = true;
		}
	}

	// Flush opcode for interpreter
	if (flushtype & FLUSH_CODE)
	{
		if (!g_cpuFlushedCode)
		{
			armAsm->Mov(RWARG1, cpuRegs.code);
			armAsm->Str(RWARG1, a64::MemOperand(RCPUSTATE, (s64)offsetof(cpuRegisters, code)));
			g_cpuFlushedCode = true;
		}
	}
}

void recCall(void (*func)())
{
	iFlushCall(FLUSH_INTERPRETER);
	armEmitCall((const void*)func);
}

void recBranchCall(void (*func)())
{
	// Set nextEventCycle = cycle to force event test after the call
	armAsm->Ldr(RWARG1, a64::MemOperand(RCPUSTATE, (s64)offsetof(cpuRegisters, cycle)));
	armAsm->Str(RWARG1, a64::MemOperand(RCPUSTATE, (s64)offsetof(cpuRegisters, nextEventCycle)));

	recCall(func);
	g_branch = 2;
}

// ========================================================================
// Cycle scaling
// ========================================================================

static u32 scaleblockcycles_calculation()
{
	bool lowcycles = (s_nBlockCycles <= 40);

	s8 cyclerate = EmuConfig.Speedhacks.EECycleRate;
	u32 scale_cycles = 0;

	if (cyclerate == 0)
	{
		scale_cycles = s_nBlockCycles >> 3;
	}
	else if (cyclerate > 0)
	{
		// overclock
		if (cyclerate == 1)
			scale_cycles = s_nBlockCycles * 0.7;
		else
			scale_cycles = s_nBlockCycles >> cyclerate;
	}
	else
	{
		// underclock
		if (cyclerate == -1)
			scale_cycles = lowcycles ? (s_nBlockCycles + 2) : (s_nBlockCycles * 130 / 100);
		else
			scale_cycles = s_nBlockCycles * (1 << (-cyclerate));
	}

	return std::max<u32>(scale_cycles, 1u);
}

u32 scaleblockcycles_clear()
{
	u32 scaled = scaleblockcycles_calculation();
	s_nBlockCycles = 0;
	return scaled;
}

// ========================================================================
// Branch test — emitted at end of each block
// ========================================================================

static void iBranchTest(u32 newpc)
{
	u32 cycles = scaleblockcycles_clear();

	// Add cycles to cpuRegs.cycle
	armAsm->Ldr(RWARG1, a64::MemOperand(RCPUSTATE, (s64)offsetof(cpuRegisters, cycle)));
	if (a64::Assembler::IsImmAddSub(cycles))
	{
		armAsm->Add(RWARG1, RWARG1, cycles);
	}
	else
	{
		armAsm->Mov(RWARG2, cycles);
		armAsm->Add(RWARG1, RWARG1, RWARG2);
	}
	armAsm->Str(RWARG1, a64::MemOperand(RCPUSTATE, (s64)offsetof(cpuRegisters, cycle)));

	// Compare cycle vs nextEventCycle
	armAsm->Ldr(RWARG2, a64::MemOperand(RCPUSTATE, (s64)offsetof(cpuRegisters, nextEventCycle)));
	armAsm->Cmp(RWARG1, RWARG2);

	// If cycle < nextEventCycle, no event pending — dispatch next block
	if (newpc == 0xffffffff)
	{
		// Dynamic branch — jump to DispatcherReg
		armEmitCondBranch(a64::Condition::lo, DispatcherReg);
	}
	else
	{
		// Static branch — emit a conditional jump to DispatcherReg
		// (In the future, this could be block linking)
		armEmitCondBranch(a64::Condition::lo, DispatcherReg);
	}

	// cycle >= nextEventCycle — event pending, jump to event handler
	armEmitJmp(DispatcherEvent);
}

// ========================================================================
// SetBranchImm / SetBranchReg
// ========================================================================

void SetBranchImm(u32 imm)
{
	// Flush everything
	iFlushCall(FLUSH_EVERYTHING);

	// Write the branch target to cpuRegs.pc
	armAsm->Mov(RWARG1, imm);
	armAsm->Str(RWARG1, a64::MemOperand(RCPUSTATE, (s64)offsetof(cpuRegisters, pc)));

	iBranchTest(imm);
}

void SetBranchReg()
{
	// PC should already be in w0/RWRET from the branch instruction
	armAsm->Str(RWRET, a64::MemOperand(RCPUSTATE, (s64)offsetof(cpuRegisters, pc)));

	// Check alignment
	armAsm->Tst(RWRET, 3);
	a64::Label aligned;
	armAsm->B(a64::Condition::eq, &aligned);

	// Unaligned — error
	armAsm->Mov(RWARG1, 1);
	armEmitCall((const void*)recError);

	armAsm->Bind(&aligned);

	// Flush everything
	iFlushCall(FLUSH_EVERYTHING);

	iBranchTest(0xffffffff);
}

// ========================================================================
// Thunk management (for fastmem backpatching)
// ========================================================================

static u8* s_thunkPtr = nullptr;

u8* recBeginThunk()
{
	pxAssert(!armHasBlock());
	s_thunkPtr = armGetAsmPtr();
	armStartBlock();
	return s_thunkPtr;
}

u8* recEndThunk()
{
	pxAssert(armHasBlock());
	u8* end = armEndBlock();
	return end;
}

// ========================================================================
// TrySwapDelaySlot — simplified version
// ========================================================================

bool TrySwapDelaySlot(u32 rs, u32 rt, u32 rd, bool allow_loadstore)
{
	// For Phase 0, we don't attempt delay slot swapping.
	// This is a safe pessimization — all delay slots are compiled in order.
	return false;
}

// ========================================================================
// Per-instruction recompilation
// ========================================================================

void recompileNextInstruction(bool delayslot, bool swapped_delay_slot)
{
	// Apply patches if enabled
	Patch::ApplyDynamicPatches(pc);

	if (!delayslot)
	{
		// Clear register allocation flags
		_clearNeededArmGPRs();
		_clearNeededNeonregs();
	}

	// Fetch instruction
	cpuRegs.code = *(u32*)PSM(pc);
	EEINST* old_instinfo = g_pCurInstInfo;

	if (!delayslot)
	{
		pc += 4;
		g_cpuFlushedPC = false;
		g_cpuFlushedCode = false;
	}
	else
	{
		g_recompilingDelaySlot = true;
	}

	g_pCurInstInfo++;

	// Detect and handle NOPs
	const OPCODE& opcode = GetCurrentInstruction();
	if (cpuRegs.code == 0)
	{
		// NOP — add some cycles
		s_nBlockCycles += 9 * (2 - ((cpuRegs.IsDelaySlot && (cpuRegs.CP0.n.Status.b.BEV || cpuRegs.CP0.n.Config & 0x8)) ? 1 : 0));
	}
	else
	{
		// Compile the instruction via the opcode table
		s_nBlockCycles += opcode.cycles * (2 - ((cpuRegs.IsDelaySlot && (cpuRegs.CP0.n.Status.b.BEV || cpuRegs.CP0.n.Config & 0x8)) ? 1 : 0));
		opcode.recompile();
	}

	// Clear register allocation flags
	_clearNeededArmGPRs();
	_clearNeededNeonregs();

	if (delayslot)
	{
		pc += 4;
		g_recompilingDelaySlot = false;
	}

	if (swapped_delay_slot)
	{
		g_pCurInstInfo = old_instinfo;
	}
}

// ========================================================================
// Self-modifying code protection (simplified for Phase 0)
// ========================================================================

static void memory_protect_recompiled_code(u32 startpc, u32 numinsts)
{
	// For Phase 0, we don't implement manual protection.
	// Blocks are simply recompiled on cache clear.
}

// ========================================================================
// Block discard / page reset callbacks
// ========================================================================

static void dyna_block_discard(u32 start, u32 sz)
{
	DevCon.WriteLn("%.8X", start);
	recClear(start, sz);
}

static void dyna_page_reset(u32 start, u32 sz)
{
	recClear(start, sz);
}

// ========================================================================
// Main block compilation function
// ========================================================================

static void recRecompile(const u32 startpc)
{
	// Check if we need to reset the recompiler cache
	if (recPtr >= recPtrEnd)
	{
		DevCon.WriteLn("EE Recompiler cache full, resetting...");
		eeRecNeedsReset = true;
		recExitExecution();
		return;
	}

	// Handle pending reset
	if (eeRecNeedsReset)
	{
		eeRecNeedsReset = false;
		recResetRaw();
	}

	// Detect ELF entry point
	if (HWADDR(startpc) == VMManager::Internal::GetCurrentELFEntryPoint())
		VMManager::Internal::EntryPointCompilingOnCPUThread();

	// Align and start a new code block
	u8* block_start = armGetAsmPtr();
	armAlignAsmPtr();
	block_start = armGetAsmPtr();

	// Track the maximum recompiled memory address
	maxrecmem = std::max((startpc & ~0xa0000000), maxrecmem);

	// Get or create block metadata
	s_pCurBlock = PC_GETBLOCK_(startpc, recLUT);
	s_pCurBlockEx = recBlocks.New(startpc, (uptr)block_start);
	pxAssert(s_pCurBlockEx);

	// Initialize recompiler state
	pc = startpc;
	g_branch = 0;
	s_nBlockCycles = 0;
	s_nBlockInterlocked = false;
	g_cpuHasConstReg = 1; // Register 0 is always const
	g_cpuFlushedConstReg = 1;
	g_cpuConstRegs[0].UD[0] = 0;
	g_cpuFlushedPC = false;
	g_cpuFlushedCode = false;
	g_maySignalException = false;
	g_recompilingDelaySlot = false;

	_initArmGPRregs();
	_initNeonregs();

	// ==============================
	// Phase 1: Scan for block end
	// ==============================

	s_nEndBlock = startpc;
	s_branchTo = 0xFFFFFFFF;
	s_nBlockFF = false;

	u32 i = startpc;
	while (true)
	{
		cpuRegs.code = *(u32*)PSM(i);
		s_nEndBlock = i + 4;

		switch (cpuRegs.code >> 26)
		{
			case 0: // special
				if (_Funct_ == 8 || _Funct_ == 9) // JR, JALR
				{
					s_nEndBlock = i + 8;
					goto StartRecomp;
				}
				else if (_Funct_ == 12 || _Funct_ == 13) // SYSCALL, BREAK
				{
					s_nEndBlock = i + 4; // No delay slot.
					goto StartRecomp;
				}
				break;

			case 1: // regimm
				if (_Rt_ < 4 || (_Rt_ >= 16 && _Rt_ < 20))
				{
					// branches (BLTZ, BGEZ, BLTZL, BGEZL, BLTZAL, BGEZAL, BLTZALL, BGEZALL)
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

			// branches
			case 4: case 5: case 6: case 7:   // BEQ, BNE, BLEZ, BGTZ
			case 20: case 21: case 22: case 23: // BEQL, BNEL, BLEZL, BGTZL
				s_branchTo = _Imm_ * 4 + i + 4;
				if (s_branchTo > startpc && s_branchTo < i)
					s_nEndBlock = s_branchTo;
				else
					s_nEndBlock = i + 8;
				goto StartRecomp;

			case 16: // cp0
				if (_Rs_ == 16)
				{
					if (_Funct_ == 24) // eret
					{
						s_nEndBlock = i + 4;
						goto StartRecomp;
					}
				}
				// Fall through to COP1/COP2 branch check
				[[fallthrough]];

			case 17: // cp1
			case 18: // cp2
				if (_Rs_ == 8)
				{
					// BC1F, BC1T, BC1FL, BC1TL / BC2F, BC2T, BC2FL, BC2TL
					s_branchTo = _Imm_ * 4 + i + 4;
					if (s_branchTo > startpc && s_branchTo < i)
						s_nEndBlock = s_branchTo;
					else
						s_nEndBlock = i + 8;
					goto StartRecomp;
				}
				break;
		}

		i += 4;

		// Don't exceed page boundaries (4KB) or reasonable block size
		if ((i & 0xFFF) == 0 || (i - startpc) >= 0xFFC)
		{
			break;
		}
	}
StartRecomp:

	// ==============================
	// Phase 2: Instruction info back-propagation
	// ==============================

	u32 numinsts = (s_nEndBlock - startpc) / 4;
	if (numinsts == 0)
		numinsts = 1;

	// Ensure instruction cache is large enough
	if (numinsts > s_nInstCacheSize)
	{
		s_nInstCacheSize = numinsts + 128;
		s_pInstCache = (EEINST*)realloc(s_pInstCache, sizeof(EEINST) * s_nInstCacheSize);
	}

	// Clear and fill instruction info
	for (u32 j = 0; j < numinsts; j++)
		_recClearInst(&s_pInstCache[j]);

	// Back-propagate register usage
	{
		EEINST* prev = nullptr;
		for (int j = numinsts - 1; j >= 0; j--)
		{
			u32 instPC = startpc + j * 4;
			u32 code = *(u32*)PSM(instPC);
			recBackpropBSC(code, prev, &s_pInstCache[j]);
			prev = &s_pInstCache[j];
		}
	}

	// COP2 analysis passes
	bool has_cop2 = false;
	for (u32 j = 0; j < numinsts; j++)
	{
		if (s_pInstCache[j].info & (1 << 1)) // COP2 flag
		{
			has_cop2 = true;
			break;
		}
	}

	if (has_cop2)
	{
		R5900::COP2MicroFinishPass cop2_finish;
		cop2_finish.Run(startpc, s_nEndBlock, s_pInstCache);

		R5900::COP2FlagHackPass cop2_flags;
		cop2_flags.Run(startpc, s_nEndBlock, s_pInstCache);
	}

	// ==============================
	// Phase 3: Code generation
	// ==============================

	// Start emitting ARM64 code
	armStartBlock();

	// Set instruction info pointer
	g_pCurInstInfo = s_pInstCache;

	// Generate code for each instruction
	while (pc < s_nEndBlock && !g_branch)
	{
		recompileNextInstruction(false, false);
	}

	// ==============================
	// Phase 4: Block finalization
	// ==============================

	// Record block size
	s_pCurBlockEx->size = (pc - startpc) / 4;

	// Handle end of block
	if (g_branch == 2)
	{
		// SYSCALL / EI / etc — flush everything and do a branch test
		iFlushCall(FLUSH_EVERYTHING);
		iBranchTest(0xffffffff);
	}
	else if (!g_branch)
	{
		// No branch — fall through to next block
		iFlushCall(FLUSH_EVERYTHING);

		// Write the next PC
		armAsm->Mov(RWARG1, pc);
		armAsm->Str(RWARG1, a64::MemOperand(RCPUSTATE, (s64)offsetof(cpuRegisters, pc)));

		iBranchTest(pc);
	}

	// End the code block and flush I-cache
	u8* block_end = armEndBlock();

	// Record the native code size
	s_pCurBlockEx->x86size = (u32)(block_end - block_start);

	// Set the block's function pointer to the generated code
	s_pCurBlock->SetFnptr((uptr)block_start);

	// Copy recompiled PS2 memory to backup (for self-modifying code detection)
	if (startpc < Ps2MemSize::ExposedRam)
	{
		const u32 copysize = std::min(s_pCurBlockEx->size * 4, Ps2MemSize::ExposedRam - startpc);
		std::memcpy(&recRAMCopy[startpc], PSM(startpc), copysize);
	}

	// Register with perf profiler
	Perf::ee.RegisterPC(block_start, s_pCurBlockEx->x86size, startpc);

	s_pCurBlock = nullptr;
	s_pCurBlockEx = nullptr;
}

// ========================================================================
// Helper: _eeMoveGPRtoR (ARM64 version)
// ========================================================================

void _eeMoveGPRtoR(const vixl::aarch64::Register& to, int fromgpr)
{
	if (fromgpr == 0)
	{
		// $zero is always 0
		if (to.Is64Bits())
			armAsm->Mov(to, a64::xzr);
		else
			armAsm->Mov(to, a64::wzr);
	}
	else if (GPR_IS_CONST1(fromgpr))
	{
		// Known constant value
		if (to.Is64Bits())
			armAsm->Mov(to, (u64)g_cpuConstRegs[fromgpr].SD[0]);
		else
			armAsm->Mov(to, (u32)g_cpuConstRegs[fromgpr].UL[0]);
	}
	else
	{
		// Load from cpuRegs.GPR
		s64 offset = (s64)offsetof(cpuRegisters, GPR) + fromgpr * sizeof(GPR_reg64);
		if (to.Is64Bits())
			armAsm->Ldr(to, a64::MemOperand(RCPUSTATE, offset));
		else
			armAsm->Ldr(to, a64::MemOperand(RCPUSTATE, offset));
	}
}

// ========================================================================
// Helper: _eeFlushAllDirty
// ========================================================================

void _eeFlushAllDirty()
{
	_flushNeonregs();
	_flushArmGPRregs();
	_flushConstRegs(false);
}

// ========================================================================
// Stubs for register management used by instruction implementations
// ========================================================================

void _eeOnWriteReg(int reg, int signext)
{
	GPR_DEL_CONST(reg);
}

void _deleteEEreg(int reg, int flush)
{
	if (!reg)
		return;

	if (flush == DELETE_REG_FLUSH || flush == DELETE_REG_FLUSH_AND_FREE)
	{
		_deleteGPRtoArmGPR(reg, flush);
		_deleteGPRtoNeonreg(reg, flush);
	}
	else
	{
		_deleteGPRtoArmGPR(reg, flush);
		_deleteGPRtoNeonreg(reg, flush);
	}

	GPR_DEL_CONST(reg);
}

void _deleteEEreg128(int reg)
{
	if (!reg)
		return;

	_deleteGPRtoNeonreg(reg, DELETE_REG_FLUSH_AND_FREE);
	_deleteGPRtoArmGPR(reg, DELETE_REG_FREE_NO_WRITEBACK);
	GPR_DEL_CONST(reg);
}

void _flushEEreg(int reg, bool clear)
{
	if (!reg)
		return;

	// TODO: implement full register flushing when allocator is complete
}

int _eeTryRenameReg(int to, int from, int fromhost, int other, int xmminfo)
{
	// Phase 0: no register renaming
	return -1;
}

// ========================================================================
// Branch helper: recDoBranchImm
// ========================================================================

void R5900::Dynarec::recDoBranchImm(u32 branchTo, u32* jmpSkip, bool isLikely, bool swappedDelaySlot)
{
	// Phase 0 implementation: call interpreter for complex branches.
	// The simplified path writes branchTo to pc and does iBranchTest.

	SaveBranchState();

	// "Taken" path
	iFlushCall(FLUSH_EVERYTHING);
	armAsm->Mov(RWARG1, branchTo);
	armAsm->Str(RWARG1, a64::MemOperand(RCPUSTATE, (s64)offsetof(cpuRegisters, pc)));
	iBranchTest(branchTo);
}

// ========================================================================
// Recompile template stubs (used by instruction implementations)
// ========================================================================

// rd = rs op rt — with constant propagation
void eeRecompileCodeRC0(R5900FNPTR constcode, R5900FNPTR_INFO constscode, R5900FNPTR_INFO consttcode, R5900FNPTR_INFO noconstcode, int xmminfo)
{
	if (!_Rd_ && (xmminfo & XMMINFO_WRITED))
		return;

	if (GPR_IS_CONST2(_Rs_, _Rt_))
	{
		if (_Rd_ && (xmminfo & XMMINFO_WRITED))
		{
			_deleteGPRtoArmGPR(_Rd_, DELETE_REG_FREE_NO_WRITEBACK);
			_deleteGPRtoNeonreg(_Rd_, DELETE_REG_FLUSH_AND_FREE);
			GPR_SET_CONST(_Rd_);
		}
		constcode();
		return;
	}

	int info = 0;
	if (GPR_IS_CONST1(_Rs_))
	{
		info |= PROCESS_CONSTS;
		constscode(info);
	}
	else if (GPR_IS_CONST1(_Rt_))
	{
		info |= PROCESS_CONSTT;
		consttcode(info);
	}
	else
	{
		noconstcode(info);
	}
}

// rt = rs op imm16
void eeRecompileCodeRC1(R5900FNPTR constcode, R5900FNPTR_INFO noconstcode, int xmminfo)
{
	if (!_Rt_)
		return;

	if (GPR_IS_CONST1(_Rs_))
	{
		_deleteGPRtoArmGPR(_Rt_, DELETE_REG_FREE_NO_WRITEBACK);
		_deleteGPRtoNeonreg(_Rt_, DELETE_REG_FLUSH_AND_FREE);
		GPR_SET_CONST(_Rt_);
		constcode();
		return;
	}

	int info = 0;
	noconstcode(info);
}

// rd = rt op sa
void eeRecompileCodeRC2(R5900FNPTR constcode, R5900FNPTR_INFO noconstcode, int xmminfo)
{
	if (!_Rd_)
		return;

	if (GPR_IS_CONST1(_Rt_))
	{
		_deleteGPRtoArmGPR(_Rd_, DELETE_REG_FREE_NO_WRITEBACK);
		_deleteGPRtoNeonreg(_Rd_, DELETE_REG_FLUSH_AND_FREE);
		GPR_SET_CONST(_Rd_);
		constcode();
		return;
	}

	int info = 0;
	noconstcode(info);
}

// NEON (128-bit) register allocation for vector ops
int eeRecompileCodeNEON(int xmminfo)
{
	// Phase 0: return 0 (no allocation)
	return 0;
}

void eeFPURecompileCode(R5900FNPTR_INFO neoncode, R5900FNPTR fpucode, int xmminfo)
{
	// Phase 0: call the interpreter fallback
	recCall(fpucode);
}

// ========================================================================
// COP2 flag analysis helpers (used by iR5900Analysis.cpp)
// ========================================================================

int cop2flags(u32 code)
{
	if (code >> 26 != 022)
		return 0; // not COP2
	if ((code >> 25 & 1) == 0)
		return 0; // a branch or transfer instruction

	switch (code >> 2 & 15)
	{
		case 15:
			switch (code >> 6 & 0x1f)
			{
				case 4: // ITOF*
				case 5: // FTOI*
				case 12: // MOVE MR32
				case 13: // LQI SQI LQD SQD
				case 15: // MTIR MFIR ILWR ISWR
				case 16: // RNEXT RGET RINIT RXOR
					return 0;
				case 7: // MULAq, ABS, MULAi, CLIP
					if ((code & 3) == 1) // ABS
						return 0;
					if ((code & 3) == 3) // CLIP
						return 4;
					return 3;
				case 11: // SUBA, MSUBA, OPMULA, NOP
					if ((code & 3) == 3) // NOP
						return 0;
					return 3;
				case 14: // DIV, SQRT, RSQRT, WAITQ
					if ((code & 3) == 3) // WAITQ
						return 0;
					return 1;
				default:
					break;
			}
			break;
		case 4: // MAXbc
		case 5: // MINbc
		case 12: // IADD, ISUB, IADDI
		case 13: // IAND, IOR
		case 14: // VCALLMS, VCALLMSR
			return 0;
		case 7:
			if ((code & 1) == 1) // MAXi, MINIi
				return 0;
			return 3;
		case 10:
			if ((code & 3) == 3) // MAX
				return 0;
			return 3;
		case 11:
			if ((code & 3) == 3) // MINI
				return 0;
			return 3;
		default:
			break;
	}
	return 3;
}

// ========================================================================
// R5900cpu interface — the recCpu struct
// ========================================================================

R5900cpu recCpu = {
	recReserve,
	recShutdown,
	recResetEE,
	recStep,
	recExecute,
	recSafeExitExecution,
	recCancelInstruction,
	recClear
};
