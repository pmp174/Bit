// SPDX-FileCopyrightText: 2002-2026 PCSX2 Dev Team
// SPDX-License-Identifier: GPL-3.0+

// ARM64 Register Allocator Implementation
// Ported from x86/iCore.cpp and x86/ix86-32/iCore.cpp
//
// Manages:
//   1. ARM64 GPR allocation (6 callee-saved registers x23-x28)
//   2. NEON 128-bit register allocation (8 callee-saved registers q8-q15)
//   3. Constant register flushing

#include "Common.h"
#include "R3000A.h"
#include "VU.h"
#include "arm64/iCore.h"
#include "arm64/iR5900.h"
#include "arm64/AsmHelpers.h"
#include "R5900.h"

namespace a64 = vixl::aarch64;

// ========================================================================
// Global allocator state
// ========================================================================

u16 g_armGPRAllocCounter = 0;
u16 g_neonAllocCounter = 0;

EEINST* g_pCurInstInfo = nullptr;

_armGPRreg armGPRregs[ARMGPR_COUNT], s_saveArmGPRregs[ARMGPR_COUNT];
_neonregs neonregs[ARMNEON_COUNT], s_saveNeonregs[ARMNEON_COUNT];

// Compatibility alias: xmmregs_alias() returns neonregs pointer
_xmmregs* xmmregs_alias() { return neonregs; }

// ========================================================================
// ARM64 GPR Register Allocation
// ========================================================================

void _initArmGPRregs()
{
	std::memset(armGPRregs, 0, sizeof(armGPRregs));
	g_armGPRAllocCounter = 0;
}

// Find a free GPR slot. Evicts LRU if all are in use.
int _getFreeArmGPR(int mode)
{
	int tempi = -1;
	u32 bestcount = 0x10000;

	// First pass: find an unused slot
	for (int i = 0; i < ARMGPR_COUNT; i++)
	{
		if (!armGPRregs[i].inuse)
			return i;
	}

	// Second pass: find the LRU slot that isn't needed, preferring temps
	for (int i = 0; i < ARMGPR_COUNT; i++)
	{
		pxAssert(armGPRregs[i].inuse);
		if (armGPRregs[i].needed)
			continue;

		if (armGPRregs[i].type == ARMTYPE_TEMP)
		{
			_freeArmGPR(armGPRSlotToReg(i));
			return i;
		}

		if (armGPRregs[i].counter < bestcount)
		{
			tempi = i;
			bestcount = armGPRregs[i].counter;
		}
	}

	if (tempi != -1)
	{
		_freeArmGPR(armGPRSlotToReg(tempi));
		return tempi;
	}

	pxFailRel("*PCSX2*: ARM64 GPR Reg Allocation Error in _getFreeArmGPR()!");
	return -1;
}

// Write back a GPR slot to memory. Emits str instruction via VIXL.
void _writebackArmGPR(int armreg)
{
	const int slot = armGPRRegToSlot(armreg);
	pxAssert(slot >= 0 && slot < ARMGPR_COUNT);

	switch (armGPRregs[slot].type)
	{
		case ARMTYPE_GPR:
		{
			RALOG("Writing back ARM GPR slot %d (x%d) for guest reg %d\n", slot, armreg, armGPRregs[slot].reg);
			pxAssert(armGPRregs[slot].reg != 0);
			// Store 64-bit value (sign-extended lower 64 bits of 128-bit MIPS GPR)
			armAsm->Str(armXRegister(armreg),
				a64::MemOperand(RCPUSTATE, (s64)offsetof(cpuRegisters, GPR.r[armGPRregs[slot].reg].UD[0])));
		}
		break;

		case ARMTYPE_FPRC:
		{
			RALOG("Writing back ARM GPR slot %d (x%d) for guest FPCR %d\n", slot, armreg, armGPRregs[slot].reg);
			armAsm->Str(armWRegister(armreg),
				a64::MemOperand(RCPUSTATE,
					(s64)(offsetof(cpuRegisters, GPR) + sizeof(GPRregs) + sizeof(GPR_reg) * 2 +
						  sizeof(CP0regs) + sizeof(u32) /* sa */ + sizeof(u32) /* IsDelaySlot */ +
						  sizeof(u32) /* pc */ + sizeof(u32) /* code */)));
			// Actually, fpuRegs is in the same cpuRegistersPack, but not at a fixed offset from cpuRegs.
			// We need to use the absolute address approach instead.
			// Recalculate: fpuRegs is a separate global aligned alongside cpuRegs.
			armMoveAddressToReg(RSCRATCHADDR, &fpuRegs.fprc[armGPRregs[slot].reg]);
			armAsm->Str(armWRegister(armreg), a64::MemOperand(RSCRATCHADDR));
		}
		break;

		case ARMTYPE_VIREG:
		{
			RALOG("Writing back ARM GPR slot %d (x%d) for guest VI reg %d\n", slot, armreg, armGPRregs[slot].reg);
			armMoveAddressToReg(RSCRATCHADDR, &VU0.VI[armGPRregs[slot].reg].UL);
			armAsm->Strh(armWRegister(armreg), a64::MemOperand(RSCRATCHADDR));
		}
		break;

		case ARMTYPE_PCWRITEBACK:
		{
			RALOG("Writing back PC writeback in ARM GPR slot %d (x%d)\n", slot, armreg);
			armAsm->Str(armWRegister(armreg), MEMBASE_PTR(pcWriteback));
		}
		break;

		case ARMTYPE_PSX:
		{
			RALOG("Writing back ARM GPR slot %d (x%d) for guest PSX reg %d\n", slot, armreg, armGPRregs[slot].reg);
			pxAssert(armGPRregs[slot].reg != 0);
			armMoveAddressToReg(RSCRATCHADDR, &psxRegs.GPR.r[armGPRregs[slot].reg]);
			armAsm->Str(armWRegister(armreg), a64::MemOperand(RSCRATCHADDR));
		}
		break;

		case ARMTYPE_PSX_PCWRITEBACK:
		{
			RALOG("Writing back PSX PC writeback in ARM GPR slot %d (x%d)\n", slot, armreg);
			armMoveAddressToReg(RSCRATCHADDR, &psxRegs.pcWriteback);
			armAsm->Str(armWRegister(armreg), a64::MemOperand(RSCRATCHADDR));
		}
		break;

		case ARMTYPE_TEMP:
			// Temp registers don't need writeback
			break;

		default:
			pxFailRel("Unexpected ARM GPR type in writeback");
			break;
	}
}

