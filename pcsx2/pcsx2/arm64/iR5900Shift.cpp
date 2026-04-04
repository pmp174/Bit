// SPDX-FileCopyrightText: 2002-2026 PCSX2 Dev Team
// SPDX-License-Identifier: GPL-3.0+

// ARM64 EE Recompiler — Native shift instructions (Phase 1)
//
// Fixed shift (rd = rt OP sa):
//   SLL, SRL, SRA (32-bit, sign-extended to 64)
//   DSLL, DSRL, DSRA (64-bit, shift by sa)
//   DSLL32, DSRL32, DSRA32 (64-bit, shift by sa+32)
//
// Variable shift (rd = rt OP rs):
//   SLLV, SRLV, SRAV (32-bit, sign-extended to 64)
//   DSLLV, DSRLV, DSRAV (64-bit)

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
// SLL  —  rd = sign_ext32(rt << sa)
// ========================================================================

static void recSLL_const()
{
	g_cpuConstRegs[_Rd_].SD[0] = s64(s32(g_cpuConstRegs[_Rt_].UL[0] << _Sa_));
}

static void recSLL_(int info)
{
	_addNeededGPRtoArmGPR(_Rt_);
	_addNeededGPRtoArmGPR(_Rd_);
	const int rt = _allocArmGPR(ARMTYPE_GPR, _Rt_, MODE_READ);
	const int rd = _allocArmGPR(ARMTYPE_GPR, _Rd_, MODE_WRITE);

	if (_Sa_ != 0)
	{
		armAsm->Lsl(armWRegister(rd), armWRegister(rt), _Sa_);
		armAsm->Sxtw(armXRegister(rd), armWRegister(rd));
	}
	else
	{
		// SLL $0, rt, 0 is NOP if Rd==0, but we get here only if Rd != 0
		armAsm->Sxtw(armXRegister(rd), armWRegister(rt));
	}
	_clearNeededArmGPRs();
}

EERECOMPILE_CODEX(eeRecompileCodeRC2, SLL, XMMINFO_WRITED | XMMINFO_READT);

// ========================================================================
// SRL  —  rd = sign_ext32(rt >> sa)  (logical/unsigned)
// ========================================================================

static void recSRL_const()
{
	g_cpuConstRegs[_Rd_].SD[0] = s64(s32(g_cpuConstRegs[_Rt_].UL[0] >> _Sa_));
}

static void recSRL_(int info)
{
	_addNeededGPRtoArmGPR(_Rt_);
	_addNeededGPRtoArmGPR(_Rd_);
	const int rt = _allocArmGPR(ARMTYPE_GPR, _Rt_, MODE_READ);
	const int rd = _allocArmGPR(ARMTYPE_GPR, _Rd_, MODE_WRITE);

	if (_Sa_ != 0)
	{
		armAsm->Lsr(armWRegister(rd), armWRegister(rt), _Sa_);
		armAsm->Sxtw(armXRegister(rd), armWRegister(rd));
	}
	else
	{
		armAsm->Sxtw(armXRegister(rd), armWRegister(rt));
	}
	_clearNeededArmGPRs();
}

EERECOMPILE_CODEX(eeRecompileCodeRC2, SRL, XMMINFO_WRITED | XMMINFO_READT);

// ========================================================================
// SRA  —  rd = sign_ext32(rt >> sa)  (arithmetic/signed)
// ========================================================================

static void recSRA_const()
{
	g_cpuConstRegs[_Rd_].SD[0] = s64(s32(g_cpuConstRegs[_Rt_].SL[0] >> _Sa_));
}

static void recSRA_(int info)
{
	_addNeededGPRtoArmGPR(_Rt_);
	_addNeededGPRtoArmGPR(_Rd_);
	const int rt = _allocArmGPR(ARMTYPE_GPR, _Rt_, MODE_READ);
	const int rd = _allocArmGPR(ARMTYPE_GPR, _Rd_, MODE_WRITE);

	if (_Sa_ != 0)
	{
		armAsm->Asr(armWRegister(rd), armWRegister(rt), _Sa_);
		armAsm->Sxtw(armXRegister(rd), armWRegister(rd));
	}
	else
	{
		armAsm->Sxtw(armXRegister(rd), armWRegister(rt));
	}
	_clearNeededArmGPRs();
}

EERECOMPILE_CODEX(eeRecompileCodeRC2, SRA, XMMINFO_WRITED | XMMINFO_READT);

