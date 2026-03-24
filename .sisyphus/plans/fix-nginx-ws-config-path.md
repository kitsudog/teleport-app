# 修复 entrypoint.sh nginx 配置路径

## TL;DR

将 nginx WebSocket 配置文件从 `/etc/nginx/conf.d/ws/` 子目录移动到 `/etc/nginx/conf.d/` 根目录，解决 nginx 默认配置不加载子目录配置的问题。

**修改内容**:
- 第56行: `mkdir -p /etc/nginx/conf.d/ws` → `mkdir -p /etc/nginx/conf.d`
- 第57行: `/etc/nginx/conf.d/ws/${APP_NAME}.conf` → `/etc/nginx/conf.d/ws-${APP_NAME}.conf`
- 第120行: 检查逻辑改为匹配 `ws-*.conf` 文件

**估计工作量**: Quick (< 5分钟)
**并行执行**: NO

---

## Context

### 问题描述
`entrypoint.sh` 生成的 nginx WebSocket 配置文件放在 `/etc/nginx/conf.d/ws/` 子目录下：

```bash
mkdir -p /etc/nginx/conf.d/ws
cat > /etc/nginx/conf.d/ws/${APP_NAME}.conf << EOF
```

但 nginx 默认只加载 `/etc/nginx/conf.d/*.conf`，**不会递归加载子目录**，导致配置未生效。

### 解决方案
将配置文件直接放到 `conf.d/` 目录，使用 `ws-` 前缀命名避免冲突。

---

## Work Objectives

### Core Objective
修复 nginx 配置路径，确保 WebSocket 代理配置能被 nginx 正确加载。

### Concrete Deliverables
- 修改后的 `entrypoint.sh` 文件

### Definition of Done
- [ ] `entrypoint.sh` 第56行删除 `/ws` 子目录
- [ ] `entrypoint.sh` 第57行配置文件名添加 `ws-` 前缀
- [ ] `entrypoint.sh` 第120行检查逻辑改为检测 `ws-*.conf` 文件
- [ ] 验证修改后的脚本语法正确

---

## Verification Strategy

### Agent-Executed QA Scenarios

**Scenario: 验证 entrypoint.sh 语法正确**
  Tool: Bash
  Preconditions: 无
  Steps:
    1. 执行: `bash -n /Users/luozhangming/Documents/workspace/_daveluo/teleport-app/entrypoint.sh`
    2. 断言: 退出码为 0（无语法错误）
  Expected Result: 脚本语法检查通过
  Evidence: 终端输出

**Scenario: 验证修改后的文件内容**
  Tool: Bash (grep)
  Preconditions: 修改已完成
  Steps:
    1. 执行: `grep -n "mkdir -p /etc/nginx/conf.d" entrypoint.sh`
    2. 断言: 输出包含 `mkdir -p /etc/nginx/conf.d`（无 `/ws`）
    3. 执行: `grep -n "ws-" entrypoint.sh | head -3`
    4. 断言: 输出包含 `ws-${APP_NAME}.conf`
    5. 执行: `grep -n "ws-\*.conf" entrypoint.sh`
    6. 断言: 输出包含 `ws-*.conf`
  Expected Result: 所有三处修改都正确应用
  Evidence: grep 输出结果

---

## TODOs

- [ ] 1. 修改 nginx 配置目录路径

  **What to do**:
  - 打开 `entrypoint.sh` 第56-57行
  - 将 `mkdir -p /etc/nginx/conf.d/ws` 改为 `mkdir -p /etc/nginx/conf.d`
  - 将 `/etc/nginx/conf.d/ws/${APP_NAME}.conf` 改为 `/etc/nginx/conf.d/ws-${APP_NAME}.conf`

  **Recommended Agent Profile**:
  - **Category**: `quick`
  - **Skills**: []
  - **Reason**: 简单的字符串替换，不需要复杂技能

  **Parallelization**:
  - **Can Run In Parallel**: NO
  - **Blocked By**: None
  - **Blocks**: Task 2

  **References**:
  - `entrypoint.sh:56` - 原始目录创建代码
  - `entrypoint.sh:57` - 原始配置文件路径

  **Acceptance Criteria**:
  - [ ] 第56行不再包含 `/ws` 子目录
  - [ ] 第57行配置文件名以 `ws-` 开头

  **Agent-Executed QA**:
  ```
  Scenario: 验证路径修改
    Tool: Bash
    Steps:
      1. grep -n "mkdir -p /etc/nginx/conf.d[^/]" entrypoint.sh
      2. Assert: 匹配成功
      3. grep -n "/etc/nginx/conf.d/ws-" entrypoint.sh
      4. Assert: 匹配成功
  ```

  **Commit**: YES
  - Message: `fix(entrypoint): move nginx ws config to conf.d root`
  - Files: `entrypoint.sh`

- [ ] 2. 修改 nginx 配置检查逻辑

  **What to do**:
  - 打开 `entrypoint.sh` 第120行
  - 将目录存在检查改为文件模式匹配
  - 原代码: `if [ -d /etc/nginx/conf.d/ws ] && [ "$(ls -A /etc/nginx/conf.d/ws)" ]; then`
  - 新代码: `if ls /etc/nginx/conf.d/ws-*.conf >/dev/null 2>&1; then`

  **Recommended Agent Profile**:
  - **Category**: `quick`
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: NO
  - **Blocked By**: Task 1
  - **Blocks**: None

  **References**:
  - `entrypoint.sh:120` - 原始检查逻辑

  **Acceptance Criteria**:
  - [ ] 第120行使用 `ls /etc/nginx/conf.d/ws-*.conf` 检查文件
  - [ ] 脚本语法检查通过: `bash -n entrypoint.sh`

  **Agent-Executed QA**:
  ```
  Scenario: 验证检查逻辑修改
    Tool: Bash
    Steps:
      1. grep -n "ws-\*.conf" entrypoint.sh
      2. Assert: 匹配成功
      3. bash -n entrypoint.sh
      4. Assert: 退出码为 0
  ```

  **Commit**: YES (groups with 1)

---

## Commit Strategy

| After Task | Message | Files | Verification |
|------------|---------|-------|--------------|
| 1+2 | `fix(entrypoint): move nginx ws config to conf.d root` | entrypoint.sh | `bash -n entrypoint.sh` |

---

## Success Criteria

### Verification Commands
```bash
# 检查语法
bash -n entrypoint.sh

# 验证修改
grep -n "mkdir -p /etc/nginx/conf.d[^/]" entrypoint.sh
grep -n "ws-${APP_NAME}.conf" entrypoint.sh
grep -n "ws-\*.conf" entrypoint.sh
```

### Final Checklist
- [ ] 第56行: `mkdir -p /etc/nginx/conf.d`（无 `/ws`）
- [ ] 第57行: `/etc/nginx/conf.d/ws-${APP_NAME}.conf`（有 `ws-` 前缀）
- [ ] 第120行: `ls /etc/nginx/conf.d/ws-*.conf`（检查文件存在）
- [ ] 脚本语法检查通过
