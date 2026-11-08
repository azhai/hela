# 验证记录

## 环境

- macOS arm64，Apple clang 21，LLVM 22.1.8（`/opt/homebrew/opt/llvm@22`）
- 基线：`dev-2026-11:63aac30`

构建命令（**必须用 Apple clang**）：

```sh
CXX=/usr/bin/clang++ LLVM_CONFIG=/opt/homebrew/opt/llvm@22/bin/llvm-config ./build_odin.sh release
```

> 用 homebrew LLVM 23 的 `clang++` 配 macOS 26.5 SDK 会因 libc++ 头文件报 `size_t` / `FP_ZERO` 未定义（20 个错误），与本项目改动无关。

## M1–M6 结果（含 M2 改版后的复测）

| 检查 | 结果 |
|---|---|
| 编译器构建（release） | ✅ `EXIT=0`，约 30 秒增量 / 2–3 分钟全量 |
| `./odin version` | ✅ `dev-2026-11:63aac30` |
| `tests/hela/run.sh` | ✅ 全绿（M7 后七步，M8 后八步，M9 后九步） |
| 新代码按 CI 风格检查（`-vet -vet-tabs -strict-style -vet-style -warnings-as-errors -disallow-do`） | ✅ `tests/hela/layout`、`tests/hela/abi`、`tests/hela/ring`、`tests/hela/split`、`core/hela/ring`、`core/hela/layout` 全部干净 |
| `tests/hela/layout` 12 条 `#assert` | ✅ `odin check` 通过 |
| `tests/hela/explicit_fail` | ✅ 按预期报错，信息含「requires every byte to be named」 |
| 清单确定性（两次生成 diff） | ✅ 完全一致 |
| 方言头 `#+dialect hela`（扩展名仍为 `.odin`） | ✅ 10 个原 `.hel` 文件迁回 `.odin`；`find -name "*.hel"` 为 0 |
| 无方言头的普通 `.odin` 引用 Hela 库的多态类型 | ✅ `/tmp/plainuse`：`ring.Ring(u64)` 编译并运行，`size_of` 192 |
| `-emit-layout:cbor` | ✅ 合法 CBOR（`a4` map(4)，`types` 为 array） |
| `examples/demo` | ✅ |
| 核心包编译检查（`-no-entry-point`） | ✅ `core/sync`、`core/mem`、`core/nbio`、`core/encoding/json`、`core/odin/parser`、`core/thread`、`core/simd`、`core/fmt`、`base/runtime`、`core/hela/layout` |
| 完整 `tests/core` 套件 | ✅ **913 tests, all successful**（`EXIT=0`）。M6 / M7 / M9 三轮均全绿。首轮约 13 分钟（下载 BMP/JPG/X509/XML 资产），之后约 20 秒 |
| 自举解析库认识 Hela 标签 | ✅ M9 首轮曾失败：`core/hela/ring/spsc.odin(40:29): invalid struct tag '#explicit'`；在 `core/odin/ast` 与 `core/odin/parser` 补上 `explicit`/`split` 后 913 全绿 |

## M7 结果

| 检查 | 结果 |
|---|---|
| `-emit-layout-for:<单文件>` | ✅ 命中该文件的 5 个类型 |
| `-emit-layout-for:<目录>` | ✅ `core/hela/layout` → 3 个类型；`cmd/hela-layout` 默认导出 0 个 |
| `-emit-layout-for` 排除他包 | ✅ 指定 `tests/hela/abi` 时不再导出 `tests/hela/layout` 的 `Ring_Header` |
| `-layout-cache-line:128` | ✅ 清单 `cache_line` = 128；`Ring_Header` 由 2 行变 1 行 |
| intrinsic 与清单一同跟随 | ✅ `-layout-cache-line:128` 下 `tests/hela/layout` 的 `layout_cache_lines_of(Ring_Header) == 2` 断言按预期失败 |
| `-layout-cache-line` 参数校验 | ✅ 非 2 的幂 / 越界被 `bad_flags` 拒绝 |
| 清单 `file` 为相对路径 | ✅ `"file":"tests/hela/layout/main.odin"` |
| 默认输出名仍生效 | ✅ 不给 `-emit-layout-file` 时写 `layout.json` |
| `hela-layout --hashes` | ✅ 14 行 `pkg::name<TAB>hash`（M9 增加 `abi::Cursor`） |
| ABI 门禁：仅改名（字节不变） | ✅ 退出码 1，`abi::Slot` hash `60d7ad…` → `0b1663…` |
| ABI 门禁：字段换序（`Mixed` 的 `tag`↔`value`） | ✅ 第 1 层 `#assert` 先拦：`layout_padding_of(Mixed) == 13`、`layout_tail_padding_of(Mixed) == 6`、`offset_of_by_string(Mixed, "value") == 8` 三条同时失败 |
| `HELA_UPDATE_GOLDEN=1` 刷新基线 | ✅ 覆盖 `tests/hela/abi/golden.hash` 后再次全绿 |

## M8 结果

