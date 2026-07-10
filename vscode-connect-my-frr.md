# 用 VS Code 连接 Lima 虚机 my-frr

## 环境信息

| 项目 | 值 |
|------|-----|
| 虚机名 | my-frr |
| OS | Ubuntu (aarch64 / Linux 6.17) |
| SSH 地址 | 127.0.0.1:51244 |
| SSH 用户 | fanwei |
| SSH Host 别名 | `lima-my-frr` |

---

## 前提条件

### 1. 确保虚机在运行

```bash
limactl list
# STATUS 应为 Running
```

如果是 Stopped，执行：

```bash
limactl start my-frr
```

### 2. 验证 SSH 可达

```bash
ssh lima-my-frr "uname -a"
```

看到 Linux 输出即表示 SSH 正常。

---

## VS Code 连接步骤

### 步骤 1：安装 Remote - SSH 插件

在 VS Code 插件市场搜索并安装：

```
Remote - SSH
```

插件 ID：`ms-vscode-remote.remote-ssh`

### 步骤 2：连接到虚机

方式一（命令面板）：

1. 按 `Cmd+Shift+P` 打开命令面板
2. 输入 `Remote-SSH: Connect to Host...`
3. 选择或输入 `lima-my-frr`

方式二（SSH 配置已自动写入 `~/.ssh/config`，直接选择即可）：

1. 点击 VS Code 左下角的 `><` 图标
2. 选择 `Connect to Host...`
3. 从列表中选择 `lima-my-frr`

### 步骤 3：选择工作目录

连接成功后，VS Code 会在虚机内打开新窗口。点击 `Open Folder`，
选择虚机内的目录，例如：

- `/home/fanwei/` — 用户主目录
- `/etc/frr/` — FRR 配置目录

---

## ~/.ssh/config 中的配置（已自动生成）

Lima 启动时会将以下内容写入 `~/.ssh/config`：

```
Host lima-my-frr
  IdentityFile "/Users/fanwei/.lima/_config/user"
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  NoHostAuthenticationForLocalhost yes
  PreferredAuthentications publickey
  Compression no
  BatchMode yes
  IdentitiesOnly yes
  GSSAPIAuthentication no
  Ciphers "^aes128-gcm@openssh.com,aes256-gcm@openssh.com"
  User fanwei
  ControlMaster auto
  ControlPath "/Users/fanwei/.lima/my-frr/ssh.sock"
  ControlPersist yes
  Hostname 127.0.0.1
  Port 51244
```

> **注意**：Port（51244）在每次虚机启动时可能不同。Lima 会自动更新 `~/.ssh/config`，
> 无需手动修改，但如果 VS Code 连接失败，执行 `limactl list` 确认端口是否变化，
> 然后重新执行 `limactl show-ssh --format=config my-frr` 检查最新配置。

---

## 常用命令

```bash
# 查看虚机状态
limactl list

# 启动
limactl start my-frr

# 停止
limactl stop my-frr

# 直接进入 shell
limactl shell my-frr

# 以 root 进入
limactl shell --workdir / my-frr sudo -i
```
