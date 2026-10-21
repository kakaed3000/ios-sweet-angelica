#pragma once
#include <stdint.h>

/* Boot the ANGELICAXNU payload found in the LK ramdisk; returns only on error. */
const char *loader_boot(uintptr_t dtb);