// ========================================================================
// SLLV  —  rd = sign_ext32(rt << rs[4:0])
// ========================================================================

static void recSLLV_const()
{
	g_cpuConstRegs[_Rd_].SD[0] = s64(s32(g_cpuConstRegs[_Rt_].UL[0] << (g_cpuConstRegs[_Rs_].UL[0] & 0x1f)));
}

static void recSLLV_consts(int info)
{
	const u32 sa = g_cpuConstRegs[_Rs_].UL[0] & 0x1f;

	_addNeededGPRtoArmGPR(_Rt_);
	_addNeededGPRtoArmGPR(_Rd_);
	const int rt = _allocArmGPR(ARMTYPE_GPR, _Rt_, MODE_READ);
	const int rd = _allocArmGPR(ARMTYPE_GPR, _Rd_, MODE_WRITE);

	if (sa != 0)
		armAsm->Lsl(armWRegister(rd), armWRegister(rt), sa);
	else if (rd != rt)
		armAsm->Mov(armWRegister(rd), armWRegister(rt));
	armAsm->Sxtw(armXRegister(rd), armWRegister(rd));
	_clearNeededArmGPRs();
}

static void recSLLV_constt(int info)
{
	const u32 tval = g_cpuConstRegs[_Rt_].UL[0];

	_addNeededGPRtoArmGPR(_Rs_);
	_addNeededGPRtoArmGPR(_Rd_);
	const int rs = _allocArmGPR(ARMTYPE_GPR, _Rs_, MODE_READ);
	const int rd = _allocArmGPR(ARMTYPE_GPR, _Rd_, MODE_WRITE);

	armAsm->Mov(armWRegister(rd), tval);
	armAsm->Lsl(armWRegister(rd), armWRegister(rd), armWRegister(rs));
	armAsm->Sxtw(armXRegister(rd), armWRegister(rd));
	_clearNeededArmGPRs();
}

static void recSLLV_(int info)
{
	_addNeededGPRtoArmGPR(_Rs_);
	_addNeededGPRtoArmGPR(_Rt_);
	_addNeededGPRtoArmGPR(_Rd_);
	const int rs = _allocArmGPR(ARMTYPE_GPR, _Rs_, MODE_READ);
	const int rt = _allocArmGPR(ARMTYPE_GPR, _Rt_, MODE_READ);
	const int rd = _allocArmGPR(ARMTYPE_GPR, _Rd_, MODE_WRITE);

	// ARM64 LSLV uses only lower 5 bits for 32-bit ops automatically
	armAsm->Lsl(armWRegister(rd), armWRegister(rt), armWRegister(rs));
	armAsm->Sxtw(armXRegister(rd), armWRegister(rd));
	_clearNeededArmGPRs();
}

EERECOMPILE_CODERC0(SLLV, XMMINFO_WRITED | XMMINFO_READS | XMMINFO_READT);

// ========================================================================
// SRLV  —  rd = sign_ext32(rt >> rs[4:0])  (logical)
// ========================================================================

static void recSRLV_const()
{
	g_cpuConstRegs[_Rd_].SD[0] = s64(s32(g_cpuConstRegs[_Rt_].UL[0] >> (g_cpuConstRegs[_Rs_].UL[0] & 0x1f)));
}

static void recSRLV_consts(int info)
{
	const u32 sa = g_cpuConstRegs[_Rs_].UL[0] & 0x1f;

	_addNeededGPRtoArmGPR(_Rt_);
	_addNeededGPRtoArmGPR(_Rd_);
	const int rt = _allocArmGPR(ARMTYPE_GPR, _Rt_, MODE_READ);
	const int rd = _allocArmGPR(ARMTYPE_GPR, _Rd_, MODE_WRITE);

	if (sa != 0)
		armAsm->Lsr(armWRegister(rd), armWRegister(rt), sa);
	else if (rd != rt)
		armAsm->Mov(armWRegister(rd), armWRegister(rt));
	armAsm->Sxtw(armXRegister(rd), armWRegister(rd));
	_clearNeededArmGPRs();
}

static void recSRLV_constt(int info)
{
	const u32 tval = g_cpuConstRegs[_Rt_].UL[0];

	_addNeededGPRtoArmGPR(_Rs_);
	_addNeededGPRtoArmGPR(_Rd_);
	const int rs = _allocArmGPR(ARMTYPE_GPR, _Rs_, MODE_READ);
	const int rd = _allocArmGPR(ARMTYPE_GPR, _Rd_, MODE_WRITE);

	armAsm->Mov(armWRegister(rd), tval);
	armAsm->Lsr(armWRegister(rd), armWRegister(rd), armWRegister(rs));
	armAsm->Sxtw(armXRegister(rd), armWRegister(rd));
	_clearNeededArmGPRs();
}

