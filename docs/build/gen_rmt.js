const pptxgen = require("pptxgenjs");

const pres = new pptxgen();
pres.layout = "LAYOUT_WIDE";

const NAVY = "1F3864";
const INK = "1E283C";
const MUTE = "6E7682";
const BG = "EEF3FA";
const F = "Microsoft YaHei";

const FIGS = "/home/gf/Project/rmt-processor-0903/rmt-bsv-hw/docs/build";

function textW(s, pt) {
  let w = 0;
  for (const ch of s) w += ch.charCodeAt(0) < 0x2E80 ? 0.155 : 0.345;
  return w * pt / 24;
}
function title(s, zh, en) {
  s.addText(zh, { x: 0.5, y: 0.26, w: 9.5, h: 0.52, margin: 0, fontFace: F, fontSize: 24, bold: true, color: NAVY, align: "left" });
  if (en) s.addText(en, { x: 0.6 + textW(zh, 24), y: 0.36, w: 12.7 - textW(zh, 24), h: 0.4, margin: 0,
    fontFace: F, fontSize: 14, color: MUTE, align: "left" });
}
function topText(s, txt) {
  s.addText(txt, { x: 0.5, y: 0.9, w: 12.34, h: 0.62, margin: 0, fontFace: F,
    fontSize: 12, color: INK, align: "left", valign: "top", lineSpacingMultiple: 1.15 });
}
function fig(s, file, x) {
  s.addImage({ path: `${FIGS}/${file}`, x, y: 1.62, w: 6.05, h: 3.3 });
}
function summaryCard(s, txt) {
  s.addShape(pres.ShapeType.rect, { x: 0.5, y: 5.42, w: 12.34, h: 1.72, fill: { color: BG }, line: { color: BG, width: 0 } });
  s.addShape(pres.ShapeType.roundRect, { x: 0.72, y: 5.62, w: 0.78, h: 0.34, rectRadius: 0.06, fill: { color: NAVY }, line: { color: NAVY, width: 0 } });
  s.addText("小结", { x: 0.72, y: 5.62, w: 0.78, h: 0.34, margin: 0, fontFace: F, fontSize: 12, bold: true, color: "FFFFFF", align: "center", valign: "middle" });
  s.addText(txt, { x: 0.72, y: 6.08, w: 11.9, h: 0.98, margin: 0, fontFace: F, fontSize: 11.5, color: INK,
    align: "left", valign: "top", lineSpacingMultiple: 1.18 });
}

// ================= Slide 1 =================
const s1 = pres.addSlide();
s1.background = { color: "FFFFFF" };
title(s1, "8 口可编程交换机架构：软硬件与 RMT 流水线", "8-Port Programmable Switch & RMT Pipeline");
topText(s1, "RMT-BSV 是 Bluespec SystemVerilog 实现的可重构匹配表（RMT）交换机：8 个端口（MAC + 报文缓冲）共享一条可编程流水线，256-bit 数据总线 @ 156.25 MHz。数据平面为「可编程解析器（FSM 状态表驱动）→ 4 级 Match-Action（TCAM 1024 项 Exact/LPM + 每级 16 路 VLIW ALU，读旧写新）→ TCP 乱序重排（256 会话）→ 逆解析器」，PHV 寄存器堆 160 字段 × 128-bit（4-bank）。软件工具链中 P4 编译器将 P4 程序编译为解析图、表项与 ALU 微码，经 AXI-Lite 控制面下发；C 参考模型 1:1 复现硬件语义，支撑算法验证。");
fig(s1, "fig1_arch.png", 0.5);
fig(s1, "fig2_pipe.png", 6.78);
summaryCard(s1, "特点：① 数据平面完全可编程——解析器状态表、匹配表、动作微码均运行时可配置，已验证 SRv6/VXLAN/NDN/DNN-IDS 等 8 种 P4 数据平面；② 软硬件闭环——P4 编译器生成配置、C 参考模型同语义对照，缩短硬件开发迭代；③ 硬件创新——在经典 RMT 流水线中内嵌 TCP 乱序重排与会话重组引擎（256 会话 × 64 报文重排深度），支持在网计算类应用。");

// ================= Slide 2 =================
const s2 = pres.addSlide();
s2.background = { color: "FFFFFF" };
title(s2, "功能测试环境与测试", "Functional Test Environment & Results");
topText(s2, "功能测试在 Bluesim 仿真平台上进行：测试套件经 RMTTop 的 AXI-Stream 端口注入构造报文并观测输出，逐字节比对期望值。共 5 组协议端到端套件、19 项设计用例（SRv6 3 例、VXLAN 3 例、NDN 4 例、DNN-IDS 3 例、TCP 重组 6 例），另有 32 项模块级用例覆盖解析器、Match/Action 引擎、PHV 与 TCP 重组；本轮对 SRv6、VXLAN、TCP 重组三套件完成实测验证。");
fig(s2, "fig3_env.png", 0.5);
fig(s2, "fig4_tests.png", 6.78);
summaryCard(s2, "实测结果：SRv6（End 行为、ACL 放行/拒绝）、VXLAN（解封装、封装、双向流量）、TCP 重组（按序/乱序/重复、SYN/FIN 会话、超时）三套件端到端全部通过（ALL PASS），报文逐字节比对一致，TCP 会话统计正确。NDN 与 DNN-IDS 套件已随框架实现，按计划留待下一轮验证。测试基础设施（TestFramework：向量加载、统计、断言比对）可复用于全部 8 种 P4 数据平面的回归验证。");

pres.writeFile({ fileName: "/home/gf/Project/rmt-processor-0903/rmt-bsv-hw/docs/RMT_switch.pptx" })
  .then(() => console.log("written"));
