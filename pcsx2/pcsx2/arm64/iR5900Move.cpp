// SPDX-FileCopyrightText: 2002-2026 PCSX2 Dev Team
// SPDX-License-Identifier: GPL-3.0+

// ARM64 EE Recompiler — Native move instructions (Phase 1)
//
// MFHI/MTHI, MFLO/MTLO: Move from/to HI/LO registers
// MOVZ/MOVN: Conditional move (use "temp" suffix due to ARM64 mnemonic conflict)
// MFSA/MTSA: Move from/to SA (shift amount) register
// MTSAB/MTSAH: Move to SA with byte/halfword alignment
// MFHI1/MTHI1, MFLO1/MTLO1: Same for pipeline 1

#include "Common.h"
#include "R5900OpcodeTables.h"
#include "arm64/iR5900.h"
#include "arm64/iCore.h"

namespace a64 = vixl::aarch64;

namespace Interp = R5900::Interpreter::OpcodeImpl;

namespace R5900 {
namespace Dynarec {
namespace OpcodeImpl {

// HI/LO offsets: pipe 0 = SD[0], pipe 1 = SD[1]
static s64 hiOff(bool pipe1) { return (s64)offsetof(cpuRegisters, HI.SD[pipe1 ? 1 : 0]); }
static s64 loOff(bool pipe1) { return (s64)offsetof(cpuRegisters, LO.SD[pipe1 ? 1 : 0]); }

// ========================================================================
// MFHI  —  rd = HI
// ========================================================================

static void recMFHIsuper(bool pipe1)
{
	if (!_Rd_)
		return;

	_addNeededGPRtoArmGPR(_Rd_);
	const int rd = _allocArmGPR(ARMTYPE_GPR, _Rd_, MODE_WRITE);
	armAsm->Ldr(armXRegister(rd), a64::MemOperand(RCPUSTATE, hiOff(pipe1)));
	_clearNeededArmGPRs();
}

void recMFHI()
{
	EE::Profiler.EmitOp(eeOpcode::MFHI);
	recMFHIsuper(false);
}

void recMFHI1()
{
	EE::Profiler.EmitOp(eeOpcode::MFHI1);
	recMFHIsuper(true);
}

// ========================================================================
// MTHI  —  HI = rs
// ========================================================================

static void recMTHIsuper(bool pipe1)
{
	if (GPR_IS_CONST1(_Rs_))
	{
		const s64 val = g_cpuConstRegs[_Rs_].SD[0];
		armAsm->Mov(a64::x4, val);
		armAsm->Str(a64::x4, a64::MemOperand(RCPUSTATE, hiOff(pipe1)));
	}
	else
	{
		_addNeededGPRtoArmGPR(_Rs_);
		const int rs = _allocArmGPR(ARMTYPE_GPR, _Rs_, MODE_READ);
		armAsm->Str(armXRegister(rs), a64::MemOperand(RCPUSTATE, hiOff(pipe1)));
		_clearNeededArmGPRs();
	}
}

void recMTHI()
{
	EE::Profiler.EmitOp(eeOpcode::MTHI);
	recMTHIsuper(false);
}

void recMTHI1()
{
	EE::Profiler.EmitOp(eeOpcode::MTHI1);
	recMTHIsuper(true);
}

// ========================================================================
// MFLO  —  rd = LO
// ========================================================================

static void recMFLOsuper(bool pipe1)
{
	if (!_Rd_)
		return;

	_addNeededGPRtoArmGPR(_Rd_);
	const int rd = _allocArmGPR(ARMTYPE_GPR, _Rd_, MODE_WRITE);
	armAsm->Ldr(armXRegister(rd), a64::MemOperand(RCPUSTATE, loOff(pipe1)));
	_clearNeededArmGPRs();
}

void recMFLO()
{
	EE::Profiler.EmitOp(eeOpcode::MFLO);
	recMFLOsuper(false);
}

void recMFLO1()
{
	EE::Profiler.EmitOp(eeOpcode::MFLO1);
	recMFLOsuper(true);
}

// ========================================================================
// MTLO  —  LO = rs
// ========================================================================

static void recMTLOsuper(bool pipe1)
{
	if (GPR_IS_CONST1(_Rs_))
	{
		const s64 val = g_cpuConstRegs[_Rs_].SD[0];
		armAsm->Mov(a64::x4, val);
		armAsm->Str(a64::x4, a64::MemOperand(RCPUSTATE, loOff(pipe1)));
	}
	else
	{
		_addNeededGPRtoArmGPR(_Rs_);
		const int rs = _allocArmGPR(ARMTYPE_GPR, _Rs_, MODE_READ);
		armAsm->Str(armXRegister(rs), a64::MemOperand(RCPUSTATE, loOff(pipe1)));
		_clearNeededArmGPRs();
	}
}

void recMTLO()
{
	EE::Profiler.EmitOp(eeOpcode::MTLO);
	recMTLOsuper(false);
}

void recMTLO1()
{
	EE::Profiler.EmitOp(eeOpcode::MTLO1);
	recMTLOsuper(true);
}

// ========================================================================
// MOVZ  —  rd = rs if rt == 0
// Uses "MOVZtemp" naming because MOVZ conflicts with ARM64 mnemonic.
// The EERECOMPILE_CODERC0 macro generates recMOVZtemp() which is called
// by the public recMOVZ() below.
// ========================================================================

static void recMOVZtemp_const()
{
	g_cpuConstRegs[_Rd_].UD[0] = g_cpuConstRegs[_Rs_].UD[0];
}

static void recMOVZtemp_consts(int info)
{
	_addNeededGPRtoArmGPR(_Rt_);
	_addNeededGPRtoArmGPR(_Rd_);
	const int rt = _allocArmGPR(ARMTYPE_GPR, _Rt_, MODE_READ);
	const int rd = _allocArmGPR(ARMTYPE_GPR, _Rd_, MODE_READ | MODE_WRITE);

	const s64 cval = g_cpuConstRegs[_Rs_].SD[0];

	a64::Label skip;
	armAsm->Cbnz(armXRegister(rt), &skip);
	armAsm->Mov(armXRegister(rd), cval);
	armAsm->Bind(&skip);
	_clearNeededArmGPRs();
}

static void recMOVZtemp_constt(int info)
{
	// Rt is const — if rt == 0, unconditionally copy rs to rd
	if (g_cpuConstRegs[_Rt_].UD[0] != 0)
		return;

	_addNeededGPRtoArmGPR(_Rs_);
	_addNeededGPRtoArmGPR(_Rd_);
	const int rs = _allocArmGPR(ARMTYPE_GPR, _Rs_, MODE_READ);
	const int rd = _allocArmGPR(ARMTYPE_GPR, _Rd_, MODE_WRITE);

	if (rd != rs)
		armAsm->Mov(armXRegister(rd), armXRegister(rs));
	_clearNeededArmGPRs();
}

static void recMOVZtemp_(int info)
{
	_addNeededGPRtoArmGPR(_Rs_);
	_addNeededGPRtoArmGPR(_Rt_);
	_addNeededGPRtoArmGPR(_Rd_);
	const int rs = _allocArmGPR(ARMTYPE_GPR, _Rs_, MODE_READ);
	const int rt = _allocArmGPR(ARMTYPE_GPR, _Rt_, MODE_READ);
	const int rd = _allocArmGPR(ARMTYPE_GPR, _Rd_, MODE_READ | MODE_WRITE);

	armAsm->Cmp(armXRegister(rt), a64::xzr);
	armAsm->Csel(armXRegister(rd), armXRegister(rs), armXRegister(rd), a64::eq);
	_clearNeededArmGPRs();
}

EERECOMPILE_CODERC0(MOVZtemp, XMMINFO_WRITED | XMMINFO_READD | XMMINFO_READS | XMMINFO_READT);

void recMOVZ()
{
	if (_Rs_ == _Rd_)
		return;

	if (GPR_IS_CONST1(_Rt_) && g_cpuConstRegs[_Rt_].UD[0] != 0)
		return;

	recMOVZtemp();
}

// ========================================================================
// MOVN  —  rd = rs if rt != 0
// Same "temp" naming convention.
// ========================================================================

static void recMOVNtemp_const()
{
	g_cpuConstRegs[_Rd_].UD[0] = g_cpuConstRegs[_Rs_].UD[0];
}

static void recMOVNtemp_consts(int info)
{
	_addNeededGPRtoArmGPR(_Rt_);
	_addNeededGPRtoArmGPR(_Rd_);
	const int rt = _allocArmGPR(ARMTYPE_GPR, _Rt_, MODE_READ);
	const int rd = _allocArmGPR(ARMTYPE_GPR, _Rd_, MODE_READ | MODE_WRITE);

	const s64 cval = g_cpuConstRegs[_Rs_].SD[0];

	a64::Label skip;
	armAsm->Cbz(armXRegister(rt), &skip);
	armAsm->Mov(armXRegister(rd), cval);
	armAsm->Bind(&skip);
	_clearNeededArmGPRs();
}

static void recMOVNtemp_constt(int info)
{
	if (g_cpuConstRegs[_Rt_].UD[0] == 0)
		return;

	_addNeededGPRtoArmGPR(_Rs_);
	_addNeededGPRtoArmGPR(_Rd_);
	const int rs = _allocArmGPR(ARMTYPE_GPR, _Rs_, MODE_READ);
	const int rd = _allocArmGPR(ARMTYPE_GPR, _Rd_, MODE_WRITE);

	if (rd != rs)
		armAsm->Mov(armXRegister(rd), armXRegister(rs));
	_clearNeededArmGPRs();
}

static void recMOVNtemp_(int info)
{
	_addNeededGPRtoArmGPR(_Rs_);
	_addNeededGPRtoArmGPR(_Rt_);
	_addNeededGPRtoArmGPR(_Rd_);
	const int rs = _allocArmGPR(ARMTYPE_GPR, _Rs_, MODE_READ);
	const int rt = _allocArmGPR(ARMTYPE_GPR, _Rt_, MODE_READ);
	const int rd = _allocArmGPR(ARMTYPE_GPR, _Rd_, MODE_READ | MODE_WRITE);

	armAsm->Cmp(armXRegister(rt), a64::xzr);
	armAsm->Csel(armXRegister(rd), armXRegister(rs), armXRegister(rd), a64::ne);
	_clearNeededArmGPRs();
}

EERECOMPILE_CODERC0(MOVNtemp, XMMINFO_WRITED | XMMINFO_READD | XMMINFO_READS | XMMINFO_READT);

void recMOVN()
{
	if (_Rs_ == _Rd_)
		return;

	if (GPR_IS_CONST1(_Rt_) && g_cpuConstRegs[_Rt_].UD[0] == 0)
		return;

	recMOVNtemp();
}

// ========================================================================
// MFSA  —  rd = SA
// ========================================================================

void recMFSA()
{
	EE::Profiler.EmitOp(eeOpcode::MFSA);

	if (!_Rd_)
		return;

	_addNeededGPRtoArmGPR(_Rd_);
	const int rd = _allocArmGPR(ARMTYPE_GPR, _Rd_, MODE_WRITE);

	// SA is u32, LDR w-form zero-extends to 64-bit
	armAsm->Ldr(armWRegister(rd), MEMBASE_PTR(sa));
	_clearNeededArmGPRs();
}

// ========================================================================
// MTSA  —  SA = rs
// ========================================================================

void recMTSA()
{
	EE::Profiler.EmitOp(eeOpcode::MTSA);

	if (GPR_IS_CONST1(_Rs_))
	{
		armAsm->Mov(a64::w4, g_cpuConstRegs[_Rs_].UL[0]);
		armAsm->Str(a64::w4, MEMBASE_PTR(sa));
	}
	else
	{
		_addNeededGPRtoArmGPR(_Rs_);
		const int rs = _allocArmGPR(ARMTYPE_GPR, _Rs_, MODE_READ);
		armAsm->Str(armWRegister(rs), MEMBASE_PTR(sa));
		_clearNeededArmGPRs();
	}
}

// ========================================================================
// MTSAB / MTSAH — interpreter fallback
// ========================================================================

REC_FUNC(MTSAB);
REC_FUNC(MTSAH);

} // namespace OpcodeImpl
} // namespace Dynarec
} // namespace R5900
