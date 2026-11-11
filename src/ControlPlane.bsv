// ============================================================
// ControlPlane.bsv - 控制面接口
//
// AXI-Lite → 内部命令转换
//
// ★ 修复内容（相对原实现）：
//   1. 原 axi_write 在同一动作序列里 write_addr + write_data，write_data
//      读到的 write_addr_r 是旧值（寄存器同周期读旧值）→ 命令地址错乱。
//      现在两步分拍：先写地址，下一拍再写数据。
//   2. 原 axi_read 等待的读响应永远无人产生 → 死锁。现在直接组合读状态
//      寄存器（绕过 AXI 读回环）。
//   3. 原 dispatch_command 只处理 9 种命令里的 3 种 → 补全 TABLE_DELETE、
//      TCP_SESSION_CREATE/DELETE、PHV_TEMPLATE_SET。
// ============================================================

package ControlPlane;

import Vector :: *;
import FIFOF :: *;
import SpecialFIFOs :: *;
import GetPut :: *;
import DefaultValue :: *;
import RMTInterfaces :: *;
import AXILiteSlave :: *;
`include "RMTConfig.bh"

// ============================================================
//                       辅助函数
// ============================================================

function ActionProgram defaultValueAction();
    ActionProgram ap;
    ap.action_id = 0;
    ap.nparams = 0;
    ap.prog = replicate(replicate(ALUInsn {
        op: ALU_NOP,
        fd: 0, fs1: 0, fs2: 0,
        fbase: 0, stride: 0,
        imm: 0, use_param: False, pidx: 0
    }));
    ap.nslots = replicate(0);
    ap.nwords = 0;
    return ap;
endfunction

// ============================================================
//                       实现
// ============================================================

module mkControlPlane(ControlPlaneIfc);
    // AXI-Lite Slave
    AXILiteSlaveIfc axi_slave <- mkAXILiteSlave;

    // 命令分发 FIFO
    FIFOF#(CPCmd) parser_config_fifo <- mkFIFOF;
    FIFOF#(Tuple2#(Bit#(4), TCAMEntry)) table_insert_fifo <- mkFIFOF;
    FIFOF#(Tuple2#(Bit#(4), Bit#(10))) table_delete_fifo <- mkFIFOF;
    // ★ (物理级, 动作号, 程序)：原实现只有动作号，无法确定装载到哪一级
    FIFOF#(Tuple3#(Bit#(2), Bit#(5), ActionProgram)) action_load_fifo <- mkFIFOF;
    FIFOF#(Tuple2#(Bit#(8), FieldValue)) phv_template_fifo <- mkFIFOF;
    FIFOF#(Tuple2#(TCP5Tuple, Bit#(32))) tcp_create_fifo <- mkFIFOF;
    FIFOF#(TCP5Tuple) tcp_delete_fifo <- mkFIFOF;

    // ★ TCP 会话 5 元组分两笔 AXI 写暂存：第 1 笔写 IP 对，
    //   第 2 笔写端口对 + 初始 expected_seq（原实现端口恒 0，会话永不命中）
    Reg#(TCP5Tuple) sess_key_r <- mkRegU;
    Reg#(Bool)      sess_key_ok_r <- mkReg(False);

    // 统计计数器
    Reg#(Bit#(64)) rx_count_r <- mkReg(0);
    Reg#(Bit#(64)) tx_count_r <- mkReg(0);
    Reg#(Bit#(64)) drop_count_r <- mkReg(0);
    Reg#(Bit#(32)) latency_r <- mkReg(0);
    Reg#(Bit#(16)) tcp_sessions_r <- mkReg(0);

    // AXI 写两步暂存
    Reg#(AXILiteWrite) axi_wr_r <- mkRegU;
    Reg#(Bool) axi_wr_pending_r <- mkReg(False);
    Reg#(Bool) axi_wr_addr_done_r <- mkReg(False);

    // AXI 读地址（组合返回，无需暂存回环）

    // --------------------------------------------------------
    // 规则：AXI 写——第 1 拍写地址
    // --------------------------------------------------------
    rule axi_write_addr (axi_wr_pending_r && !axi_wr_addr_done_r);
        axi_slave.write_addr(axi_wr_r);
        axi_wr_addr_done_r <= True;
    endrule

    // 规则：AXI 写——第 2 拍写数据（此时 write_addr_r 已是本命令地址）
    rule axi_write_data (axi_wr_pending_r && axi_wr_addr_done_r);
        axi_slave.write_data(axi_wr_r);
        axi_wr_pending_r <= False;
        axi_wr_addr_done_r <= False;
    endrule

    // --------------------------------------------------------
    // 规则：命令分发
    // --------------------------------------------------------
    rule dispatch_command;
        let cmd <- axi_slave.get_command;

        case (cmd.cmd)
            CP_CMD_PARSER_CONFIG:
                // ★ 不再入队：AXI 单次 64-bit 写无法承载 ParseState（约 2.5Kbit），
                //   解析图配置走专用接口 config_parser（仿真测试台/未来 DMA）。
                //   原实现入队后 RMTTop 从不消费，FIFO 堆满 16 条后 dispatch
                //   卡死 → AXI 写通道整体死锁。
                noAction;

            CP_CMD_TABLE_INSERT: begin
                // 解析 TCAMEntry（key=低 64 位扩展，mask=全关心；
                // ★ 命中动作号由 addr[11:8] 给出，原实现恒 0）
                TCAMEntry entry;
                entry.key = zeroExtend(cmd.data);
                entry.mask = '1;
                entry.action_id = zeroExtend(cmd.addr[11:8]);
                entry.params = 0;
                table_insert_fifo.enq(tuple2(cmd.addr[7:4], entry));
            end

            CP_CMD_TABLE_DELETE:
                table_delete_fifo.enq(tuple2(cmd.addr[7:4], cmd.addr[9:0]));

            CP_CMD_ACTION_LOAD:
                // ★ 物理级 = addr[1:0]，动作号 = addr[6:2]
                action_load_fifo.enq(tuple3(cmd.addr[1:0], cmd.addr[6:2],
                                            defaultValueAction));

            CP_CMD_PHV_TEMPLATE_SET: begin
                FieldValue fv;
                fv.value = zeroExtend(cmd.data);
                fv.bitlen = 64;
                phv_template_fifo.enq(tuple2(cmd.addr[7:0], fv));
            end

            // ★ TCP 会话命令分两笔写（addr[0] 选择）：
            //   0: data = src_ip[31:0] | dst_ip[63:32]
            //   1: data = sport[15:0] | dport[31:16] | init_seq[63:32]
            CP_CMD_TCP_SESSION_CREATE: begin
                if (cmd.addr[0] == 1'b0) begin
                    TCP5Tuple key;
                    key.src_ip   = cmd.data[31:0];
                    key.dst_ip   = cmd.data[63:32];
                    key.src_port = 0;
                    key.dst_port = 0;
                    sess_key_r    <= key;
                    sess_key_ok_r <= True;
                end
                else if (sess_key_ok_r) begin
                    TCP5Tuple key = sess_key_r;
                    key.src_port = cmd.data[15:0];
                    key.dst_port = cmd.data[31:16];
                    tcp_create_fifo.enq(tuple2(key, cmd.data[63:32]));
                    sess_key_ok_r <= False;
                end
            end

            CP_CMD_TCP_SESSION_DELETE: begin
                if (cmd.addr[0] == 1'b0) begin
                    TCP5Tuple key;
                    key.src_ip   = cmd.data[31:0];
                    key.dst_ip   = cmd.data[63:32];
                    key.src_port = 0;
                    key.dst_port = 0;
                    sess_key_r    <= key;
                    sess_key_ok_r <= True;
                end
                else if (sess_key_ok_r) begin
                    TCP5Tuple key = sess_key_r;
                    key.src_port = cmd.data[15:0];
                    key.dst_port = cmd.data[31:16];
                    tcp_delete_fifo.enq(key);
                    sess_key_ok_r <= False;
                end
            end

            default: begin
                // CP_CMD_PIPE_CONFIG / CP_CMD_STATUS_READ：暂不处理
                noAction;
            end
        endcase
    endrule

    // --------------------------------------------------------
    // 接口方法
    // --------------------------------------------------------

    // parser_config 保留接口兼容（AXI 无法承载 ParseState，当前无生产者）
    interface Get parser_config = toGet(parser_config_fifo);
    interface Get table_insert = toGet(table_insert_fifo);
    interface Get table_delete = toGet(table_delete_fifo);
    interface Get action_load = toGet(action_load_fifo);
    interface Get phv_template_set = toGet(phv_template_fifo);
    interface Get tcp_session_create = toGet(tcp_create_fifo);
    interface Get tcp_session_delete = toGet(tcp_delete_fifo);

    method Bit#(64) get_rx_count;
        return rx_count_r;
    endmethod

    method Bit#(64) get_tx_count;
        return tx_count_r;
    endmethod

    method Bit#(64) get_drop_count;
        return drop_count_r;
    endmethod

    method Bit#(32) get_pipeline_latency;
        return latency_r;
    endmethod

    method Bit#(16) get_tcp_active_sessions;
        return tcp_sessions_r;
    endmethod

    method Action axi_write(Bit#(32) addr, Bit#(64) data) if (!axi_wr_pending_r);
        axi_wr_r <= AXILiteWrite { addr: addr, data: data, strb: '1 };
        axi_wr_pending_r <= True;
        axi_wr_addr_done_r <= False;
    endmethod

    method ActionValue#(Bit#(64)) axi_read(Bit#(32) addr);
        // ★ 组合读状态寄存器（原 AXI 读回环无人响应会死锁，改为直读）
        return case (addr[15:12])
            4'hA: rx_count_r;
            4'hB: tx_count_r;
            4'hC: drop_count_r;
            4'hD: zeroExtend(tcp_sessions_r);
            default: 0;
        endcase;
    endmethod

endmodule

endpackage
