# -*- coding: utf-8 -*-
"""RMT 8-port switch panels in ReSUN style (figlib)."""
import sys
sys.path.insert(0, "/home/gf/Downloads/ReSUN")
from figlib import *  # noqa

OUT = "/home/gf/Project/rmt-processor-0903/rmt-bsv-hw/docs/build"
import os
os.makedirs(OUT, exist_ok=True)
W, H = 6.05, 3.3

# ================= panel a: 8口交换机软硬件总体架构 =================
c = Canvas(W, H)
c.panel_title("a", "8 口可编程交换机总体架构", "Hardware / Software Co-Design")

# ---- 软件大框 ----
c.box(0.12, 0.55, 1.58, 2.4, fill=BLUE_PALE, outline=NAVY, lw=1.6, radius=0.07)
c.text(0.24, 0.69, "软件工具链", size=10, bold=True, color=NAVY, anchor="lm")
c.note(1.62, 0.69, "rmt-pipeline", size=7.5, anchor="rm")
c.module(0.24, 0.92, 1.34, 0.95, "P4 编译器", fill=NAVY_FILL, tsize=9.5, label_pos="tl", lw=1.5)
for i, t in enumerate(["前端解析", "后端映射", "配置生成"]):
    c.chip(0.32, 1.18 + i * 0.22, 1.18, 0.18, t, size=7.5, lw=1.0)
c.module(0.24, 2.02, 1.34, 0.78, "C 参考模型", fill=TEAL_FILL, tsize=9.5, label_pos="tl", lw=1.5)
for i, t in enumerate(["1:1 硬件语义", "多队列引擎"]):
    c.chip(0.32, 2.28 + i * 0.22, 1.18, 0.18, t, size=7.5, lw=1.0)

# ---- 硬件大框 ----
c.box(1.98, 0.55, 3.95, 2.4, fill=WHITE, outline=NAVY, lw=1.8, dash=True, radius=0.07)
c.text(2.0, 0.69, "8 口可编程交换机（RMT-BSV）", size=10, bold=True, color=NAVY, anchor="lm")
c.note(5.83, 0.69, "256-bit @ 156.25 MHz", size=7.5, anchor="rm")

