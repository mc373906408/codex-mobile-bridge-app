# Agent Note: iOS 预览存储并发首次创建锁文件

Status: implemented

## Problem

完整打包 run `42204971409` 的 Swift/Rust 原生预览测试中，两个独立 `CloudMetadataStore` 第一次并发进入事务时，一个 `openat` 返回 `ENOENT`，尚未进入更新回调，最终四十次更新只持久化三十九次。现有测试每轮两个 worker 更新一次，已避免连续 fsync 的饥饿，却只在第一轮创建锁文件，不能充分覆盖首次创建竞争。

故障形态与 [Go 的 macOS openat 并发创建复现](https://github.com/golang/go/issues/81246)一致：相对于已打开目录描述符使用不带 `O_EXCL` 的 `O_CREAT`，竞争首次创建同名文件时可能错误返回 `ENOENT`。该外部复现解释选用哪条系统调用路径，本项目的通过依据仍是实际 Swift 测试和 CI。

## Decision

锁文件先使用不带 `O_CREAT` 的 `openat` 打开；仅在 `ENOENT` 时尝试 `O_CREAT | O_EXCL` 创建；仅在创建返回 `EEXIST` 时再打开另一方已创建的文件。一次获取最多三次打开调用，不循环重试、不截断、不替换、不删除锁文件，其他错误仍立即失败。

所有打开继续相对于已固定的目录描述符执行，保持 `O_NOFOLLOW`、`O_NONBLOCK`、`O_CLOEXEC` 和创建权限 `0600`。打开后仍校验普通文件、唯一硬链接以及目录和锁文件 inode 身份；事务前后及提交前继续校验身份，`flock` 超时与持久化顺序不变。

## 记录归属

检索活跃记录后，[P2P 与 CI](../architecture/2026-11-06-easytier-p2p.md)部分重叠，继续持有每轮两个 worker 的持久化序列化测试与独立 Swift 门禁；[全局架构省察](../architecture/2026-11-04-app-architecture-and-scope-audit.md)部分重叠，继续持有预览元数据和扩展的权限边界；[云状态边界](2026-11-04-cloud-state-boundaries-and-legacy-removal.md)部分重叠，继续持有预览存储故障不阻断聊天。本篇只持有锁文件首次创建竞争的处理。发布、连接恢复、手机安装、旧格式移除、持久中继及通知默认初始化记录不规定该系统调用路径；没有完全吸收记录或过时提案。

## Alternatives considered

- 对原 `O_CREAT` 打开遇到 `ENOENT` 加一次重试，改动较小，但仍依赖同一条有竞争问题的路径；独占创建能将“另一方已创建”明确表示为 `EEXIST`，并保持调用次数有界。
- 测试提前创建锁文件可以稳定后续 `flock` 检查，但会避开 App 和通知扩展同时首次访问的真实场景，不能修复生产路径。
- 改用绝对路径 `open` 可以绕开报告中的失败路径，但会丢失当前目录描述符提供的路径固定能力，因此保留相对目录打开。

## Testing

新增五十轮全新目录、每轮八个独立 store 同时读取的回归，共四百次首次访问；启动门保证各 worker 就绪后才放行，完成等待有界。读取不写 metadata，以免把首次创建竞争与 fsync 排队混在一起。既有四十次持久化更新，以及符号链接、硬链接、FIFO、目录替换、锁替换和锁等待超时测试继续执行。

Swift 检查在 macOS CI 上分别运行普通配置和真实 Rust 预览 ABI 配置；Windows 源码图检查不能代替 Swift 运行结果。[发布流程](../process/2026-11-04-github-mobile-release.md)的 `swift_policy_only` 手动模式只运行该门禁，验证通过后再按同一提交执行完整打包。完整打包与签名产物以对应提交的 GitHub run 为准。

## Consequences

首次并发访问避开 Darwin 有问题的创建或打开路径，正常已有锁只执行一次打开。文件在竞争期间继续被移除、目录被替换或权限异常时仍可能失败；这些失败不会被当成空存储或成功事务。修复不扩大预览数据的访问权限，也不改变存储格式。
