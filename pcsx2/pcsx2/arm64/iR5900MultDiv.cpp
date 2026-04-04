// SPDX-FileCopyrightText: 2002-2026 PCSX2 Dev Team
// SPDX-License-Identifier: GPL-3.0+

// ARM64 EE Recompiler — Native multiply/divide instructions (Phase 1)
//
// MULT/MULTU: 32×32 → 64 (HI:LO)
// DIV/DIVU: 32÷32 → quotient(LO), remainder(HI)
// MADD/MADDU: HI:LO += rs × rt
// MULT1/MULTU1/DIV1/DIVU1/MADD1/MADDU1: Same ops using pipeline 1 (HI.SD[1]:LO.SD[1])
//
// PS2 EE HI/LO are 128-bit: lower 64 bits = pipe 0, upper 64 bits = pipe 1

#include "Common.h"
#include "R5900OpcodeTables.h"
#include "arm64/iR5900.h"
#include "arm64/iCore.h"

namespace a64 = vixl::aarch64;

namespace Interp = R5900::Interpreter::OpcodeImpl;

namespace R5900 {
namespace Dynarec {
namespace OpcodeImpl {

// ========================================================================
// Helpers for HI/LO access (pipe 0 uses SD[0], pipe 1 uses SD[1])
// ========================================================================

static s64 hiOffset(bool pipe1) { return (s64)offsetof(cpuRegisters, HI.SD[pipe1 ? 1 : 0]); }
static s64 loOffset(bool pipe1) { return (s64)offsetof(cpuRegisters, LO.SD[pipe1 ? 1 : 0]); }

// Store x4 to HI, x5 to LO
static void storeHILO(bool pipe1)
{
	armAsm->Str(a64::x4, a64::MemOperand(RCPUSTATE, hiOffset(pipe1)));
	armAsm->Str(a64::x5, a64::MemOperand(RCPUSTATE, loOffset(pipe1)));
}

// Load HI→x4, LO→x5
static void loadHILO(bool pipe1)
{
	armAsm->Ldr(a64::x4, a64::MemOperand(RCPUSTATE, hiOffset(pipe1)));
	armAsm->Ldr(a64::x5, a64::MemOperand(RCPUSTATE, loOffset(pipe1)));
}

// Flush NEON allocations for HI and LO
static void flushHILONeon()
{
	_deleteGPRtoNeonreg(XMMGPR_HI, DELETE_REG_FLUSH_AND_FREE);
	_deleteGPRtoNeonreg(XMMGPR_LO, DELETE_REG_FLUSH_AND_FREE);
}

// Write Rd from LO if Rd is specified (PS2 extension: MULT/MADD can optionally write Rd)
static void writeRdFromLO(bool pipe1)
{
	if (!_Rd_)
		return;

	_addNeededGPRtoArmGPR(_Rd_);
	const int rd = _allocArmGPR(ARMTYPE_GPR, _Rd_, MODE_WRITE);
	armAsm->Ldr(armXRegister(rd), a64::MemOperand(RCPUSTATE, loOffset(pipe1)));
	_clearNeededArmGPRs();
}

// ========================================================================
// MULT / MULTU — HI:LO = rs[31:0] * rt[31:0]
// ========================================================================

static void recMULTsuper(bool sign, bool pipe1)
{
	flushHILONeon();

	_addNeededGPRtoArmGPR(_Rs_);
	_addNeededGPRtoArmGPR(_Rt_);
	const int rs = _allocArmGPR(ARMTYPE_GPR, _Rs_, MODE_READ);
	const int rt = _allocArmGPR(ARMTYPE_GPR, _Rt_, MODE_READ);

	// ARM64 smull/umull: 32×32 → 64 natively
	if (sign)
		armAsm->Smull(a64::x5, armWRegister(rs), armWRegister(rt));
	else
		armAsm->Umull(a64::x5, armWRegister(rs), armWRegister(rt));

	// Split: HI = sign_ext(upper 32), LO = sign_ext(lower 32)
	armAsm->Asr(a64::x4, a64::x5, 32);  // HI
	armAsm->Sxtw(a64::x5, a64::w5);     // LO

	storeHILO(pipe1);
	_clearNeededArmGPRs();

	writeRdFromLO(pipe1);
}

void recMULT()
{
	EE::Profiler.EmitOp(eeOpcode::MULT);
	recMULTsuper(true, false);
}

void recMULTU()
{
	EE::Profiler.EmitOp(eeOpcode::MULTU);
	recMULTsuper(false, false);
}

void recMULT1()
{
	EE::Profiler.EmitOp(eeOpcode::MULT1);
	recMULTsuper(true, true);
}

void recMULTU1()
{
	EE::Profiler.EmitOp(eeOpcode::MULTU1);
	recMULTsuper(false, true);
}

// ========================================================================
// DIV / DIVU — LO = rs / rt, HI = rs % rt
// ========================================================================

static void recDIVsuper(bool sign, bool pipe1)
{
	flushHILONeon();

	_addNeededGPRtoArmGPR(_Rs_);
	_addNeededGPRtoArmGPR(_Rt_);
	const int rs = _allocArmGPR(ARMTYPE_GPR, _Rs_, MODE_READ);
	const int rt = _allocArmGPR(ARMTYPE_GPR, _Rt_, MODE_READ);

	a64::Label skip, done;

	// Check divide by zero
	armAsm->Cbz(armWRegister(rt), &skip);

	// Perform division
	if (sign)
		armAsm->Sdiv(a64::w5, armWRegister(rs), armWRegister(rt));
	else
		armAsm->Udiv(a64::w5, armWRegister(rs), armWRegister(rt));

	// Remainder = rs - (quotient * rt)
	armAsm->Msub(a64::w4, a64::w5, armWRegister(rt), armWRegister(rs));

	// Sign-extend both
	armAsm->Sxtw(a64::x4, a64::w4);  // HI = remainder
	armAsm->Sxtw(a64::x5, a64::w5);  // LO = quotient

	storeHILO(pipe1);
	armAsm->B(&done);

	// Divide by zero handler
	armAsm->Bind(&skip);
	if (sign)
	{
		// Signed: LO = (rs >= 0) ? -1 : 1, HI = sign_ext(rs)
		armAsm->Cmp(armWRegister(rs), 0);
		armAsm->Mov(a64::x5, (s64)-1);
		armAsm->Mov(a64::x6, (s64)1);
		armAsm->Csel(a64::x5, a64::x5, a64::x6, a64::ge);
	}
	else
	{
		// Unsigned: LO = -1
		armAsm->Mov(a64::x5, (s64)(s32)-1);
	}
	armAsm->Sxtw(a64::x4, armWRegister(rs));  // HI = sign_ext(rs)
	storeHILO(pipe1);

	armAsm->Bind(&done);
	_clearNeededArmGPRs();
}

void recDIV()
{
	EE::Profiler.EmitOp(eeOpcode::DIV);
	recDIVsuper(true, false);
}

void recDIVU()
{
	EE::Profiler.EmitOp(eeOpcode::DIVU);
	recDIVsuper(false, false);
}

void recDIV1()
{
	EE::Profiler.EmitOp(eeOpcode::DIV1);
	recDIVsuper(true, true);
}

void recDIVU1()
{
	EE::Profiler.EmitOp(eeOpcode::DIVU1);
	recDIVsuper(false, true);
}

// ========================================================================
// MADD / MADDU — HI:LO += rs * rt
// ========================================================================

static void recMADDsuper(bool sign, bool pipe1)
{
	flushHILONeon();

	_addNeededGPRtoArmGPR(_Rs_);
	_addNeededGPRtoArmGPR(_Rt_);
	const int rs = _allocArmGPR(ARMTYPE_GPR, _Rs_, MODE_READ);
	const int rt = _allocArmGPR(ARMTYPE_GPR, _Rt_, MODE_READ);

	// Load current HI:LO
	loadHILO(pipe1);

	// Reconstruct 64-bit accumulator from HI[31:0]:LO[31:0]
	// x6 = (HI[31:0] << 32) | LO[31:0]
	armAsm->Lsl(a64::x6, a64::x4, 32);
	armAsm->Bfxil(a64::x6, a64::x5, 0, 32);

	// Multiply-accumulate
	if (sign)
		armAsm->Smull(a64::x7, armWRegister(rs), armWRegister(rt));
	else
		armAsm->Umull(a64::x7, armWRegister(rs), armWRegister(rt));

	armAsm->Add(a64::x6, a64::x6, a64::x7);

	// Split back: HI = sign_ext(upper 32), LO = sign_ext(lower 32)
	armAsm->Asr(a64::x4, a64::x6, 32);
	armAsm->Sxtw(a64::x5, a64::w6);

	storeHILO(pipe1);
	_clearNeededArmGPRs();

	writeRdFromLO(pipe1);
}

void recMADD()
{
	EE::Profiler.EmitOp(eeOpcode::MADD);
	recMADDsuper(true, false);
}

void recMADDU()
{
	EE::Profiler.EmitOp(eeOpcode::MADDU);
	recMADDsuper(false, false);
}

void recMADD1()
{
	EE::Profiler.EmitOp(eeOpcode::MADD1);
	recMADDsuper(true, true);
}

void recMADDU1()
{
	EE::Profiler.EmitOp(eeOpcode::MADDU1);
	recMADDsuper(false, true);
}

} // namespace OpcodeImpl
} // namespace Dynarec
} // namespace R5900
