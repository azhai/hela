# M29 · 把上游 odin 拉进 main，再合进 hela

这一篇不是"新增语言特性"，是**维护动作**：让 fork 跟上上游，并记录怎么跟。

起点是 hela 仓库的 `main` 只有**一个无父提交**（`63aac30` "fork from odin dev2026-11"）。
也就是说这个 fork 与 odin 没有共同历史 —— `git merge upstream/master` 会是
"unrelated histories"，几万个文件全冲突，等于重写一遍。

所以这里走**快照同步**：main 的树整体替换成上游的树，两者用 **tree SHA 对账**；
hela 再合 main，git 以"上一份快照"为 merge base，算出来的正好是"上游这三周改了什么"。

---

## 1. 抓上游：git 协议过不去，改用 codeload 的 tarball

四轮 `git fetch` 全部死在响应末尾，错误都一样：

```
RPC failed; curl 18 transfer closed with outstanding read data remaining
fetch-pack: unexpected disconnect while reading sideband packet
```

- `--depth=400`（限深）：4m12s 后差 18683 字节断；
- `git -c http.version=HTTP/2`：2m54s 后差 5640 字节断。

两者的共同点是"只差最后几 KB"，是代理对**流式 chunked 响应**的截断，不是仓库大。
git 的 pack 是 sideband 流式的，没法续传；换成静态下载就好了：

```
curl -L -o /tmp/odin.tgz https://codeload.github.com/odin-lang/Odin/tar.gz/refs/heads/master
# 166 MB，~115 s，1.4 MB/s（比 git 端点快 8 倍）
```

tarball 与真树的一致性用 GitHub 的 tree API 核对（`git/trees/master?recursive=1`，
4291 个 blob），**逐个对 blob SHA**，只有两类差异：

1. **CRLF**：上游有 90 个文件本来就存 CRLF，而本仓库 `.gitattributes` 是 `text=auto`，
   `git add` 会把它们改写成 LF → blob 变了。所以不能用 `git add`，改用
   `git hash-object -w --no-filters` + `git update-index --index-info`（连 ignore 也绕过）。
2. **Git LFS**：99 个 vendor 预编译库（`.lib/.a/.dll/.o`，共 **168.5 MiB**）在上游是
   132 字节的 LFS 指针，而 codeload 的 tarball 给的是**解析后的真实文件**。
   指针可以从真实文件反推（`sha256` + `size`），写回去后 blob SHA 与上游一致：

   ```
   version https://git-lfs.github.com/spec/v1
   oid sha256:<64 hex>
   size <bytes>
   ```

这两点处理完，`git write-tree` 得到 `d861ef6…`，与上游 master 的 tree SHA **完全相同**。
这就是这次同步唯一的验收标准 —— 不是"看起来一样"，是 SHA 一样。

```
main 1875a13  tree d861ef613e71649962f8f8df3cf2f8448a868746
上游 7f5fe36  tree d861ef613e71649962f8f8df3cf2f8448a868746
```

区间 `dev-2026-11(e28f5d1) → master(7f5fe36)`：**新增 272 / 修改 459 / 删除 20**。

---

## 2. 合进 hela：只有一个冲突

hela 侧改动 144 个文件、+22571/−30，其中编译器侧 19 个文件、+2540/−30，
**几乎全是追加**（`check_type.cpp` 891/0、`main.cpp` 139/0）。上游改 `src/` 37 个文件、
+5943/−3959（`check_asm`、`check_escape`、`llvm_*` 大幅重构）。

结果：**18 个编译器文件自动合并，只有 `src/check_type.cpp` 冲突**。

冲突的成因是两边在同一个锚点各插入一坨：hela 在 `set_polymorphic_record_instantiation_name`
之后插了 768 行布局检查，上游在同一位置插了 `poly_operands_have_errors`。
git 把两边的**函数体交错**在一起，冲突块从 772 行拉到 1288 行 —— 直接看会以为要大改。

解法不是手工重排，而是**换一个方向合并**：以**上游版本为底**，把 hela 的 9 个 hunk 打上去。

```
git show main:src/check_type.cpp > /tmp/theirs.cpp      # 以上游为底
git diff 63aac30 backup/hela-pre-sync -- src/check_type.cpp > /tmp/hela.patch
git apply --reject /tmp/hela.patch                       # 20/21 干净应用
```

剩下两处手工：

1. 上游新增的 `poly_operands_have_errors` 插到 `check_struct_type` 定义之前
   （它原来夹在被 hela 撑开的两个函数之间，补丁的上下文对不上）。
2. 上游把 `has_errors.store` / `wait_signal_set` 从 `if (!is_polymorphic)` **块内提到块外**
   —— 多态 struct 走不到那个分支，信号永远不置位，字段会一直等。而 hela 的
   split/offset/explicit/sharing 检查正好占住了原位。**两个都保留**：块内的信号给 hela
   的检查用（它们要读 offsets），块外的那对补上游修的那个洞。