| 检查 | 结果 |
|---|---|
| `core/hela/ring` 编译（`-no-entry-point`） | ✅ 一次通过 |
| `tests/hela/ring` 13 条布局 `#assert` | ✅ 通过（参数化 struct `Ring($T)` + `#explicit` 组合可用） |
| 单线程 push/pop/FIFO/满空判定 | ✅ |
| 环绕（4 轮 × 4 槽，`& mask` 路径） | ✅ |
| 非 2 的幂容量被拒绝 | ✅ `0 / -1 / 3 / 6 / 100` 全部拒绝 |
| 双线程 100 万条消息、顺序与校验和 | ✅ 无丢失、无乱序 |
| 吞吐（`-o:speed`） | ℹ️ 22 – 47 M msg/s（跨运行波动，仅作参考） |
| 伪共享实测（两计数器，多次运行） | ✅ 同一行 122–150 M inc/s；各自一行 492–565 M inc/s；**3.5–4.1x** |
| TSAN（`-sanitize:thread`） | ✅ 已链接 `libclang_rt.tsan_osx_dynamic.dylib`，无 data race 报告；此模式下伪共享比降到 ~1.5x（插桩串行化所致，不作结论） |
| `-vet`（`tests/hela/ring`） | ✅ 无告警 |

## M9 结果（`struct #split(N)`）

| 检查 | 结果 |
|---|---|
| `#split(64)` 上界：`size_of`/`align_of` | ✅ 192 / 64；字段 offset 0 / 64 / 128 |
| 与手工 `#explicit` + `_: [N]u8` 字节等价 | ✅ 5 条 `#assert` 全等（size、align、三个字段 offset） |
| padding 仍被如实报出 | ✅ `layout_padding_of(Split) == 175`、`layout_tail_padding_of(Split) == 63` |
| 规则是「向上取整上个字段末尾」而非 `i*N` | ✅ `Wide` 的 `end` 在 192（64+100→192），size 256 |
| 多态实例化 | ✅ `Box(u64)` 128、`Box([80]u8)` 192，`stamp` 在 128 |
| 运行时 | ✅ `[3]Split` stride 192/384，字段全部 round-trip，`&tail-&head >= 64` |
| 负例：无方言头 | ✅ `tests/hela/split_plain` → `'struct #split(N)' is a Hela feature` |
| 负例：与 `#explicit` 同用 | ✅ `tests/hela/split_conflict` → `keep only '#split'` |
| 清单元数据 | ✅ `"split":64`、`"explicit":false`；`padding_before` 0/56/56 |
| `layout_hash` 只描述字节 | ✅ `#explicit`+手工 padding 与 `#split(64)` 同 hash：`062e77f196d3cf1e`；`run.sh` 直接断言两者相等 |
| hash 跳过 `_` 字段的直接后果 | ✅ `abi::Ring_Header` 从 `9521ea22b62f580d` 变为 `90d7a5295de285a9`；`golden.hash` 其余 13 行不变 |
| 清单 v2 | ✅ `version: 2`；每类型 16 键（15 + `fields`），CBOR 解码后消费完所有字节 |
| 字节地图区分声明式 padding | ✅ `Split` 渲染出 `declared #split(64)` 与 `<stride>` 行 |
| 编译器重建 | ✅ `EXIT=0` |

## 已知限制

1. `#soa` 的字节地图按「分量数组」显示，不是「元素交错」的直觉图。
2. 清单 `file` 为「相对 working directory，不在其下则绝对」。跨目录调用时 `file` 会不同，
   但 `layout_hash` 与 `--diff` 都不看 `file`，ABI 门禁不受影响。
3. `golden.hash` 只覆盖 host target；`align_of` / `size_of` 依赖 target，跨 target 门禁需要
   `golden.<os>_<arch>.hash` 命名方案（未做）。
4. `#explicit` / `#split` 都只控制 padding，不支持「乱序摆放字段」（那需要 per-field offset 语法）。
5. `#split(N)` 是整结构体一刀切，不能只让某几个字段换行；字段级 `@(align(N))` 尚未支持。
6. `-emit-layout-for` 命中不到任何文件时静默输出空 `types`，不报错（便于脚本按需开关）。
7. `core/hela/ring` 单独跑 `-vet-unused` 会误报 `'sync' declared but not used`：多态过程体在实例化前
   不检查，体内对导入包的引用因此没被记录。`.odin` 同样复现，属上游行为，未修（见 `08-m8-ring.md` §6）。
8. 伪共享的 ring 对比数据不可用（0.95x–3.3x 乱跳），已从测试中删除，只保留编译期对照与计数器实测。

## 复现

```sh
cd /opt/repos/hela
./build_odin.sh release
./tests/hela/run.sh

# 手工
./odin check tests/hela/layout -no-entry-point -emit-layout:json -emit-layout-file:/tmp/layout.json
./odin build cmd/hela-layout -out:/tmp/hela-layout
/tmp/hela-layout /tmp/layout.json Ring_Header

# ABI 门禁
./odin check tests/hela/abi -no-entry-point -emit-layout:json -emit-layout-file:/tmp/abi.json
/tmp/hela-layout --hashes /tmp/abi.json | diff - tests/hela/abi/golden.hash

# 跨包导出 + 自定义 cache line
./odin check cmd/hela-layout -emit-layout:json -emit-layout-file:/tmp/y.json \
    -emit-layout-for:core/hela/layout -layout-cache-line:128

# ring 库与伪共享
./odin run tests/hela/ring -o:speed
HELA_TSAN=1 ./tests/hela/run.sh

# #split 与手写 padding 的字节等价性
./odin run tests/hela/split
./odin check tests/hela/split -no-entry-point -emit-layout:json -emit-layout-file:/tmp/sp.json
```
