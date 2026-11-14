# k8s-builder

离线资源与组件二进制构建发布仓：通过 GitHub Actions 下载上游离线资产、打包 Helm Chart 及其镜像、编译 nginx 二进制，统一发布到本仓 GitHub Release。

## 目录结构

```
k8s-builder/
├── versions.env                  # 非 Chart 组件版本（二进制 / 压缩包 / 镜像）
├── charts.yaml                   # Chart 仓库、名称与版本（Calico / CoreDNS / NodeLocalDNS）
├── nginx/
│   └── Dockerfile                # 多阶段编译 stream 专用 nginx，PGP 签名校验
├── charts/
│   └── nodelocaldns/             # 本地 Chart 骨架（Kubernetes 1.37）
├── ci-scripts/
│   ├── common.sh                 # 公共变量与下载工具
│   ├── download-assets.sh        # 下载二进制 / 压缩包到 dist/bin、dist/tarball
│   ├── fetch-charts.sh           # 拉取/打包 Chart，解析镜像并按目录打包
│   ├── export-pause-image.sh     # docker save 导出 pause 镜像为 tgz
│   └── build-nginx.sh            # 构建镜像并从中提取 nginx 二进制
└── .github/workflows/
    └── release.yml               # 创建 Release 或手动触发
```

## 版本管理

- **`versions.env`**：管理非 Chart 组件版本，CI 通过 `set -a; . versions.env; set +a` 加载。
- **`charts.yaml`**：管理所有 Helm Chart 的 `repository` / `chart` / `version`，`versions.env` 不重复维护。
  - `repository` 为 http(s) Helm 仓库时 `helm repo add + helm pull`；版本未进入 index 时回退 GitHub Release 直链。
  - `repository: local` 时对仓库内 `charts/<chart>/` 执行 `helm package`。

## CI 产物（dist/）

| 目录 | 内容 |
|---|---|
| `dist/bin/` | cfssl、cfssljson、docker-compose、runc、calicoctl、nginx（编译产物） |
| `dist/tarball/` | docker、cri-dockerd、containerd、crictl、cni、etcd、k8s client/server/node、helm、caddy、harbor 安装包 |
| `dist/charts/` | tigera-operator、Calico CRD、coredns、nodelocaldns 离线 tgz |
| `dist/images/<chart>/` | 各 Chart 渲染出的镜像，docker save 后 gzip 为 `.tar.gz` |
| `dist/images/pause/` | pause 镜像离线归档 |
| `dist/SHA256SUMS` | 全部发布物校验清单 |

## 触发方式

- **Release 创建**：发布 Release 时自动构建并上传附件。
- **手动触发**：Actions 中 `workflow_dispatch`，可指定 Release tag。

## 说明

- 仅 `nginx/Dockerfile` 内做完整性校验，采用 nginx 官方 PGP 签名（`.asc`）校验；其余上游资产仅做下载成功校验。
- Chart 镜像解析基于 `helm template` 渲染结果提取 `image` 字段；由 CR/后续配置注入的镜像可能无法在模板期提取，脚本会跳过并告警。
