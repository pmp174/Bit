// SPDX-FileCopyrightText: 2002-2026 PCSX2 Dev Team
// SPDX-License-Identifier: GPL-3.0+

// ARM64 EE Recompiler — Native arithmetic instructions (Phase 1)
//
// rd = rs OP rt instructions:
//   ADD/ADDU, SUB/SUBU (32-bit, sign-extended to 64)
//   DADD/DADDU, DSUB/DSUBU (64-bit)
//   AND, OR, XOR, NOR (64-bit logical)
//   SLT, SLTU (64-bit comparison → boolean)

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
// Helpers for register allocation in rd = rs OP rt pattern
// ========================================================================

// Allocate source (Rs or Rt) and destination (Rd) registers.
// Returns the host register numbers via out parameters.
static void allocRdRsRt(int& rd, int& rs, int& rt, int rdMode = MODE_WRITE)
{
	_addNeededGPRtoArmGPR(_Rs_);
	_addNeededGPRtoArmGPR(_Rt_);
	_addNeededGPRtoArmGPR(_Rd_);
	rs = _allocArmGPR(ARMTYPE_GPR, _Rs_, MODE_READ);
	rt = _allocArmGPR(ARMTYPE_GPR, _Rt_, MODE_READ);
	rd = _allocArmGPR(ARMTYPE_GPR, _Rd_, rdMode);
}

static void allocRdRs(int& rd, int& rs)
{
	_addNeededGPRtoArmGPR(_Rs_);
	_addNeededGPRtoArmGPR(_Rd_);
	rs = _allocArmGPR(ARMTYPE_GPR, _Rs_, MODE_READ);
	// If Rd == Rs, allocator returns same slot with WRITE added
	rd = _allocArmGPR(ARMTYPE_GPR, _Rd_, MODE_WRITE);
}

static void allocRdRt(int& rd, int& rt)
{
	_addNeededGPRtoArmGPR(_Rt_);
	_addNeededGPRtoArmGPR(_Rd_);
	rt = _allocArmGPR(ARMTYPE_GPR, _Rt_, MODE_READ);
	rd = _allocArmGPR(ARMTYPE_GPR, _Rd_, MODE_WRITE);
}

// ========================================================================
// ADD / ADDU  —  rd = sign_ext32(rs[31:0] + rt[31:0])
// ========================================================================

static void recADD_const()
{
	g_cpuConstRegs[_Rd_].SD[0] = s64(s32(g_cpuConstRegs[_Rs_].UL[0] + g_cpuConstRegs[_Rt_].UL[0]));
}

static void recADD_consts(int info)
{
	const s32 cval = g_cpuConstRegs[_Rs_].SL[0];
	int rd, rt;
	allocRdRt(rd, rt);

	if (cval == 0)
		armAsm->Sxtw(armXRegister(rd), armWRegister(rt));
	else
	{
		armAsm->Add(armWRegister(rd), armWRegister(rt), a64::Operand(cval));
		armAsm->Sxtw(armXRegister(rd), armWRegister(rd));
	}
	_clearNeededArmGPRs();
}

static void recADD_constt(int info)
{
	const s32 cval = g_cpuConstRegs[_Rt_].SL[0];
	int rd, rs;
	allocRdRs(rd, rs);

	if (cval == 0)
		armAsm->Sxtw(armXRegister(rd), armWRegister(rs));
	else
	{
		armAsm->Add(armWRegister(rd), armWRegister(rs), a64::Operand(cval));
		armAsm->Sxtw(armXRegister(rd), armWRegister(rd));
	}
	_clearNeededArmGPRs();
}

static void recADD_(int info)
{
	int rd, rs, rt;
	allocRdRsRt(rd, rs, rt);

	armAsm->Add(armWRegister(rd), armWRegister(rs), armWRegister(rt));
	armAsm->Sxtw(armXRegister(rd), armWRegister(rd));
	_clearNeededArmGPRs();
}

EERECOMPILE_CODERC0(ADD, XMMINFO_WRITED | XMMINFO_READS | XMMINFO_READT);

// ADDU is identical to ADD for our purposes (no overflow trap)
static void recADDU_const()  { recADD_const(); }
static void recADDU_consts(int info) { recADD_consts(info); }
static void recADDU_constt(int info) { recADD_constt(info); }
static void recADDU_(int info) { recADD_(info); }
EERECOMPILE_CODERC0(ADDU, XMMINFO_WRITED | XMMINFO_READS | XMMINFO_READT);