// Allocate a GPR slot for the given type/reg/mode.
// If the register is already allocated, update its mode and return it.
// Otherwise, allocate a free slot and load the value if MODE_READ.
int _allocArmGPR(int type, int reg, int mode)
{
	if (type == ARMTYPE_GPR || type == ARMTYPE_PSX)
	{
		pxAssertMsg(reg >= 0 && reg < 34, "Register index out of bounds.");
	}

	// Check for NEON conflict when allocating GPR for a MIPS GPR in write mode
	const int hostNeonReg = (type == ARMTYPE_GPR) ? _checkNeonreg(XMMTYPE_GPRREG, reg, 0) : -1;

	if (type != ARMTYPE_TEMP)
	{
		for (int i = 0; i < ARMGPR_COUNT; i++)
		{
			if (!armGPRregs[i].inuse || armGPRregs[i].type != type || armGPRregs[i].reg != reg)
				continue;

			pxAssert(type != ARMTYPE_GPR || !GPR_IS_CONST1(reg) ||
				(GPR_IS_CONST1(reg) && g_cpuFlushedConstReg & (1u << reg)));

			// Can't go from write-only to read-only
			pxAssert(!((armGPRregs[i].mode & (MODE_READ | MODE_WRITE)) == MODE_WRITE &&
				(mode & (MODE_READ | MODE_WRITE)) == MODE_READ));

			if (type == ARMTYPE_GPR)
			{
				RALOG("Reusing ARM GPR slot %d for guest reg %d\n", i, reg);
				if (mode & MODE_WRITE)
				{
					if (GPR_IS_CONST1(reg))
					{
						RALOG("Clearing constant value for guest reg %d on write mode change\n", reg);
						GPR_DEL_CONST(reg);
					}
					if (hostNeonReg >= 0)
					{
						RALOG("Invalidating NEON reg %d for guest reg %d due to GPR write\n", hostNeonReg, reg);
						pxAssert(!(neonregs[hostNeonReg].mode & MODE_WRITE));
						_freeNeonreg(hostNeonReg);
					}
				}
			}
			else if (type == ARMTYPE_VIREG)
			{
				// Keep VI temporaries separate
				if (reg < 0)
					continue;
			}

			armGPRregs[i].counter = g_armGPRAllocCounter++;
			armGPRregs[i].mode |= mode & ~MODE_CALLEESAVED;
			armGPRregs[i].needed = 1;
			return armGPRSlotToReg(i);
		}
	}

	// Not already allocated — get a free slot
	const int slot = _getFreeArmGPR(mode);
	const int armreg = armGPRSlotToReg(slot);

	armGPRregs[slot].type = type;
	armGPRregs[slot].reg = reg;
	armGPRregs[slot].mode = mode & ~MODE_CALLEESAVED;
	armGPRregs[slot].counter = g_armGPRAllocCounter++;
	armGPRregs[slot].needed = 1;
	armGPRregs[slot].inuse = 1;

	if (type == ARMTYPE_GPR)
	{
		RALOG("Allocating ARM GPR slot %d (x%d) for guest reg %d\n", slot, armreg, reg);

		// Clear const flag when writing to a GPR (new allocation path)
		if ((mode & MODE_WRITE) && GPR_IS_CONST1(reg))
		{
			RALOG("Clearing constant value for guest reg %d on new write alloc\n", reg);
			GPR_DEL_CONST(reg);
		}

		// Clear any NEON allocation that holds this GPR when writing
		if (mode & MODE_WRITE)
		{
			const int hostNeonReg = _checkNeonreg(XMMTYPE_GPRREG, reg, 0);
			if (hostNeonReg >= 0)
			{
				RALOG("Invalidating NEON reg %d for guest reg %d due to new GPR write\n", hostNeonReg, reg);
				_freeNeonreg(hostNeonReg);
			}
		}
	}

	if (mode & MODE_READ)
	{
		switch (type)
		{
			case ARMTYPE_GPR:
			{
				if (reg == 0)
				{
					// $zero is always 0
					armAsm->Mov(armWRegister(armreg), 0);
				}
				else
				{
					if (hostNeonReg >= 0)
					{
						// Value is in a NEON register — extract lower 64 bits
						RALOG("Copying guest reg %d from NEON %d to GPR x%d\n", reg, hostNeonReg, armreg);
						armAsm->Fmov(armXRegister(armreg), armDRegister(hostNeonReg + ARMNEON_FIRST));

						// If the NEON reg was dirty, free it to avoid sync issues
						if (neonregs[hostNeonReg].mode & MODE_WRITE)
						{
							RALOG("Freeing dirty NEON %d for guest reg %d\n", hostNeonReg, reg);
							_freeNeonreg(hostNeonReg);
						}
					}
					else if (GPR_IS_CONST1(reg))
					{
						RALOG("Loading constant %lld for guest reg %d to GPR x%d\n",
							g_cpuConstRegs[reg].SD[0], reg, armreg);
						armAsm->Mov(armXRegister(armreg), (s64)g_cpuConstRegs[reg].SD[0]);
						g_cpuFlushedConstReg |= (1u << reg);
						armGPRregs[slot].mode |= MODE_WRITE; // reg is dirty (contains const value)
					}
					else
					{
						// Load from cpuRegs memory
						RALOG("Loading guest reg %d from memory to GPR x%d\n", reg, armreg);
						armAsm->Ldr(armXRegister(armreg),
							a64::MemOperand(RCPUSTATE, (s64)offsetof(cpuRegisters, GPR.r[reg].UD[0])));
					}
				}
			}
			break;

			case ARMTYPE_FPRC:
			{
				RALOG("Loading guest FPCR %d to GPR x%d\n", reg, armreg);
				armMoveAddressToReg(RSCRATCHADDR, &fpuRegs.fprc[reg]);
				armAsm->Ldr(armWRegister(armreg), a64::MemOperand(RSCRATCHADDR));
			}
			break;

			case ARMTYPE_PSX:
			{
				if (reg == 0)
				{
					armAsm->Mov(armWRegister(armreg), 0);
				}
				else
				{
					RALOG("Loading guest PSX reg %d to GPR x%d\n", reg, armreg);
					armMoveAddressToReg(RSCRATCHADDR, &psxRegs.GPR.r[reg]);
					armAsm->Ldr(armWRegister(armreg), a64::MemOperand(RSCRATCHADDR));
				}
			}
			break;

			case ARMTYPE_VIREG:
			{
				RALOG("Loading guest VI reg %d to GPR x%d\n", reg, armreg);
				armMoveAddressToReg(RSCRATCHADDR, &VU0.VI[reg].UL);
				armAsm->Ldrh(armWRegister(armreg), a64::MemOperand(RSCRATCHADDR));
			}
			break;

			default:
				break;
		}
	}

	// Handle write-mode side effects
	if (type == ARMTYPE_GPR && (mode & MODE_WRITE))
	{
		if (reg < 32 && GPR_IS_CONST1(reg))
		{
			RALOG("Clearing constant value for guest reg %d on write alloc\n", reg);
			GPR_DEL_CONST(reg);
		}
		if (hostNeonReg >= 0)
		{
			RALOG("Invalidating NEON %d for guest reg %d due to GPR write alloc\n", hostNeonReg, reg);
			_freeNeonreg(hostNeonReg);
		}
	}

	return armreg;
}

