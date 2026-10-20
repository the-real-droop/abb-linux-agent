// SPDX-License-Identifier: GPL-2.0-only

#include "includes.h"
MODULE_LICENSE("GPL");

static inline void dummy(void)
{
	struct vm_area_struct vma;

	vm_flags_init(&vma, VM_READ | VM_WRITE);
}