// ========================================================================
// SUB / SUBU  —  rd = sign_ext32(rs[31:0] - rt[31:0])
// ========================================================================

static void recSUB_const()
{
	g_cpuConstRegs[_Rd_].SD[0] = s64(s32(g_cpuConstRegs[_Rs_].UL[0] - g_cpuConstRegs[_Rt_].UL[0]));
}

static void recSUB_consts(int info)
{
	const s32 cval = g_cpuConstRegs[_Rs_].SL[0];
	int rd, rt;
	allocRdRt(rd, rt);

	// rd = cval - rt
	if (cval == 0)
	{
		armAsm->Neg(armWRegister(rd), armWRegister(rt));
		armAsm->Sxtw(armXRegister(rd), armWRegister(rd));
	}
	else
	{
		// Need scratch for the constant since SUB has no immediate-first form
		armAsm->Mov(a64::w4, cval);
		armAsm->Sub(armWRegister(rd), a64::w4, armWRegister(rt));
		armAsm->Sxtw(armXRegister(rd), armWRegister(rd));
	}
	_clearNeededArmGPRs();
}

static void recSUB_constt(int info)
{
	const s32 cval = g_cpuConstRegs[_Rt_].SL[0];
	int rd, rs;
	allocRdRs(rd, rs);

	if (cval == 0)
		armAsm->Sxtw(armXRegister(rd), armWRegister(rs));
	else
	{
		armAsm->Sub(armWRegister(rd), armWRegister(rs), a64::Operand(cval));
		armAsm->Sxtw(armXRegister(rd), armWRegister(rd));
	}
	_clearNeededArmGPRs();
}

static void recSUB_(int info)
{
	int rd, rs, rt;
	allocRdRsRt(rd, rs, rt);

	armAsm->Sub(armWRegister(rd), armWRegister(rs), armWRegister(rt));
	armAsm->Sxtw(armXRegister(rd), armWRegister(rd));
	_clearNeededArmGPRs();
}

EERECOMPILE_CODERC0(SUB, XMMINFO_WRITED | XMMINFO_READS | XMMINFO_READT);

static void recSUBU_const()  { recSUB_const(); }
static void recSUBU_consts(int info) { recSUB_consts(info); }
static void recSUBU_constt(int info) { recSUB_constt(info); }
static void recSUBU_(int info) { recSUB_(info); }
EERECOMPILE_CODERC0(SUBU, XMMINFO_WRITED | XMMINFO_READS | XMMINFO_READT);

// ========================================================================
// DADD / DADDU  —  rd = rs + rt  (64-bit)
// ========================================================================

static void recDADD_const()
{
	g_cpuConstRegs[_Rd_].SD[0] = g_cpuConstRegs[_Rs_].SD[0] + g_cpuConstRegs[_Rt_].SD[0];
}

static void recDADD_consts(int info)
{
	const s64 cval = g_cpuConstRegs[_Rs_].SD[0];
	int rd, rt;
	allocRdRt(rd, rt);

	if (cval == 0)
	{
		if (rd != rt)
			armAsm->Mov(armXRegister(rd), armXRegister(rt));
	}
	else
	{
		armAsm->Add(armXRegister(rd), armXRegister(rt), a64::Operand(cval));
	}
	_clearNeededArmGPRs();
}

static void recDADD_constt(int info)
{
	const s64 cval = g_cpuConstRegs[_Rt_].SD[0];
	int rd, rs;
	allocRdRs(rd, rs);

	if (cval == 0)
	{
		if (rd != rs)
			armAsm->Mov(armXRegister(rd), armXRegister(rs));
	}
	else
	{
		armAsm->Add(armXRegister(rd), armXRegister(rs), a64::Operand(cval));
	}
	_clearNeededArmGPRs();
}

static void recDADD_(int info)
{
	int rd, rs, rt;
	allocRdRsRt(rd, rs, rt);

	armAsm->Add(armXRegister(rd), armXRegister(rs), armXRegister(rt));
	_clearNeededArmGPRs();
}

EERECOMPILE_CODERC0(DADD, XMMINFO_WRITED | XMMINFO_READS | XMMINFO_READT);

static void recDADDU_const()  { recDADD_const(); }
static void recDADDU_consts(int info) { recDADD_consts(info); }
static void recDADDU_constt(int info) { recDADD_constt(info); }
static void recDADDU_(int info) { recDADD_(info); }
EERECOMPILE_CODERC0(DADDU, XMMINFO_WRITED | XMMINFO_READS | XMMINFO_READT);

