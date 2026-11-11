// ============================================================
// RMTInterfaces.bsv - RMT BSV 硬件流水线所有类型定义和接口
//
// Reconfigurable Match Tables (RMT) Hardware Pipeline
//
// 本包定义了流水线中所有模块间通信的数据类型和接口协议
// ============================================================

package RMTInterfaces;

import Vector :: *;
import GetPut :: *;
import FIFO :: *;
import FIFOF :: *;
import SpecialFIFOs :: *;
import DefaultValue :: *;
`include "RMTConfig.bh"

// ============================================================
//                        基础类型别名
// ============================================================

typedef `PHV_FIELD_WIDTH    FieldWidth;       // 128
typedef `PHV_MAX_FIELDS     MaxFields;        // 160
typedef `PHV_MAX_HDRS       MaxHdrs;          // 64
typedef `PHV_FIELD_IDX_BITS FieldIdxBits;     // 8
typedef `ETH_DATA_WIDTH     EthDataWidth;     // 256
typedef `ETH_DATA_BYTES     EthDataBytes;     // 32

// ============================================================
//                        字段值 (FieldValue)
//            128-bit 右对齐，与软件 fv_t 完全对应
// ============================================================

typedef struct {
    Bit#(FieldWidth)  value;     // 128-bit 字段值，右对齐（大端）
    Bit#(8)           bitlen;    // 实际字段位宽（0-128）
} FieldValue deriving (Bits, Eq, FShow);

// 从 FieldValue 提取低 64 位（常用）
function Bit#(64) fv_to_u64(FieldValue fv);
    return fv.value[63:0];
endfunction

// 从 64 位值构造 FieldValue
function FieldValue u64_to_fv(Bit#(64) v, Bit#(8) bl);
    FieldValue fv;
    fv.value  = {64'h0, v};
    fv.bitlen = bl;
    return fv;
endfunction

// FieldValue 按位掩码截断
function FieldValue fv_mask(FieldValue fv);
    FieldValue res = fv;
    if (fv.bitlen < 128) begin
        Bit#(128) mask = (1 << fv.bitlen) - 1;
        res.value = fv.value & mask;
    end
    return res;
endfunction

// ============================================================
//             PHV (Packet Header Vector) - 完整结构
//  流水线各级共享的"寄存器堆"，存储报文的全部头部字段
// ============================================================

typedef struct {
    Vector#(MaxFields, FieldValue) fields;   // 160 字段槽位
    Bit#(MaxHdrs)                  hvalid;   // 头部有效性位图
    Bit#(160)                      dirty;    // 脏位图（160 bits，每字段 1 bit）
    Bool                           structural; // 发生头部增删（需完整逆解析）
    Bool                           has_inject; // 缓存注入内容
    Bool                           dropped;    // ★ 动作丢弃标志（ALU_DROP 置位）
} PHV deriving (Bits);

// 默认 PHV（所有字段清零，头部全无效）
instance DefaultValue#(PHV);
    defaultValue = PHV {
        fields:     replicate(FieldValue { value: 0, bitlen: 0 }),
        hvalid:     0,
        dirty:      0,
        structural: False,
        has_inject: False,
        dropped:    False
    };
endinstance

// ============================================================
//              报文描述符 (PktDesc)
//   与报文在流水线中一起流动的元数据
// ============================================================

typedef struct {
    Bit#(12)   pkt_len;         // 报文长度（字节）
    Bit#(10)   in_port;         // 入端口号
    Bit#(10)   out_port;        // 出端口（由流水线设置）
    Bool       dropped;         // 丢包标志
    Bit#(48)   timestamp;       // 入端口时间戳（ns 截断）
    Bit#(12)   hdr_bytes;       // 解析器输出：头部长度
    Bit#(12)   payload_offset;  // 有效载荷在缓冲中的起始位置
    Bool       is_tcp;          // ★ TCP 标记（用于重组路径）★
} PktDesc deriving (Bits, Eq, FShow);

// 默认报文描述符
instance DefaultValue#(PktDesc);
    defaultValue = PktDesc {
        pkt_len:        0,
        in_port:        0,
        out_port:       0,
        dropped:        False,
        timestamp:      0,
        hdr_bytes:      0,
        payload_offset: 0,
        is_tcp:         False
    };
endinstance

// ============================================================
//             解析器配置类型 (Parser Types)
// ============================================================

typedef enum {
    POP_EXTRACT,        // 提取单个头部
    POP_EXTRACT_ARRAY   // 提取头部栈（运行时决定数量）
} ParseOpKind deriving (Bits, Eq, FShow);

typedef struct {
    ParseOpKind    kind;        // 操作类型
    Bit#(6)        hdr_id;      // 要提取的头部 ID
    Bit#(8)        count_field; // EXTRACT_ARRAY：从该 PHV 字段取数量
    Bit#(8)        count_add;   // 加到数量上的偏移
} ParseOp deriving (Bits, Eq, FShow);

typedef struct {
    Bit#(64)       sel_val;     // 分支匹配值
    Bit#(5)        next_state;  // 下一解析器状态
} SelCase deriving (Bits, Eq, FShow);

// 解析状态（解析图的一个节点）
typedef struct {
    Bit#(6)                  name_id;     // 状态名（调试用）
    Vector#(4, ParseOp)      ops;         // 解析操作（最多 4 个并行）
    Bit#(3)                  nops;        // 有效操作数
    Bit#(8)                  sel_field;   // select 字段（-1 = 无条件）
    Vector#(16, SelCase)     cases;       // select 分支
    Bit#(5)                  ncases;      // 有效分支数
    Bit#(5)                  def_next;    // 默认下一状态（PS_ACCEPT = 0x1F）
} ParseState deriving (Bits, Eq, FShow);

// 特殊状态值
typedef 5'h1F PS_ACCEPT;  // 解析接受（终止）

// ============================================================
//             ALU 指令类型 (ALU Types)
//            与软件 alu_insn_t 完全对应
// ============================================================

typedef enum {
    ALU_NOP          = 6'h00,
    ALU_MOVI         = 6'h01,     // 立即数加载
    ALU_MOV          = 6'h02,     // 字段拷贝
    ALU_ADD          = 6'h03,     // 加法
    ALU_SUB          = 6'h04,     // 减法
    ALU_AND          = 6'h05,     // 与
    ALU_OR           = 6'h06,     // 或
    ALU_XOR          = 6'h07,     // 异或
    ALU_SHL          = 6'h08,     // 左移
    ALU_SHR          = 6'h09,     // 右移
    ALU_ADDI         = 6'h0A,     // 加立即数
    ALU_SUBI         = 6'h0B,     // 减立即数
    ALU_ANDI         = 6'h0C,     // 与立即数
    ALU_ORI          = 6'h0D,     // 或立即数
    ALU_XORI         = 6'h0E,     // 异或立即数
    ALU_SHLI         = 6'h0F,     // 左移立即数
    ALU_SHRI         = 6'h10,     // 右移立即数
    ALU_MOVX         = 6'h11,     // 索引寄存器访问（SRv6 seg[SL]）
    ALU_VALID        = 6'h12,     // 置头部有效
    ALU_INVALID      = 6'h13,     // 清头部有效
    // 有状态 extern 操作（初始版本可选，留作扩展）
    ALU_CS_LOOKUP    = 6'h14,     // Cache lookup
    ALU_CS_INSERT    = 6'h15,     // Cache insert
    ALU_PIT_INSERT   = 6'h16,     // PIT insert (NDN)
    ALU_PIT_CONSUME  = 6'h17,     // PIT consume (NDN)
    ALU_UTIL_MARK    = 6'h18,     // Utilization mark (Telescope)
    ALU_UTIL_PROBE   = 6'h19,     // Utilization probe (Telescope)
    ALU_SKETCH_INC   = 6'h1A,     // Sketch increment
    ALU_SKETCH_GET   = 6'h1B,     // Sketch query
    ALU_DNN_INFER    = 6'h1C,     // DNN 推理（MLP，见 ActionEngine.dnn_infer）
    ALU_DROP         = 6'h1D      // 条件丢弃：字段 fs1 值非零 → 置 PHV.dropped
} ALUOpcode deriving (Bits, Eq, FShow);

// 单条 ALU 指令
typedef struct {
    ALUOpcode      op;           // 操作码
    Bit#(8)        fd;           // 目的字段索引
    Bit#(8)        fs1;          // 源字段 1
    Bit#(8)        fs2;          // 源字段 2
    Bit#(8)        fbase;        // 基址字段（MOVX 用）
    Bit#(8)        stride;       // 步长（MOVX 用）
    Bit#(64)       imm;          // 立即数 / 动作参数
    Bool           use_param;    // 从动作数据取立即数（而不是字面量）
    Bit#(4)        pidx;         // 参数索引（use_param 时有效）
} ALUInsn deriving (Bits, Eq, FShow);

// VLIW word：ALU_NUM_PER_STAGE 条并行执行的 ALU 指令（参数化，当前 8）
typedef Vector#(`ALU_NUM_PER_STAGE, ALUInsn) VLIWWord;

