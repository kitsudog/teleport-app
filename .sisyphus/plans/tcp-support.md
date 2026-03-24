# 计划：PEM 模式多 TCP 应用代理支持

## 背景

当前 `entrypoint.sh` 有两种运行模式：
- **Mode 1（PEM 代理）**：挂载 `/teleport.pem`，用 `tsh proxy app` 代理已注册的应用。当前只支持单个 `APP_NAME` + `APP_PORT`
- **Mode 2（Token 注册）**：通过 `TELEPORT_TOKEN` 将节点注册到集群，支持 `APP_N_URL=http://` 和 `tcp://`。**已完善，不动**

本次任务：**重写 Mode 1**，支持通过 `TCP_APPS` 环境变量同时代理多个 TCP 应用。

## 设计决策（已确认）

| 决策项 | 结论 |
|--------|------|
| Token 模式（Mode 2） | 完全不动，一行代码都不改 |
| PEM 模式入口变量 | 去掉旧的 `APP_NAME`/`APP_PORT`，纯 `TCP_APPS` 驱动 |
| TCP_APPS 格式 | 分号分隔，`name:port` 或仅 `name`（自增端口） |
| TCP_START_PORT | 默认 8000，未指定端口的 app 从此自增 |
| TCP_LAN | 默认 true，用 socat 将端口从 0.0.0.0 转发到 127.0.0.1 |
| 端口分配策略 | 用户指定端口 = socat 对外端口；tsh 内部端口从高位范围自动分配（如 40001 起步），不影响用户 |
| 进程崩溃策略 | 任一 tsh/socat 进程退出 → 容器立即退出，交给 Docker 重启策略 |

## 关键技术细节

### 端口冲突解决方案

`tsh proxy app` 只能绑 `127.0.0.1`，socat 绑 `0.0.0.0`。如果用同一端口会 EADDRINUSE。

解决方案：**两套端口**
- **外部端口**（用户在 TCP_APPS 指定）：socat 绑 `0.0.0.0:<外部端口>`
- **内部端口**（自动分配）：tsh 绑 `127.0.0.1:<内部端口>`，从 40001 开始递增
- socat 做转发：`0.0.0.0:<外部端口>` → `127.0.0.1:<内部端口>`

当 `TCP_LAN=false` 时：不启动 socat，tsh 直接用外部端口绑 `127.0.0.1`

### 进程管理

```bash
trap 'kill $(jobs -p) 2>/dev/null; wait' SIGTERM SIGINT

# 启动所有 tsh + socat 后台进程
for app in ...; do
  tsh proxy app $name --port $internal_port -i /teleport.pem --proxy=$TELEPORT_PROXY &
  socat TCP-LISTEN:$external_port,fork,bind=0.0.0.0 TCP:127.0.0.1:$internal_port &
done

# 任一进程退出就退出容器
wait -n
kill $(jobs -p) 2>/dev/null
exit 1
```

### Usage 输出（最终版）

```
Usage:

  Mode 1 - PEM Proxy (mount /teleport.pem):
    docker run -v ./teleport.pem:/teleport.pem \
      -e TELEPORT_PROXY=tp.example.com:443 \
      -e TCP_APPS="redis:6379;pg:5432" teleport-app

    Required:
      TELEPORT_PROXY          Proxy address
      TCP_APPS                TCP apps to proxy (;-sep)

    Optional:
      TCP_START_PORT          Auto-increment port (default: 8000)
      TCP_LAN                 Bind 0.0.0.0 via socat (default: true)

    Examples:
      TCP_APPS="redis:6379;pg:5432"
      TCP_APPS="svc1;svc2;svc3"                        # ports: 8000,8001,8002
      TCP_APPS="redis:6379;worker1;worker2"             # 6379,8000,8001
      TCP_APPS="svc1;svc2" TCP_START_PORT=9000          # 9000,9001

  Mode 2 - Token Join (register services):
    docker run -e TELEPORT_TOKEN=xxx \
      -e TELEPORT_PROXY=tp.example.com:443 teleport-app

    Required:
      TELEPORT_TOKEN          Join token
      TELEPORT_PROXY          Proxy address

    Optional:
      NODE_NAME               Node name (default: auto)

    Apps (supports http:// and tcp://):
      APP_N_NAME              App name        e.g. APP_0_NAME=grafana
      APP_N_URL               App URL         e.g. APP_0_URL=http://grafana:3000
                                              e.g. APP_0_URL=tcp://localhost:5432
      APP_N_LABEL             Labels (;-sep)  e.g. APP_0_LABEL="env=prod;team=be"
      APP_N_HOST              Host rewrite    e.g. APP_0_HOST=grafana.internal
      DEFAULT_URL             Default URL
      DEFAULT_LABEL           Default labels
```