// Check if a register is already allocated. If so, update mode and return the ARM reg number.
// Returns -1 if not found.
int _checkArmGPR(int type, int reg, int mode)
{
	for (int i = 0; i < ARMGPR_COUNT; i++)
	{
		if (armGPRregs[i].inuse && armGPRregs[i].reg == reg && armGPRregs[i].type == type)
		{
			// Shouldn't have dirty constants
			pxAssert(type != ARMTYPE_GPR || !GPR_IS_DIRTY_CONST(reg));

			if ((type == ARMTYPE_GPR || type == ARMTYPE_PSX) &&
				!(armGPRregs[i].mode & MODE_READ) && (mode & MODE_READ))
			{
				pxFailRel("Somehow ended up with an allocated ARM GPR without mode");
			}

			// For GPR write, go through the alloc path to handle NEON invalidation
			if (mode & MODE_WRITE)
			{
				if (type == ARMTYPE_GPR)
					return _allocArmGPR(ARMTYPE_GPR, reg, mode);
			}

			armGPRregs[i].mode |= mode;
			armGPRregs[i].counter = g_armGPRAllocCounter++;
			armGPRregs[i].needed = 1;
			return armGPRSlotToReg(i);
		}
	}

	return -1;
}

bool _hasArmGPR(int type, int reg, int required_mode)
{
	for (int i = 0; i < ARMGPR_COUNT; i++)
	{
		if (armGPRregs[i].inuse && armGPRregs[i].type == type && armGPRregs[i].reg == reg)
		{
			return ((armGPRregs[i].mode & required_mode) == required_mode);
		}
	}
	return false;
}

void _addNeededArmGPR(int type, int reg)
{
	for (int i = 0; i < ARMGPR_COUNT; i++)
	{
		if (!armGPRregs[i].inuse || armGPRregs[i].reg != reg || armGPRregs[i].type != type)
			continue;

		armGPRregs[i].counter = g_armGPRAllocCounter++;
		armGPRregs[i].needed = 1;
	}
}

void _clearNeededArmGPRs()
{
	for (int i = 0; i < ARMGPR_COUNT; i++)
	{
		if (armGPRregs[i].needed)
		{
			if (armGPRregs[i].inuse && (armGPRregs[i].mode & MODE_WRITE))
				armGPRregs[i].mode |= MODE_READ;
		}
		armGPRregs[i].needed = 0;
	}
}

void _freeArmGPR(int armreg)
{
	const int slot = armGPRRegToSlot(armreg);
	pxAssert(slot >= 0 && slot < ARMGPR_COUNT);

	if (armGPRregs[slot].inuse && (armGPRregs[slot].mode & MODE_WRITE))
	{
		_writebackArmGPR(armreg);
		armGPRregs[slot].mode &= ~MODE_WRITE;
	}

	_freeArmGPRWithoutWriteback(armreg);
}

void _freeArmGPRWithoutWriteback(int armreg)
{
	const int slot = armGPRRegToSlot(armreg);
	pxAssert(slot >= 0 && slot < ARMGPR_COUNT);
	armGPRregs[slot].inuse = 0;
}

void _freeArmGPRs()
{
	for (int i = 0; i < ARMGPR_COUNT; i++)
		_freeArmGPR(armGPRSlotToReg(i));
}

void _flushArmGPRregs()
{
	for (int i = 0; i < ARMGPR_COUNT; i++)
	{
		if (armGPRregs[i].inuse && (armGPRregs[i].mode & MODE_WRITE))
		{
			pxAssert(armGPRregs[i].type != ARMTYPE_GPR || !GPR_IS_DIRTY_CONST(armGPRregs[i].reg));

			RALOG("Flushing ARM GPR slot %d\n", i);
			_writebackArmGPR(armGPRSlotToReg(i));
			armGPRregs[i].mode = (armGPRregs[i].mode & ~MODE_WRITE) | MODE_READ;
		}
	}
}

// ========================================================================
// Constant Register Flushing
// ========================================================================

void _flushConstReg(int reg)
{
	if (GPR_IS_CONST1(reg) && !(g_cpuFlushedConstReg & (1u << reg)))
	{
		RALOG("Flushing constant reg %d (value %lld)\n", reg, g_cpuConstRegs[reg].SD[0]);

		if (reg == 0)
			DevCon.Warning("Flushing r0!");

		// Load the constant value into a scratch register, then store to cpuRegs
		armAsm->Mov(RXVIXLSCRATCH, (s64)g_cpuConstRegs[reg].SD[0]);
		armAsm->Str(RXVIXLSCRATCH,
			a64::MemOperand(RCPUSTATE, (s64)offsetof(cpuRegisters, GPR.r[reg].UD[0])));

		g_cpuFlushedConstReg |= (1u << reg);
	}
}