// 动作程序：最多 8 个 VLIW word 的微码
typedef struct {
    Bit#(5)                       action_id;   // 动作 ID
    Bit#(4)                       nparams;     // 参数个数
    Vector#(8, VLIWWord)          prog;        // 微码（8 个 VLIW word）
    Vector#(8, Bit#(5))           nslots;      // 每 word 的有效槽位数
    Bit#(4)                       nwords;      // 有效 word 数
} ActionProgram deriving (Bits, Eq);

// ============================================================
//               Write-Back 条目（两相提交）
//     匹配软件 wb_t：记录待写回 PHV 的结果
// ============================================================

typedef enum {
    WB_NONE,       // 无写操作
    WB_FIELD,      // 字段值写回
    WB_VALIDITY,   // 头部有效性写回
    WB_DROP        // ★ 置包丢弃标志（ALU_DROP）
} WBKind deriving (Bits, Eq);

typedef struct {
    WBKind        kind;       // 写回类型
    Bit#(8)       fd;         // 目的字段 ID（WB_FIELD）或头部 ID（WB_VALIDITY）
    FieldValue    val;        // 新字段值
    Bool          valid;      // 对于 WB_VALIDITY：新有效性
} WriteBackEntry deriving (Bits, Eq);

function WriteBackEntry defaultWB();
    WriteBackEntry wb;
    wb.kind = WB_NONE;
    wb.fd = 0;
    wb.val = FieldValue { value: 0, bitlen: 0 };
    wb.valid = False;
    return wb;