// ========================================================================
// DSUB / DSUBU  —  rd = rs - rt  (64-bit)
// ========================================================================

static void recDSUB_const()
{
	g_cpuConstRegs[_Rd_].SD[0] = g_cpuConstRegs[_Rs_].SD[0] - g_cpuConstRegs[_Rt_].SD[0];
}

static void recDSUB_consts(int info)
{
	const s64 cval = g_cpuConstRegs[_Rs_].SD[0];
	int rd, rt;
	allocRdRt(rd, rt);

	if (cval == 0)
	{
		armAsm->Neg(armXRegister(rd), armXRegister(rt));
	}
	else
	{
		armAsm->Mov(a64::x4, cval);
		armAsm->Sub(armXRegister(rd), a64::x4, armXRegister(rt));
	}
	_clearNeededArmGPRs();
}

static void recDSUB_constt(int info)
{
	const s64 cval = g_cpuConstRegs[_Rt_].SD[0];
	int rd, rs;
	allocRdRs(rd, rs);

	if (cval == 0)
	{
		if (rd != rs)
			armAsm->Mov(armXRegister(rd), armXRegister(rs));
	}
	else
	{
		armAsm->Sub(armXRegister(rd), armXRegister(rs), a64::Operand(cval));
	}
	_clearNeededArmGPRs();
}

static void recDSUB_(int info)
{
	int rd, rs, rt;
	allocRdRsRt(rd, rs, rt);

	armAsm->Sub(armXRegister(rd), armXRegister(rs), armXRegister(rt));
	_clearNeededArmGPRs();
}

EERECOMPILE_CODERC0(DSUB, XMMINFO_WRITED | XMMINFO_READS | XMMINFO_READT);

static void recDSUBU_const()  { recDSUB_const(); }
static void recDSUBU_consts(int info) { recDSUB_consts(info); }
static void recDSUBU_constt(int info) { recDSUB_constt(info); }
static void recDSUBU_(int info) { recDSUB_(info); }
EERECOMPILE_CODERC0(DSUBU, XMMINFO_WRITED | XMMINFO_READS | XMMINFO_READT);

// ========================================================================
// AND  —  rd = rs & rt  (64-bit)
// ========================================================================

static void recAND_const()
{
	g_cpuConstRegs[_Rd_].UD[0] = g_cpuConstRegs[_Rs_].UD[0] & g_cpuConstRegs[_Rt_].UD[0];
}

static void recAND_consts(int info)
{
	const u64 cval = g_cpuConstRegs[_Rs_].UD[0];
	int rd, rt;
	allocRdRt(rd, rt);

	if (cval == 0)
		armAsm->Mov(armXRegister(rd), a64::xzr);
	else if (cval == ~(u64)0)
	{
		if (rd != rt)
			armAsm->Mov(armXRegister(rd), armXRegister(rt));
	}
	else
		armAsm->And(armXRegister(rd), armXRegister(rt), a64::Operand(cval));

	_clearNeededArmGPRs();
}

static void recAND_constt(int info)
{
	const u64 cval = g_cpuConstRegs[_Rt_].UD[0];
	int rd, rs;
	allocRdRs(rd, rs);

	if (cval == 0)
		armAsm->Mov(armXRegister(rd), a64::xzr);
	else if (cval == ~(u64)0)
	{
		if (rd != rs)
			armAsm->Mov(armXRegister(rd), armXRegister(rs));
	}
	else
		armAsm->And(armXRegister(rd), armXRegister(rs), a64::Operand(cval));

	_clearNeededArmGPRs();
}

static void recAND_(int info)
{
	int rd, rs, rt;
	allocRdRsRt(rd, rs, rt);

	armAsm->And(armXRegister(rd), armXRegister(rs), armXRegister(rt));
	_clearNeededArmGPRs();
}

EERECOMPILE_CODERC0(AND, XMMINFO_WRITED | XMMINFO_READS | XMMINFO_READT);

// ========================================================================
// OR  —  rd = rs | rt  (64-bit)
// ========================================================================

static void recOR_const()
{
	g_cpuConstRegs[_Rd_].UD[0] = g_cpuConstRegs[_Rs_].UD[0] | g_cpuConstRegs[_Rt_].UD[0];
}