## 范围边界

### IN
- 重写 PEM 模式（entrypoint.sh 第 2-14 行区域）
- TCP_APPS 解析、端口分配、验证
- socat + tsh 多进程管理
- 信号处理（SIGTERM/SIGINT）
- 更新 usage 输出
- 测试用例

### OUT
- Token 模式（不动一行）
- Dockerfile 改动
- app_config.yaml 改动
- 重试逻辑、健康检查
- 日志框架

## 边界情况处理

| 输入 | 预期行为 |
|------|----------|
| `TCP_APPS=""` 或未设置 | 显示 usage，exit 1 |
| `TCP_APPS="redis:6379"` 单个 | 正常工作 |
| `TCP_APPS="redis:6379;"` 尾部分号 | 忽略空段 |
| `TCP_APPS="redis:abc"` 非数字端口 | 报错 exit 1 |
| `TCP_APPS="redis:0"` 或 `:99999` | 报错：端口超范围 (1-65535) |
| `TCP_APPS="redis:6379;redis:5432"` 重名 | 报错：应用名重复 |
| `TCP_APPS="redis:6379;pg:6379"` 端口重复 | 报错：端口重复 |
| `TCP_APPS="w1;w2"` 无 TCP_START_PORT | 默认 8000，端口 8000/8001 |
| `TCP_LAN=false` | 不启动 socat，tsh 直接用外部端口 |
| Docker SIGTERM | trap 捕获，kill 所有子进程，clean exit |

## 任务依赖图

```
Wave 1: Task 1（测试基础设施）
    ↓
Wave 2: Task 2（测试用例 — TDD red phase）
    ↓
Wave 3: Task 3（实现 PEM 模式 TCP_APPS）
    ↓
Wave 4: Task 4（验证 + 提交）
```

## 任务详情

<!-- TASKS_START -->

### Task 1：创建测试基础设施

**描述**：创建 `test/` 目录，包含 mock 的 `tsh` 和 `socat` 脚本，以及测试辅助函数。

**分类**：`quick` | **技能**：`[]`
**依赖**：无

**具体要求**：
1. 创建 `test/mocks/tsh` — 可执行脚本，将所有参数记录到 `$MOCK_LOG_DIR/tsh.log`，格式每行一次调用。用 `sleep 999 &` 模拟后台持续运行
2. 创建 `test/mocks/socat` — 同上，记录到 `$MOCK_LOG_DIR/socat.log`
3. 创建 `test/helpers.sh` — 提供函数：
   - `setup_mocks()`：创建临时目录，将 `test/mocks/` 加入 PATH 最前
   - `teardown_mocks()`：清理临时目录，恢复 PATH
   - `assert_tsh_called_with <expected_args>`：检查 tsh.log 包含预期参数
   - `assert_socat_called_with <expected_args>`：检查 socat.log 包含预期参数
   - `assert_exit_code <expected> <actual>`：验证退出码
   - `assert_output_contains <string>`：验证标准输出/错误包含指定文本
   - `create_pem_file()`：在临时目录创建假的 `/teleport.pem`
4. mock tsh 还需要处理 `apps ls` 子命令（只打印 "mock apps list"）

**验收标准**：
- `bash test/helpers.sh` 退出码 0（自测通过）
- mock 脚本可执行，能正确记录调用参数

---

### Task 2：编写测试用例（TDD red phase）

**描述**：编写覆盖所有场景的测试用例。此阶段测试应全部失败（实现尚未开始）。

**分类**：`unspecified-low` | **技能**：`[]`
**依赖**：Task 1

**具体要求**：

创建 `test/test_pem_mode.sh`，包含以下测试函数：

1. `test_basic_multi_app` — `TCP_APPS="redis:6379;pg:5432"`
   - 预期：tsh 被调用 2 次，端口分别正确
   - 预期：socat 被调用 2 次，外部端口 6379/5432

2. `test_auto_increment` — `TCP_APPS="w1;w2;w3"` + `TCP_START_PORT=9000`
   - 预期：端口 9000/9001/9002

3. `test_default_start_port` — `TCP_APPS="w1;w2"` 不设 TCP_START_PORT
   - 预期：端口 8000/8001

4. `test_mixed_mode` — `TCP_APPS="redis:6379;w1;w2;pg:5432;w3"` + `TCP_START_PORT=9000`
   - 预期：redis:6379, w1:9000, w2:9001, pg:5432, w3:9002

5. `test_missing_teleport_proxy` — 不设 TELEPORT_PROXY
   - 预期：exit 1，输出 usage 信息

6. `test_missing_tcp_apps` — 不设 TCP_APPS（但有 /teleport.pem）
   - 预期：exit 1，输出 usage 信息