endfunction

// ============================================================
//               Match 表类型 (Match Table Types)
// ============================================================

typedef enum {
    MATCH_EXACT,    // 精确匹配（所有位都关心）
    MATCH_LPM       // 最长前缀匹配
} MatchType deriving (Bits, Eq, FShow);

// 表的 key 字段定义
typedef struct {
    Bit#(8)        field_id;      // key 的 PHV 字段索引
    MatchType      match_type;    // Exact 或 LPM
} KeyField deriving (Bits, Eq, FShow);

// 表配置
typedef struct {
    Bit#(4)                          table_id;      // 表 ID
    Vector#(8, KeyField)             keys;          // key 字段列表（最多 8 个）
    Bit#(4)                          nkeys;         // 有效 key 数
    Vector#(5, Bit#(5))              action_ids;    // 允许的动作索引
    Bit#(4)                          nactions;      // 动作数
    Bit#(5)                          default_action;// 未命中时的默认动作
    Vector#(8, Bit#(64))             def_params;    // 默认动作参数
    Bit#(3)                          stage;         // 物理级分配
    Bit#(6)                          pred_hdr;      // 门控：头部有效时才应用（-1 = 始终）
} TableConfig deriving (Bits, Eq, FShow);

// TCAM 条目（硬件匹配用）
typedef struct {
    Bit#(128)      key;           // key 值
    Bit#(128)      mask;          // 掩码（1=关心，0=不关心）
    Bit#(5)        action_id;     // 命中时执行的动作
    Bit#(8)        params;        // 动作参数 SRAM 索引
} TCAMEntry deriving (Bits, Eq, FShow);

// Match 结果（Match 引擎输出）
typedef struct {
    Bool             hit;            // 是否命中
    Bit#(5)          action_id;      // 要执行的动作
    Bit#(8)          param_base;     // 参数 SRAM 基址
    Bit#(4)          nparams;        // 参数个数
    Bit#(4)          table_id;       // 哪个表命中
    Vector#(8, Bit#(64)) params;     // ★ 动作参数（命中=表项参数；未命中=默认动作参数）
} MatchResult deriving (Bits, Eq);

function MatchResult defaultMR();
    MatchResult mr;
    mr.hit = False;
    mr.action_id = 0;
    mr.param_base = 0;
    mr.nparams = 0;
    mr.table_id = 0;
    mr.params = replicate(0);
    return mr;
endfunction

// ============================================================
//           TCP 会话跟踪类型 ★ 新增核心 ★
// ============================================================

// TCP 会话状态
typedef enum {
    TCP_SESS_IDLE,          // 空闲（无此会话）
    TCP_SESS_SYN,           // 收到 SYN，等待 SYN-ACK
    TCP_SESS_ESTABLISHED,   // 连接已建立
    TCP_SESS_FIN            // 收到 FIN，正在关闭
} TCPSessState deriving (Bits, Eq, FShow);

