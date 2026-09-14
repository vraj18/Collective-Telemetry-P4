/* -*- P4_16 -*- */
/*
 * Collective-Aware In-Switch Telemetry
 * ------------------------------------
 * Implements the design from the project report / PPT:
 *   1. A lightweight "context-shim" header tags every collective-communication
 *      packet (AllReduce / Ring-Shift / Gather) with an operation context ID
 *      and a participant ID, so packets that are otherwise independent
 *      5-tuples can be correlated in-network.
 *   2. For each active operation context, the switch maintains the min and
 *      max observed arrival timestamps (t_fast, t_slow) in stateful P4
 *      registers, using only register arithmetic (no division / floats,
 *      per the hardware constraints noted in the design).
 *   3. Intra-operation skew  delta_t = t_slow - t_fast  is compared against
 *      an operator-defined threshold theta on every packet.
 *   4. Normal packets only update local register state and are forwarded
 *      with no added overhead. Only when delta_t > theta does the switch
 *      clone a compact telemetry report (participant ID + local queue
 *      state) to the control plane / collector -- event-driven,
 *      straggler-triggered reporting instead of per-packet telemetry.
 *
 * Target: BMv2 (simple_switch), v1model architecture.
 */

#include <core.p4>
#include <v1model.p4>

/*************************************************************************
************************* C O N S T A N T S *****************************
*************************************************************************/

const bit<16> TYPE_IPV4       = 0x0800;
const bit<16> TYPE_REPORT     = 0x1234;   // custom EtherType for telemetry reports
const bit<8>  IP_PROTO_UDP    = 17;
const bit<16> COLLECTIVE_PORT = 4321;     // UDP dst port used by collective traffic

// Number of concurrently tracked operation contexts. Must be a power of two
// because the context ID is mapped to a register index by bit-slicing
// (no modulo / division allowed in the P4 data plane).
const bit<32> CTX_TABLE_SIZE = 1024;

// Mirroring session used to clone straggler reports out to the collector.
// Configure the destination port at runtime with:
//   simple_switch_CLI: mirroring_add 1 <collector_port>
const bit<32> MIRROR_SESSION_ID = 1;

/*************************************************************************
*************************** H E A D E R S *******************************
*************************************************************************/

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

// --- Context-Shim header -------------------------------------------------
// The lightweight association between a packet and the collective
// operation it belongs to (slide 14, step 1: "Parse").
header shim_t {
    bit<8>  version;
    bit<8>  opType;           // 0 = AllReduce, 1 = Ring-Shift, 2 = Gather
    bit<16> contextId;        // identifies one synchronization step / round
    bit<8>  participantId;    // which worker this packet came from
    bit<8>  numParticipants;  // total participants expected this round
    bit<16> seq;              // sequence number within the round
}

