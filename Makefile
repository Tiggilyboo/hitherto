.SUFFIXES:

CC = clang
ASFLAGS = -g -Isrc
LDFLAGS = -nostdlib -Wl,-e,_start -lvulkan
SRCS := $(wildcard src/*.s)
INCS := $(wildcard src/*.inc)
OBJS := $(patsubst src/%.s,obj/%.o,$(SRCS))
EXPANDED := $(patsubst src/%.s,obj/%.expanded.s,$(SRCS))
BIN := hitherto

all: $(BIN)

$(BIN): $(OBJS)
	rm -f $@
	$(CC) -g -o $@ $^ $(LDFLAGS)

obj/%.o: src/%.s $(INCS) | obj
	$(CC) $(ASFLAGS) -c -o $@ $<

obj:
	mkdir -p obj

clean:
	rm -rf obj $(BIN)

expanded: $(EXPANDED)

obj/%.expanded.s: src/%.s $(INCS) | obj
	llvm-mc -triple=x86_64-linux-gnu -x86-asm-syntax=intel -I src $< -o $@

.PHONY: all clean
