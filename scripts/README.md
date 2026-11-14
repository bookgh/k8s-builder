# K8s v1.37.2 二进制 HA 部署脚本（纯 Shell）

在**部署节点**执行全部安装；公共脚本只在部署节点本地运行，远端节点不落地脚本、不 source 公共库，仅通过 `scp` 接收二进制/证书/配置，通过 `ssh` 执行单条安装/启停命令。

## 前提

- 操作系统：Rocky Linux 9（x86_64），节点 IP/主机名初始可达。
- 部署节点与所有节点网络互通；防火墙/SELinux 由 `02-init` 关闭禁用。
- 离线物料由 `03-download` 从 `bookgh/k8s-builder` Release（`v1.37.2-r1`）拉取并校验 SHA256。

## 环境变量（不写入脚本）

| 变量 | 说明 |
|---|---|
| `SSH_PASSWORD` | 节点 root 密码，用于 `01-ssh` 首次推送公钥；已免密后可不提供 |
| `HARBOR_ADMIN_PASSWORD` | `INSTALL_HARBOR=true` 时必填，Harbor 管理员口令 |

## 快速开始

```bash
# 在源码目录 k8s-builder/scripts/ 下
chmod +x *.sh lib/*.sh

# 全量执行
./main.sh

# 仅执行指定阶段（编号前缀匹配）
./main.sh 07 08

# 列出阶段
./main.sh list
```

## 阶段顺序

| 阶段 | 脚本 | 职责 |
|---|---|---|
| 00 | `00-preflight.sh` | OS/架构/资源/工具/变量与节点表自检 |
| 01 | `01-ssh.sh` | 密钥生成、公钥分发、免密验证 |
| 02 | `02-init.sh` | 主机名/hosts/防火墙/SELinux/swap/模块/sysctl/ulimit/journald/基础包 |
| 03 | `03-download.sh` | 拉取 Release 离线物料，SHA256 校验与关键物料核对 |
| 04 | `04-caddy.sh` | caddy file-server `:2026`，对外分发物料与配置副本 |
| 05 | `05-harbor.sh` | 可选 Harbor 安装、hosts 解析、节点信任 |
| 06 | `06-cert.sh` | cfssl 证书与 kubeconfig 生成（admin 仅留部署节点） |
| 07 | `07-etcd.sh` | 堆叠 etcd 三节点部署与健康检查 |
| 08 | `08-runtime.sh` | containerd（默认）/ docker（可选）运行时、镜像加速、Harbor 信任 |
| 09 | `09-master.sh` | kube-lb + apiserver / controller-manager / scheduler |
| 10 | `10-worker.sh` | kubelet / kube-proxy / CNI 分发启动、节点注册 |
| 11 | `11-network.sh` | helm 离线部署 Calico / CoreDNS / NodeLocal DNSCache |
| 99 | `99-verify.sh` | 全集群终检 |

## 目录口径（相对脚本目录推导）

```
k8s-builder/
├── scripts/                 # 本目录（部署节点本地运行）
│   ├── env.sh               # 集中变量
│   ├── main.sh              # 编排入口
│   ├── lib/common.sh        # 日志/校验/远程执行/HTTP/systemd/等待
│   ├── lib/inventory.sh     # 节点表解析与角色/网络派生
│   └── NN-*.sh              # 各阶段脚本
├── k8s-offline/             # 离线物料（03 落地）：bin/charts/images/tarball
└── deploy/                  # 配置与产物留痕：ssl/kube-cfg/sys-cfg/.../config
```

## 关键开关（`env.sh`）

- `RUNTIME=containerd|docker`：全局二选一，不混部。
- `INSTALL_HARBOR=false|true`：是否安装本地 Harbor。
- `MASTER_COUNT=3`：前 N 个节点为 Master+Etcd，其余 Worker。
- `PROXY_MODE=ipvs`；`CALICO_NETWORKING_BACKEND=bird|vxlan`。

## 备注

- Metrics Server 本轮不安装，后续补充。
- 证书有效期 100 年（`876000h`）。
- 重入保护：etcd 数据目录已存在时 `initial-cluster-state` 自动改为 `existing`。
