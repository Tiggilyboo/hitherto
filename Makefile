.SUFFIXES:

CC = clang
ASFLAGS = -g
LDFLAGS = -nostdlib -Wl,-e,_start -lvulkan

SRCS := $(wildcard src/*.s)
OBJS := $(patsubst src/%.s,obj/%.o,$(SRCS))
BIN := hitherto

all: $(BIN)

$(BIN): $(OBJS)
	$(CC) -g -o $@ $^ $(LDFLAGS)

obj/%.o: src/%.s | obj
	$(CC) $(ASFLAGS) -c -o $@ $<

obj:
	mkdir -p obj

clean:
	rm -rf obj $(BIN)

.PHONY: all clean