static void recOR_consts(int info)
{
	const u64 cval = g_cpuConstRegs[_Rs_].UD[0];
	int rd, rt;
	allocRdRt(rd, rt);

	if (cval == 0)
	{
		if (rd != rt)
			armAsm->Mov(armXRegister(rd), armXRegister(rt));
	}
	else if (cval == ~(u64)0)
		armAsm->Mov(armXRegister(rd), a64::Operand(~(u64)0));
	else
		armAsm->Orr(armXRegister(rd), armXRegister(rt), a64::Operand(cval));

	_clearNeededArmGPRs();
}

static void recOR_constt(int info)
{
	const u64 cval = g_cpuConstRegs[_Rt_].UD[0];
	int rd, rs;
	allocRdRs(rd, rs);

	if (cval == 0)
	{
		if (rd != rs)
			armAsm->Mov(armXRegister(rd), armXRegister(rs));
	}
	else if (cval == ~(u64)0)
		armAsm->Mov(armXRegister(rd), a64::Operand(~(u64)0));
	else
		armAsm->Orr(armXRegister(rd), armXRegister(rs), a64::Operand(cval));

	_clearNeededArmGPRs();
}

static void recOR_(int info)
{
	int rd, rs, rt;
	allocRdRsRt(rd, rs, rt);

	armAsm->Orr(armXRegister(rd), armXRegister(rs), armXRegister(rt));
	_clearNeededArmGPRs();
}

EERECOMPILE_CODERC0(OR, XMMINFO_WRITED | XMMINFO_READS | XMMINFO_READT);

// ========================================================================
// XOR  —  rd = rs ^ rt  (64-bit)
// ========================================================================

static void recXOR_const()
{
	g_cpuConstRegs[_Rd_].UD[0] = g_cpuConstRegs[_Rs_].UD[0] ^ g_cpuConstRegs[_Rt_].UD[0];
}

static void recXOR_consts(int info)
{
	const u64 cval = g_cpuConstRegs[_Rs_].UD[0];
	int rd, rt;
	allocRdRt(rd, rt);

	if (cval == 0)
	{
		if (rd != rt)
			armAsm->Mov(armXRegister(rd), armXRegister(rt));
	}
	else if (cval == ~(u64)0)
		armAsm->Mvn(armXRegister(rd), armXRegister(rt));
	else
		armAsm->Eor(armXRegister(rd), armXRegister(rt), a64::Operand(cval));

	_clearNeededArmGPRs();
}

static void recXOR_constt(int info)
{
	const u64 cval = g_cpuConstRegs[_Rt_].UD[0];
	int rd, rs;
	allocRdRs(rd, rs);

	if (cval == 0)
	{
		if (rd != rs)
			armAsm->Mov(armXRegister(rd), armXRegister(rs));
	}
	else if (cval == ~(u64)0)
		armAsm->Mvn(armXRegister(rd), armXRegister(rs));
	else
		armAsm->Eor(armXRegister(rd), armXRegister(rs), a64::Operand(cval));

	_clearNeededArmGPRs();
}

static void recXOR_(int info)
{
	int rd, rs, rt;
	allocRdRsRt(rd, rs, rt);

	armAsm->Eor(armXRegister(rd), armXRegister(rs), armXRegister(rt));
	_clearNeededArmGPRs();
}

EERECOMPILE_CODERC0(XOR, XMMINFO_WRITED | XMMINFO_READS | XMMINFO_READT);

// ========================================================================
// NOR  —  rd = ~(rs | rt)  (64-bit)
// ========================================================================

static void recNOR_const()
{
	g_cpuConstRegs[_Rd_].UD[0] = ~(g_cpuConstRegs[_Rs_].UD[0] | g_cpuConstRegs[_Rt_].UD[0]);
}

static void recNOR_consts(int info)
{
	const u64 cval = g_cpuConstRegs[_Rs_].UD[0];
	int rd, rt;
	allocRdRt(rd, rt);

	if (cval == 0)
		armAsm->Mvn(armXRegister(rd), armXRegister(rt));
	else if (cval == ~(u64)0)
		armAsm->Mov(armXRegister(rd), a64::xzr);
	else
	{
		// ORN rd, xzr, rt gives ~rt, but we need ~(cval | rt)
		armAsm->Orr(armXRegister(rd), armXRegister(rt), a64::Operand(cval));
		armAsm->Mvn(armXRegister(rd), armXRegister(rd));
	}
	_clearNeededArmGPRs();
}