void _flushConstRegs(bool delete_const)
{
	int zero_reg_count = 0;
	int minusone_reg_count = 0;

	for (u32 i = 0; i < 32; i++)
	{
		if (!GPR_IS_CONST1(i) || (g_cpuFlushedConstReg & (1u << i)))
			continue;

		if (g_cpuConstRegs[i].SD[0] == 0)
			zero_reg_count++;
		else if (g_cpuConstRegs[i].SD[0] == -1)
			minusone_reg_count++;
	}

	// Optimize: if multiple zero constants, precompute zero in scratch
	if (zero_reg_count > 1)
	{
		armAsm->Mov(RXVIXLSCRATCH, 0);
		for (u32 i = 0; i < 32; i++)
		{
			if (!GPR_IS_CONST1(i) || (g_cpuFlushedConstReg & (1u << i)))
				continue;

			if (g_cpuConstRegs[i].SD[0] == 0)
			{
				armAsm->Str(RXVIXLSCRATCH,
					a64::MemOperand(RCPUSTATE, (s64)offsetof(cpuRegisters, GPR.r[i].UD[0])));
				g_cpuFlushedConstReg |= 1u << i;
				if (delete_const)
					g_cpuHasConstReg &= ~(1u << i);
			}
		}
	}

	// Optimize: if multiple -1 constants, precompute
	if (minusone_reg_count > 1)
	{
		armAsm->Mov(RXVIXLSCRATCH, (s64)-1);
		for (u32 i = 0; i < 32; i++)
		{
			if (!GPR_IS_CONST1(i) || (g_cpuFlushedConstReg & (1u << i)))
				continue;

			if (g_cpuConstRegs[i].SD[0] == -1)
			{
				armAsm->Str(RXVIXLSCRATCH,
					a64::MemOperand(RCPUSTATE, (s64)offsetof(cpuRegisters, GPR.r[i].UD[0])));
				g_cpuFlushedConstReg |= 1u << i;
				if (delete_const)
					g_cpuHasConstReg &= ~(1u << i);
			}
		}
	}

	// Flush remaining constants
	for (u32 i = 0; i < 32; i++)
	{
		if (!GPR_IS_CONST1(i) || (g_cpuFlushedConstReg & (1u << i)))
			continue;

		armAsm->Mov(RXVIXLSCRATCH, (s64)g_cpuConstRegs[i].SD[0]);
		armAsm->Str(RXVIXLSCRATCH,
			a64::MemOperand(RCPUSTATE, (s64)offsetof(cpuRegisters, GPR.r[i].UD[0])));

		g_cpuFlushedConstReg |= 1u << i;
		if (delete_const)
			g_cpuHasConstReg &= ~(1u << i);
	}
}

// ========================================================================
// Register Validation (debug)
// ========================================================================

void _validateRegs()
{
#ifdef PCSX2_DEVBUILD
	// Check that no two registers are in write mode in both GPR and NEON
	for (s8 guestreg = 0; guestreg < 32; guestreg++)
	{
		u32 gprreg = 0, gprmode = 0;
		u32 neonreg_idx = 0, neonmode = 0;

		for (int hostreg = 0; hostreg < ARMGPR_COUNT; hostreg++)
		{
			if (armGPRregs[hostreg].inuse && armGPRregs[hostreg].type == ARMTYPE_GPR &&
				armGPRregs[hostreg].reg == guestreg)
			{
				pxAssertMsg(gprreg == 0 && gprmode == 0, "register is not already allocated in a GPR");
				gprreg = hostreg;
				gprmode = armGPRregs[hostreg].mode;
			}
		}
		for (int hostreg = 0; hostreg < ARMNEON_COUNT; hostreg++)
		{
			if (neonregs[hostreg].inuse && neonregs[hostreg].type == XMMTYPE_GPRREG &&
				neonregs[hostreg].reg == guestreg)
			{
				pxAssertMsg(neonreg_idx == 0 && neonmode == 0, "register is not already allocated in NEON");
				neonreg_idx = hostreg;
				neonmode = neonregs[hostreg].mode;
			}
		}

		if ((gprmode | neonmode) & MODE_WRITE)
			pxAssertMsg((gprmode & MODE_WRITE) != (neonmode & MODE_WRITE),
				"only one of GPR or NEON is in write state");

		if (gprmode & MODE_WRITE)
			pxAssertMsg(neonmode == 0, "when writing to GPR, NEON must be invalid");
		if (neonmode & MODE_WRITE)
			pxAssertMsg(gprmode == 0, "when writing to NEON, GPR must be invalid");
	}
#endif
}

// ========================================================================
// NEON (128-bit) Register Allocation
// ========================================================================

void _initNeonregs()
{
	std::memset(neonregs, 0, sizeof(neonregs));
	g_neonAllocCounter = 0;
}

// Find a free NEON slot. Evicts LRU if all are in use.
int _getFreeNeonreg(u32 maxreg)
{
	int tempi = -1;
	u32 bestcount = 0x10000;

	// First pass: find an unused slot
	for (u32 i = 0; i < maxreg; i++)
	{
		if (!neonregs[i].inuse)
			return (int)i;
	}

	// Second pass: find dead regs (not used in later instructions)
	tempi = -1;
	bestcount = 0xffff;
	for (u32 i = 0; i < maxreg; i++)
	{
		pxAssert(neonregs[i].inuse);
		if (neonregs[i].needed)
			continue;

		pxAssert(neonregs[i].type != XMMTYPE_TEMP);

		if (neonregs[i].counter < bestcount)
		{
			switch (neonregs[i].type)
			{
				case XMMTYPE_GPRREG:
					if (EEINST_USEDTEST(neonregs[i].reg))
						continue;
					break;
				case XMMTYPE_FPREG:
					if (FPUINST_USEDTEST(neonregs[i].reg))
						continue;
					break;
				case XMMTYPE_VFREG:
					if (EEINST_VFUSEDTEST(neonregs[i].reg))
						continue;
					break;
			}

			tempi = (int)i;
			bestcount = neonregs[i].counter;
		}
	}

	if (tempi != -1)
	{
		_freeNeonreg(tempi);
		return tempi;
	}

	// Last resort: LRU without the used-test filter
	bestcount = 0xffff;
	for (u32 i = 0; i < maxreg; i++)
	{
		pxAssert(neonregs[i].inuse);
		if (neonregs[i].needed)
			continue;

		if (neonregs[i].counter < bestcount)
		{
			tempi = (int)i;
			bestcount = neonregs[i].counter;
		}
	}

	if (tempi != -1)
	{
		_freeNeonreg(tempi);
		return tempi;
	}

	pxFailRel("*PCSX2*: NEON Reg Allocation Error in _getFreeNeonreg()!");
	return -1;
}

int _allocTempNeonreg()
{
	const int neonreg = _getFreeNeonreg();
	neonregs[neonreg].inuse = 1;
	neonregs[neonreg].type = XMMTYPE_TEMP;
	neonregs[neonreg].needed = 1;
	neonregs[neonreg].counter = g_neonAllocCounter++;
	return neonreg;
}

