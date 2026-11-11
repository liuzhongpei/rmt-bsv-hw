// ============================================================
// SessionFSM.bsv - TCP 会话状态机
//
// 管理 SYN/ESTABLISHED/FIN 状态转换
//
// ★ 修复内容（相对原实现）：
//   原 transition 永远从 defaultValue(IDLE) 开始，从不读取真实会话，
//   状态机无法转换。现在：
//     - 新增 set_current 方法，由 TCPReorderEngine 先注入当前会话；
//     - transition 基于当前会话 + PHV 标志做真实状态转换；
//     - 实现 SYN→ESTABLISHED（收到带 ACK 的包视为握手完成）。
// ============================================================

package SessionFSM;

import Vector :: *;
import DefaultValue :: *;
import RMTInterfaces :: *;
`include "RMTConfig.bh"

// ============================================================
//                       接口定义
// ============================================================

interface SessionFSMIfc;
    // 注入当前会话（须在 transition 前调用）
    method Action set_current(TCPSessionEntry sess);

    // 状态转换请求
    method Action transition(Bit#(8) session_id, PHV phv);

    // 获取更新后的会话条目
    method ActionValue#(TCPSessionEntry) get_updated;
endinterface

// ============================================================
//             纯函数：TCP 会话状态转换
// ★ 供 TCPReorderEngine 在 process_hit 中直接调用（模块接口的
//   set_current/transition/get_updated 三拍握手会因守卫时序死锁，
//   纯函数是最简正确方案）
// ============================================================

function TCPSessionEntry fsm_transition(TCPSessionEntry sess, PHV phv);
    Bit#(8) flags = phv.fields[24].value[7:0];  // 假设 tcp.flags 在 field 24
    Bool is_syn = (flags & 8'h02) != 0;
    Bool is_fin = (flags & 8'h01) != 0;
    Bool is_rst = (flags & 8'h04) != 0;
    Bool is_ack = (flags & 8'h10) != 0;

    case (sess.state)
        TCP_SESS_SYN: begin
            if (is_rst) begin
                sess.state = TCP_SESS_IDLE;
                sess.active = False;
            end
            else if (is_ack) begin
                // SYN 后收到带 ACK 的包（SYN-ACK 或纯 ACK）→ 建立连接
                sess.state = TCP_SESS_ESTABLISHED;
            end
        end

        TCP_SESS_ESTABLISHED: begin
            if (is_fin) begin
                sess.state = TCP_SESS_FIN;
            end
            else if (is_rst) begin
                sess.state = TCP_SESS_IDLE;
                sess.active = False;
            end
        end

        TCP_SESS_FIN: begin
            sess.age_counter = sess.age_counter + 1;
            if (sess.age_counter > 1000) begin
                sess.state = TCP_SESS_IDLE;
                sess.active = False;
            end
        end

        default: begin
            // TCP_SESS_IDLE：不处理
        end
    endcase

    return sess;
endfunction

// ============================================================
//                       实现
// ============================================================

module mkSessionFSM(SessionFSMIfc);
    Reg#(TCPSessionEntry) current_r <- mkRegU;
    Reg#(TCPSessionEntry) updated_entry_r <- mkRegU;
    Reg#(Bool) updated_valid_r <- mkReg(False);

    // --------------------------------------------------------
    // 方法：注入当前会话
    // --------------------------------------------------------
    method Action set_current(TCPSessionEntry sess);
        current_r <= sess;
    endmethod

    // --------------------------------------------------------
    // 方法：状态转换（复用纯函数 fsm_transition）
    // --------------------------------------------------------
    method Action transition(Bit#(8) session_id, PHV phv);
        updated_entry_r <= fsm_transition(current_r, phv);
        updated_valid_r <= True;
    endmethod

    method ActionValue#(TCPSessionEntry) get_updated if (updated_valid_r);
        updated_valid_r <= False;
        return updated_entry_r;
    endmethod

endmodule

endpackage