// TCP 5 元组（会话 key）
typedef struct {
    Bit#(32)   src_ip;        // 源 IP
    Bit#(32)   dst_ip;        // 目的 IP
    Bit#(16)   src_port;      // 源端口
    Bit#(16)   dst_port;      // 目的端口
} TCP5Tuple deriving (Bits, Eq, FShow);

// TCP 会话条目
typedef struct {
    TCP5Tuple       key;           // 5 元组 key
    TCPSessState    state;         // 会话状态
    Bit#(32)        expected_seq;  // 期望的下一序列号
    Bit#(32)        ack_seq;       // 确认号
    Bit#(16)        window;        // 窗口大小
    Bit#(8)         buf_count;     // 重排缓冲中报文数
    Bool            active;        // 会话是否活跃
    Bit#(16)        age_counter;   // 老化计数器（超时用）
} TCPSessionEntry deriving (Bits, Eq, FShow);

instance DefaultValue#(TCPSessionEntry);
    defaultValue = TCPSessionEntry {
        key:           TCP5Tuple { src_ip: 0, dst_ip: 0, src_port: 0, dst_port: 0 },
        state:         TCP_SESS_IDLE,
        expected_seq:  0,
        ack_seq:       0,
        window:        0,
        buf_count:     0,
        active:        False,
        age_counter:   0
    };
endinstance

// 重排缓冲条目
typedef struct {
    Bit#(32)   tcp_seq;     // TCP 序列号（避免使用保留字 seq）
    Bit#(12)   pkt_len;       // 报文长度
    Bit#(12)   payload_len;   // 有效载荷长度
    Bit#(16)   buf_idx;       // 报文数据在缓冲中的索引
    Bit#(8)    session_id;    // 所属会话 ID
    Bool       valid;         // 条目是否有效
    Bit#(16)   age;           // 等待时间（周期数）
} ReorderSlot deriving (Bits, Eq, FShow);

function ReorderSlot defaultRS();
    ReorderSlot rs;
    rs.tcp_seq = 0;
    rs.pkt_len = 0;
    rs.payload_len = 0;
    rs.buf_idx = 0;
    rs.session_id = 0;
    rs.valid = False;
    rs.age = 0;
    return rs;
endfunction

// ============================================================
//             控制面类型 (Control Plane Types)
// ============================================================

typedef enum {
    CP_CMD_TABLE_INSERT,       // 插入表项
    CP_CMD_TABLE_DELETE,       // 删除表项
    CP_CMD_PARSER_CONFIG,      // 配置解析器状态
    CP_CMD_ACTION_LOAD,        // 加载动作微码
    CP_CMD_PHV_TEMPLATE_SET,   // 设置 PHV 模板
    CP_CMD_PIPE_CONFIG,        // 配置流水线参数
    CP_CMD_STATUS_READ,        // 读状态寄存器
    CP_CMD_TCP_SESSION_CREATE, // ★ 创建 TCP 会话 ★
    CP_CMD_TCP_SESSION_DELETE  // ★ 删除 TCP 会话 ★
} CPCmdKind deriving (Bits, Eq, FShow);

typedef struct {
    CPCmdKind      cmd;         // 命令类型
    Bit#(32)       addr;        // 地址/索引
    Bit#(64)       data;        // 数据
} CPCmd deriving (Bits, Eq, FShow);

// ============================================================
//          以太网 AXI-Stream 类型 (256-bit 数据总线)
// ============================================================

typedef struct {
    Bit#(EthDataWidth)  data;     // 256-bit 数据
    Bit#(EthDataBytes)  keep;     // 字节使能（32 bits）
    Bool                last;     // 报文结束（EOF）
    Bool                valid;    // 数据有效
    Bool                first;    // 报文开始（SOF）
} EthStream deriving (Bits, Eq);

// ============================================================
//                流水线级寄存器
//    流水线级间传递的状态（PHV 快照 + 报文描述符）
// ============================================================

typedef struct {
    PHV         phv;           // 完整 PHV 快照
    PktDesc     desc;          // 报文描述符
    Bool        valid;         // 有效标志（False = 流水线气泡）
} StageReg deriving (Bits);

instance DefaultValue#(StageReg);
    defaultValue = StageReg {
        phv:   defaultValue,
        desc:  defaultValue,
        valid: False
    };
endinstance

// ============================================================
//                 接口定义 (Interface Definitions)
// ============================================================

