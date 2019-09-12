#pragma once

typedef unsigned long ino_t;
typedef void DIR;

struct dirent {
    /* Inode number */
    ino_t d_ino;
    /* Length of this record */
    unsigned short d_reclen;
    /* Type of file; not supported by all filesystem types */
    unsigned char d_type;
    /* Null-terminated filename */
    char d_name[256];
};

extern DIR *opendir(const char *dirname);
extern int closedir(DIR *dirp);
extern struct dirent* readdir(DIR *dirp);
