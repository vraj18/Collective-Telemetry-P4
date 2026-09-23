P4_SRC := p4src/collective_telemetry.p4
JSON   := build/collective_telemetry.json

.PHONY: all build run clean

all: build

build: $(P4_SRC)
	@mkdir -p build
	p4c --target bmv2 --arch v1model -o $(JSON) $(P4_SRC)
	@echo "Built $(JSON)"

run: build
	sudo /usr/bin/python3 topology.py

clean:
	sudo mn -c
	-sudo pkill simple_switch
	rm -rf build /tmp/s1.log
