// SPDX-FileCopyrightText: 2002-2026 PCSX2 Dev Team
// SPDX-License-Identifier: GPL-3.0+

// ARM64 EE Recompiler — Native immediate arithmetic instructions (Phase 1)
//
// rt = rs OP imm16 instructions:
//   ADDI/ADDIU (32-bit add immediate, sign-extended to 64)
//   DADDI/DADDIU (64-bit add immediate)
//   SLTI/SLTIU (set on less than immediate)
//   ANDI, ORI, XORI (logical immediate, zero-extended)
//   LUI (load upper immediate)

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
// ADDI / ADDIU  —  rt = sign_ext32(rs[31:0] + sign_ext(imm16))
// ========================================================================

static void recADDI_const()
{
	g_cpuConstRegs[_Rt_].SD[0] = s64(s32(g_cpuConstRegs[_Rs_].UL[0] + (u32)s32(_Imm_)));
}

static void recADDI_(int info)
{
	const s32 imm = _Imm_;

	_addNeededGPRtoArmGPR(_Rs_);
	_addNeededGPRtoArmGPR(_Rt_);
	const int rs = _allocArmGPR(ARMTYPE_GPR, _Rs_, MODE_READ);
	const int rt = _allocArmGPR(ARMTYPE_GPR, _Rt_, MODE_WRITE);

	if (imm == 0)
	{
		armAsm->Sxtw(armXRegister(rt), armWRegister(rs));
	}
	else
	{
		armAsm->Add(armWRegister(rt), armWRegister(rs), a64::Operand(imm));
		armAsm->Sxtw(armXRegister(rt), armWRegister(rt));
	}
	_clearNeededArmGPRs();
}

EERECOMPILE_CODEX(eeRecompileCodeRC1, ADDI, XMMINFO_WRITET | XMMINFO_READS);

// ADDIU is identical to ADDI (no overflow trap)
static void recADDIU_const() { recADDI_const(); }
static void recADDIU_(int info) { recADDI_(info); }
EERECOMPILE_CODEX(eeRecompileCodeRC1, ADDIU, XMMINFO_WRITET | XMMINFO_READS);

// ========================================================================
// DADDI / DADDIU  —  rt = rs + sign_ext(imm16)  (64-bit)
// ========================================================================

static void recDADDI_const()
{
	g_cpuConstRegs[_Rt_].SD[0] = g_cpuConstRegs[_Rs_].SD[0] + s64(_Imm_);
}

static void recDADDI_(int info)
{
	const s64 imm = s64(_Imm_);

	_addNeededGPRtoArmGPR(_Rs_);
	_addNeededGPRtoArmGPR(_Rt_);
	const int rs = _allocArmGPR(ARMTYPE_GPR, _Rs_, MODE_READ);
	const int rt = _allocArmGPR(ARMTYPE_GPR, _Rt_, MODE_WRITE);

	if (imm == 0)
	{
		if (rt != rs)
			armAsm->Mov(armXRegister(rt), armXRegister(rs));
	}
	else
	{
		armAsm->Add(armXRegister(rt), armXRegister(rs), a64::Operand(imm));
	}
	_clearNeededArmGPRs();
}

EERECOMPILE_CODEX(eeRecompileCodeRC1, DADDI, XMMINFO_WRITET | XMMINFO_READS);

static void recDADDIU_const() { recDADDI_const(); }
static void recDADDIU_(int info) { recDADDI_(info); }
EERECOMPILE_CODEX(eeRecompileCodeRC1, DADDIU, XMMINFO_WRITET | XMMINFO_READS);

// ========================================================================
// SLTI  —  rt = (rs < sign_ext(imm16)) ? 1 : 0  (signed)
// ========================================================================

static void recSLTI_const()
{
	g_cpuConstRegs[_Rt_].UD[0] = g_cpuConstRegs[_Rs_].SD[0] < s64(_Imm_);
}

static void recSLTI_(int info)
{
	const s64 imm = s64(_Imm_);

	_addNeededGPRtoArmGPR(_Rs_);
	_addNeededGPRtoArmGPR(_Rt_);
	const int rs = _allocArmGPR(ARMTYPE_GPR, _Rs_, MODE_READ);
	const int rt = _allocArmGPR(ARMTYPE_GPR, _Rt_, MODE_WRITE);

	armAsm->Cmp(armXRegister(rs), a64::Operand(imm));
	armAsm->Cset(armXRegister(rt), a64::lt);
	_clearNeededArmGPRs();
}

EERECOMPILE_CODEX(eeRecompileCodeRC1, SLTI, XMMINFO_WRITET | XMMINFO_READS);

// ========================================================================
// SLTIU  —  rt = (rs < sign_ext(imm16)) ? 1 : 0  (unsigned)
// Note: The immediate is sign-extended then treated as unsigned for comparison
// ========================================================================

static void recSLTIU_const()
{
	g_cpuConstRegs[_Rt_].UD[0] = g_cpuConstRegs[_Rs_].UD[0] < (u64)(s64)_Imm_;
}