7. `test_invalid_port` — `TCP_APPS="redis:abc"`
   - 预期：exit 1，报错

8. `test_duplicate_name` — `TCP_APPS="redis:6379;redis:5432"`
   - 预期：exit 1，报错

9. `test_duplicate_port` — `TCP_APPS="redis:6379;pg:6379"`
   - 预期：exit 1，报错

10. `test_tcp_lan_false` — `TCP_APPS="redis:6379"` + `TCP_LAN=false`
    - 预期：tsh 调用 1 次，socat **不被调用**

11. `test_single_app` — `TCP_APPS="redis:6379"`
    - 预期：正常工作，tsh 1 次，socat 1 次

12. `test_usage_message` — 验证 PEM 模式 usage 输出包含 `TCP_APPS`、`TCP_START_PORT`、`TCP_LAN`

每个测试函数：设置环境变量 → 创建假 pem 文件 → 运行 entrypoint.sh → 检查 mock 日志和退出码

**验收标准**：
- `bash test/test_pem_mode.sh` 能运行所有测试并报告结果（不崩溃）
- 此阶段测试预期全部 FAIL

---

### Task 3：实现 PEM 模式 TCP_APPS 逻辑

**描述**：重写 `entrypoint.sh` 的 PEM 模式部分（第 2-14 行区域），实现多 TCP 应用代理。

**分类**：`deep` | **技能**：`[]`
**依赖**：Task 2

**具体实现要求**：

1. **保留入口判断**：`if [ -s /teleport.pem ];then` 不变

2. **参数验证**：
   - 检查 `TELEPORT_PROXY` 非空
   - 检查 `TCP_APPS` 非空
   - 缺失则打印 Mode 1 usage 并 exit 1

3. **解析 TCP_APPS**：
   - 按 `;` 分割
   - 每段按 `:` 分割为 name 和 port
   - 无 port 的从 `TCP_START_PORT`（默认 8000）自增
   - 验证：port 是数字且 1-65535，无重名，无重复端口

4. **内部端口分配**：
   - 从 40001 开始递增，每个 app 分配一个
   - 当 `TCP_LAN=false` 时不需要内部端口，tsh 直接用外部端口

5. **启动 banner**：
   ```
   === TCP Proxy Apps ===
   redis         :6379  (internal: 40001)
   postgres      :5432  (internal: 40002)
   worker1       :8000  (internal: 40003)
   =====================
   ```
   当 `TCP_LAN=false` 时不显示 internal 列

6. **信号处理**：
   ```bash
   trap 'kill $(jobs -p) 2>/dev/null; wait' SIGTERM SIGINT
   ```

7. **执行 `tsh apps ls`**（信息性展示，和当前行为一致）：
   ```bash
   tsh apps ls -i /teleport.pem --proxy=$TELEPORT_PROXY
   ```

8. **启动代理进程**（每个 app）：
   ```bash
   tsh proxy app $name --port $internal_port -i /teleport.pem --proxy=$TELEPORT_PROXY &
   if [ "${TCP_LAN}" != "false" ]; then
     socat TCP-LISTEN:$external_port,fork,bind=0.0.0.0 TCP:127.0.0.1:$internal_port &
   fi
   ```

9. **进程监控**：
   ```bash
   wait -n
   echo "进程异常退出" >&2
   kill $(jobs -p) 2>/dev/null
   exit 1
   ```

10. **Token 模式代码完全不动**：`fi` 之后到文件结尾的所有代码保持原样

**代码风格**：
- 不加 `set -euo pipefail`（和现有风格一致）
- 错误信息用 `echo "..." >&2`
- 不引入外部依赖

**验收标准**：
- `bash test/test_pem_mode.sh` 所有测试通过（exit 0）
- Token 模式代码（当前 15-83 行）与修改前完全一致

---

### Task 4：最终验证与提交

**描述**：全面验证，确保 Token 模式未被改动，创建 git commit。

**分类**：`quick` | **技能**：`["git-master"]`
**依赖**：Task 3

**具体要求**：
1. 运行 `bash test/test_pem_mode.sh` 确认全部通过
2. 提取新旧 entrypoint.sh 的 Token 模式部分做 diff，确认为空
3. 创建单一原子提交：
   ```
   feat: extend PEM mode to support multiple TCP apps via TCP_APPS
   ```
4. 确保 test/ 目录也包含在提交中

**验收标准**：
- 测试全部通过
- Token 模式 diff 为空
- git commit 存在且信息正确

<!-- TASKS_END -->

## 最终验证波

运行以下验证确认计划执行成功：

1. `bash test/test_pem_mode.sh` → exit 0
2. Token 模式 diff 为空
3. `git log -1 --oneline` 显示正确的提交信息
