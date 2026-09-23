/* -*- P4_16 -*- */
/*
 * Collective-Aware In-Switch Telemetry -- core detector.
 *
 *   Parse   -> context-shim header (op type, context id, participant id)
 *   Lookup  -> context id's low bits select a register slot
 *   Update  -> t_fast = min(t_fast, t_arrival), t_slow = max(t_slow, t_arrival)
 *   Calculate -> skew = t_slow - t_fast   (register subtraction only)
 *   Decide  -> skew > theta  => clone a compact report to the collector
 *              skew <= theta => forward only, no telemetry generated
 *
 * Register API note: this v1model.p4 declares
 *     void read(out T result, in bit<32> index);
 * i.e. read() writes into an out-parameter, it does not return a value.
 * Every register access below uses that form.
 */

#include <core.p4>
#include <v1model.p4>

/*************** CONSTANTS ***************/

const bit<16> TYPE_IPV4       = 0x0800;
const bit<16> TYPE_REPORT     = 0x1234;   // EtherType for telemetry reports
const bit<8>  IP_PROTO_UDP    = 17;
const bit<16> COLLECTIVE_PORT = 4321;     // UDP dst port used by collective traffic

const bit<32> CTX_TABLE_SIZE   = 1024;    // must be power of two (bit-sliced index, no div)
const bit<32> MIRROR_SESSION_ID = 1;      // configured via: mirroring_add 1 <collector_port>

// BMv2 instance_type value for an Ingress-to-Egress clone. Not defined by
// v1model.p4 itself -- declared locally, as every P4 program using clones does.
const bit<32> PKT_INSTANCE_TYPE_INGRESS_CLONE = 1;

/*************** HEADERS ***************/

typedef bit<9>  egressSpec_t;
typedef bit<48> macAddr_t;
typedef bit<32> ip4Addr_t;

header ethernet_t {
    macAddr_t dstAddr;
    macAddr_t srcAddr;
    bit<16>   etherType;
}

header ipv4_t {
    bit<4>    version;
    bit<4>    ihl;
    bit<8>    diffserv;
    bit<16>   totalLen;
    bit<16>   identification;
    bit<3>    flags;
    bit<13>   fragOffset;
    bit<8>    ttl;
    bit<8>    protocol;
    bit<16>   hdrChecksum;
    ip4Addr_t srcAddr;
    ip4Addr_t dstAddr;
}

header udp_t {
    bit<16> srcPort;
    bit<16> dstPort;
    bit<16> length_;
    bit<16> checksum;
}

// Context-shim: associates a packet with the collective operation it
// belongs to, so otherwise-independent flows can be correlated in-switch.
header shim_t {
    bit<8>  version;
    bit<8>  opType;           // 0 = AllReduce, 1 = Ring-Shift, 2 = Gather
    bit<16> contextId;        // identifies one synchronization round
    bit<8>  participantId;    // which worker sent this packet
    bit<8>  numParticipants;  // total participants expected this round
    bit<16> seq;
}

// Compact telemetry report -- only ever generated on a straggler event.
header report_t {
    bit<16> contextId;
    bit<8>  opType;
    bit<8>  stragglerId;
    bit<48> tFast;
    bit<48> tSlow;
    bit<48> skew;
    bit<32> queueDepth;
    bit<32> queueDelay;
}

struct metadata {
    bit<16> contextId;
    bit<8>  opType;
    bit<8>  stragglerId;
    bit<48> tFast;
    bit<48> tSlow;
    bit<48> skew;
}

struct headers {
    ethernet_t ethernet;
    ipv4_t     ipv4;
    udp_t      udp;
    shim_t     shim;
    report_t   report;
}

/*************** PARSER ***************/

parser MyParser(packet_in packet,
                 out headers hdr,
                 inout metadata meta,
                 inout standard_metadata_t standard_metadata) {

    state start {
        transition parse_ethernet;
    }

    state parse_ethernet {
        packet.extract(hdr.ethernet);
        transition select(hdr.ethernet.etherType) {
            TYPE_IPV4: parse_ipv4;
            default:   accept;
        }
    }

    state parse_ipv4 {
        packet.extract(hdr.ipv4);
        transition select(hdr.ipv4.protocol) {
            IP_PROTO_UDP: parse_udp;
            default:      accept;
        }
    }

    state parse_udp {
        packet.extract(hdr.udp);
        transition select(hdr.udp.dstPort) {
            COLLECTIVE_PORT: parse_shim;
            default:         accept;
        }
    }

    state parse_shim {
        packet.extract(hdr.shim);
        transition accept;
    }
}

/*************** CHECKSUM VERIFY ***************/

control MyVerifyChecksum(inout headers hdr, inout metadata meta) {
    apply { }
}

/*************** INGRESS ***************/

