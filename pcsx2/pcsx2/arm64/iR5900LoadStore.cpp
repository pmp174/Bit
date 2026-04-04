// SPDX-FileCopyrightText: 2002-2026 PCSX2 Dev Team
// SPDX-License-Identifier: GPL-3.0+

// ARM64 EE Recompiler — Load/Store instructions (Phase 2)
//
// Native address computation + C vtlb function calls for common ops.
// Unaligned ops and COP1/COP2 memory ops remain as interpreter fallback.

#include "Common.h"
#include "R5900OpcodeTables.h"
#include "arm64/iR5900.h"
#include "arm64/iCore.h"
#include "vtlb.h"

namespace a64 = vixl::aarch64;

namespace Interp = R5900::Interpreter::OpcodeImpl;

namespace R5900 {
namespace Dynarec {
namespace OpcodeImpl {

// ========================================================================
// Helpers
// ========================================================================

// Offset for GPR[rt].SD[0] in cpuRegs (lower 64 bits of 128-bit register)
static s64 gprOffset(int rt)
{
	return (s64)offsetof(cpuRegisters, GPR) + rt * 16;
}

// Compute effective address into RWARG1 (w0): addr = Rs + sign_ext(Imm16)
// Must be called AFTER register flush (so memory state is up to date).
static void computeAddress()
{
	if (GPR_IS_CONST1(_Rs_))
	{
		u32 addr = g_cpuConstRegs[_Rs_].UL[0] + _Imm_;
		armAsm->Mov(RWARG1, addr);
	}
	else
	{
		_eeMoveGPRtoR(RWARG1, _Rs_);
		if (_Imm_ != 0)
			armAsm->Add(RWARG1, RWARG1, (s32)_Imm_);
	}
}

// ========================================================================
// Loads: LB, LBU, LH, LHU, LW, LWU, LD, LQ
// Pattern: flush → compute addr → call vtlb → extend → store to GPR
// ========================================================================

void recLB()
{
	EE::Profiler.EmitOp(eeOpcode::LB);
	iFlushCall(FLUSH_EVERYTHING);
	computeAddress();
	armEmitCall(reinterpret_cast<const void*>(&vtlb_memRead<mem8_t>));
	if (_Rt_)
	{
		armAsm->Sxtb(RXRET, RWRET);
		armAsm->Str(RXRET, a64::MemOperand(RCPUSTATE, gprOffset(_Rt_)));
		GPR_DEL_CONST(_Rt_);
	}
}

void recLBU()
{
	EE::Profiler.EmitOp(eeOpcode::LBU);
	iFlushCall(FLUSH_EVERYTHING);
	computeAddress();
	armEmitCall(reinterpret_cast<const void*>(&vtlb_memRead<mem8_t>));
	if (_Rt_)
	{
		// Uxtb clears bits 8-31 of w0; writing w0 also clears bits 32-63 of x0
		armAsm->Uxtb(RWRET, RWRET);
		armAsm->Str(RXRET, a64::MemOperand(RCPUSTATE, gprOffset(_Rt_)));
		GPR_DEL_CONST(_Rt_);
	}
}

void recLH()
{
	EE::Profiler.EmitOp(eeOpcode::LH);
	iFlushCall(FLUSH_EVERYTHING);
	computeAddress();
	armEmitCall(reinterpret_cast<const void*>(&vtlb_memRead<mem16_t>));
	if (_Rt_)
	{
		armAsm->Sxth(RXRET, RWRET);
		armAsm->Str(RXRET, a64::MemOperand(RCPUSTATE, gprOffset(_Rt_)));
		GPR_DEL_CONST(_Rt_);
	}
}

void recLHU()
{
	EE::Profiler.EmitOp(eeOpcode::LHU);
	iFlushCall(FLUSH_EVERYTHING);
	computeAddress();
	armEmitCall(reinterpret_cast<const void*>(&vtlb_memRead<mem16_t>));
	if (_Rt_)
	{
		armAsm->Uxth(RWRET, RWRET);
		armAsm->Str(RXRET, a64::MemOperand(RCPUSTATE, gprOffset(_Rt_)));
		GPR_DEL_CONST(_Rt_);
	}
}

void recLW()
{
	EE::Profiler.EmitOp(eeOpcode::LW);
	iFlushCall(FLUSH_EVERYTHING);
	computeAddress();
	armEmitCall(reinterpret_cast<const void*>(&vtlb_memRead<mem32_t>));
	if (_Rt_)
	{
		armAsm->Sxtw(RXRET, RWRET);
		armAsm->Str(RXRET, a64::MemOperand(RCPUSTATE, gprOffset(_Rt_)));
		GPR_DEL_CONST(_Rt_);
	}
}

void recLWU()
{
	EE::Profiler.EmitOp(eeOpcode::LWU);
	iFlushCall(FLUSH_EVERYTHING);
	computeAddress();
	armEmitCall(reinterpret_cast<const void*>(&vtlb_memRead<mem32_t>));
	if (_Rt_)
	{
		// w0 → x0 already zero-extends upper 32 bits on ARM64
		armAsm->Str(RXRET, a64::MemOperand(RCPUSTATE, gprOffset(_Rt_)));
		GPR_DEL_CONST(_Rt_);
	}
}

void recLD()
{
	EE::Profiler.EmitOp(eeOpcode::LD);
	iFlushCall(FLUSH_EVERYTHING);
	computeAddress();
	armEmitCall(reinterpret_cast<const void*>(&vtlb_memRead<mem64_t>));
	if (_Rt_)
	{
		armAsm->Str(RXRET, a64::MemOperand(RCPUSTATE, gprOffset(_Rt_)));
		GPR_DEL_CONST(_Rt_);
	}
}

void recLQ()
{
	EE::Profiler.EmitOp(eeOpcode::LQ);
	iFlushCall(FLUSH_EVERYTHING);
	computeAddress();
	armAsm->And(RWARG1, RWARG1, ~0xFu);  // Align to 16 bytes
	armEmitCall(reinterpret_cast<const void*>(&vtlb_memRead128));
	if (_Rt_)
	{
		// Result in q0 (RQRET), store 128 bits to GPR[Rt]
		armAsm->Str(RQRET, a64::MemOperand(RCPUSTATE, gprOffset(_Rt_)));
		GPR_DEL_CONST(_Rt_);
	}
}

// ========================================================================
// Stores: SB, SH, SW, SD, SQ
// Pattern: flush → compute addr → load value → call vtlb
// ========================================================================

void recSB()
{
	EE::Profiler.EmitOp(eeOpcode::SB);
	iFlushCall(FLUSH_EVERYTHING);
	computeAddress();
	_eeMoveGPRtoR(RWARG2, _Rt_);
	armEmitCall(reinterpret_cast<const void*>(&vtlb_memWrite<mem8_t>));
}

void recSH()
{
	EE::Profiler.EmitOp(eeOpcode::SH);
	iFlushCall(FLUSH_EVERYTHING);
	computeAddress();
	_eeMoveGPRtoR(RWARG2, _Rt_);
	armEmitCall(reinterpret_cast<const void*>(&vtlb_memWrite<mem16_t>));
}

void recSW()
{
	EE::Profiler.EmitOp(eeOpcode::SW);
	iFlushCall(FLUSH_EVERYTHING);
	computeAddress();
	_eeMoveGPRtoR(RWARG2, _Rt_);
	armEmitCall(reinterpret_cast<const void*>(&vtlb_memWrite<mem32_t>));
}

void recSD()
{
	EE::Profiler.EmitOp(eeOpcode::SD);
	iFlushCall(FLUSH_EVERYTHING);
	computeAddress();
	_eeMoveGPRtoR(RXARG2, _Rt_);
	armEmitCall(reinterpret_cast<const void*>(&vtlb_memWrite<mem64_t>));
}

void recSQ()
{
	EE::Profiler.EmitOp(eeOpcode::SQ);
	iFlushCall(FLUSH_EVERYTHING);
	computeAddress();
	armAsm->And(RWARG1, RWARG1, ~0xFu);  // Align to 16 bytes
	// Load 128-bit GPR[Rt] into q0 for the vtlb call
	armAsm->Ldr(a64::q0, a64::MemOperand(RCPUSTATE, gprOffset(_Rt_)));
	armEmitCall(reinterpret_cast<const void*>(&vtlb_memWrite128));
}

// ========================================================================
// Unaligned loads/stores — interpreter fallback
// ========================================================================
REC_FUNC(LWL);
REC_FUNC(LWR);
REC_FUNC(LDL);
REC_FUNC(LDR);
REC_FUNC(SWL);
REC_FUNC(SWR);
REC_FUNC(SDL);
REC_FUNC(SDR);

// ========================================================================
// COP1/COP2 memory ops — interpreter fallback
// ========================================================================
REC_FUNC(LWC1);
REC_FUNC(SWC1);
REC_FUNC(LQC2);
REC_FUNC(SQC2);

} // namespace OpcodeImpl
} // namespace Dynarec
} // namespace R5900