// --- Telemetry report header ---------------------------------------------
// Compact, only ever generated on a straggler event -- never per packet.
header report_t {
    bit<16> contextId;
    bit<8>  opType;
    bit<8>  stragglerId;      // the lagging participant
    bit<48> tFast;            // fastest observed arrival (us)
    bit<48> tSlow;            // slowest observed arrival (us)
    bit<48> skew;             // delta_t = tSlow - tFast (us)
    bit<32> queueDepth;       // local queue occupancy at report time
    bit<32> queueDelay;       // local queueing delay at report time (us)
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

/*************************************************************************
*************************** P A R S E R **********************************
*************************************************************************/

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

/*************************************************************************
********************* C H E C K S U M   V E R I F Y ***********************
*************************************************************************/

control MyVerifyChecksum(inout headers hdr, inout metadata meta) {
    apply { /* not verified in this prototype */ }
}

/*************************************************************************
*************************** I N G R E S S ********************************
*************************************************************************/

control MyIngress(inout headers hdr,
                   inout metadata meta,
                   inout standard_metadata_t standard_metadata) {

    // ---- Per-operation-context state (pure register arithmetic) --------
    register<bit<48>>(CTX_TABLE_SIZE) regTFast;    // min observed timestamp
    register<bit<48>>(CTX_TABLE_SIZE) regTSlow;    // max observed timestamp
    register<bit<8>>(CTX_TABLE_SIZE)  regValid;    // 1 once context initialised
    register<bit<16>>(CTX_TABLE_SIZE) regCount;    // packets seen this round
    register<bit<8>>(CTX_TABLE_SIZE)  regSlowPid;  // participant that set tSlow
    register<bit<48>>(1)              regThreshold;// operator-defined theta (us)

    action drop() {
        mark_to_drop(standard_metadata);
    }

    action set_egress_port(egressSpec_t port) {
        standard_metadata.egress_spec = port;
    }

    // Plain destination-based forwarding between workers. This project's
    // contribution is the telemetry logic below, not the forwarding plane.
    table forwarding {
        key = { hdr.ipv4.dstAddr: exact; }
        actions = { set_egress_port; drop; }
        size = 64;
        default_action = drop();
    }

    // ---- Steps 2-5 from the design: Lookup, Update, Calculate, Decide --
    action update_and_check_skew() {
        // Step 2: Operation-context lookup. Low 10 bits of the context ID
        // select the register slot (bit-slicing == free hardware AND mask,
        // no division needed).
        bit<32> ctxIndex = (bit<32>)hdr.shim.contextId[9:0];
        bit<48> ts       = standard_metadata.ingress_global_timestamp;

        bit<8>  valid = regValid.read(ctxIndex);
        bit<48> tfast;
        bit<48> tslow;
        bit<16> cnt;

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
            // Step 3: Timestamp update -- t_fast = min(t_fast, t), t_slow = max(t_slow, t)
            tfast = regTFast.read(ctxIndex);
            tslow = regTSlow.read(ctxIndex);

            if (ts < tfast) {
                tfast = ts;
                regTFast.write(ctxIndex, tfast);
            }
            if (ts > tslow) {
                tslow = ts;
                regTSlow.write(ctxIndex, tslow);
                regSlowPid.write(ctxIndex, hdr.shim.participantId);
            }
            cnt = regCount.read(ctxIndex) + 1;
            regCount.write(ctxIndex, cnt);
        }

        // Step 4: Skew calculation. delta_t = t_slow - t_fast (register
        // subtraction only -- no floating point, matches hardware limits).
        bit<48> skew  = tslow - tfast;
        bit<48> theta = regThreshold.read(0);

        meta.contextId   = hdr.shim.contextId;
        meta.opType       = hdr.shim.opType;
        meta.tFast        = tfast;
        meta.tSlow        = tslow;
        meta.skew         = skew;
        meta.stragglerId  = regSlowPid.read(ctxIndex);

        // Step 5: Threshold decision.
        //   skew <= theta -> Normal   -> forward only, no telemetry
        //   skew >  theta -> Straggler -> clone a compact report
        if (skew > theta) {
            clone3(CloneType.I2E, MIRROR_SESSION_ID, meta);
        }

        // Round complete (all expected participants observed this context)
        // -> reset state so the same context ID can be reused next round.
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

/*************************************************************************
**************************** E G R E S S **********************************
*************************************************************************/

control MyEgress(inout headers hdr,
                  inout metadata meta,
                  inout standard_metadata_t standard_metadata) {
    apply {
        if (standard_metadata.instance_type == PKT_INSTANCE_TYPE_INGRESS_CLONE) {
            // This is the straggler-triggered clone (Ingress-to-Egress),
            // not the original data packet. Turn it into a compact
            // telemetry report, enriched with this switch's *current*
            // queue state -- deq_qdepth / deq_timedelta are only valid
            // once a packet has actually passed through the traffic
            // manager, which is why this enrichment happens here in
            // egress rather than back in the ingress decision above
            // (the same reasoning STRAGFLOW uses for its egress-side
            // deq_timedelta check).
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

/*************************************************************************
********************* C H E C K S U M   C O M P U T E **********************
*************************************************************************/

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

/*************************************************************************
*************************** D E P A R S E R *******************************
*************************************************************************/

control MyDeparser(packet_out packet, in headers hdr) {
    apply {
        packet.emit(hdr.ethernet);
        packet.emit(hdr.ipv4);
        packet.emit(hdr.udp);
        packet.emit(hdr.shim);
        packet.emit(hdr.report);
    }
}

/*************************************************************************
*************************** S W I T C H ***********************************
*************************************************************************/

V1Switch(
MyParser(),
MyVerifyChecksum(),
MyIngress(),
MyEgress(),
MyComputeChecksum(),
MyDeparser()
) main;