static void recSLTIU_(int info)
{
	// Sign-extend imm16, then compare as unsigned
	const s64 imm = s64(_Imm_);

	_addNeededGPRtoArmGPR(_Rs_);
	_addNeededGPRtoArmGPR(_Rt_);
	const int rs = _allocArmGPR(ARMTYPE_GPR, _Rs_, MODE_READ);
	const int rt = _allocArmGPR(ARMTYPE_GPR, _Rt_, MODE_WRITE);

	armAsm->Cmp(armXRegister(rs), a64::Operand(imm));
	armAsm->Cset(armXRegister(rt), a64::lo);
	_clearNeededArmGPRs();
}

EERECOMPILE_CODEX(eeRecompileCodeRC1, SLTIU, XMMINFO_WRITET | XMMINFO_READS);

// ========================================================================
// ANDI  —  rt = rs & zero_ext(imm16)  (64-bit)
// ========================================================================

static void recANDI_const()
{
	g_cpuConstRegs[_Rt_].UD[0] = g_cpuConstRegs[_Rs_].UD[0] & (u64)(u16)_Imm_;
}

static void recANDI_(int info)
{
	const u64 imm = (u64)(u16)_Imm_;

	_addNeededGPRtoArmGPR(_Rs_);
	_addNeededGPRtoArmGPR(_Rt_);
	const int rs = _allocArmGPR(ARMTYPE_GPR, _Rs_, MODE_READ);
	const int rt = _allocArmGPR(ARMTYPE_GPR, _Rt_, MODE_WRITE);

	if (imm == 0)
		armAsm->Mov(armXRegister(rt), a64::xzr);
	else
		armAsm->And(armXRegister(rt), armXRegister(rs), a64::Operand(imm));

	_clearNeededArmGPRs();
}

EERECOMPILE_CODEX(eeRecompileCodeRC1, ANDI, XMMINFO_WRITET | XMMINFO_READS);

// ========================================================================
// ORI  —  rt = rs | zero_ext(imm16)  (64-bit)
// ========================================================================

static void recORI_const()
{
	g_cpuConstRegs[_Rt_].UD[0] = g_cpuConstRegs[_Rs_].UD[0] | (u64)(u16)_Imm_;
}

static void recORI_(int info)
{
	const u64 imm = (u64)(u16)_Imm_;

	_addNeededGPRtoArmGPR(_Rs_);
	_addNeededGPRtoArmGPR(_Rt_);
	const int rs = _allocArmGPR(ARMTYPE_GPR, _Rs_, MODE_READ);
	const int rt = _allocArmGPR(ARMTYPE_GPR, _Rt_, MODE_WRITE);

	if (imm == 0)
	{
		if (rt != rs)
			armAsm->Mov(armXRegister(rt), armXRegister(rs));
	}
	else
		armAsm->Orr(armXRegister(rt), armXRegister(rs), a64::Operand(imm));

	_clearNeededArmGPRs();
}

EERECOMPILE_CODEX(eeRecompileCodeRC1, ORI, XMMINFO_WRITET | XMMINFO_READS);

// ========================================================================
// XORI  —  rt = rs ^ zero_ext(imm16)  (64-bit)
// ========================================================================

static void recXORI_const()
{
	g_cpuConstRegs[_Rt_].UD[0] = g_cpuConstRegs[_Rs_].UD[0] ^ (u64)(u16)_Imm_;
}

static void recXORI_(int info)
{
	const u64 imm = (u64)(u16)_Imm_;

	_addNeededGPRtoArmGPR(_Rs_);
	_addNeededGPRtoArmGPR(_Rt_);
	const int rs = _allocArmGPR(ARMTYPE_GPR, _Rs_, MODE_READ);
	const int rt = _allocArmGPR(ARMTYPE_GPR, _Rt_, MODE_WRITE);

	if (imm == 0)
	{
		if (rt != rs)
			armAsm->Mov(armXRegister(rt), armXRegister(rs));
	}
	else
		armAsm->Eor(armXRegister(rt), armXRegister(rs), a64::Operand(imm));

	_clearNeededArmGPRs();
}

EERECOMPILE_CODEX(eeRecompileCodeRC1, XORI, XMMINFO_WRITET | XMMINFO_READS);

// ========================================================================
// LUI  —  rt = sign_ext(imm16 << 16)
// Always constant-propagated when EE_CONST_PROP is enabled.
// ========================================================================

void recLUI()
{
	EE::Profiler.EmitOp(eeOpcode::LUI);

	if (!_Rt_)
		return;

	const s64 val = s64(s32(((u32)cpuRegs.code << 16)));

	_deleteGPRtoArmGPR(_Rt_, DELETE_REG_FREE_NO_WRITEBACK);
	_deleteGPRtoNeonreg(_Rt_, DELETE_REG_FLUSH_AND_FREE);

	if (EE_CONST_PROP)
	{
		GPR_SET_CONST(_Rt_);
		g_cpuConstRegs[_Rt_].SD[0] = val;
	}
	else
	{
		const int rt = _allocArmGPR(ARMTYPE_GPR, _Rt_, MODE_WRITE);
		armAsm->Mov(armXRegister(rt), val);
		_clearNeededArmGPRs();
	}
}

} // namespace OpcodeImpl
} // namespace Dynarec
} // namespace R5900
