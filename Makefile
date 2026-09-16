.SUFFIXES:

CC = clang
MODE ?= debug

ifeq ($(MODE),release)
	MODEDIR := obj-release
	ASFLAGS = -Isrc
	LDFLAGS = -no-pie -nostdlib -Wl,-e,_start -s
else
	MODEDIR := obj
	ASFLAGS = -g -Isrc
	LDFLAGS = -g -no-pie -nostdlib -Wl,-e,_start
endif

SRCS := $(wildcard *.s)
OBJS := $(patsubst %.s,$(MODEDIR)/%.o,$(SRCS))
BIN := hitherto

all: $(BIN)

release:
	$(MAKE) MODE=release

$(BIN): $(OBJS)
	rm -f $@
	$(CC) -o $@ $^ $(LDFLAGS)

$(MODEDIR)/%.o: %.s | $(MODEDIR)
	$(CC) $(ASFLAGS) -c -o $@ $<

$(MODEDIR):
	mkdir -p $@

clean:
	rm -rf obj obj-release $(BIN)

.PHONY: all clean release