static void recSRLV_(int info)
{
	_addNeededGPRtoArmGPR(_Rs_);
	_addNeededGPRtoArmGPR(_Rt_);
	_addNeededGPRtoArmGPR(_Rd_);
	const int rs = _allocArmGPR(ARMTYPE_GPR, _Rs_, MODE_READ);
	const int rt = _allocArmGPR(ARMTYPE_GPR, _Rt_, MODE_READ);
	const int rd = _allocArmGPR(ARMTYPE_GPR, _Rd_, MODE_WRITE);

	armAsm->Lsr(armWRegister(rd), armWRegister(rt), armWRegister(rs));
	armAsm->Sxtw(armXRegister(rd), armWRegister(rd));
	_clearNeededArmGPRs();
}

EERECOMPILE_CODERC0(SRLV, XMMINFO_WRITED | XMMINFO_READS | XMMINFO_READT);

// ========================================================================
// SRAV  —  rd = sign_ext32(rt >> rs[4:0])  (arithmetic)
// ========================================================================

static void recSRAV_const()
{
	g_cpuConstRegs[_Rd_].SD[0] = s64(s32(g_cpuConstRegs[_Rt_].SL[0] >> (g_cpuConstRegs[_Rs_].UL[0] & 0x1f)));
}

static void recSRAV_consts(int info)
{
	const u32 sa = g_cpuConstRegs[_Rs_].UL[0] & 0x1f;

	_addNeededGPRtoArmGPR(_Rt_);
	_addNeededGPRtoArmGPR(_Rd_);
	const int rt = _allocArmGPR(ARMTYPE_GPR, _Rt_, MODE_READ);
	const int rd = _allocArmGPR(ARMTYPE_GPR, _Rd_, MODE_WRITE);

	if (sa != 0)
		armAsm->Asr(armWRegister(rd), armWRegister(rt), sa);
	else if (rd != rt)
		armAsm->Mov(armWRegister(rd), armWRegister(rt));
	armAsm->Sxtw(armXRegister(rd), armWRegister(rd));
	_clearNeededArmGPRs();
}

static void recSRAV_constt(int info)
{
	const s32 tval = g_cpuConstRegs[_Rt_].SL[0];

	_addNeededGPRtoArmGPR(_Rs_);
	_addNeededGPRtoArmGPR(_Rd_);
	const int rs = _allocArmGPR(ARMTYPE_GPR, _Rs_, MODE_READ);
	const int rd = _allocArmGPR(ARMTYPE_GPR, _Rd_, MODE_WRITE);

	armAsm->Mov(armWRegister(rd), tval);
	armAsm->Asr(armWRegister(rd), armWRegister(rd), armWRegister(rs));
	armAsm->Sxtw(armXRegister(rd), armWRegister(rd));
	_clearNeededArmGPRs();
}

static void recSRAV_(int info)
{
	_addNeededGPRtoArmGPR(_Rs_);
	_addNeededGPRtoArmGPR(_Rt_);
	_addNeededGPRtoArmGPR(_Rd_);
	const int rs = _allocArmGPR(ARMTYPE_GPR, _Rs_, MODE_READ);
	const int rt = _allocArmGPR(ARMTYPE_GPR, _Rt_, MODE_READ);
	const int rd = _allocArmGPR(ARMTYPE_GPR, _Rd_, MODE_WRITE);

	armAsm->Asr(armWRegister(rd), armWRegister(rt), armWRegister(rs));
	armAsm->Sxtw(armXRegister(rd), armWRegister(rd));
	_clearNeededArmGPRs();
}

EERECOMPILE_CODERC0(SRAV, XMMINFO_WRITED | XMMINFO_READS | XMMINFO_READT);

// ========================================================================
// DSLL  —  rd = rt << sa  (64-bit)
// ========================================================================

static void recDSLL_const()
{
	g_cpuConstRegs[_Rd_].UD[0] = g_cpuConstRegs[_Rt_].UD[0] << _Sa_;
}

