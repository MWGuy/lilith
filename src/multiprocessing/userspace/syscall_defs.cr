SYSCALL_ERR     = (-1).to_u32
SYSCALL_SUCCESS = 1u32

EGENER  = -1
EFAULT  = -2
ENOENT  = -3
EBADFD  = -4
EINVAL  = -5
ENOEXEC = -6

SC_OPEN     =  0u32
SC_READ     =  1u32
SC_WRITE    =  2u32
SC_FATTR    =  3u32
SC_SPAWN    =  4u32
SC_CLOSE    =  5u32
SC_EXIT     =  6u32
SC_SEEK     =  7u32
SC_GETCWD   =  8u32
SC_CHDIR    =  9u32
SC_SBRK     = 10u32
SC_READDIR  = 11u32
SC_WAITPID  = 12u32
SC_IOCTL    = 13u32
SC_MMAP     = 14u32
SC_TIME     = 15u32
SC_SLEEP    = 16u32
SC_GETENV   = 17u32
SC_SETENV   = 18u32
SC_CREATE   = 19u32
SC_TRUNCATE = 20u32
SC_WAITFD   = 21u32
SC_REMOVE   = 22u32
SC_MUNMAP   = 23u32

SC_MMAP_DRV           = 0u32
SC_PROCESS_CREATE_DRV = 1u32

SC_SEEK_SET = 0
SC_SEEK_CUR = 1
SC_SEEK_END = 2

SC_SPAWN_MAX_ARGS = 255

SC_IOCTL_ERR = -1

SC_IOCTL_TCSAFLUSH       = 0
SC_IOCTL_TCSAGETS        = 1
SC_IOCTL_TIOCGWINSZ      = 2
SC_IOCTL_GFX_BITBLIT     = 3
SC_IOCTL_GFX_SWAPBUF     = 4
SC_IOCTL_TIOCGSTATE      = 5
SC_IOCTL_PIPE_CONF_FLAGS = 6
SC_IOCTL_PIPE_CONF_PID   = 7

SC_PATH_MAX = 4096
