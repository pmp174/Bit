// SPDX-FileCopyrightText: 2002-2026 PCSX2 Dev Team
// SPDX-License-Identifier: GPL-3.0+

// ARM64 EE Recompiler — FPU (COP1) instructions (Phase 2)
//
// Native ARM64 VFP codegen for common FPU operations with PS2 clamping.
// Accumulator ops and branches remain as interpreter fallback.

#include "Common.h"
#include "R5900OpcodeTables.h"
#include "arm64/iR5900.h"
#include "arm64/iCore.h"

namespace a64 = vixl::aarch64;

namespace Interp = R5900::Interpreter::OpcodeImpl::COP1;

// FPU instruction fields (reuse standard MIPS bit fields)
#define _Ft_ _Rt_
#define _Fs_ _Rd_
#define _Fd_ _Sa_

// FPU condition flag in FCR31 (bit 23)
#define FPUflagC  0x00800000u

namespace R5900 {
namespace Dynarec {
namespace OpcodeImpl {
namespace COP1 {

// ========================================================================
// FPU register access helpers
// ========================================================================

// Offset from RCPUSTATE to fpuRegs.fpr[n]
static s64 fpuFprOff(int n)
{
	return (s64)offsetof(cpuRegistersPack, fpuRegs) + n * (s64)sizeof(FPRreg);
}

// Offset from RCPUSTATE to fpuRegs.fprc[n]
static s64 fpuFprcOff(int n)
{
	return (s64)offsetof(cpuRegistersPack, fpuRegs) +
		   (s64)offsetof(fpuRegisters, fprc) + n * 4;
}

// Offset from RCPUSTATE to fpuRegs.ACC
static s64 fpuAccOff()
{
	return (s64)offsetof(cpuRegistersPack, fpuRegs) +
		   (s64)offsetof(fpuRegisters, ACC);
}

// Offset for GPR[rt].SD[0]
static s64 gprOffset(int rt)
{
	return (s64)offsetof(cpuRegisters, GPR) + rt * 16;
}

// ========================================================================
// PS2 FPU output clamping
// Inf/NaN → ±FLT_MAX, denormal → ±0
// Clobbers: w4, w5
// ========================================================================

static void fpuPS2Clamp(const a64::VRegister& sd)
{
	// Move to integer for bit inspection
	armAsm->Fmov(a64::w4, sd);

	// Extract exponent (bits 23-30)
	armAsm->Ubfx(a64::w5, a64::w4, 23, 8);

	// Fast check: if 1 <= exp <= 254, the number is normal → skip
	armAsm->Sub(a64::w5, a64::w5, 1);
	armAsm->Cmp(a64::w5, 253);
	a64::Label done;
	armAsm->B(a64::ls, &done);

	// Restore exponent
	armAsm->Add(a64::w5, a64::w5, 1);

	// Check: exp == 255 → Inf/NaN → ±FLT_MAX
	armAsm->Cmp(a64::w5, 0xFF);
	a64::Label notInf;
	armAsm->B(a64::ne, &notInf);

	// Clamp Inf/NaN to ±FLT_MAX
	armAsm->And(a64::w4, a64::w4, 0x80000000u);  // Keep sign bit
	armAsm->Mov(a64::w5, 0x7F7FFFFFu);            // +FLT_MAX
	armAsm->Orr(a64::w4, a64::w4, a64::w5);
	armAsm->Fmov(sd, a64::w4);
	armAsm->B(&done);

	armAsm->Bind(&notInf);
	// exp == 0: flush denormal to ±0 (zero is already OK but harmless to rewrite)
	armAsm->And(a64::w4, a64::w4, 0x80000000u);
	armAsm->Fmov(sd, a64::w4);

	armAsm->Bind(&done);
}

// ========================================================================
// Register transfer: MFC1 / MTC1 / CFC1 / CTC1
// ========================================================================

void recMFC1()
{
	EE::Profiler.EmitOp(eeOpcode::MFC1);

	if (!_Rt_)
		return;

	// rt = sign_ext(fpuRegs.fpr[fs].UL)
	_addNeededGPRtoArmGPR(_Rt_);
	const int rt = _allocArmGPR(ARMTYPE_GPR, _Rt_, MODE_WRITE);

	armAsm->Ldr(armWRegister(rt), a64::MemOperand(RCPUSTATE, fpuFprOff(_Fs_)));
	armAsm->Sxtw(armXRegister(rt), armWRegister(rt));
	_clearNeededArmGPRs();
}

void recMTC1()
{
	EE::Profiler.EmitOp(eeOpcode::MTC1);

	s64 fsOff = fpuFprOff(_Fs_);

	if (GPR_IS_CONST1(_Rt_))
	{
		armAsm->Mov(a64::w4, g_cpuConstRegs[_Rt_].UL[0]);
		armAsm->Str(a64::w4, a64::MemOperand(RCPUSTATE, fsOff));
	}
	else
	{
		_addNeededGPRtoArmGPR(_Rt_);
		const int rt = _allocArmGPR(ARMTYPE_GPR, _Rt_, MODE_READ);
		armAsm->Str(armWRegister(rt), a64::MemOperand(RCPUSTATE, fsOff));
		_clearNeededArmGPRs();
	}
}

void recCFC1()
{
	EE::Profiler.EmitOp(eeOpcode::CFC1);

	if (!_Rt_)
		return;

	// Only fcr0 and fcr31 are valid
	_addNeededGPRtoArmGPR(_Rt_);
	const int rt = _allocArmGPR(ARMTYPE_GPR, _Rt_, MODE_WRITE);

	if (_Fs_ == 31 || _Fs_ == 0)
	{
		armAsm->Ldr(armWRegister(rt), a64::MemOperand(RCPUSTATE, fpuFprcOff(_Fs_)));
		armAsm->Sxtw(armXRegister(rt), armWRegister(rt));
	}
	else
	{
		armAsm->Mov(armXRegister(rt), a64::xzr);
	}
	_clearNeededArmGPRs();
}

void recCTC1()
{
	EE::Profiler.EmitOp(eeOpcode::CTC1);

	// Only fcr31 is writable
	if (_Fs_ != 31)
		return;

	s64 fcrOff = fpuFprcOff(31);

	if (GPR_IS_CONST1(_Rt_))
	{
		armAsm->Mov(a64::w4, g_cpuConstRegs[_Rt_].UL[0]);
		armAsm->Str(a64::w4, a64::MemOperand(RCPUSTATE, fcrOff));
	}
	else
	{
		_addNeededGPRtoArmGPR(_Rt_);
		const int rt = _allocArmGPR(ARMTYPE_GPR, _Rt_, MODE_READ);
		armAsm->Str(armWRegister(rt), a64::MemOperand(RCPUSTATE, fcrOff));
		_clearNeededArmGPRs();
	}
}

// ========================================================================
// Simple moves: MOV_S / ABS_S / NEG_S
// ========================================================================

void recMOV_S()
{
	EE::Profiler.EmitOp(eeOpcode::MOV_F);

	s64 fsOff = fpuFprOff(_Fs_);
	s64 fdOff = fpuFprOff(_Fd_);

	if (_Fd_ == _Fs_)
		return;  // No-op

	armAsm->Ldr(RSSCRATCH, a64::MemOperand(RCPUSTATE, fsOff));
	armAsm->Str(RSSCRATCH, a64::MemOperand(RCPUSTATE, fdOff));
}

void recABS_S()
{
	EE::Profiler.EmitOp(eeOpcode::ABS_F);

	s64 fsOff = fpuFprOff(_Fs_);
	s64 fdOff = fpuFprOff(_Fd_);

	armAsm->Ldr(RSSCRATCH, a64::MemOperand(RCPUSTATE, fsOff));
	armAsm->Fabs(RSSCRATCH, RSSCRATCH);
	fpuPS2Clamp(RSSCRATCH);
	armAsm->Str(RSSCRATCH, a64::MemOperand(RCPUSTATE, fdOff));
}

void recNEG_S()
{
	EE::Profiler.EmitOp(eeOpcode::NEG_F);

	s64 fsOff = fpuFprOff(_Fs_);
	s64 fdOff = fpuFprOff(_Fd_);

	armAsm->Ldr(RSSCRATCH, a64::MemOperand(RCPUSTATE, fsOff));
	armAsm->Fneg(RSSCRATCH, RSSCRATCH);
	fpuPS2Clamp(RSSCRATCH);
	armAsm->Str(RSSCRATCH, a64::MemOperand(RCPUSTATE, fdOff));
}

// ========================================================================
// Arithmetic: ADD_S / SUB_S / MUL_S / DIV_S / SQRT_S
// All apply PS2 output clamping (Inf→FLT_MAX, denormal→0)
// ========================================================================

void recADD_S()
{
	EE::Profiler.EmitOp(eeOpcode::ADD_F);

	armAsm->Ldr(RSSCRATCH, a64::MemOperand(RCPUSTATE, fpuFprOff(_Fs_)));
	armAsm->Ldr(RSSCRATCH2, a64::MemOperand(RCPUSTATE, fpuFprOff(_Ft_)));
	armAsm->Fadd(RSSCRATCH, RSSCRATCH, RSSCRATCH2);
	fpuPS2Clamp(RSSCRATCH);
	armAsm->Str(RSSCRATCH, a64::MemOperand(RCPUSTATE, fpuFprOff(_Fd_)));
}

void recSUB_S()
{
	EE::Profiler.EmitOp(eeOpcode::SUB_F);

	armAsm->Ldr(RSSCRATCH, a64::MemOperand(RCPUSTATE, fpuFprOff(_Fs_)));
	armAsm->Ldr(RSSCRATCH2, a64::MemOperand(RCPUSTATE, fpuFprOff(_Ft_)));
	armAsm->Fsub(RSSCRATCH, RSSCRATCH, RSSCRATCH2);
	fpuPS2Clamp(RSSCRATCH);
	armAsm->Str(RSSCRATCH, a64::MemOperand(RCPUSTATE, fpuFprOff(_Fd_)));
}

void recMUL_S()
{
	EE::Profiler.EmitOp(eeOpcode::MUL_F);

	armAsm->Ldr(RSSCRATCH, a64::MemOperand(RCPUSTATE, fpuFprOff(_Fs_)));
	armAsm->Ldr(RSSCRATCH2, a64::MemOperand(RCPUSTATE, fpuFprOff(_Ft_)));
	armAsm->Fmul(RSSCRATCH, RSSCRATCH, RSSCRATCH2);
	fpuPS2Clamp(RSSCRATCH);
	armAsm->Str(RSSCRATCH, a64::MemOperand(RCPUSTATE, fpuFprOff(_Fd_)));
}

void recDIV_S()
{
	EE::Profiler.EmitOp(eeOpcode::DIV_F);

	armAsm->Ldr(RSSCRATCH, a64::MemOperand(RCPUSTATE, fpuFprOff(_Fs_)));
	armAsm->Ldr(RSSCRATCH2, a64::MemOperand(RCPUSTATE, fpuFprOff(_Ft_)));
	armAsm->Fdiv(RSSCRATCH, RSSCRATCH, RSSCRATCH2);
	fpuPS2Clamp(RSSCRATCH);  // Handles x/0 → ±FLT_MAX, 0/0 → FLT_MAX
	armAsm->Str(RSSCRATCH, a64::MemOperand(RCPUSTATE, fpuFprOff(_Fd_)));
}

void recSQRT_S()
{
	EE::Profiler.EmitOp(eeOpcode::SQRT_F);

	armAsm->Ldr(RSSCRATCH, a64::MemOperand(RCPUSTATE, fpuFprOff(_Ft_)));
	// PS2 takes abs before sqrt (negative inputs → sqrt(|x|))
	armAsm->Fabs(RSSCRATCH, RSSCRATCH);
	armAsm->Fsqrt(RSSCRATCH, RSSCRATCH);
	fpuPS2Clamp(RSSCRATCH);
	armAsm->Str(RSSCRATCH, a64::MemOperand(RCPUSTATE, fpuFprOff(_Fd_)));
}

// RSQRT_S is complex — interpreter fallback
REC_FUNC(RSQRT_S);

// ========================================================================
// Comparison: C_F / C_EQ / C_LT / C_LE
// Set FPUflagC (bit 23) in fpuRegs.fprc[31]
// ========================================================================

// C_F: always false (clear condition flag)
void recC_F()
{
	EE::Profiler.EmitOp(eeOpcode::CF_F);

	s64 fcrOff = fpuFprcOff(31);
	armAsm->Ldr(a64::w4, a64::MemOperand(RCPUSTATE, fcrOff));
	armAsm->Mov(a64::w5, FPUflagC);
	armAsm->Bic(a64::w4, a64::w4, a64::w5);
	armAsm->Str(a64::w4, a64::MemOperand(RCPUSTATE, fcrOff));
}

// Helper: compare fs,ft and conditionally set FPUflagC
static void recFPUCompare(a64::Condition cond)
{
	armAsm->Ldr(RSSCRATCH, a64::MemOperand(RCPUSTATE, fpuFprOff(_Fs_)));
	armAsm->Ldr(RSSCRATCH2, a64::MemOperand(RCPUSTATE, fpuFprOff(_Ft_)));
	armAsm->Fcmp(RSSCRATCH, RSSCRATCH2);

	s64 fcrOff = fpuFprcOff(31);
	armAsm->Ldr(a64::w4, a64::MemOperand(RCPUSTATE, fcrOff));
	armAsm->Mov(a64::w5, FPUflagC);
	armAsm->Bic(a64::w4, a64::w4, a64::w5);      // Clear flag

	// Conditionally OR in the flag using CSET + shifted ORR
	armAsm->Cset(a64::w6, cond);
	armAsm->Orr(a64::w4, a64::w4, a64::Operand(a64::w6, a64::LSL, 23));

	armAsm->Str(a64::w4, a64::MemOperand(RCPUSTATE, fcrOff));
}

// C_EQ: ordered equal (NaN → false)
void recC_EQ()
{
	EE::Profiler.EmitOp(eeOpcode::CEQ_F);
	recFPUCompare(a64::eq);
}

// C_LT: ordered less-than (NaN → false). Use MI (N==1), not LT (N!=V).
void recC_LT()
{
	EE::Profiler.EmitOp(eeOpcode::CLT_F);
	recFPUCompare(a64::mi);
}

// C_LE: ordered less-or-equal (NaN → false). Use LS (!C||Z), not LE (Z||N!=V).
void recC_LE()
{
	EE::Profiler.EmitOp(eeOpcode::CLE_F);
	recFPUCompare(a64::ls);
}

// ========================================================================
// Min / Max
// ========================================================================

void recMAX_S()
{
	EE::Profiler.EmitOp(eeOpcode::MAX_F);

	armAsm->Ldr(RSSCRATCH, a64::MemOperand(RCPUSTATE, fpuFprOff(_Fs_)));
	armAsm->Ldr(RSSCRATCH2, a64::MemOperand(RCPUSTATE, fpuFprOff(_Ft_)));
	armAsm->Fmax(RSSCRATCH, RSSCRATCH, RSSCRATCH2);
	armAsm->Str(RSSCRATCH, a64::MemOperand(RCPUSTATE, fpuFprOff(_Fd_)));
}

void recMIN_S()
{
	EE::Profiler.EmitOp(eeOpcode::MIN_F);

	armAsm->Ldr(RSSCRATCH, a64::MemOperand(RCPUSTATE, fpuFprOff(_Fs_)));
	armAsm->Ldr(RSSCRATCH2, a64::MemOperand(RCPUSTATE, fpuFprOff(_Ft_)));
	armAsm->Fmin(RSSCRATCH, RSSCRATCH, RSSCRATCH2);
	armAsm->Str(RSSCRATCH, a64::MemOperand(RCPUSTATE, fpuFprOff(_Fd_)));
}

// ========================================================================
// Conversion: CVT_S (int→float) / CVT_W (float→int)
// ========================================================================

void recCVT_S()
{
	EE::Profiler.EmitOp(eeOpcode::CVTS_F);

	s64 fsOff = fpuFprOff(_Fs_);
	s64 fdOff = fpuFprOff(_Fd_);

	// Load integer value
	armAsm->Ldr(a64::w4, a64::MemOperand(RCPUSTATE, fsOff));
	// Convert signed int to float
	armAsm->Scvtf(RSSCRATCH, a64::w4);
	armAsm->Str(RSSCRATCH, a64::MemOperand(RCPUSTATE, fdOff));
}

void recCVT_W()
{
	EE::Profiler.EmitOp(eeOpcode::CVTW);

	s64 fsOff = fpuFprOff(_Fs_);
	s64 fdOff = fpuFprOff(_Fd_);

	// Load float value
	armAsm->Ldr(RSSCRATCH, a64::MemOperand(RCPUSTATE, fsOff));

	// Convert float to signed int (round toward zero, saturate)
	armAsm->Fcvtzs(a64::w4, RSSCRATCH);

	// PS2 quirk: NaN → 0x7FFFFFFF (ARM64 gives 0 for NaN)
	armAsm->Fcmp(RSSCRATCH, RSSCRATCH);           // NaN != NaN sets V flag
	armAsm->Mov(a64::w5, 0x7FFFFFFFu);
	armAsm->Csel(a64::w4, a64::w5, a64::w4, a64::vs);  // If NaN, use INT_MAX

	armAsm->Str(a64::w4, a64::MemOperand(RCPUSTATE, fdOff));
}

// ========================================================================
// Accumulator ops — interpreter fallback
// ========================================================================
REC_FUNC(ADDA_S);
REC_FUNC(SUBA_S);
REC_FUNC(MULA_S);
REC_FUNC(MADD_S);
REC_FUNC(MSUB_S);
REC_FUNC(MADDA_S);
REC_FUNC(MSUBA_S);

// ========================================================================
// FPU branches — interpreter fallback (branch instructions)
// ========================================================================
REC_SYS(BC1F);
REC_SYS(BC1T);
REC_SYS(BC1FL);
REC_SYS(BC1TL);

} // namespace COP1
} // namespace OpcodeImpl
} // namespace Dynarec
} // namespace R5900