static void recDSLL_(int info)
{
	_addNeededGPRtoArmGPR(_Rt_);
	_addNeededGPRtoArmGPR(_Rd_);
	const int rt = _allocArmGPR(ARMTYPE_GPR, _Rt_, MODE_READ);
	const int rd = _allocArmGPR(ARMTYPE_GPR, _Rd_, MODE_WRITE);

	if (_Sa_ != 0)
		armAsm->Lsl(armXRegister(rd), armXRegister(rt), _Sa_);
	else if (rd != rt)
		armAsm->Mov(armXRegister(rd), armXRegister(rt));
	_clearNeededArmGPRs();
}

EERECOMPILE_CODEX(eeRecompileCodeRC2, DSLL, XMMINFO_WRITED | XMMINFO_READT);

// ========================================================================
// DSRL  —  rd = rt >> sa  (64-bit, logical)
// ========================================================================

static void recDSRL_const()
{
	g_cpuConstRegs[_Rd_].UD[0] = g_cpuConstRegs[_Rt_].UD[0] >> _Sa_;
}

static void recDSRL_(int info)
{
	_addNeededGPRtoArmGPR(_Rt_);
	_addNeededGPRtoArmGPR(_Rd_);
	const int rt = _allocArmGPR(ARMTYPE_GPR, _Rt_, MODE_READ);
	const int rd = _allocArmGPR(ARMTYPE_GPR, _Rd_, MODE_WRITE);

	if (_Sa_ != 0)
		armAsm->Lsr(armXRegister(rd), armXRegister(rt), _Sa_);
	else if (rd != rt)
		armAsm->Mov(armXRegister(rd), armXRegister(rt));
	_clearNeededArmGPRs();
}

EERECOMPILE_CODEX(eeRecompileCodeRC2, DSRL, XMMINFO_WRITED | XMMINFO_READT);

// ========================================================================
// DSRA  —  rd = rt >> sa  (64-bit, arithmetic)
// ========================================================================

static void recDSRA_const()
{
	g_cpuConstRegs[_Rd_].SD[0] = g_cpuConstRegs[_Rt_].SD[0] >> _Sa_;
}

static void recDSRA_(int info)
{
	_addNeededGPRtoArmGPR(_Rt_);
	_addNeededGPRtoArmGPR(_Rd_);
	const int rt = _allocArmGPR(ARMTYPE_GPR, _Rt_, MODE_READ);
	const int rd = _allocArmGPR(ARMTYPE_GPR, _Rd_, MODE_WRITE);

	if (_Sa_ != 0)
		armAsm->Asr(armXRegister(rd), armXRegister(rt), _Sa_);
	else if (rd != rt)
		armAsm->Mov(armXRegister(rd), armXRegister(rt));
	_clearNeededArmGPRs();
}

EERECOMPILE_CODEX(eeRecompileCodeRC2, DSRA, XMMINFO_WRITED | XMMINFO_READT);

// ========================================================================
// DSLL32  —  rd = rt << (sa + 32)  (64-bit)
// ========================================================================

static void recDSLL32_const()
{
	g_cpuConstRegs[_Rd_].UD[0] = g_cpuConstRegs[_Rt_].UD[0] << (_Sa_ + 32);
}

static void recDSLL32_(int info)
{
	_addNeededGPRtoArmGPR(_Rt_);
	_addNeededGPRtoArmGPR(_Rd_);
	const int rt = _allocArmGPR(ARMTYPE_GPR, _Rt_, MODE_READ);
	const int rd = _allocArmGPR(ARMTYPE_GPR, _Rd_, MODE_WRITE);

	armAsm->Lsl(armXRegister(rd), armXRegister(rt), _Sa_ + 32);
	_clearNeededArmGPRs();
}

EERECOMPILE_CODEX(eeRecompileCodeRC2, DSLL32, XMMINFO_WRITED | XMMINFO_READT);

// ========================================================================
// DSRL32  —  rd = rt >> (sa + 32)  (64-bit, logical)
// ========================================================================

static void recDSRL32_const()
{
	g_cpuConstRegs[_Rd_].UD[0] = g_cpuConstRegs[_Rt_].UD[0] >> (_Sa_ + 32);
}

static void recDSRL32_(int info)
{
	_addNeededGPRtoArmGPR(_Rt_);
	_addNeededGPRtoArmGPR(_Rd_);
	const int rt = _allocArmGPR(ARMTYPE_GPR, _Rt_, MODE_READ);
	const int rd = _allocArmGPR(ARMTYPE_GPR, _Rd_, MODE_WRITE);

	armAsm->Lsr(armXRegister(rd), armXRegister(rt), _Sa_ + 32);
	_clearNeededArmGPRs();
}

