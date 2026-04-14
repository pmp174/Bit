// SPDX-FileCopyrightText: 2002-2026 PCSX2 Dev Team
// SPDX-License-Identifier: GPL-3.0+

// ARM64 VU Micro-Mode Recompiler (Phase 5 — Interpreter Fallback)
//
// Provides recMicroVU0/recMicroVU1 implementations for ARM64.
// Currently wraps the interpreter for actual VU instruction execution,
// providing the proper recompiler lifecycle and class interface.
// This enables VU recompiler selection in VMManager and the MTVU
// (Multi-Threaded VU1) speedhack. Native ARM64 NEON codegen for
// VU instructions can be added incrementally in future phases.

#include "Common.h"
#include "VUmicro.h"
#include "MTVU.h"
#include "Dmac.h"
#include "R5900.h"

#include <cfenv>

// --------------------------------------------------------------------------------------
//  Global Instances
// --------------------------------------------------------------------------------------

recMicroVU0 CpuMicroVU0;
recMicroVU1 CpuMicroVU1;

// --------------------------------------------------------------------------------------
//  Constructors
// --------------------------------------------------------------------------------------

recMicroVU0::recMicroVU0()
{
	m_Idx = 0;
	IsInterpreter = false;
}

recMicroVU1::recMicroVU1()
{
	m_Idx = 1;
	IsInterpreter = false;
}

// --------------------------------------------------------------------------------------
//  Reserve / Shutdown
// --------------------------------------------------------------------------------------

void recMicroVU0::Reserve()
{
	// ARM64 VU0 rec: interpreter-fallback mode, no JIT cache needed yet
	DevCon.WriteLn("ARM64 microVU0: Reserve (interpreter-fallback)");
}

void recMicroVU1::Reserve()
{
	DevCon.WriteLn("ARM64 microVU1: Reserve (interpreter-fallback)");
	vu1Thread.Open();
}

void recMicroVU0::Shutdown()
{
	DevCon.WriteLn("ARM64 microVU0: Shutdown");
}

void recMicroVU1::Shutdown()
{
	if (vu1Thread.IsOpen())
		vu1Thread.WaitVU();
	DevCon.WriteLn("ARM64 microVU1: Shutdown");
}

// --------------------------------------------------------------------------------------
//  Reset
// --------------------------------------------------------------------------------------

void recMicroVU0::Reset()
{
	DevCon.WriteLn("ARM64 microVU0: Reset");
	VU0.nextBlockCycles = 0;
	VU0.fmacwritepos = 0;
	VU0.fmacreadpos = 0;
	VU0.fmaccount = 0;
	VU0.ialuwritepos = 0;
	VU0.ialureadpos = 0;
	VU0.ialucount = 0;
}

void recMicroVU1::Reset()
{
	vu1Thread.WaitVU();
	vu1Thread.Get_MTVUChanges();
	DevCon.WriteLn("ARM64 microVU1: Reset");
	VU1.nextBlockCycles = 0;
	VU1.fmacwritepos = 0;
	VU1.fmacreadpos = 0;
	VU1.fmaccount = 0;
	VU1.ialuwritepos = 0;
	VU1.ialureadpos = 0;
	VU1.ialucount = 0;
}

// --------------------------------------------------------------------------------------
//  SetStartPC
// --------------------------------------------------------------------------------------

void recMicroVU0::SetStartPC(u32 startPC)
{
	VU0.start_pc = startPC;
}

void recMicroVU1::SetStartPC(u32 startPC)
{
	VU1.start_pc = startPC;
}

// --------------------------------------------------------------------------------------
//  Step (debug single-step)
// --------------------------------------------------------------------------------------

void recMicroVU0::Step()
{
	vu0Exec(&VU0);
}

void recMicroVU1::Step()
{
	vu1Exec(&VU1);
}