// Write back a NEON register to memory
void _writebackNeonreg(int neonreg)
{
	pxAssert(neonreg >= 0 && neonreg < ARMNEON_COUNT);

	const int armqreg = neonreg + ARMNEON_FIRST;

	switch (neonregs[neonreg].type)
	{
		case XMMTYPE_VFREG:
		{
			if (neonregs[neonreg].reg == 33)
			{
				// VU0 I register (scalar float)
				armMoveAddressToReg(RSCRATCHADDR, &VU0.VI[REG_I].F);
				armAsm->Str(armSRegister(armqreg), a64::MemOperand(RSCRATCHADDR));
			}
			else if (neonregs[neonreg].reg == 32)
			{
				// VU0 ACC (128-bit)
				armMoveAddressToReg(RSCRATCHADDR, &VU0.ACC.F[0]);
				armAsm->Str(armQRegister(armqreg), a64::MemOperand(RSCRATCHADDR));
			}
			else if (neonregs[neonreg].reg > 0)
			{
				armMoveAddressToReg(RSCRATCHADDR, &VU0.VF[neonregs[neonreg].reg].F[0]);
				armAsm->Str(armQRegister(armqreg), a64::MemOperand(RSCRATCHADDR));
			}
		}
		break;

		case XMMTYPE_GPRREG:
		{
			pxAssert(neonregs[neonreg].reg != 0);
			// Store full 128-bit MIPS GPR
			armAsm->Str(armQRegister(armqreg),
				a64::MemOperand(RCPUSTATE,
					(s64)offsetof(cpuRegisters, GPR.r[neonregs[neonreg].reg].UQ)));
		}
		break;

		case XMMTYPE_FPREG:
		{
			// FPU register — 32-bit float
			armMoveAddressToReg(RSCRATCHADDR, &fpuRegs.fpr[neonregs[neonreg].reg].f);
			armAsm->Str(armSRegister(armqreg), a64::MemOperand(RSCRATCHADDR));
		}
		break;

		case XMMTYPE_FPACC:
		{
			// FPU ACC — 32-bit float
			armMoveAddressToReg(RSCRATCHADDR, &fpuRegs.ACC.f);
			armAsm->Str(armSRegister(armqreg), a64::MemOperand(RSCRATCHADDR));
		}
		break;

		default:
			break;
	}
}

int _allocFPtoNeonreg(int fpreg, int mode)
{
	// Check if already allocated
	for (int i = 0; i < ARMNEON_COUNT; i++)
	{
		if (!neonregs[i].inuse || neonregs[i].type != XMMTYPE_FPREG || neonregs[i].reg != fpreg)
			continue;

		if (!(neonregs[i].mode & MODE_READ) && (mode & MODE_READ))
		{
			armMoveAddressToReg(RSCRATCHADDR, &fpuRegs.fpr[fpreg].f);
			armAsm->Ldr(armSRegister(i + ARMNEON_FIRST), a64::MemOperand(RSCRATCHADDR));
			neonregs[i].mode |= MODE_READ;
		}

		neonregs[i].counter = g_neonAllocCounter++;
		neonregs[i].needed = 1;
		neonregs[i].mode |= mode;
		return i;
	}

	// Allocate new
	const int neonreg = _getFreeNeonreg();
	neonregs[neonreg].inuse = 1;
	neonregs[neonreg].type = XMMTYPE_FPREG;
	neonregs[neonreg].reg = fpreg;
	neonregs[neonreg].mode = mode;
	neonregs[neonreg].needed = 1;
	neonregs[neonreg].counter = g_neonAllocCounter++;

	if (mode & MODE_READ)
	{
		armMoveAddressToReg(RSCRATCHADDR, &fpuRegs.fpr[fpreg].f);
		armAsm->Ldr(armSRegister(neonreg + ARMNEON_FIRST), a64::MemOperand(RSCRATCHADDR));
	}

	return neonreg;
}

int _allocGPRtoNeonreg(int gprreg, int mode)
{
	// Check for GPR conflict
	const int hostGPRreg = (mode & MODE_WRITE) ? _checkArmGPR(ARMTYPE_GPR, gprreg, MODE_READ) : -1;

	for (int i = 0; i < ARMNEON_COUNT; i++)
	{
		if (!neonregs[i].inuse || neonregs[i].type != XMMTYPE_GPRREG || neonregs[i].reg != gprreg)
			continue;

		if (!(neonregs[i].mode & (MODE_READ | MODE_WRITE)) && (mode & MODE_READ))
			pxFailRel("Somehow ended up with an allocated NEON without mode");

		if (mode & MODE_WRITE && hostGPRreg >= 0)
		{
			RALOG("Invalidating cached guest GPR reg %d in host GPR x%d due to NEON transition\n",
				gprreg, hostGPRreg);
			const int slot = armGPRRegToSlot(hostGPRreg);
			armGPRregs[slot].inuse = 0;
		}

		if (mode & MODE_WRITE)
		{
			if (GPR_IS_CONST1(gprreg))
			{
				RALOG("Clearing constant value for guest GPR reg %d on NEON reconfig\n", gprreg);
				GPR_DEL_CONST(gprreg);
			}
			if (hostGPRreg >= 0)
			{
				pxAssert(!(armGPRregs[armGPRRegToSlot(hostGPRreg)].mode & MODE_WRITE));
				_freeArmGPRWithoutWriteback(hostGPRreg);
			}
		}

		neonregs[i].counter = g_neonAllocCounter++;
		neonregs[i].needed = 1;
		neonregs[i].mode |= mode;
		return i;
	}

	// Allocate new
	const int neonreg = _getFreeNeonreg();
	const int armqreg = neonreg + ARMNEON_FIRST;
	RALOG("Allocating NEON %d (q%d) for guest GPR %d\n", neonreg, armqreg, gprreg);

	neonregs[neonreg].inuse = 1;
	neonregs[neonreg].type = XMMTYPE_GPRREG;
	neonregs[neonreg].reg = gprreg;
	neonregs[neonreg].mode = mode;
	neonregs[neonreg].needed = 1;
	neonregs[neonreg].counter = g_neonAllocCounter++;

	if (mode & MODE_READ)
	{
		if (gprreg == 0)
		{
			// $zero — clear the register
			armAsm->Movi(armQRegister(armqreg).V16B(), 0);
		}
		else
		{
			if (GPR_IS_CONST1(gprreg))
			{
				RALOG("Writing constant value %lld from guest reg %d to NEON %d\n",
					g_cpuConstRegs[gprreg].SD[0], gprreg, neonreg);

				// Load full 128-bit from memory, then replace lower 64 bits with const
				armAsm->Ldr(armQRegister(armqreg),
					a64::MemOperand(RCPUSTATE,
						(s64)offsetof(cpuRegisters, GPR.r[gprreg].UQ)));
				armAsm->Mov(RXVIXLSCRATCH, (s64)g_cpuConstRegs[gprreg].SD[0]);
				armAsm->Mov(a64::VRegister(armqreg, 64, 2).D(), 0, RXVIXLSCRATCH);
				neonregs[neonreg].mode |= MODE_WRITE; // dirty
				g_cpuFlushedConstReg |= (1u << gprreg);

				// Kill any GPR allocation since we have the const
				if (hostGPRreg >= 0)
				{
					RALOG("Invalidating guest reg %d in GPR x%d due to const write to NEON %d\n",
						gprreg, hostGPRreg, neonreg);
					armGPRregs[armGPRRegToSlot(hostGPRreg)].inuse = 0;
				}
			}
			else if (hostGPRreg >= 0)
			{
				const int gprSlot = armGPRRegToSlot(hostGPRreg);
				RALOG("Copying guest reg %d from GPR x%d to NEON %d\n", gprreg, hostGPRreg, neonreg);

				// Load full 128-bit from memory
				armAsm->Ldr(armQRegister(armqreg),
					a64::MemOperand(RCPUSTATE,
						(s64)offsetof(cpuRegisters, GPR.r[gprreg].UQ)));

				// If GPR was dirty, inject its value into the lower 64 bits
				if (armGPRregs[gprSlot].mode & MODE_WRITE)
				{
					RALOG("Moving dirty guest reg %d from GPR x%d to NEON %d\n",
						gprreg, hostGPRreg, neonreg);
					armAsm->Mov(a64::VRegister(armqreg, 64, 2).D(), 0, armXRegister(hostGPRreg));
					_freeArmGPRWithoutWriteback(hostGPRreg);
					neonregs[neonreg].mode |= MODE_WRITE;
				}
			}
			else
			{
				// Load full 128 bits from memory
				RALOG("Loading guest reg %d to NEON %d\n", gprreg, neonreg);
				armAsm->Ldr(armQRegister(armqreg),
					a64::MemOperand(RCPUSTATE,
						(s64)offsetof(cpuRegisters, GPR.r[gprreg].UQ)));
			}
		}
	}

	if ((mode & MODE_WRITE) && gprreg < 32 && GPR_IS_CONST1(gprreg))
	{
		RALOG("Clearing constant value for guest GPR reg %d on NEON alloc\n", gprreg);
		GPR_DEL_CONST(gprreg);
	}
	if ((mode & MODE_WRITE) && hostGPRreg >= 0)
	{
		RALOG("Invalidating GPR x%d for guest reg %d due to NEON write alloc\n", hostGPRreg, gprreg);
		_freeArmGPRWithoutWriteback(hostGPRreg);
	}

	return neonreg;
}

