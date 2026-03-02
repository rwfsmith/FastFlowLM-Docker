#!/usr/bin/env python3
# =============================================================================
# fix-module-relocations.py — Fix pre-resolved relocations in kernel modules
#
# Kernel 6.12+ added a security check in arch/x86/kernel/module.c
# (apply_relocate_add) that rejects modules with non-zero values at
# R_X86_64_64 relocation targets:
#
#   "Invalid relocation target, existing value is nonzero for type 1"
#
# This happens because 'ld -r' (partial/relocatable linking) resolves
# cross-object symbol references during intermediate linking steps,
# writing resolved addresses to relocation targets. On x86-64, the
# ABI mandates RELA relocations where the addend is stored in the
# relocation entry (r_addend), NOT at the target location. The values
# written by ld -r to the target are redundant and can be safely zeroed.
#
# Usage:
#   python3 fix-module-relocations.py <module.ko>
# =============================================================================

import struct
import sys
import os

# ELF constants
EI_CLASS = 4
ELFCLASS64 = 2
SHT_RELA = 4
R_X86_64_64 = 1  # type 1: absolute 64-bit relocation


def fix_relocations(filepath):
    """Zero out non-zero values at R_X86_64_64 relocation targets in a .ko file."""

    with open(filepath, 'rb') as f:
        data = bytearray(f.read())

    # Verify ELF magic
    if data[:4] != b'\x7fELF':
        print(f"  Error: {filepath} is not an ELF file", file=sys.stderr)
        return False

    if data[EI_CLASS] != ELFCLASS64:
        print(f"  Error: {filepath} is not a 64-bit ELF", file=sys.stderr)
        return False

    # Parse ELF64 header (little-endian)
    e_shoff = struct.unpack_from('<Q', data, 40)[0]      # Section header table offset
    e_shentsize = struct.unpack_from('<H', data, 58)[0]   # Section header entry size
    e_shnum = struct.unpack_from('<H', data, 60)[0]       # Number of section headers

    fixed_count = 0
    scanned_count = 0

    # Iterate through section headers looking for RELA sections
    for i in range(e_shnum):
        sh_base = e_shoff + i * e_shentsize
        sh_type = struct.unpack_from('<I', data, sh_base + 4)[0]

        if sh_type != SHT_RELA:
            continue

        # Parse RELA section header (ELF64 Shdr offsets)
        # sh_name:      +0  (4 bytes)
        # sh_type:      +4  (4 bytes)
        # sh_flags:     +8  (8 bytes)
        # sh_addr:      +16 (8 bytes)
        # sh_offset:    +24 (8 bytes)
        # sh_size:      +32 (8 bytes)
        # sh_link:      +40 (4 bytes)
        # sh_info:      +44 (4 bytes)  <-- index of target section
        # sh_addralign: +48 (8 bytes)
        # sh_entsize:   +56 (8 bytes)
        rela_offset = struct.unpack_from('<Q', data, sh_base + 24)[0]    # sh_offset
        rela_size = struct.unpack_from('<Q', data, sh_base + 32)[0]      # sh_size
        rela_info = struct.unpack_from('<I', data, sh_base + 44)[0]      # sh_info (target section index)
        rela_entsize = struct.unpack_from('<Q', data, sh_base + 56)[0]   # sh_entsize

        if rela_entsize == 0:
            continue

        # Get the target section's file offset and size
        target_sh_base = e_shoff + rela_info * e_shentsize
        target_offset = struct.unpack_from('<Q', data, target_sh_base + 24)[0]
        target_size = struct.unpack_from('<Q', data, target_sh_base + 32)[0]

        # Iterate through relocation entries
        num_relas = rela_size // rela_entsize
        for j in range(num_relas):
            entry_offset = rela_offset + j * rela_entsize

            r_offset = struct.unpack_from('<Q', data, entry_offset)[0]
            r_info = struct.unpack_from('<Q', data, entry_offset + 8)[0]

            r_type = r_info & 0xFFFFFFFF

            if r_type == R_X86_64_64:
                scanned_count += 1
                # Compute file position of the relocation target
                target_file_pos = target_offset + r_offset

                if target_file_pos + 8 <= len(data) and target_file_pos < target_offset + target_size:
                    current_val = struct.unpack_from('<Q', data, target_file_pos)[0]
                    if current_val != 0:
                        # Zero it — the addend is in r_addend, this value is redundant
                        struct.pack_into('<Q', data, target_file_pos, 0)
                        fixed_count += 1

    if fixed_count > 0:
        with open(filepath, 'wb') as f:
            f.write(data)
        print(f"  Fixed {fixed_count}/{scanned_count} R_X86_64_64 relocation target(s)")
    else:
        print(f"  All {scanned_count} R_X86_64_64 relocation targets are clean")

    return True


if __name__ == '__main__':
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <module.ko>", file=sys.stderr)
        sys.exit(1)

    filepath = sys.argv[1]
    if not os.path.isfile(filepath):
        print(f"Error: {filepath} not found", file=sys.stderr)
        sys.exit(1)

    print(f"Fixing relocation targets in {os.path.basename(filepath)}...")
    if not fix_relocations(filepath):
        sys.exit(1)
