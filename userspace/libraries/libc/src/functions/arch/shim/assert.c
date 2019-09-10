#include <stdlib.h>
#include <stdio.h>

void __assert__(int truthy, const char *s) {
    if(!truthy) {
        fprintf(stderr, "assertion failed: %s\n", s);
        abort();
    }
}