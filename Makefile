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

SRCS := $(wildcard src/*.s)
HTS := $(wildcard src/*.ht)
OBJS := $(patsubst src/%.s,$(MODEDIR)/%.o,$(SRCS))
BIN := hitherto

all: $(BIN)

release:
	$(MAKE) MODE=release

$(BIN): $(OBJS)
	rm -f $@
	$(CC) -o $@ $^ $(LDFLAGS)

$(MODEDIR)/%.o: src/%.s $(HTS) | $(MODEDIR)
	$(CC) $(ASFLAGS) -c -o $@ $<

$(MODEDIR):
	mkdir -p $(MODEDIR)

clean:
	rm -rf obj obj-release $(BIN)

obj/%.s: src/%.s | obj
	llvm-mc -triple=x86_64-linux-gnu -x86-asm-syntax=intel -I src $< -o $@

.PHONY: all clean release
