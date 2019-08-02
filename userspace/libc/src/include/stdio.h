#pragma once

#include <stddef.h>

typedef void FILE;

extern FILE *stdin;
extern FILE *stdout;
extern FILE *stderr;

FILE *fopen(const char *pathname, const char *mode);
int fclose(FILE *stream);

int fflush(FILE *);

char *fgets(char *, int, FILE *);
int fgetc(FILE *stream);
int fputs(const char *s, FILE *stream);
int fnputs(const char *s, unsigned long len, FILE *stream);

size_t fread(void *ptr, size_t size, size_t nmemb, FILE *stream);
size_t fwrite(const void *ptr, size_t size, size_t nmemb,
              FILE *stream);

int fseek(FILE *stream, long offset, int whence);
long ftell(FILE *stream);

int feof(FILE *stream);

int printf(const char *format, ...);
int fprintf(FILE *stream, const char *format, ...);
int dprintf(int fd, const char *format, ...);
int sprintf(char *str, const char *format, ...);
int snprintf(char *str, size_t size, const char *format, ...);

int putc(int c, FILE *stream);
int puts(const char *s);
int getchar(void);

#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2

#define EOF 0