EERECOMPILE_CODEX(eeRecompileCodeRC2, DSRL32, XMMINFO_WRITED | XMMINFO_READT);

// ========================================================================
// DSRA32  —  rd = rt >> (sa + 32)  (64-bit, arithmetic)
// ========================================================================

static void recDSRA32_const()
{
	g_cpuConstRegs[_Rd_].SD[0] = g_cpuConstRegs[_Rt_].SD[0] >> (_Sa_ + 32);
}

static void recDSRA32_(int info)
{
	_addNeededGPRtoArmGPR(_Rt_);
	_addNeededGPRtoArmGPR(_Rd_);
	const int rt = _allocArmGPR(ARMTYPE_GPR, _Rt_, MODE_READ);
	const int rd = _allocArmGPR(ARMTYPE_GPR, _Rd_, MODE_WRITE);

	armAsm->Asr(armXRegister(rd), armXRegister(rt), _Sa_ + 32);
	_clearNeededArmGPRs();
}

EERECOMPILE_CODEX(eeRecompileCodeRC2, DSRA32, XMMINFO_WRITED | XMMINFO_READT);

// ========================================================================
// DSLLV  —  rd = rt << rs[5:0]  (64-bit)
// ========================================================================

static void recDSLLV_const()
{
	g_cpuConstRegs[_Rd_].UD[0] = g_cpuConstRegs[_Rt_].UD[0] << (g_cpuConstRegs[_Rs_].UL[0] & 0x3f);
}

static void recDSLLV_consts(int info)
{
	const u32 sa = g_cpuConstRegs[_Rs_].UL[0] & 0x3f;

	_addNeededGPRtoArmGPR(_Rt_);
	_addNeededGPRtoArmGPR(_Rd_);
	const int rt = _allocArmGPR(ARMTYPE_GPR, _Rt_, MODE_READ);
	const int rd = _allocArmGPR(ARMTYPE_GPR, _Rd_, MODE_WRITE);

	if (sa != 0)
		armAsm->Lsl(armXRegister(rd), armXRegister(rt), sa);
	else if (rd != rt)
		armAsm->Mov(armXRegister(rd), armXRegister(rt));
	_clearNeededArmGPRs();
}

static void recDSLLV_constt(int info)
{
	const u64 tval = g_cpuConstRegs[_Rt_].UD[0];

	_addNeededGPRtoArmGPR(_Rs_);
	_addNeededGPRtoArmGPR(_Rd_);
	const int rs = _allocArmGPR(ARMTYPE_GPR, _Rs_, MODE_READ);
	const int rd = _allocArmGPR(ARMTYPE_GPR, _Rd_, MODE_WRITE);

	armAsm->Mov(armXRegister(rd), tval);
	armAsm->Lsl(armXRegister(rd), armXRegister(rd), armXRegister(rs));
	_clearNeededArmGPRs();
}

static void recDSLLV_(int info)
{
	_addNeededGPRtoArmGPR(_Rs_);
	_addNeededGPRtoArmGPR(_Rt_);
	_addNeededGPRtoArmGPR(_Rd_);
	const int rs = _allocArmGPR(ARMTYPE_GPR, _Rs_, MODE_READ);
	const int rt = _allocArmGPR(ARMTYPE_GPR, _Rt_, MODE_READ);
	const int rd = _allocArmGPR(ARMTYPE_GPR, _Rd_, MODE_WRITE);

	armAsm->Lsl(armXRegister(rd), armXRegister(rt), armXRegister(rs));
	_clearNeededArmGPRs();
}

EERECOMPILE_CODERC0(DSLLV, XMMINFO_WRITED | XMMINFO_READS | XMMINFO_READT);

// ========================================================================
// DSRLV  —  rd = rt >> rs[5:0]  (64-bit, logical)
// ========================================================================

static void recDSRLV_const()
{
	g_cpuConstRegs[_Rd_].UD[0] = g_cpuConstRegs[_Rt_].UD[0] >> (g_cpuConstRegs[_Rs_].UL[0] & 0x3f);
}

static void recDSRLV_consts(int info)
{
	const u32 sa = g_cpuConstRegs[_Rs_].UL[0] & 0x3f;

	_addNeededGPRtoArmGPR(_Rt_);
	_addNeededGPRtoArmGPR(_Rd_);
	const int rt = _allocArmGPR(ARMTYPE_GPR, _Rt_, MODE_READ);
	const int rd = _allocArmGPR(ARMTYPE_GPR, _Rd_, MODE_WRITE);

	if (sa != 0)
		armAsm->Lsr(armXRegister(rd), armXRegister(rt), sa);
	else if (rd != rt)
		armAsm->Mov(armXRegister(rd), armXRegister(rt));
	_clearNeededArmGPRs();
}