int _allocFPACCtoNeonreg(int mode)
{
	// Check if already allocated
	for (int i = 0; i < ARMNEON_COUNT; i++)
	{
		if (!neonregs[i].inuse || neonregs[i].type != XMMTYPE_FPACC)
			continue;

		if (!(neonregs[i].mode & MODE_READ) && (mode & MODE_READ))
		{
			armMoveAddressToReg(RSCRATCHADDR, &fpuRegs.ACC.f);
			armAsm->Ldr(armSRegister(i + ARMNEON_FIRST), a64::MemOperand(RSCRATCHADDR));
			neonregs[i].mode |= MODE_READ;
		}

		neonregs[i].counter = g_neonAllocCounter++;
		neonregs[i].needed = 1;
		neonregs[i].mode |= mode;
		return i;
	}

	// Allocate new
	const int neonreg = _getFreeNeonreg();
	neonregs[neonreg].inuse = 1;
	neonregs[neonreg].type = XMMTYPE_FPACC;
	neonregs[neonreg].mode = mode;
	neonregs[neonreg].needed = 1;
	neonregs[neonreg].reg = 0;
	neonregs[neonreg].counter = g_neonAllocCounter++;

	if (mode & MODE_READ)
	{
		armMoveAddressToReg(RSCRATCHADDR, &fpuRegs.ACC.f);
		armAsm->Ldr(armSRegister(neonreg + ARMNEON_FIRST), a64::MemOperand(RSCRATCHADDR));
	}

	return neonreg;
}

void _reallocateNeonreg(int neonreg, int newtype, int newreg, int newmode, bool writeback)
{
	pxAssert(neonreg >= 0 && neonreg < ARMNEON_COUNT);
	if (writeback)
		_freeNeonreg(neonreg);

	neonregs[neonreg].inuse = 1;
	neonregs[neonreg].type = newtype;
	neonregs[neonreg].reg = newreg;
	neonregs[neonreg].mode = newmode;
	neonregs[neonreg].needed = 1;
}

int _checkNeonreg(int type, int reg, int mode)
{
	for (int i = 0; i < ARMNEON_COUNT; i++)
	{
		if (neonregs[i].inuse && (neonregs[i].type == (type & 0xff)) && (neonregs[i].reg == reg))
		{
			// Shouldn't have dirty constants
			pxAssert(type != XMMTYPE_GPRREG || !GPR_IS_DIRTY_CONST(reg));

			if (type == XMMTYPE_GPRREG && !(neonregs[i].mode & (MODE_READ | MODE_WRITE)) && (mode & MODE_READ))
				pxFailRel("Somehow ended up with an allocated NEON without mode");

			if (type == XMMTYPE_GPRREG && (mode & MODE_WRITE))
			{
				// Go through alloc path for potential GPR invalidation
				return _allocGPRtoNeonreg(reg, mode);
			}

			neonregs[i].mode |= mode;
			neonregs[i].counter = g_neonAllocCounter++;
			neonregs[i].needed = 1;
			return i;
		}
	}

	return -1;
}

bool _hasNeonreg(int type, int reg, int required_mode)
{
	for (int i = 0; i < ARMNEON_COUNT; i++)
	{
		if (neonregs[i].inuse && neonregs[i].type == type && neonregs[i].reg == reg)
		{
			return ((neonregs[i].mode & required_mode) == required_mode);
		}
	}
	return false;
}

// ========================================================================
// Needed-flag management for NEON and GPR
// ========================================================================

void _addNeededFPtoNeonreg(int fpreg)
{
	for (int i = 0; i < ARMNEON_COUNT; i++)
	{
		if (!neonregs[i].inuse || neonregs[i].type != XMMTYPE_FPREG || neonregs[i].reg != fpreg)
			continue;

		neonregs[i].counter = g_neonAllocCounter++;
		neonregs[i].needed = 1;
		break;
	}
}

void _addNeededFPACCtoNeonreg()
{
	for (int i = 0; i < ARMNEON_COUNT; i++)
	{
		if (!neonregs[i].inuse || neonregs[i].type != XMMTYPE_FPACC)
			continue;

		neonregs[i].counter = g_neonAllocCounter++;
		neonregs[i].needed = 1;
		break;
	}
}

void _addNeededGPRtoArmGPR(int gprreg)
{
	for (int i = 0; i < ARMGPR_COUNT; i++)
	{
		if (!armGPRregs[i].inuse || armGPRregs[i].type != ARMTYPE_GPR || armGPRregs[i].reg != gprreg)
			continue;

		armGPRregs[i].counter = g_armGPRAllocCounter++;
		armGPRregs[i].needed = 1;
		break;
	}
}

