CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra -std=c11 -D_POSIX_C_SOURCE=200809L
LDLIBS := -lcrypto

SRCS := main.c common.c crypto.c cnmt.c nacp.c tik.c pfs0.c hfs0.c nca_header.c nca_content.c romfs.c bktr.c nca_decrypt.c
OBJS := $(SRCS:.c=.o)
BIN := ../../bin/smtool

.PHONY: all clean
all: $(BIN)

$(BIN): $(OBJS)
	@mkdir -p $(dir $(BIN))
	$(CC) $(CFLAGS) -o $@ $(OBJS) $(LDLIBS)

%.o: %.c common.h
	$(CC) $(CFLAGS) -c -o $@ $<

clean:
	rm -f $(OBJS) $(BIN)
