.SUFFIXES:

CC = clang
ASFLAGS = -g -Isrc
LDFLAGS = -g -no-pie -nostdlib -Wl,-e,_start -lvulkan
SRCS := $(wildcard src/*.s)
INCS := $(wildcard src/*.inc)
OBJS := $(patsubst src/%.s,obj/%.o,$(SRCS))
BIN := hitherto

all: $(BIN)

$(BIN): $(OBJS)
	rm -f $@
	$(CC) -o $@ $^ $(LDFLAGS)

obj/%.o: src/%.s $(INCS) | obj
	$(CC) $(ASFLAGS) -c -o $@ $<

obj:
	mkdir -p obj

clean:
	rm -rf obj $(BIN)

obj/%.s: src/%.s $(INCS) | obj
	llvm-mc -triple=x86_64-linux-gnu -x86-asm-syntax=intel -I src $< -o $@

.PHONY: all clean