void _addNeededPSXtoArmGPR(int gprreg)
{
	for (int i = 0; i < ARMGPR_COUNT; i++)
	{
		if (!armGPRregs[i].inuse || armGPRregs[i].type != ARMTYPE_PSX || armGPRregs[i].reg != gprreg)
			continue;

		armGPRregs[i].counter = g_armGPRAllocCounter++;
		armGPRregs[i].needed = 1;
		break;
	}
}

void _addNeededGPRtoNeonreg(int gprreg)
{
	for (int i = 0; i < ARMNEON_COUNT; i++)
	{
		if (!neonregs[i].inuse || neonregs[i].type != XMMTYPE_GPRREG || neonregs[i].reg != gprreg)
			continue;

		neonregs[i].counter = g_neonAllocCounter++;
		neonregs[i].needed = 1;
		break;
	}
}

void _clearNeededNeonregs()
{
	for (int i = 0; i < ARMNEON_COUNT; i++)
	{
		if (neonregs[i].needed)
		{
			// Written registers are now readable
			if (neonregs[i].inuse && (neonregs[i].mode & MODE_WRITE))
				neonregs[i].mode |= MODE_READ;
			neonregs[i].needed = 0;
		}

		if (neonregs[i].inuse)
		{
			pxAssert(neonregs[i].type != XMMTYPE_TEMP);
		}
	}
}

// ========================================================================
// Delete operations (flush/free a specific guest register)
// ========================================================================

void _deleteGPRtoArmGPR(int reg, int flush)
{
	for (int i = 0; i < ARMGPR_COUNT; i++)
	{
		if (armGPRregs[i].inuse && armGPRregs[i].type == ARMTYPE_GPR && armGPRregs[i].reg == reg)
		{
			switch (flush)
			{
				case DELETE_REG_FREE:
					_freeArmGPR(armGPRSlotToReg(i));
					break;

				case DELETE_REG_FLUSH:
				case DELETE_REG_FLUSH_AND_FREE:
					if (armGPRregs[i].mode & MODE_WRITE)
					{
						pxAssert(reg != 0);
						// Store 64-bit to memory
						armAsm->Str(armXRegister(armGPRSlotToReg(i)),
							a64::MemOperand(RCPUSTATE,
								(s64)offsetof(cpuRegisters, GPR.r[reg].UD[0])));

						armGPRregs[i].mode &= ~MODE_WRITE;
						armGPRregs[i].mode |= MODE_READ;
					}
					if (flush == DELETE_REG_FLUSH_AND_FREE)
						armGPRregs[i].inuse = 0;
					break;

				case DELETE_REG_FREE_NO_WRITEBACK:
					armGPRregs[i].inuse = 0;
					break;
			}
			return;
		}
	}
}

void _deletePSXtoArmGPR(int reg, int flush)
{
	for (int i = 0; i < ARMGPR_COUNT; i++)
	{
		if (armGPRregs[i].inuse && armGPRregs[i].type == ARMTYPE_PSX && armGPRregs[i].reg == reg)
		{
			switch (flush)
			{
				case DELETE_REG_FREE:
					_freeArmGPR(armGPRSlotToReg(i));
					break;

				case DELETE_REG_FLUSH:
				case DELETE_REG_FLUSH_AND_FREE:
					if (armGPRregs[i].mode & MODE_WRITE)
					{
						pxAssert(reg != 0);
						armMoveAddressToReg(RSCRATCHADDR, &psxRegs.GPR.r[reg]);
						armAsm->Str(armWRegister(armGPRSlotToReg(i)),
							a64::MemOperand(RSCRATCHADDR));

						armGPRregs[i].mode &= ~MODE_WRITE;
						armGPRregs[i].mode |= MODE_READ;

						RALOG("Writing back ARM GPR slot %d for guest PSX reg %d\n", i, reg);
					}
					if (flush == DELETE_REG_FLUSH_AND_FREE)
						armGPRregs[i].inuse = 0;
					break;

				case DELETE_REG_FREE_NO_WRITEBACK:
					armGPRregs[i].inuse = 0;
					break;
			}
			return;
		}
	}
}

void _deleteGPRtoNeonreg(int reg, int flush)
{
	for (int i = 0; i < ARMNEON_COUNT; i++)
	{
		if (neonregs[i].inuse && neonregs[i].type == XMMTYPE_GPRREG && neonregs[i].reg == reg)
		{
			switch (flush)
			{
				case DELETE_REG_FREE:
					_freeNeonreg(i);
					break;

				case DELETE_REG_FLUSH:
				case DELETE_REG_FLUSH_AND_FREE:
					if (neonregs[i].mode & MODE_WRITE)
					{
						pxAssert(reg != 0);
						armAsm->Str(armQRegister(i + ARMNEON_FIRST),
							a64::MemOperand(RCPUSTATE,
								(s64)offsetof(cpuRegisters, GPR.r[reg].UQ)));

						neonregs[i].mode &= ~MODE_WRITE;
						neonregs[i].mode |= MODE_READ;
					}
					if (flush == DELETE_REG_FLUSH_AND_FREE)
						neonregs[i].inuse = 0;
					break;

				case DELETE_REG_FREE_NO_WRITEBACK:
					neonregs[i].inuse = 0;
					break;
			}
			return;
		}
	}
}

void _deleteFPtoNeonreg(int reg, int flush)
{
	for (int i = 0; i < ARMNEON_COUNT; i++)
	{
		if (neonregs[i].inuse && neonregs[i].type == XMMTYPE_FPREG && neonregs[i].reg == reg)
		{
			switch (flush)
			{
				case DELETE_REG_FREE:
				case DELETE_REG_FLUSH_AND_FREE:
					_freeNeonreg(i);
					return;

				case DELETE_REG_FLUSH:
					if (neonregs[i].mode & MODE_WRITE)
					{
						armMoveAddressToReg(RSCRATCHADDR, &fpuRegs.fpr[reg].f);
						armAsm->Str(armSRegister(i + ARMNEON_FIRST),
							a64::MemOperand(RSCRATCHADDR));
						neonregs[i].mode &= ~MODE_WRITE;
						neonregs[i].mode |= MODE_READ;
					}
					return;

				case DELETE_REG_FREE_NO_WRITEBACK:
					neonregs[i].inuse = 0;
					return;
			}
		}
	}
}

// ========================================================================
// Free / Flush NEON registers
// ========================================================================