# 端口阵列中框（8 小框）
c.module(2.12, 0.92, 3.68, 0.72, "端口阵列 ×8", fill=NAVY_FILL, tsize=9, label_pos="tl", lw=1.5)
for i in range(8):
    px = 2.22 + (i % 4) * 0.88
    py = 1.18 + (i // 4) * 0.2
    c.chip(px, py, 0.78, 0.17, f"P{i} MAC+Buf", size=6.8, lw=1.0)

# RMT 流水线中框
c.module(2.12, 1.88, 3.68, 0.5, "RMT 可编程流水线", fill=GOLD_FILL, tsize=9, label_pos="tl", lw=1.5)
pipe = ["解析器", "Match-Action ×4", "TCP 重组", "逆解析器"]
for i, t in enumerate(pipe):
    x = 2.2 + i * 0.9
    c.chip(x, 2.14, 0.82, 0.18, t, size=7, lw=1.0)
    if i < len(pipe) - 1:
        c.arrow(x + 0.82, 2.23, x + 0.9, 2.23, lw=1.2, head=0.05)

# 控制面中框
c.module(2.12, 2.56, 2.1, 0.32, "控制面 ControlPlane", fill=TEAL_FILL, tsize=8.5, label_pos="tl", lw=1.3)
c.chip(4.38, 2.6, 1.45, 0.24, "AXI-Lite · 表项管理", size=7.5, lw=1.0)

# 数据流：端口 -> 流水线 -> 端口（左右两条青绿折线）
c.arrow(2.7, 1.66, 2.7, 1.88, lw=1.8, head=0.07)
c.note(2.78, 1.77, "收包", size=7.5, color=TEAL, anchor="lm")
c.arrow(5.25, 1.88, 5.25, 1.66, lw=1.8, head=0.07)
c.note(5.33, 1.77, "发送", size=7.5, color=TEAL, anchor="lm")

# 配置流：P4编译器 -> 控制面（金色虚线，走两框间隙，标签竖排）
c.dashed_line(1.58, 1.2, 1.84, 1.2, color=GOLD, lw=1.6)
c.dashed_line(1.84, 1.2, 1.84, 2.72, color=GOLD, lw=1.6)
c.arrow(1.84, 2.72, 2.12, 2.72, color=GOLD, lw=1.6, dashed=True, head=0.07)
c.text(1.84, 1.95, "配\n置\n下\n发", size=6.2, color=GOLD, anchor="mm")

c.legend(3.12, [("tealbox", "控制 / 参考模型"), ("box", "数据面模块"),
                ("arrow", "数据流"), ("dash", "配置流")])
c.save(f"{OUT}/fig1_arch.png")

# ================= panel b: RMT 可编程流水线微架构 =================
c = Canvas(W, H)
c.panel_title("b", "RMT 可编程流水线微架构", "Pipeline Microarchitecture")

c.box(0.15, 0.52, 5.75, 2.42, fill=BLUE_PALE, outline=NAVY, lw=1.6, radius=0.07)
c.text(0.27, 0.66, "数据通路（流水线拓扑）", size=10, bold=True, color=NAVY, anchor="lm")

# 一级流水：五个中框
c.module(0.3, 0.92, 0.85, 1.5, "报文缓冲", fill=NAVY_FILL, tsize=9, label_pos="tl", lw=1.5)
c.chip(0.37, 1.28, 0.71, 0.24, "512×256b", size=7, lw=1.0)
c.chip(0.37, 1.58, 0.71, 0.24, "信用流控", size=7, lw=1.0)

c.module(1.3, 0.92, 1.05, 1.5, "可编程解析器", fill=NAVY_FILL, tsize=9, label_pos="tl", lw=1.5)
for i, t in enumerate(["FSM 状态表", "动态提取", "PHV 写入"]):
    c.chip(1.37, 1.26 + i * 0.32, 0.91, 0.26, t, size=7.2, lw=1.0)

c.module(2.5, 0.92, 1.9, 1.5, "Match-Action ×4 级", fill=GOLD_FILL, tsize=9, label_pos="tl", lw=1.5)
for k in range(2):
    sx = 2.6 + k * 0.92
    c.box(sx, 1.24, 0.82, 0.62, fill=WHITE, outline=NAVY, lw=1.1, radius=0.05)
    c.text(sx + 0.41, 1.36, f"Stage {k}" if k == 0 else "Stage 3", size=7.5, bold=True, anchor="mm")
    c.text(sx + 0.41, 1.52, "TCAM 匹配", size=6.8, color=INK, anchor="mm")
    c.text(sx + 0.41, 1.68, "16×VLIW ALU", size=6.8, color=INK, anchor="mm")
    if k == 0:
        c.arrow(sx + 0.82, 1.55, sx + 0.92, 1.55, lw=1.3, head=0.05)
    else:
        c.text(sx + 0.41, 1.98, "… 级联 …", size=6.8, color=GRAY, anchor="mm")
c.chip(2.6, 2.12, 1.7, 0.2, "Exact / LPM · 读旧写新语义", size=7, lw=1.0)

c.module(4.45, 0.92, 0.62, 1.5, "TCP 重组", fill=TEAL_FILL, tsize=8, label_pos="tl", lw=1.5)
c.chip(4.5, 1.28, 0.52, 0.24, "256 会话", size=6.2, lw=1.0)
c.chip(4.5, 1.58, 0.52, 0.24, "重排×64", size=6.2, lw=1.0)

c.module(5.12, 0.92, 0.63, 1.5, "逆解析器", fill=NAVY_FILL, tsize=8, label_pos="tl", lw=1.5)
c.chip(5.17, 1.4, 0.53, 0.24, "重组", size=6.5, lw=1.0)

# 贯穿箭头
for x1, x2 in [(1.15, 1.3), (2.35, 2.5), (4.4, 4.45), (5.07, 5.12)]:
    c.arrow(x1, 1.67, x2, 1.67, lw=1.8, head=0.07)

# PHV 寄存器堆（底部，读写总线）
c.module(1.3, 2.56, 3.87, 0.32, "PHV 寄存器堆  160 字段 × 128-bit（4-bank）", fill=TEAL_FILL,
         tsize=8.5, label_pos="tl", lw=1.3)
c.arrow(1.8, 2.42, 1.8, 2.56, color=GRAY, lw=1.2, dashed=True, both=True, head=0.05)
c.arrow(3.45, 2.42, 3.45, 2.56, color=GRAY, lw=1.2, dashed=True, both=True, head=0.05)
c.note(5.25, 2.72, "字段总线", size=7, color=GRAY, anchor="rm")

c.legend(3.12, [("box", "处理模块"), ("tealbox", "存储 / 状态"),
                ("arrow", "数据流"), ("dash", "PHV 读写")])
c.save(f"{OUT}/fig2_pipe.png")

# ================= panel c: 功能测试环境 =================
c = Canvas(W, H)
c.panel_title("c", "功能测试环境", "Functional Test Environment")

c.box(0.15, 0.52, 5.75, 2.42, fill=BLUE_PALE, outline=NAVY, lw=1.6, radius=0.07)
c.text(0.27, 0.66, "Bluesim 仿真平台", size=10, bold=True, color=NAVY, anchor="lm")

# 测试套件中框
c.module(0.3, 0.92, 1.75, 1.5, "测试套件（5 组）", fill=NAVY_FILL, tsize=9, label_pos="tl", lw=1.5)
suites = [("SRv6", "3 例"), ("VXLAN", "3 例"), ("NDN", "4 例"),
          ("DNN-IDS", "3 例"), ("TCP 重组", "6 例")]
for i, (t, n) in enumerate(suites):
    xx = 0.38 + (i % 2) * 0.84
    yy = 1.24 + (i // 2) * 0.38
    c.chip(xx, yy, 0.76, 0.3, f"{t} {n}", size=6.8, lw=1.0)
c.module(0.3, 2.52, 1.75, 0.34, "TestFramework 框架", fill=TEAL_FILL, tsize=8, label_pos="tl", lw=1.2)

# DUT 中框
c.box(2.5, 0.88, 2.28, 1.96, fill=WHITE, outline=NAVY, lw=1.6, dash=True, radius=0.07)
c.text(2.62, 1.02, "RMTTop（被测设计 DUT）", size=9, bold=True, color=NAVY, anchor="lm")
dut = [("解析器 FSM", NAVY_FILL), ("Match-Action ×4", GOLD_FILL), ("TCP 重组引擎", TEAL_FILL),
       ("逆解析器", NAVY_FILL), ("控制面 AXI-Lite", TEAL_FILL)]
for i, (t, f) in enumerate(dut):
    c.chip(2.62, 1.18 + i * 0.32, 2.04, 0.26, t, size=7.5, lw=1.0, fill=f, radius=0.05)

# 结果检查
c.module(5.0, 0.92, 0.8, 1.96, "结果检查", fill=CORAL_FILL, tsize=9, label_pos="tl", lw=1.5)
for i, t in enumerate(["字段比对", "计数统计"]):
    c.chip(5.06, 1.3 + i * 0.4, 0.68, 0.3, t, size=7, lw=1.0)
c.chip(5.06, 2.14, 0.68, 0.34, "PASS/FAIL", size=6.8, lw=1.3, fill=WHITE, outline=CORAL,
       color=CORAL, bold=True)

# 箭头
c.arrow(2.05, 1.5, 2.5, 1.5, lw=1.6, head=0.07)
c.note(2.27, 1.32, "激励", size=7, color=TEAL)
c.arrow(2.5, 2.3, 2.05, 2.3, lw=1.6, head=0.07)
c.note(2.27, 2.46, "观测", size=7, color=TEAL)
c.arrow(4.78, 1.9, 5.0, 1.9, color=GRAY, lw=1.3, dashed=True, head=0.06)

c.legend(3.12, [("box", "测试组件"), ("tealbox", "框架 / 控制面"),
                ("arrow", "激励 / 数据"), ("dash", "观测")])
c.save(f"{OUT}/fig3_env.png")

# ================= panel d: 测试用例与结果 =================
c = Canvas(W, H)
c.panel_title("d", "功能测试用例与结果", "Test Cases & Results")

cols = [
    ("SRv6", "3 例", ["End 行为", "ACL 放行", "ACL 拒绝"], NAVY_FILL),
    ("VXLAN", "3 例", ["解封装", "封装", "双向流量"], NAVY_FILL),
    ("NDN", "4 例", ["Interest 转发", "Data 返回", "CS 命中", "Nonce 检测"], TEAL_FILL),
    ("DNN-IDS", "3 例", ["TCP 分类", "SYN flood", "特征提取"], GOLD_FILL),
    ("TCP 重组", "6 例", ["按序", "乱序", "重复", "SYN 会话", "FIN 会话", "超时"], CORAL_FILL),
]
for i, (name, cnt, cases, f) in enumerate(cols):
    x = 0.18 + i * 1.17
    c.module(x, 0.72, 1.05, 2.0, "", fill=f, lw=1.6)
    c.badge(x + 0.525, 0.72, cnt.split(" ")[0], d=0.28, size=10)
    c.text(x + 0.525, 0.98, name, size=9, bold=True, anchor="mm")
    c.text(x + 0.525, 1.12, cnt, size=6.8, color=GRAY, anchor="mm")
    for j, t in enumerate(cases):
        c.chip(x + 0.08, 1.26 + j * 0.235, 0.89, 0.2, t, size=6.8, lw=1.0)

# 结果标签条
c.box(0.18, 2.85, 0.62, 0.26, fill=GOLD, outline=GOLD, lw=0, radius=0.05)
c.text(0.49, 2.98, "结果", size=9, bold=True, color=WHITE, anchor="mm")
c.note(0.92, 2.91, "19 项端到端用例（5 组协议套件），另有 32 项模块级用例覆盖解析 / 匹配 / 动作 / PHV / 重组",
       size=8.5, color=INK, anchor="lm")
c.note(0.92, 3.03, "实测：SRv6 / VXLAN / TCP 重组三套件 ALL PASS；NDN、DNN-IDS 待验证",
       size=8.5, color=CORAL, anchor="lm")

# 手工彩色图例（套件配色，放在标题行右侧空白处）
lg = [(NAVY_FILL, "协议转发"), (TEAL_FILL, "命名数据"), (GOLD_FILL, "智能计算"), (CORAL_FILL, "核心创新")]
lx = 2.95
for f, lab in lg:
    c.box(lx, 0.44, 0.22, 0.13, fill=f, outline=NAVY, lw=1.2, radius=0.02)
    c.text(lx + 0.27, 0.505, lab, size=7.5, color=INK, anchor="lm")
    lx += 0.3 + c.text_w(lab, 7.5) + 0.08
c.save(f"{OUT}/fig4_tests.png")

print("rmt figs done")
