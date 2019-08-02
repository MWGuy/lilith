#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <syscalls.h>

void spawn_process(char *s, char **argv) {
    pid_t child = spawnv(s, argv);
    if (child > 0)
        waitpid(child, 0, 0);
    else
        printf("unknown command or file name\n");
}

int main(int argc, char **argv) {
    // tty
    open("/kbd", 0);
    open("/vga", 0);

    // shell
    char *path = calloc(PATH_MAX + 1, 1);
    while(1) {
        getcwd(path, PATH_MAX);

        printf("%s> ", path);
        fflush(stdout);

        char buf[256]={0};
        fgets(buf, sizeof(buf), stdin);

        char *tok = strtok(buf, " \n");
        if (tok != NULL) {
            if(strcmp(tok, "cd") == NULL) {
                chdir(strtok(NULL, ""));
            } else {
                const int MAX_ARGS = 256;
                char **argv = calloc(MAX_ARGS, sizeof(char *));
                argv[0] = tok;
                int idx = 1;
                while((tok = strtok(NULL, " ")) != NULL && idx < MAX_ARGS) {
                    argv[idx] = tok;
                }
                spawn_process(buf, argv);
                free(argv);
            }
            fflush(stdout);
        }
    }
}