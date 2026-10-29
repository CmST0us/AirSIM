#define _GNU_SOURCE
#include <sys/socket.h>
#include <sys/wait.h>
#include <poll.h>
#include <unistd.h>
#include <signal.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <time.h>
#include <string.h>

/* Local hardware probe: discards PCM and reports only helper metadata. */
int main(int argc, char **argv) {
  if (argc != 2) return 2;
  int control[2], pcm[2];
  if (socketpair(AF_UNIX, SOCK_STREAM, 0, control) ||
      socketpair(AF_UNIX, SOCK_STREAM, 0, pcm)) return 2;
  pid_t child = fork();
  if (!child) {
    dup2(control[1], 3); dup2(pcm[1], 4);
    for (int fd=5; fd<10; fd++) close(fd);
    execl(argv[1], argv[1], "--session", "12345678-1234-4123-8123-123456789abc",
          "--profile", "eg25-qdc507", NULL);
    _exit(127);
  }
  close(control[1]); close(pcm[1]);
  unsigned char message[2052];size_t have=0,bytes=0;
  time_t end=time(NULL)+6,last=0;
  int status=0;
  signal(SIGPIPE,SIG_IGN);
  while (time(NULL)<end) {
    if (time(NULL)!=last) {
      unsigned char ping[]={13,0,0,0,'{','"','o','p','"',':','"','p','i','n','g','"','}'};
      write(control[0],ping,sizeof(ping));last=time(NULL);
    }
    struct pollfd fds[]={{control[0],POLLIN,0},{pcm[0],POLLIN,0}};
    poll(fds,2,100);
    if (fds[1].revents&POLLIN) { unsigned char data[4096];ssize_t n=read(pcm[0],data,sizeof(data));if(n>0)bytes+=n; }
    if (fds[0].revents&POLLIN) {
      ssize_t n=read(control[0],message+have,sizeof(message)-have);
      if(n<=0)break;
      have+=n;
      while(have>=4) {
        uint32_t size=(uint32_t)message[0]|(uint32_t)message[1]<<8|(uint32_t)message[2]<<16|(uint32_t)message[3]<<24;
        if(size>2048)return 2;
        if(have<size+4)break;
        fwrite(message+4,1,size,stdout);putchar('\n');fflush(stdout);
        have-=size+4;memmove(message,message+size+4,have);
      }
    }
    if(waitpid(child,&status,WNOHANG)==child) { child=0;break; }
  }
  if(child>0){kill(child,SIGTERM);waitpid(child,&status,0);}
  close(control[0]);close(pcm[0]);
  printf("pcm_bytes_discarded=%zu child_status=%d\n",bytes,status);
  return status?1:0;
}
