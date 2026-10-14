# ymoon 演示与验证指南

ymoon 是 Yjs 的 MoonBit 实现。Yjs 是 Tiptap、BlockNote、Monaco、CodeMirror 等编辑器做实时协同时使用的 CRDT，npm 周下载约 1000 万次。ymoon 读写 Yjs 的二进制更新格式（v1），**同样的编辑操作，ymoon 输出的字节与 yjs@13.6.33 完全相同**，因此 MoonBit 程序可以作为一个完整的 peer 加入任何 Yjs 协同：做同步服务端、离线客户端、文档检查工具，或者和人一起编辑文档的 AI Agent。代码可编译到 wasm、wasm-gc、JavaScript 和 native 四个后端。

## 体验

### 1. 在线：字节级对比台（无需安装）

打开 <https://wangzh12023.github.io/ymoon/>（本地服务启动后也可访问 `http://localhost:6633/wire-bench`）。

- 左边编辑器运行 ymoon（MoonBit 编译到 JavaScript），右边运行 npm 上未经修改的 `yjs@13.6.33`。
- 每次按键产生一个二进制更新发给对方。页面同时让另一个引擎重放同一操作，并逐字节比较，顶部显示 `N/N updates byte-identical across engines`。
- 点击 Wire 列表中的任意一条，下方解码器给每个字节标注含义（client、clock、origin、父类型、内容、删除集）。
- 取消一侧的 *connected*，两边分别输入，再勾选：两边交换状态向量，只补发缺失的部分，然后收敛。

### 2. 本地：官方编辑器经由 MoonBit 服务端协同

```sh
moon build --target js --release
cd examples/playground && npm install && node build.mjs && cd ../..
cd examples/collab-editor && npm install && node build.mjs
node server.mjs 6633
```

在浏览器中打开两个 `http://localhost:6633/` 窗口：

- 浏览器端是 npm 上的 Quill、yjs、y-websocket、y-quill，没有任何改动；它们连接的服务端是 ymoon。
- 两个窗口同时输入、加粗、做列表，内容实时同步，能看到对方的光标和名字。
- 右侧 **MoonBit 服务端副本** 每 0.8 秒读取一次服务端自己合并出来的文档，并和本窗口比较内容与状态向量；一致时显示“服务端副本与本窗口完全一致”。
- 点“断开连接”后继续输入，另一个窗口也输入，再“重新连接”：双方收敛。
- 再开第三个窗口（后加入者）：它从 MoonBit 服务端拿到完整文档。

### 3. 命令行工具

```sh
moon run cmd/ymoon -- inspect testdata/js-notes-a.ybin
moon run cmd/ymoon -- dump testdata/js-notes-a.ybin testdata/js-notes-b.ybin
moon run cmd/ymoon -- merge testdata/js-notes-a.ybin testdata/js-notes-b.ybin -o merged.ybin
moon run cmd/ymoon -- diff testdata/js-notes-a.ybin testdata/js-notes-b.ybin -o delta.ybin
moon run cmd/ymoon -- sv merged.ybin
```

`testdata/` 中的文件由 JavaScript 版 yjs 写出。`dump` 输出：

```json
{
  "meta": { "owner": "alice" },
  "notes": "Hello big Yjs from JavaScript",
  "todo": ["ship ymoon"]
}
```

### 4. 纯 MoonBit 原生服务端（Linux / macOS）

```sh
moon work init . server
moon -C server run main --target native -- 1234
```

基于 `moonbitlang/async` 的 HTTP 与 WebSocket，不经过 JavaScript。CI 在 Linux 上编译它，并让 4 个官方 y-websocket 客户端连上去协同（`oracle/e2e-native-server.mjs`）。`moonbitlang/async` 在 Windows 上需要 MSVC，MinGW 环境请使用第 2 节的 Node.js 版本，房间逻辑是同一份 MoonBit 代码。

## 验证

| 检查内容 | 命令 | 期望输出 |
|---|---|---|
| 与 yjs 的差分测试：随机生成多 peer 编辑会话（富文本、emoji、中文、数组、map、GC 开关、部分同步），逐字节比较每个更新、状态向量、同步差量和最终状态 | `cd oracle && npm install && node gen-traces.mjs 2000 <任意种子> > out/traces.jsonl && cd ..`，然后 `moon test --target all` | 每个后端 `differential traces: 2000/2000 passed`，`failed: 0` |
| 四个后端的全部测试（参考向量、API、CRDT 性质测试、协议、CLI、README 示例） | `moon test --target all` | wasm / wasm-gc / js / native 均 `failed: 0` |
| 形式化验证（Why3 + Z3，有界机器整数模型，包含溢出检查） | `MOON_PROVE_PRELUDE_OVERRIDE=~/.moon/lib/prelude_proof_machine_int moon prove verified` | `Succeeded: 46 goals proved` |
| 官方 y-websocket 客户端互通（4 个客户端并发编辑、在线状态、后加入者） | `node oracle/e2e-ywebsocket.mjs` | `E2E OK` |
| 真实浏览器端到端（Chrome 中的 Quill 编辑器 + 字节对比台） | `cd examples/collab-editor && node browser-test.mjs` | `BROWSER E2E OK` |
| 真实负载：automerge-paper 编辑轨迹（259,778 次按键） | `node oracle/bench-yjs.mjs`、`node oracle/bench-ymoon-js.mjs`、`moon run bench/cli --target native --release` | 三者 `update_bytes` 都是 `223414` |

CI（GitHub Actions）每次提交都会用新的随机种子重新生成差分会话并运行上面全部检查：<https://github.com/wangzh12023/ymoon/actions>。

## 已知限制

- 未实现：v2 更新编码、UndoManager、Snapshot / RelativePosition、带 delta 的事件对象、子文档加载（见 GitHub issues #1–#4）。
- 性能：automerge-paper 轨迹上 yjs（V8）约 1.0 s，ymoon 编译到 JS 约 1.3 s，native 约 2.0 s。为了字节一致，算法与 yjs 保持一致，后续再做优化。
- 并发插入恰好落在代理对（emoji）中间时，yjs 自身会在不同 peer 上产生 U+FFFD（yjs issue #248）。ymoon 与 yjs 行为一致，回归测试中有记录。
