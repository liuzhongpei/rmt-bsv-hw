// ============================================================
// TestFramework.bsv - 测试基础设施
//
// 通用测试工具：报文构造、期望输出检查、统计收集
// ============================================================

package TestFramework;

import Vector :: *;
import FIFOF :: *;
import SpecialFIFOs :: *;
import DefaultValue :: *;
import RMTInterfaces :: *;
`include "RMTConfig.bh"

// ============================================================
//                       测试统计
// ============================================================

typedef struct {
    Bit#(32) total_packets;
    Bit#(32) passed_packets;
    Bit#(32) failed_packets;
    Bit#(32) dropped_packets;
} TestStats deriving (Bits, Eq, FShow);

instance DefaultValue#(TestStats);
    defaultValue = TestStats {
        total_packets: 0,
        passed_packets: 0,
        failed_packets: 0,
        dropped_packets: 0
    };
endinstance

// ============================================================
//                       测试向量
// ============================================================

typedef struct {
    Bit#(32) test_id;                 // 测试 ID
    Vector#(64, Bit#(256)) pkt_data;  // 输入报文数据
    Bit#(12) pkt_len;                 // 报文长度
    Bit#(10) in_port;                 // 入端口
    Vector#(64, Bit#(256)) expected_data;  // 期望输出
    Bit#(12) expected_len;            // 期望长度
    Bit#(10) expected_port;           // 期望出端口
    Bool expect_drop;                 // 是否期望丢弃
} TestVector deriving (Bits, Eq);

// ============================================================
//                       测试平台接口
// ============================================================

interface TestPlatformIfc;
    // 加载测试向量
    method Action load_test_vector(TestVector tv);

    // 运行测试
    method Action start_test;

    // 获取结果
    method ActionValue#(Bool) get_result;
    method TestStats get_stats;
    method Bit#(32) get_error_code;
endinterface

// ============================================================
//                       辅助函数
// ============================================================

// 从字节数组构造 256-bit beat
function Bit#(256) bytes_to_beat(Vector#(32, Bit#(8)) bytes);
    Bit#(256) result = 0;
    for (Integer i = 0; i < 32; i = i + 1) begin
        result = (result << 8) | zeroExtend(bytes[i]);
    end
    return result;
endfunction

// 从 256-bit beat 提取字节
function Vector#(32, Bit#(8)) beat_to_bytes(Bit#(256) beat);
    Vector#(32, Bit#(8)) bytes = newVector;
    for (Integer i = 0; i < 32; i = i + 1) begin
        Integer start_bit = i * 8;
        bytes[i] = beat[start_bit + 7 : start_bit];
    end
    return bytes;
endfunction

// 构造以太网头部
function Vector#(14, Bit#(8)) make_eth_header(Bit#(48) dmac, Bit#(48) smac, Bit#(16) ethertype);
    Vector#(14, Bit#(8)) hdr = newVector;
    // DMAC (6 bytes)
    for (Integer i = 0; i < 6; i = i + 1) begin
        Integer start_bit = i * 8;
        hdr[i] = dmac[start_bit + 7 : start_bit];
    end
    // SMAC (6 bytes)
    for (Integer i = 0; i < 6; i = i + 1) begin
        Integer start_bit = i * 8;
        hdr[6+i] = smac[start_bit + 7 : start_bit];
    end
    // Ethertype (2 bytes)
    hdr[12] = ethertype[15:8];
    hdr[13] = ethertype[7:0];
    return hdr;
endfunction

// 构造 IPv6 头部
function Vector#(40, Bit#(8)) make_ipv6_header(Bit#(128) src, Bit#(128) dst, Bit#(8) next_hdr, Bit#(8) hop_limit);
    Vector#(40, Bit#(8)) hdr = newVector;
    // Version (4 bits) + Traffic Class (8 bits) + Flow Label (20 bits)
    hdr[0] = 8'h60;  // Version 6
    hdr[1] = 8'h00;
    hdr[2] = 8'h00;
    hdr[3] = 8'h00;
    // Payload Length (2 bytes) - 简化
    hdr[4] = 8'h00;
    hdr[5] = 8'h00;
    // Next Header
    hdr[6] = next_hdr;
    // Hop Limit
    hdr[7] = hop_limit;
    // Source Address (16 bytes)
    for (Integer i = 0; i < 16; i = i + 1) begin
        Integer start_bit = i * 8;
        hdr[8+i] = src[start_bit + 7 : start_bit];
    end
    // Destination Address (16 bytes)
    for (Integer i = 0; i < 16; i = i + 1) begin
        Integer start_bit = i * 8;
        hdr[24+i] = dst[start_bit + 7 : start_bit];
    end
    return hdr;
endfunction

// 比较两个报文数据
function Bool compare_packets(Vector#(64, Bit#(256)) actual, Vector#(64, Bit#(256)) expected, Bit#(12) len);
    Bit#(12) beats = (len + 31) >> 5;  // ceil(len / 32)
    Bool packets_match = True;

    for (Integer i = 0; i < 64; i = i + 1) begin
        if (fromInteger(i) < beats) begin
            if (actual[i] != expected[i]) begin
                packets_match = False;
            end
        end
    end
    return packets_match;
endfunction

// ============================================================
//                       测试平台实现
// ============================================================

module mkTestPlatform(TestPlatformIfc);
    // 测试向量
    Reg#(TestVector) test_vec_r <- mkRegU;
    Reg#(Bool) test_loaded_r <- mkReg(False);

    // 统计
    Reg#(TestStats) stats_r <- mkReg(defaultValue);

    // 错误信息（简化为错误码）
    Reg#(Bit#(32)) error_code_r <- mkReg(0);

    // 结果 FIFO
    FIFOF#(Bool) result_fifo <- mkFIFOF;

    // --------------------------------------------------------
    // 接口方法
    // --------------------------------------------------------

    method Action load_test_vector(TestVector tv);
        test_vec_r <= tv;
        test_loaded_r <= True;
    endmethod

    // ★ 已废弃：本方法从不驱动 DUT、从不比对输出，直接"通过"（假测试根因）。
    //   真实协议端到端测试已改为直接实例化 mkRMTTop（TestTCPReorder/TestSRv6/
    //   TestVXLAN），不再使用 mkTestPlatform。本接口保留仅为兼容旧引用。
    method Action start_test if (test_loaded_r);
        TestStats s = stats_r;
        s.total_packets  = s.total_packets + 1;
        s.passed_packets = s.passed_packets + 1;
        stats_r <= s;
        result_fifo.enq(True);
    endmethod

    method ActionValue#(Bool) get_result;
        let res = result_fifo.first;
        result_fifo.deq;
        return res;
    endmethod

    method TestStats get_stats;
        return stats_r;
    endmethod

    method Bit#(32) get_error_code;
        return error_code_r;
    endmethod

endmodule

endpackage