control MyIngress(inout headers hdr,
                   inout metadata meta,
                   inout standard_metadata_t standard_metadata) {

    register<bit<48>>(CTX_TABLE_SIZE) regTFast;
    register<bit<48>>(CTX_TABLE_SIZE) regTSlow;
    register<bit<8>>(CTX_TABLE_SIZE)  regValid;
    register<bit<16>>(CTX_TABLE_SIZE) regCount;
    register<bit<8>>(CTX_TABLE_SIZE)  regSlowPid;
    register<bit<48>>(1)              regThreshold;  // theta, in microseconds

    action drop() {
        mark_to_drop(standard_metadata);
    }

    action set_egress_port(egressSpec_t port) {
        standard_metadata.egress_spec = port;
    }

    table forwarding {
        key = { hdr.ipv4.dstAddr: exact; }
        actions = { set_egress_port; drop; }
        size = 64;
        default_action = drop();
    }

    action update_and_check_skew() {
        bit<32> ctxIndex = (bit<32>)hdr.shim.contextId[9:0];
        bit<48> ts       = standard_metadata.ingress_global_timestamp;

        bit<8>  valid;
        bit<48> tfast;
        bit<48> tslow;
        bit<16> cnt;
        bit<16> prevCnt;
        bit<8>  slowPid;

        regValid.read(valid, ctxIndex);

        if (valid == 0) {
            // First packet observed for this operation context / round.
            regTFast.write(ctxIndex, ts);
            regTSlow.write(ctxIndex, ts);
            regValid.write(ctxIndex, 1);
            regSlowPid.write(ctxIndex, hdr.shim.participantId);
            regCount.write(ctxIndex, 1);
            tfast = ts;
            tslow = ts;
            cnt   = 1;
        } else {
            regTFast.read(tfast, ctxIndex);
            regTSlow.read(tslow, ctxIndex);

            if (ts < tfast) {
                tfast = ts;
                regTFast.write(ctxIndex, tfast);
            }
            if (ts > tslow) {
                tslow = ts;
                regTSlow.write(ctxIndex, tslow);
                regSlowPid.write(ctxIndex, hdr.shim.participantId);
            }
            regCount.read(prevCnt, ctxIndex);
            cnt = prevCnt + 1;
            regCount.write(ctxIndex, cnt);
        }

        bit<48> skew = tslow - tfast;
        bit<48> theta;
        regThreshold.read(theta, 0);

        regSlowPid.read(slowPid, ctxIndex);

        meta.contextId   = hdr.shim.contextId;
        meta.opType      = hdr.shim.opType;
        meta.tFast       = tfast;
        meta.tSlow       = tslow;
        meta.skew        = skew;
        meta.stragglerId = slowPid;

        if (skew > theta) {
            clone3(CloneType.I2E, MIRROR_SESSION_ID, meta);
        }

        if (cnt >= (bit<16>)hdr.shim.numParticipants) {
            regValid.write(ctxIndex, 0);
            regCount.write(ctxIndex, 0);
        }
    }

    apply {
        if (hdr.ipv4.isValid()) {
            forwarding.apply();
        }
        if (hdr.shim.isValid()) {
            update_and_check_skew();
        }
    }
}

/*************** EGRESS ***************/

control MyEgress(inout headers hdr,
                  inout metadata meta,
                  inout standard_metadata_t standard_metadata) {
    apply {
        if (standard_metadata.instance_type == PKT_INSTANCE_TYPE_INGRESS_CLONE) {
            hdr.report.setValid();
            hdr.report.contextId   = meta.contextId;
            hdr.report.opType      = meta.opType;
            hdr.report.stragglerId = meta.stragglerId;
            hdr.report.tFast       = meta.tFast;
            hdr.report.tSlow       = meta.tSlow;
            hdr.report.skew        = meta.skew;
            hdr.report.queueDepth  = (bit<32>)standard_metadata.deq_qdepth;
            hdr.report.queueDelay  = standard_metadata.deq_timedelta;

            hdr.ethernet.etherType = TYPE_REPORT;
            hdr.ipv4.setInvalid();
            hdr.udp.setInvalid();
            hdr.shim.setInvalid();
        }
    }
}

/*************** CHECKSUM COMPUTE ***************/

control MyComputeChecksum(inout headers hdr, inout metadata meta) {
    apply {
        update_checksum(
            hdr.ipv4.isValid(),
            { hdr.ipv4.version, hdr.ipv4.ihl, hdr.ipv4.diffserv, hdr.ipv4.totalLen,
              hdr.ipv4.identification, hdr.ipv4.flags, hdr.ipv4.fragOffset,
              hdr.ipv4.ttl, hdr.ipv4.protocol, hdr.ipv4.srcAddr, hdr.ipv4.dstAddr },
            hdr.ipv4.hdrChecksum,
            HashAlgorithm.csum16
        );
    }
}

/*************** DEPARSER ***************/

control MyDeparser(packet_out packet, in headers hdr) {
    apply {
        packet.emit(hdr.ethernet);
        packet.emit(hdr.ipv4);
        packet.emit(hdr.udp);
        packet.emit(hdr.shim);
        packet.emit(hdr.report);
    }
}

/*************** SWITCH ***************/

V1Switch(
MyParser(),
MyVerifyChecksum(),
MyIngress(),
MyEgress(),
MyComputeChecksum(),
MyDeparser()
) main;
