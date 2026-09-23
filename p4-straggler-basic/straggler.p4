#include <core.p4>
#include <v1model.p4>

/*
 * Basic collective-aware straggler detector.
 *
 * Topology:
 *
 *   h1 \
 *   h2  \
 *   h3 --- s1 --- h4
 *
 * h1, h2, h3 are collective participants.
 * h4 is the receiver.
 *
 * Each collective packet carries:
 *   context_id      : identifies one collective operation
 *   participant_id  : identifies the worker
 *
 * The switch stores the minimum and maximum ingress timestamps
 * for each context_id. If max_timestamp - min_timestamp exceeds
 * STRAGGLER_THRESHOLD_US, the latest participant is reported as
 * a straggler in the BMv2 switch log.
 */

const bit<16> ETHERTYPE_IPV4 = 0x0800;
const bit<8>  IP_PROTO_UDP   = 17;

const bit<48> STRAGGLER_THRESHOLD_US = 5000;  // 5 ms

header ethernet_t {
    bit<48> dstAddr;
    bit<48> srcAddr;
    bit<16> etherType;
}

header ipv4_t {
    bit<4>  version;
    bit<4>  ihl;
    bit<8>  diffserv;
    bit<16> totalLen;
    bit<16> identification;
    bit<3>  flags;
    bit<13> fragOffset;
    bit<8>  ttl;
    bit<8>  protocol;
    bit<16> hdrChecksum;
    bit<32> srcAddr;
    bit<32> dstAddr;
}

header udp_t {
    bit<16> srcPort;
    bit<16> dstPort;
    bit<16> length_;
    bit<16> checksum;
}

/*
 * 4-byte collective context shim at the beginning of UDP payload.
 *
 * Bytes:
 *   0..1 : context_id
 *   2    : participant_id
 *   3    : flags
 */
header collective_t {
    bit<16> context_id;
    bit<8>  participant_id;
    bit<8>  flags;
}

struct headers_t {
    ethernet_t  ethernet;
    ipv4_t      ipv4;
    udp_t       udp;
    collective_t collective;
}

struct metadata_t {
    bit<48> min_timestamp;
    bit<48> max_timestamp;
    bit<8>  min_participant;
    bit<8>  max_participant;
}

/*
 * One register entry per possible context_id.
 *
 * BMv2 registers store one scalar value per entry, so the state is
 * split across several registers rather than one struct register.
 */
register<bit<48>>(65536) min_timestamp_reg;
register<bit<48>>(65536) max_timestamp_reg;
register<bit<8>>(65536)  min_participant_reg;
register<bit<8>>(65536)  max_participant_reg;

parser MyParser(
    packet_in packet,
    out headers_t hdr,
    inout metadata_t meta,
    inout standard_metadata_t standard_metadata)
{
    state start {
        packet.extract(hdr.ethernet);
        transition select(hdr.ethernet.etherType) {
            ETHERTYPE_IPV4: parse_ipv4;
            default: accept;
        }
    }

    state parse_ipv4 {
        packet.extract(hdr.ipv4);
        transition select(hdr.ipv4.protocol) {
            IP_PROTO_UDP: parse_udp;
            default: accept;
        }
    }

    state parse_udp {
        packet.extract(hdr.udp);
        transition parse_collective;
    }

    state parse_collective {
        packet.extract(hdr.collective);
        transition accept;
    }
}

control MyVerifyChecksum(
    inout headers_t hdr,
    inout metadata_t meta)
{
    apply { }
}

control MyIngress(
    inout headers_t hdr,
    inout metadata_t meta,
    inout standard_metadata_t standard_metadata)
{
    action drop() {
        mark_to_drop(standard_metadata);
    }

    action forward(bit<9> port) {
        standard_metadata.egress_spec = port;
    }

    /*
     * h1 -> port 1
     * h2 -> port 2
     * h3 -> port 3
     * h4 -> port 4
     */
    table ipv4_forward {
        key = {
            hdr.ipv4.dstAddr : exact;
        }

        actions = {
            forward;
            drop;
        }

        const entries = {
            10.0.1.1 : forward(1);
            10.0.2.2 : forward(2);
            10.0.3.3 : forward(3);
            10.0.4.4 : forward(4);
        }

        size = 4;
        default_action = drop();
    }

    action detect_straggler() {
        bit<32> index;
        bit<48> old_min;
        bit<48> old_max;
        bit<8> old_min_participant;
        bit<8> old_max_participant;
        bit<48> now;
        bit<48> skew;

        index = (bit<32>) hdr.collective.context_id;
        now = standard_metadata.ingress_global_timestamp;

        min_timestamp_reg.read(old_min, index);
        max_timestamp_reg.read(old_max, index);
        min_participant_reg.read(old_min_participant, index);
        max_participant_reg.read(old_max_participant, index);

        /*
         * For this first experiment, participant 1 starts a new
         * collective context. The sender deliberately sends
         * participant 1 first.
         */
        if (hdr.collective.participant_id == 1) {
            old_min = now;
            old_max = now;
            old_min_participant = 1;
            old_max_participant = 1;
        }
        else {
            if (now < old_min) {
                old_min = now;
                old_min_participant = hdr.collective.participant_id;
            }

            if (now > old_max) {
                old_max = now;
                old_max_participant = hdr.collective.participant_id;
            }

            skew = old_max - old_min;

            if (skew > STRAGGLER_THRESHOLD_US) {
                log_msg(
                    "STRAGGLER context={} participant={} skew_us={} min_participant={} max_participant={}",
                    {
                        hdr.collective.context_id,
                        hdr.collective.participant_id,
                        skew,
                        old_min_participant,
                        old_max_participant
                    }
                );
            }
        }

        min_timestamp_reg.write(index, old_min);
        max_timestamp_reg.write(index, old_max);
        min_participant_reg.write(index, old_min_participant);
        max_participant_reg.write(index, old_max_participant);
    }

    apply {
        ipv4_forward.apply();

        if (hdr.collective.isValid()) {
            detect_straggler();
        }
    }
}

control MyEgress(
    inout headers_t hdr,
    inout metadata_t meta,
    inout standard_metadata_t standard_metadata)
{
    apply { }
}

control MyComputeChecksum(
    inout headers_t hdr,
    inout metadata_t meta)
{
    apply {
        /*
         * We do not modify the IPv4 header, so its checksum remains valid.
         */
    }
}

control MyDeparser(
    packet_out packet,
    in headers_t hdr)
{
    apply {
        packet.emit(hdr.ethernet);
        packet.emit(hdr.ipv4);
        packet.emit(hdr.udp);
        packet.emit(hdr.collective);

        /*
         * Any bytes after the parsed headers are automatically
         * treated as payload by BMv2 and remain after the deparser.
         */
    }
}

V1Switch(
    MyParser(),
    MyVerifyChecksum(),
    MyIngress(),
    MyEgress(),
    MyComputeChecksum(),
    MyDeparser()
) main;