**对账**（这一步比"编译过了"更有说服力）：逐文件比对 hela 相对 main 的增删行数
与合并前是否一致 —— 144 个文件全部相同，唯一差异是 `check_type.cpp` 多 5 行说明注释。
即上游改动没有吞掉 Hela 的任何东西，反过来也没有。

---

## 3. 验证

| 项 | 结果 |
|---|---|
| 重建编译器 | `dev-2026-11:310d9ae`，零错误 |
| `tests/hela/run.sh` | **29/29**（含 6 份 golden ABI hash 未变，第 28 步内存层次断言） |
| xrep `verify.sh` | 全部通过：78 golden + run2 34 + run3 56 + 单测 153 + 内建自检 |
| 上游 `tests/core` | **1495** 个用例全过（需先备齐资产，见下） |
| 上游 `tests/internal` | **273** 个用例全过 |
| 改动完整性 | hela 侧 144 个文件的增删行数与合并前**逐项相同**（唯一差异：`check_type.cpp` +5 行注释） |

`tests/core` 的正式命令行带 `-sanitize:address`，但**在本机链接不过**：

```
ld: symbol(s) not found for architecture arm64: _asan.module_ctor in normal-*.o
```

这不是合并引入的 —— 一个 hello world 加 `-sanitize:address` 同样失败，而 Odin 确实把
`-fsanitize=address` 传给了链接器（`src/llvm_backend.cpp:4337`）。是本机 Apple clang
（sysroot 指向 `/Volumes/1TB/.../MacOSX26.5.sdk`）找不到 asan 运行库。所以上面 1495 与 273
两个数字是**去掉 `-sanitize:address`** 得到的，其余严格开关（`-vet-style`、`-warnings-as-errors`、
`-disallow-do`、`ODIN_TEST_FAIL_ON_BAD_MEMORY`）都开着。

顺带发现的**上游行为变化**（会影响下游脚本）：

`odin test` 对"没有任何 `@(test)` 的包"从静默通过改成了**硬报错**
（`src/main.cpp`: `Cannot test package; no procedures with @(test) attribute found.` + `return 1`）。
xrep 的 `test.sh` 原本把根包 `.` 列在 PACKAGES 里（那时它能过），现在整轮直接失败 ——
已把 `.` 移出并注明原因。这条是 fork 点（`63aac30`）没有的，属于上游这三周新增的检查。

另外上游把 `tests/core/assets` 下的**测试资产改成按需下载**：20 个原本入库的资产被删掉，
换成 `*.manifest`（`<size> <HMAC-SHA3-512 keyed with "https://odin-lang.org"> <path>`）
由 `download_assets.py` 拉取并校验。

而在本机 `raw.githubusercontent.com` 被代理切到返回 0 字节，`python3 download_assets.py`
必然失败（`panic: downloading test assets failed!`）。绕法还是 codeload：

```
curl -L -o /tmp/test-assets.tgz \
  https://codeload.github.com/odin-lang/test-assets/tar.gz/0b1477159b58b3d7bf88a35d580d059e087dbe67
# 111 MB；再把各 suite 解到 tests/core/assets/<SUITE>/，用 --update 逐个核 HMAC
python3 download_assets.py assets --update   # 16 个 suite 全部 matches
```

这些资产目录被 `.gitignore` 忽略，不会污染仓库。

---

## 4. 下次怎么同步

```bash
# 1) 拉上游快照（git 协议在本机不可用，走 tarball）
curl -L -o /tmp/odin.tgz https://codeload.github.com/odin-lang/Odin/tar.gz/refs/heads/master
# 2) 取 tree 清单，用来对账
curl -sL "https://api.github.com/repos/odin-lang/Odin/git/trees/master?recursive=1" -o /tmp/tree.json
# 3) 在 main 的 worktree 里 rsync 覆盖，然后按上游 blob SHA 建索引（见第 1 节的两类特例）
# 4) 验收：git write-tree 必须等于上游 commit 的 tree SHA
# 5) git merge main -> hela，冲突大概率仍只在 check_type.cpp
# 6) 重建 + run.sh + xrep verify.sh
```

`main` 的模型是**快照**：它不带上游历史，所以 `git log main` 只有"fork"和每次"sync"两条。
好处是 hela 的 diff 永远是"相对某个确定的 odin 版本"，坏处是拿不到上游的单条提交
（不能 cherry-pick，也不能 bisect 上游）。要换成一个真正的下游分支，得把 fork 点的
那个快照提交嫁接到 odin 的真实历史上 —— 那需要完整的 git 历史，而本机的代理下不了，
留作以后有稳定网络时再做的选项。
