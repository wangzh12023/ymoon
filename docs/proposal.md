# ymoon 项目申报书

- **项目名称**：ymoon —— 与 Yjs 字节级兼容的 MoonBit CRDT 协同编辑库
- **参赛方向**：新生态项目建设 · 工具库（协议库 / 可复用基础组件）
- **GitHub 仓库**：https://github.com/wangzh12023/ymoon
- **项目类型**：移植。参考 yjs@13.6.33、lib0@0.2.119、y-protocols@1.0.7（均为 MIT，作者 Kevin Jahns 等）；本项目 Apache-2.0，NOTICE 中保留原许可证与版权声明。

## 1. 项目价值与生态定位

**痛点。** Yjs 是 Web 协同编辑事实上的标准（npm 周下载约 1000 万，Tiptap、BlockNote、Monaco、CodeMirror 的协同绑定都基于它），它的二进制更新格式实际上就是协同编辑的"网络协议"。现有实现只有 JavaScript 与 Rust（yrs）。我在 mooncakes.io 和 GitHub 代码搜索 `yjs / yrs / lib0 / y-protocols / YATA` 均为 0 结果。MoonBit 里已有的 CRDT（eg-walker、Loro 移植）各用私有格式，**无法和任何 Yjs 编辑器互通**。

**补齐的生态位。** 让 MoonBit 程序成为 Yjs 协同网络里的一等公民：
1. **协同服务端**：MoonBit 写的 y-websocket 房间服务，浏览器里现成的 Tiptap/BlockNote 编辑器直接连上来；
2. **AI Agent 参与协作**：Agent 作为一个 peer 直接编辑人类正在编辑的文档，而不是去解析 HTML；
3. **数据工具**：检查、合并、diff、压缩数据库里存的 Yjs 二进制文档（CLI 已实现）。

**和竞品比的优势。** 不是"又一个 CRDT"，而是**与最大生态的线上格式互通**：同样的编辑操作，ymoon 输出的字节与 yjs 完全相同。这是可以客观验证的承诺。

## 2. 交付范围与工程边界

**交付：**
- Y.Text（含富文本格式、embed、delta）、Y.Map、Y.Array、Y.Xml* 及任意嵌套；事务、GC、pending 乱序更新；
- v1 更新编解码，`merge_updates` / `diff_update` / `encode_state_vector_from_update`（无需加载文档即可操作字节）；
- y-protocols 同步协议与 awareness（光标/在线状态），y-websocket 房间逻辑（与传输层解耦）；
- CLI `ymoon`、Node.js y-websocket 服务示例、浏览器 wire bench 演示页；
- 全部支持 wasm / wasm-gc / js / native 四个后端。

**明确不做：** v2 更新编码、UndoManager、Snapshot / RelativePosition、带 delta 的事件对象、子文档加载。这些在 README 的 Scope 一节写明，不做半成品。

## 3. 实现路径与技术理解

**路径选择。** 常见做法有两种：自己设计一个 CRDT，或者 FFI 绑定 yrs。前者无法互通，后者丢掉 wasm/js 多后端且不是 MoonBit 实现。我选择**逐行移植 yjs 的 JS 源码**：Yjs 的字节输出不只取决于 YATA 冲突算法，还取决于大量"实现细节"，例如 search marker 缓存决定了在哪里切分 item、format 属性比较用的是 JS 对象引用相等、`JSON.stringify` 的数字格式、`Doc.get` 升级占位类型时会重置格式标记。这些都必须原样复现，否则字节就对不上。

**质量怎么证明（核心）：**
1. **差分测试**：用 npm 上的 yjs 随机生成多 peer 会话（富文本、emoji、中日文、数组、map、GC 开关、部分同步），记录每一个 update；ymoon 重放后逐字节比较。目前 6000 个会话、约 49 万次字节级比对全部一致，CI 每次用新种子再跑；
2. **形式化验证**：删除集查找、同步偏移、区间合并这些"时钟区间代数"用 `moon prove`（Why3 + Z3）在**有界机器整数模型**下证明（46 个证明目标），证明器真的抓到了 `start + len` 的溢出；
3. **性质测试**：收敛、交换律、幂等、merge/diff 等 CRDT 定律，QuickCheck 在四个后端运行，并真的找到了一个 pending 永久卡住的 bug；
4. **真实客户端**：4 个官方 y-websocket 客户端通过 ymoon 房间服务协同编辑并收敛；
5. **真实负载**：automerge-paper 编辑轨迹（259,778 次按键）三种引擎产出完全相同的 223,414 字节文档。

**需要的能力**：CRDT（YATA）原理、二进制协议、MoonBit 多后端与 `moon prove`、Node.js 测试工具链。