static void recNOR_constt(int info)
{
	const u64 cval = g_cpuConstRegs[_Rt_].UD[0];
	int rd, rs;
	allocRdRs(rd, rs);

	if (cval == 0)
		armAsm->Mvn(armXRegister(rd), armXRegister(rs));
	else if (cval == ~(u64)0)
		armAsm->Mov(armXRegister(rd), a64::xzr);
	else
	{
		armAsm->Orr(armXRegister(rd), armXRegister(rs), a64::Operand(cval));
		armAsm->Mvn(armXRegister(rd), armXRegister(rd));
	}
	_clearNeededArmGPRs();
}

static void recNOR_(int info)
{
	int rd, rs, rt;
	allocRdRsRt(rd, rs, rt);

	armAsm->Orr(armXRegister(rd), armXRegister(rs), armXRegister(rt));
	armAsm->Mvn(armXRegister(rd), armXRegister(rd));
	_clearNeededArmGPRs();
}

EERECOMPILE_CODERC0(NOR, XMMINFO_WRITED | XMMINFO_READS | XMMINFO_READT);

// ========================================================================
// SLT  —  rd = (rs < rt) ? 1 : 0  (signed 64-bit comparison)
// ========================================================================

static void recSLT_const()
{
	g_cpuConstRegs[_Rd_].UD[0] = g_cpuConstRegs[_Rs_].SD[0] < g_cpuConstRegs[_Rt_].SD[0];
}

static void recSLT_consts(int info)
{
	const s64 cval = g_cpuConstRegs[_Rs_].SD[0];
	int rd, rt;
	allocRdRt(rd, rt);

	// rd = (cval < rt) ? 1 : 0  →  (rt > cval) ? 1 : 0
	armAsm->Cmp(armXRegister(rt), a64::Operand(cval));
	armAsm->Cset(armXRegister(rd), a64::gt);
	_clearNeededArmGPRs();
}

static void recSLT_constt(int info)
{
	const s64 cval = g_cpuConstRegs[_Rt_].SD[0];
	int rd, rs;
	allocRdRs(rd, rs);

	// rd = (rs < cval) ? 1 : 0
	armAsm->Cmp(armXRegister(rs), a64::Operand(cval));
	armAsm->Cset(armXRegister(rd), a64::lt);
	_clearNeededArmGPRs();
}

static void recSLT_(int info)
{
	int rd, rs, rt;
	allocRdRsRt(rd, rs, rt);

	armAsm->Cmp(armXRegister(rs), armXRegister(rt));
	armAsm->Cset(armXRegister(rd), a64::lt);
	_clearNeededArmGPRs();
}

EERECOMPILE_CODERC0(SLT, XMMINFO_WRITED | XMMINFO_READS | XMMINFO_READT);

// ========================================================================
// SLTU  —  rd = (rs < rt) ? 1 : 0  (unsigned 64-bit comparison)
// ========================================================================

static void recSLTU_const()
{
	g_cpuConstRegs[_Rd_].UD[0] = g_cpuConstRegs[_Rs_].UD[0] < g_cpuConstRegs[_Rt_].UD[0];
}

static void recSLTU_consts(int info)
{
	const u64 cval = g_cpuConstRegs[_Rs_].UD[0];
	int rd, rt;
	allocRdRt(rd, rt);

	// rd = (cval < rt) ? 1 : 0  →  (rt > cval) ? 1 : 0
	armAsm->Cmp(armXRegister(rt), a64::Operand(cval));
	armAsm->Cset(armXRegister(rd), a64::hi);
	_clearNeededArmGPRs();
}

static void recSLTU_constt(int info)
{
	const u64 cval = g_cpuConstRegs[_Rt_].UD[0];
	int rd, rs;
	allocRdRs(rd, rs);

	// rd = (rs < cval) ? 1 : 0
	armAsm->Cmp(armXRegister(rs), a64::Operand(cval));
	armAsm->Cset(armXRegister(rd), a64::lo);
	_clearNeededArmGPRs();
}

static void recSLTU_(int info)
{
	int rd, rs, rt;
	allocRdRsRt(rd, rs, rt);

	armAsm->Cmp(armXRegister(rs), armXRegister(rt));
	armAsm->Cset(armXRegister(rd), a64::lo);
	_clearNeededArmGPRs();
}

EERECOMPILE_CODERC0(SLTU, XMMINFO_WRITED | XMMINFO_READS | XMMINFO_READT);

} // namespace OpcodeImpl
} // namespace Dynarec
} // namespace R5900