// ------------------- PHV 寄存器堆接口 -------------------
interface PHVRegFileIfc;
    // 读端口（4 个，每周期最多读 4 个字段）
    method Action read_req_0(Bit#(8) fid);
    method ActionValue#(FieldValue) read_resp_0;
    method Action read_req_1(Bit#(8) fid);
    method ActionValue#(FieldValue) read_resp_1;
    method Action read_req_2(Bit#(8) fid);
    method ActionValue#(FieldValue) read_resp_2;
    method Action read_req_3(Bit#(8) fid);
    method ActionValue#(FieldValue) read_resp_3;

    // 写端口（4 个，每周期最多写 4 个字段）
    method Action write_0(Bit#(8) fid, FieldValue val);
    method Action write_1(Bit#(8) fid, FieldValue val);
    method Action write_2(Bit#(8) fid, FieldValue val);
    method Action write_3(Bit#(8) fid, FieldValue val);

    // 头部有效性位图操作
    method Bit#(64) get_hvalid;
    method Action set_hvalid(Bit#(64) mask);
    method Action set_hdr_valid(Bit#(6) hdr_id);
    method Action clr_hdr_valid(Bit#(6) hdr_id);

    // 批量操作
    method Action reset_from_template;
    method Action load_template(Bit#(8) fid, FieldValue val);

    // 完整 PHV 快照（用于级间传递）
    method PHV snapshot;
    method Action restore(PHV phv);
endinterface

// ------------------- ALU 接口 -------------------
interface ALUIfc;
    method Action load(ALUInsn insn, Bit#(64) param);
    method Action operands(FieldValue s1, FieldValue s2);
    method WriteBackEntry result;
endinterface

// ------------------- Match 引擎接口 -------------------
interface MatchEngineIfc;
    method Action lookup_req(Bit#(4) table_id, PHV phv);
    method ActionValue#(MatchResult) lookup_resp;
    method Action insert_entry(Bit#(4) table_id, TCAMEntry entry);
    method Action delete_entry(Bit#(4) table_id, Bit#(10) addr);
    method Action config_table(Bit#(4) tidx, TableConfig cfg);   // ★ 表配置（原接口缺失，无法设置 keys/门控/默认动作）
    // ★ 命中动作参数装载（原实现命中时 params 恒 0，参数通路实际不可用）
    method Action load_param(Bit#(4) table_id, Bit#(8) sram_idx,
                             Bit#(4) pidx, Bit#(64) val);
    method Bit#(16) entry_count(Bit#(4) table_id);
endinterface

// ------------------- Action 引擎接口 -------------------
interface ActionEngineIfc;
    method Action start(Bit#(5) action_id, Vector#(8, Bit#(64)) params);
    method ActionValue#(Bool) done;
    interface PHVRegFileIfc phv;
    method Action load_action(Bit#(5) idx, ActionProgram prog);
    method Action load_dnn_weight(Bit#(4) idx, Bit#(32) w);   // ★ DNN 权重
endinterface

// ------------------- 流水线级接口 -------------------
interface MatchActionStageIfc;
    method Action start(StageReg sreg);
    method ActionValue#(StageReg) complete;
    method Action config_table(Bit#(4) tidx, TableConfig cfg);
    method Action insert_entry(Bit#(4) tidx, TCAMEntry entry);
    method Action load_action(Bit#(5) aidx, ActionProgram prog);
endinterface

// ------------------- 解析器接口 -------------------
interface ProgrammableParserIfc;
    method Action start(PktDesc desc);
    // 整包数据一次提供（64×256-bit，最多 2048 字节）。
    // 原按拍提供接口在单规则内多次方法调用会触发 G0004，且无法正确存储。
    method Action provide_data(Vector#(64, Bit#(256)) data);
    method ActionValue#(Tuple2#(PktDesc, Bool)) result;
    method Action load_state(Bit#(5) idx, ParseState st);
    method Action set_start_state(Bit#(5) state);
    method PHV get_phv;
endinterface

// ------------------- 逆解析器接口 -------------------
interface DeparserIfc;
    method Action start(PktDesc desc, PHV phv);
    method ActionValue#(EthStream) get_output;
    method Bool busy;
    method Action set_original_data(Vector#(64, Bit#(256)) orig);
    method Action set_dirty_bitmap(Bit#(160) dirty);
endinterface

// ------------------- 报文缓冲接口 -------------------
interface PacketBufferIfc;
    // AXI-Stream 接口
    method Action rx_data(EthStream s);
    method ActionValue#(EthStream) tx_data;
    // 内部接口
    method ActionValue#(Tuple2#(PktDesc, Vector#(64, Bit#(256)))) ingress_pkt;
    method Action egress_pkt(Tuple2#(PktDesc, Vector#(64, Bit#(256))) pkt);
    // 状态
    method Bit#(16) rx_occupancy;
    method Bit#(16) tx_occupancy;
    method Bool rx_ready;
    method Bool tx_ready;
endinterface

// ------------------- TCP 重组引擎接口 ★ 核心 ★ -------------------
interface TCPReorderEngineIfc;
    // 数据面输入（来自 Match-Action 流水线）
    method Action insert_pkt(PktDesc desc, PHV phv,
                             Vector#(64, Bit#(256)) pkt_data);
    // 重组后输出（到 Deparser / Egress）
    method ActionValue#(Tuple3#(PktDesc, PHV, Vector#(64, Bit#(256))))
        get_reassembled;
    // 会话表配置（控制面）
    // ★ init_seq：预建会话的初始 expected_seq（SYN 序号 + 1；未知时传 0）
    method Action create_session(TCP5Tuple key, Bit#(32) init_seq);
    method Action delete_session(TCP5Tuple key);
    // 状态查询
    method Bit#(16) active_sessions;
    method Bit#(32) reorder_latency;
    method Bool insert_ready;
    method Bool output_available;
endinterface

// ------------------- 控制面接口 -------------------
interface ControlPlaneIfc;
    // 内部配置接口
    interface Get#(CPCmd) parser_config;
    interface Get#(Tuple2#(Bit#(4), TCAMEntry)) table_insert;
    interface Get#(Tuple2#(Bit#(4), Bit#(10))) table_delete;
    // ★ action_load 携带物理级（0-3）与动作号，原实现只有动作号，无法确定装载到哪一级
    interface Get#(Tuple3#(Bit#(2), Bit#(5), ActionProgram)) action_load;
    interface Get#(Tuple2#(Bit#(8), FieldValue)) phv_template_set;
    interface Get#(Tuple2#(TCP5Tuple, Bit#(32))) tcp_session_create;
    interface Get#(TCP5Tuple) tcp_session_delete;

    // 状态寄存器
    method Bit#(64) get_rx_count;
    method Bit#(64) get_tx_count;
    method Bit#(64) get_drop_count;
    method Bit#(32) get_pipeline_latency;
    method Bit#(16) get_tcp_active_sessions;

    // AXI-Lite 接口（简化版，具体协议在 AXILiteSlave 中处理）
    method Action axi_write(Bit#(32) addr, Bit#(64) data);
    method ActionValue#(Bit#(64)) axi_read(Bit#(32) addr);
endinterface

// ============================================================
//                  辅助函数
// ============================================================

// 构建 TCP 5 元组（从 PHV 提取）
function TCP5Tuple build_tcp_5tuple(PHV phv);
    // 假设 PHV 字段布局：
    //   ipv4.src = field 10, ipv4.dst = field 11
    //   tcp.sport = field 20, tcp.dport = field 21
    TCP5Tuple t;
    t.src_ip   = phv.fields[10].value[31:0];
    t.dst_ip   = phv.fields[11].value[31:0];
    t.src_port = phv.fields[20].value[15:0];
    t.dst_port = phv.fields[21].value[15:0];
    return t;
endfunction

// 从 PHV 提取 TCP 序列号
function Bit#(32) extract_tcp_seq(PHV phv);
    // 假设 tcp.seq = field 22
    return phv.fields[22].value[31:0];
endfunction

// 从 PHV 提取 TCP 标志位
function Bit#(8) extract_tcp_flags(PHV phv);
    // 假设 tcp.flags = field 24
    return phv.fields[24].value[7:0];
endfunction

// 检查是否 SYN 报文
function Bool is_tcp_syn(PHV phv);
    Bit#(8) flags = extract_tcp_flags(phv);
    return (flags & 8'h02) != 0;  // SYN bit
endfunction

// 检查是否 FIN 报文
function Bool is_tcp_fin(PHV phv);
    Bit#(8) flags = extract_tcp_flags(phv);
    return (flags & 8'h01) != 0;  // FIN bit
endfunction

// 检查是否 RST 报文
function Bool is_tcp_rst(PHV phv);
    Bit#(8) flags = extract_tcp_flags(phv);
    return (flags & 8'h04) != 0;  // RST bit
endfunction

endpackage