// --------------------------------------------------------------------------------------
//  Execute — Main VU execution entry point
// --------------------------------------------------------------------------------------
// ARM64 interpreter-fallback: calls vu0Exec/vu1Exec per instruction pair.
// This matches the interpreter's execution loop but goes through the
// recompiler class interface, enabling VMManager to select this as the
// VU CPU provider and supporting the MTVU thread for VU1.

void recMicroVU0::Execute(u32 cycles)
{
	VU0.flags &= ~VUFLAG_MFLAGSET;

	if (!(VU0.VI[REG_VPU_STAT].UL & 1))
		return;

	VU0.VI[REG_TPC].UL <<= 3;

	const FPControlRegisterBackup fpcr_backup(EmuConfig.Cpu.VU0FPCR);
	u64 startcycles = VU0.cycle;

	while ((VU0.cycle - startcycles) < cycles)
	{
		if (!(VU0.VI[REG_VPU_STAT].UL & 0x1))
		{
			if (VU0.branch)
			{
				VU0.VI[REG_TPC].UL = VU0.branchpc;
				VU0.branch = 0;
			}
			break;
		}
		if (VU0.flags & VUFLAG_MFLAGSET)
			break;

		vu0Exec(&VU0);
	}

	VU0.VI[REG_TPC].UL >>= 3;

	// D/T flag interrupt check
	if (VU0.flags & 0x4)
	{
		VU0.flags &= ~0x4;
		hwIntcIrq(INTC_VU0);
	}

	VU0.nextBlockCycles = (VU0.cycle - cpuRegs.cycle) + 1;
}

void recMicroVU1::Execute(u32 cycles)
{
	if (!THREAD_VU1)
	{
		if (!(VU0.VI[REG_VPU_STAT].UL & 0x100))
			return;
	}

	VU1.VI[REG_TPC].UL <<= 3;

	const FPControlRegisterBackup fpcr_backup(EmuConfig.Cpu.VU1FPCR);
	u64 startcycles = VU1.cycle;

	while ((VU1.cycle - startcycles) < cycles)
	{
		if (!(VU0.VI[REG_VPU_STAT].UL & 0x100))
		{
			if (VU1.branch)
			{
				VU1.VI[REG_TPC].UL = VU1.branchpc;
				VU1.branch = 0;
			}
			break;
		}

		vu1Exec(&VU1);
	}

	VU1.VI[REG_TPC].UL >>= 3;

	// D/T flag interrupt check
	if (VU1.flags & 0x4 && !THREAD_VU1)
	{
		VU1.flags &= ~0x4;
		hwIntcIrq(INTC_VU1);
	}

	VU1.nextBlockCycles = (VU1.cycle - cpuRegs.cycle) + 1;
}

// --------------------------------------------------------------------------------------
//  Clear — Invalidate cached blocks
// --------------------------------------------------------------------------------------

void recMicroVU0::Clear(u32 addr, u32 size)
{
	// No block cache to invalidate yet (interpreter-fallback)
}

void recMicroVU1::Clear(u32 addr, u32 size)
{
	// No block cache to invalidate yet (interpreter-fallback)
}

// --------------------------------------------------------------------------------------
//  ResumeXGkick (VU1 only)
// --------------------------------------------------------------------------------------

void recMicroVU1::ResumeXGkick()
{
	if (!(VU0.VI[REG_VPU_STAT].UL & 0x100))
		return;
	// XGkick resume handled by interpreter execution loop
}

// --------------------------------------------------------------------------------------
//  Save State — VU JIT Freeze
// --------------------------------------------------------------------------------------
// This overrides the stub in RecStubs.cpp / recVTLB.cpp.
// Since we don't have full microVU pipeline state, freeze empty data
// to maintain save state format compatibility.

bool SaveStateBase::vuJITFreeze()
{
	if (IsSaving())
		vu1Thread.WaitVU();

	// Size must match microRegInfo (96 bytes) for save state compatibility
	std::array<u8, 96> vuState0{};
	std::array<u8, 96> vuState1{};
	Freeze(vuState0);
	Freeze(vuState1);
	return IsOkay();
}