void _freeNeonreg(int neonreg)
{
	pxAssert(neonreg >= 0 && neonreg < ARMNEON_COUNT);
	if (!neonregs[neonreg].inuse)
		return;

	if (neonregs[neonreg].mode & MODE_WRITE)
		_writebackNeonreg(neonreg);

	neonregs[neonreg].mode = 0;
	neonregs[neonreg].inuse = 0;

	if (neonregs[neonreg].type == XMMTYPE_VFREG)
		mVUFreeCOP2XMMreg(neonreg);
}

void _freeNeonregWithoutWriteback(int neonreg)
{
	pxAssert(neonreg >= 0 && neonreg < ARMNEON_COUNT);
	if (!neonregs[neonreg].inuse)
		return;

	neonregs[neonreg].mode = 0;
	neonregs[neonreg].inuse = 0;

	if (neonregs[neonreg].type == XMMTYPE_VFREG)
		mVUFreeCOP2XMMreg(neonreg);
}

int _allocVFtoNeonreg(int vfreg, int mode)
{
	// Check if already allocated (mode != 0 means EE COP2, mode == 0 means microVU)
	if (mode != 0)
	{
		for (int i = 0; i < ARMNEON_COUNT; i++)
		{
			if (neonregs[i].inuse && neonregs[i].type == XMMTYPE_VFREG && neonregs[i].reg == vfreg)
			{
				pxAssert(mode == 0 || neonregs[i].mode != 0);
				neonregs[i].counter = g_neonAllocCounter++;
				neonregs[i].mode |= mode;
				return i;
			}
		}
	}

	// Allocate new. Use maxreg-1 to avoid PQ register conflicts.
	const int neonreg = _getFreeNeonreg(ARMNEON_COUNT - 1);
	const int armqreg = neonreg + ARMNEON_FIRST;

	neonregs[neonreg].inuse = 1;
	neonregs[neonreg].type = XMMTYPE_VFREG;
	neonregs[neonreg].counter = g_neonAllocCounter++;
	neonregs[neonreg].needed = 1;
	neonregs[neonreg].reg = vfreg;
	neonregs[neonreg].mode = mode;

	if (mode & MODE_READ)
	{
		if (vfreg == 33)
		{
			// VU0 I register (scalar)
			armMoveAddressToReg(RSCRATCHADDR, &VU0.VI[REG_I].F);
			armAsm->Ldr(armSRegister(armqreg), a64::MemOperand(RSCRATCHADDR));
		}
		else if (vfreg == 32)
		{
			// VU0 ACC (128-bit)
			armMoveAddressToReg(RSCRATCHADDR, &VU0.ACC.F[0]);
			armAsm->Ldr(armQRegister(armqreg), a64::MemOperand(RSCRATCHADDR));
		}
		else
		{
			armMoveAddressToReg(RSCRATCHADDR, &VU0.VF[vfreg].F[0]);
			armAsm->Ldr(armQRegister(armqreg), a64::MemOperand(RSCRATCHADDR));
		}
	}

	return neonreg;
}

void _flushNeonreg(int neonreg)
{
	if (neonregs[neonreg].inuse && (neonregs[neonreg].mode & MODE_WRITE))
	{
		RALOG("Flushing NEON reg %d\n", neonreg);
		_writebackNeonreg(neonreg);
		neonregs[neonreg].mode = (neonregs[neonreg].mode & ~MODE_WRITE) | MODE_READ;
	}
}

void _flushNeonregs()
{
	for (int i = 0; i < ARMNEON_COUNT; i++)
		_flushNeonreg(i);
}

// ========================================================================
// Conditional allocation (allocate only if register is used later)
// ========================================================================

int _allocIfUsedGPRtoArmGPR(int gprreg, int mode)
{
	const int armreg = _checkArmGPR(ARMTYPE_GPR, gprreg, mode);
	if (armreg >= 0)
		return armreg;

	return EEINST_USEDTEST(gprreg) ? _allocArmGPR(ARMTYPE_GPR, gprreg, mode) : -1;
}

int _allocIfUsedGPRtoNeon(int gprreg, int mode)
{
	const int neonreg = _checkNeonreg(XMMTYPE_GPRREG, gprreg, mode);
	if (neonreg >= 0)
		return neonreg;

	return EEINST_XMMUSEDTEST(gprreg) ? _allocGPRtoNeonreg(gprreg, mode) : -1;
}

int _allocIfUsedFPUtoNeon(int fpureg, int mode)
{
	const int neonreg = _checkNeonreg(XMMTYPE_FPREG, fpureg, mode);
	if (neonreg >= 0)
		return neonreg;

	return FPUINST_USEDTEST(fpureg) ? _allocFPtoNeonreg(fpureg, mode) : -1;
}

// ========================================================================
// Instruction info helpers (shared with x86)
// ========================================================================

void _recClearInst(EEINST* pinst)
{
	std::memset(pinst, 0, sizeof(EEINST));
	std::memset(pinst->regs, EEINST_LIVE, sizeof(pinst->regs));
	std::memset(pinst->fpuregs, EEINST_LIVE, sizeof(pinst->fpuregs));
	std::memset(pinst->vfregs, EEINST_LIVE, sizeof(pinst->vfregs));
	std::memset(pinst->viregs, EEINST_LIVE, sizeof(pinst->viregs));
}

u32 _recIsRegReadOrWritten(EEINST* pinst, int size, u8 xmmtype, u8 reg)
{
	u32 inst = 1;

	while (size-- > 0)
	{
		for (u32 i = 0; i < std::size(pinst->writeType); ++i)
		{
			if ((pinst->writeType[i] == xmmtype) && (pinst->writeReg[i] == reg))
				return inst;
		}
		for (u32 i = 0; i < std::size(pinst->readType); ++i)
		{
			if ((pinst->readType[i] == xmmtype) && (pinst->readReg[i] == reg))
				return inst;
		}

		++inst;
		pinst++;
	}

	return 0;
}

void _recFillRegister(EEINST& pinst, int type, int reg, int write)
{
	if (write)
	{
		for (size_t i = 0; i < std::size(pinst.writeType); ++i)
		{
			if (pinst.writeType[i] == XMMTYPE_TEMP)
			{
				pinst.writeType[i] = type;
				pinst.writeReg[i] = reg;
				return;
			}
		}
		pxAssume(false);
	}
	else
	{
		for (size_t i = 0; i < std::size(pinst.readType); ++i)
		{
			if (pinst.readType[i] == XMMTYPE_TEMP)
			{
				pinst.readType[i] = type;
				pinst.readReg[i] = reg;
				return;
			}
		}
		pxAssume(false);
	}
}
