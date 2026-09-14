P4_SRC  := p4src/collective_telemetry.p4
JSON    := build/collective_telemetry.json

.PHONY: all build run stop clean

all: build

build: $(P4_SRC)
	@mkdir -p build
	p4c --target bmv2 --arch v1model -o $(JSON) $(P4_SRC)
	@echo "Built $(JSON)"

run: build
	sudo python3 topology.py

stop:
	sudo mn -c
	-sudo pkill simple_switch

clean:
	sudo mn -c
	rm -rf build *.pcap /tmp/s1.log /tmp/*.pcap
