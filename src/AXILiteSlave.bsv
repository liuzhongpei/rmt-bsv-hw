// ============================================================
// AXILiteSlave.bsv - AXI-Lite 协议处理器
//
// 简化的 AXI-Lite Slave 接口
// ============================================================

package AXILiteSlave;

import Vector :: *;
import FIFOF :: *;
import SpecialFIFOs :: *;
import RMTInterfaces :: *;
`include "RMTConfig.bh"

// ============================================================
//                       AXI-Lite 类型
// ============================================================

typedef struct {
    Bit#(32) addr;
    Bit#(64) data;
    Bit#(8)  strb;
} AXILiteWrite deriving (Bits, Eq);

typedef struct {
    Bit#(32) addr;
} AXILiteRead deriving (Bits, Eq);

// ============================================================
//                       接口定义
// ============================================================

interface AXILiteSlaveIfc;
    // AXI-Lite 写通道
    method Action write_addr(AXILiteWrite aw);
    method Action write_data(AXILiteWrite w);
    method ActionValue#(Bit#(2)) write_resp;

    // AXI-Lite 读通道
    method Action read_addr(AXILiteRead ar);
    method ActionValue#(Tuple2#(Bit#(64), Bit#(2))) read_data;

    // 内部接口
    method ActionValue#(CPCmd) get_command;
    method Action put_response(Bit#(64) data);
endinterface

// ============================================================
//                       实现
// ============================================================

module mkAXILiteSlave(AXILiteSlaveIfc);
    // 命令 FIFO
    FIFOF#(CPCmd) cmd_fifo <- mkFIFOF;
    FIFOF#(Bit#(64)) resp_fifo <- mkFIFOF;

    // 写地址缓冲
    Reg#(Bit#(32)) write_addr_r <- mkRegU;

    // 读地址缓冲
    Reg#(Bit#(32)) read_addr_r <- mkRegU;

    // --------------------------------------------------------
    // 接口方法
    // --------------------------------------------------------

    method Action write_addr(AXILiteWrite aw);
        write_addr_r <= aw.addr;
    endmethod

    method Action write_data(AXILiteWrite w);
        // 解析命令类型
        // ★ 地址译码补全：原实现只译码 4'h1/2/3，TABLE_DELETE、
        //   TCP_SESSION_CREATE/DELETE、PHV_TEMPLATE_SET 经 AXI 永远不可达
        CPCmd cmd;
        if (write_addr_r[15:12] == 4'h1) begin
            cmd.cmd = CP_CMD_PARSER_CONFIG;
        end
        else if (write_addr_r[15:12] == 4'h2) begin
            cmd.cmd = CP_CMD_TABLE_INSERT;
        end
        else if (write_addr_r[15:12] == 4'h3) begin
            cmd.cmd = CP_CMD_ACTION_LOAD;
        end
        else if (write_addr_r[15:12] == 4'h4) begin
            cmd.cmd = CP_CMD_TABLE_DELETE;
        end
        else if (write_addr_r[15:12] == 4'h5) begin
            cmd.cmd = CP_CMD_TCP_SESSION_CREATE;
        end
        else if (write_addr_r[15:12] == 4'h6) begin
            cmd.cmd = CP_CMD_TCP_SESSION_DELETE;
        end
        else if (write_addr_r[15:12] == 4'h7) begin
            cmd.cmd = CP_CMD_PHV_TEMPLATE_SET;
        end
        else begin
            cmd.cmd = CP_CMD_STATUS_READ;
        end

        cmd.addr = write_addr_r;
        cmd.data = w.data;

        cmd_fifo.enq(cmd);
    endmethod

    method ActionValue#(Bit#(2)) write_resp;
        return 2'b00;  // OKAY
    endmethod

    method Action read_addr(AXILiteRead ar);
        read_addr_r <= ar.addr;
    endmethod

    // ★ 无响应数据时可阻塞（原实现无守卫，若接真实 AXI 读通道会死锁）
    method ActionValue#(Tuple2#(Bit#(64), Bit#(2))) read_data if (resp_fifo.notEmpty);
        let data = resp_fifo.first;
        resp_fifo.deq;
        return tuple2(data, 2'b00);  // OKAY
    endmethod

    method ActionValue#(CPCmd) get_command;
        let cmd = cmd_fifo.first;
        cmd_fifo.deq;
        return cmd;
    endmethod

    method Action put_response(Bit#(64) data);
        resp_fifo.enq(data);
    endmethod

endmodule

endpackage
