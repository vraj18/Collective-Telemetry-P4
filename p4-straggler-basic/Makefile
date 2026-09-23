P4C := p4c-bm2-ss
P4SRC := straggler.p4
BUILD := build
JSON := $(BUILD)/straggler.json

all: $(JSON)

$(BUILD):
	mkdir -p $(BUILD)

$(JSON): $(P4SRC) | $(BUILD)
	$(P4C) --arch v1model -o $@ $<

run: $(JSON)
	sudo python3 ../../utils/run_exercise.py \
		-t topology.json \
		-j $(JSON)

stop:
	sudo mn -c

clean:
	rm -rf build logs pcaps
	sudo mn -c

.PHONY: all run stop clean