static void recDSRLV_constt(int info)
{
	const u64 tval = g_cpuConstRegs[_Rt_].UD[0];

	_addNeededGPRtoArmGPR(_Rs_);
	_addNeededGPRtoArmGPR(_Rd_);
	const int rs = _allocArmGPR(ARMTYPE_GPR, _Rs_, MODE_READ);
	const int rd = _allocArmGPR(ARMTYPE_GPR, _Rd_, MODE_WRITE);

	armAsm->Mov(armXRegister(rd), tval);
	armAsm->Lsr(armXRegister(rd), armXRegister(rd), armXRegister(rs));
	_clearNeededArmGPRs();
}

static void recDSRLV_(int info)
{
	_addNeededGPRtoArmGPR(_Rs_);
	_addNeededGPRtoArmGPR(_Rt_);
	_addNeededGPRtoArmGPR(_Rd_);
	const int rs = _allocArmGPR(ARMTYPE_GPR, _Rs_, MODE_READ);
	const int rt = _allocArmGPR(ARMTYPE_GPR, _Rt_, MODE_READ);
	const int rd = _allocArmGPR(ARMTYPE_GPR, _Rd_, MODE_WRITE);

	armAsm->Lsr(armXRegister(rd), armXRegister(rt), armXRegister(rs));
	_clearNeededArmGPRs();
}

EERECOMPILE_CODERC0(DSRLV, XMMINFO_WRITED | XMMINFO_READS | XMMINFO_READT);

// ========================================================================
// DSRAV  —  rd = rt >> rs[5:0]  (64-bit, arithmetic)
// ========================================================================

static void recDSRAV_const()
{
	g_cpuConstRegs[_Rd_].SD[0] = g_cpuConstRegs[_Rt_].SD[0] >> (g_cpuConstRegs[_Rs_].UL[0] & 0x3f);
}

static void recDSRAV_consts(int info)
{
	const u32 sa = g_cpuConstRegs[_Rs_].UL[0] & 0x3f;

	_addNeededGPRtoArmGPR(_Rt_);
	_addNeededGPRtoArmGPR(_Rd_);
	const int rt = _allocArmGPR(ARMTYPE_GPR, _Rt_, MODE_READ);
	const int rd = _allocArmGPR(ARMTYPE_GPR, _Rd_, MODE_WRITE);

	if (sa != 0)
		armAsm->Asr(armXRegister(rd), armXRegister(rt), sa);
	else if (rd != rt)
		armAsm->Mov(armXRegister(rd), armXRegister(rt));
	_clearNeededArmGPRs();
}

static void recDSRAV_constt(int info)
{
	const s64 tval = g_cpuConstRegs[_Rt_].SD[0];

	_addNeededGPRtoArmGPR(_Rs_);
	_addNeededGPRtoArmGPR(_Rd_);
	const int rs = _allocArmGPR(ARMTYPE_GPR, _Rs_, MODE_READ);
	const int rd = _allocArmGPR(ARMTYPE_GPR, _Rd_, MODE_WRITE);

	armAsm->Mov(armXRegister(rd), tval);
	armAsm->Asr(armXRegister(rd), armXRegister(rd), armXRegister(rs));
	_clearNeededArmGPRs();
}

static void recDSRAV_(int info)
{
	_addNeededGPRtoArmGPR(_Rs_);
	_addNeededGPRtoArmGPR(_Rt_);
	_addNeededGPRtoArmGPR(_Rd_);
	const int rs = _allocArmGPR(ARMTYPE_GPR, _Rs_, MODE_READ);
	const int rt = _allocArmGPR(ARMTYPE_GPR, _Rt_, MODE_READ);
	const int rd = _allocArmGPR(ARMTYPE_GPR, _Rd_, MODE_WRITE);

	armAsm->Asr(armXRegister(rd), armXRegister(rt), armXRegister(rs));
	_clearNeededArmGPRs();
}

EERECOMPILE_CODERC0(DSRAV, XMMINFO_WRITED | XMMINFO_READS | XMMINFO_READT);

} // namespace OpcodeImpl
} // namespace Dynarec
} // namespace R5900
