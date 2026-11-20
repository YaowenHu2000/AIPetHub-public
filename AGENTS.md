# 给在这个仓库里干活的 agent

AIPetHub：一个原生 macOS 窗口，把 Claude Code、Codex、Gemini（agy）、DeepSeek（dsh）四个命令行智能体放在一起用。
原生层是 Swift（`ai-pet-hub/Sources/`），界面是网页（`ai-pet-hub/web/`），它自己不调模型，所有请求都交给本机装好的 CLI。

## 先读什么

按需往下读，不用一上来全读：

1. 这份（规矩和入口）。
2. [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)：工作原理、按主题找代码、目录结构、怎么测。改代码前读。
3. 要动的那个目录里的 README（`tools/sprites/`、`tools/rig/`、`web/vendor/`）和文件开头的注释：每个源码文件开头都说明了它管什么。
4. 用户说明在 [README.md](README.md)（英文，只有这一份），只有改到用户看得见的行为时才需要。

## 怎么跑

都在 `ai-pet-hub/` 下：

```bash
tools/test.sh            # 离线测试，约 45 秒（编译和各步都并行），不需要 CLI 和网络。提交前必须全过
tools/test.sh --only 词   # 只编译并跑名字含这个词的离线测试组（逗号分隔多个）；改代码调试时用这个，不必每次全跑
                         # 只管 tools/tests/offline.swift 组表里的组；预览和归因、DeepSeek、暂停恢复、前端不在里面，单跑的命令见 tools/test.sh 开头
./build.sh               # 打包到 build/AIPetHub.app（不安装），约 10 秒；和 test.sh 写不同的产物，可以同时跑
tools/uitest/all.sh      # 真实窗口测试默认 26 套、最多 10 套同时跑，要先 ./build.sh；会真的调四位的 CLI（都用最便宜的模型）；跑完自动清自己的测试会话
tools/uitest/clean.sh    # 清掉单跑 tools/uitest/run.sh 留下的会话
./build.sh --install     # 装到 /Applications 并重启 App——只在用户要求时做
```

## 规矩

- **不改变现有功能和界面行为。** 修 bug 就只修那个 bug；觉得「可以写得更好」但没有实际问题的地方不要动。
- **最小改动**：不重构、不改名、不搬文件、不加抽象层、不引依赖，除非任务就是做这个。
- **这是本机自用的工具**：效率优先，默认最高权限，不做安全加固，也不要提这类建议。
- **不碰正在用的东西**：不动 `/Applications/AIPetHub.app`，不关、不重启、不暂停正在运行的 AIPetHub 和它的子进程；信号只按 pid 发给自己起的测试实例，不用 `pkill` / `killall`。不改系统设置。
- **不提交、不推送**，除非被明确要求。
- 注释和文档用简体中文，写「为什么」，不写「是什么」。
- 注释和文档里不用「我」：读的人不知道那是谁。写清楚是用户、App、还是哪个 CLI；记下「谁做了什么决定」时写名字和日期。

## 测试

- 修 bug 先写一条会失败的测试，再改，确认它变成通过。
- 时序问题用 `Sources/Runtime/TestHooks.swift` 里的开关卡在确定的位置上测，不靠循环几十轮碰运气。
- 等某件事发生，用各文件现成的等待函数和它的默认上限（离线是 `tools/tests/support.swift` 的 `testWaitLimit`，窗口是 `tools/uitest/assertions.js` 的 `until` 默认的 `WAIT`），调用处不写数字；细节见 ARCHITECTURE「开发」。
- 设施只有一套，不要再造：一个测试程序（`tools/tests/` → `build/selftest`）、一个假 CLI（`tools/fixtures/fake-cli.py`）、一个假 DeepSeek 服务（`tools/fixtures/fake-dsh.py`）、一个窗口测试入口（`tools/uitest/run.sh`）。
  公共辅助在 `tools/tests/support.swift`、`tools/uitest/prelude.js` 和 `assertions.js`，写之前先查；新写的通用辅助放进去，不在测试函数里另起一份。
- 窗口测试的每一条都要由断言判对错；只把看到的值记下来不算测试。依赖模型照做的地方，判据压在 App 自己的行为上。
- 只给测试用的开关放在 `TestHooks.swift`，用到的地方读它的默认值就行，不要在别的文件里再加 `#if HUB_SELFTEST`。

## 保持整洁

- **改了结构就同一轮改文档**：文件改名、入口变了、流程变了，把上面「先读什么」里提到它的地方一起改。过时的文档比没有文档更糟。
- **ARCHITECTURE 只写机制和去哪儿找**：修 bug 时新的行为细节写进实现它的那个文件开头或函数注释，不往 ARCHITECTURE 追加；新文件、新主题才在它的结构图和「按主题找代码」表里补一行。
- **别让文件越长越大**：源码文件超过约 500 行、文档超过约 150 行，先想想是不是该拆了。README 例外：它是对外的门面，要的是好看，不限篇幅。
- **工作过程里的东西不留在仓库里**：调查笔记、计划、报告、复现用的证据放 `$TMPDIR`，用完删掉。有长期价值的结论写进代码注释或上面那几份文档。
- 测试产生的会话跑完清掉，确认没有留下自己起的进程。
