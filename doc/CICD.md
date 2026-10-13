# Austin CI/CD：本机 WSL 演练

本次 GitHub CI 与本机手动发布、部署的逐步操作和每一步的含义，见 [操作记录与复现步骤](CICD-WALKTHROUGH.md)。

目标是亲手跑通 CI/CD 并能在面试中准确说明。当前 `hxy123-google/ci-cd` 是公开仓库：先用 GitHub 托管 Runner 验证提交触发的 CI；本机 WSL 已手动验证 Harbor 镜像发布、Docker Compose 部署和自动回退。当前暂不在公开仓库接入 WSL 自托管 Runner，因此 GitHub 不会自动执行发布与部署。以后若改为私有仓库，可按第 4、5 节接通自动流程。

## 1. 演练架构

```text
个人公开 GitHub 仓库
  PR / push ────────> GitHub 托管 Runner：Maven 构建、部署回退脚本测试

本机 WSL 手动演练 ────> Harbor 镜像仓库 ──> Docker Compose 部署
                                             健康检查失败则恢复旧镜像

以后改为私有仓库并注册 Runner 后：默认分支 push ──> 自动发布、部署
                                    手动输入旧 SHA ──> 人工回退
```

发布和部署作业只接受个人仓库默认分支（`main`）的提交，并要求标签为 `austin-lab` 的自托管 Runner。当前不注册 Runner，也不设置 Harbor 仓库变量，所以 GitHub 上只运行 CI。[GitHub 建议自托管 Runner 用于私有仓库](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/add-runners)，因为公开仓库的 PR 可能运行不可信代码。未来启用 Runner 时，WSL 和电脑必须保持开机。当前实验机是 Ubuntu 22.04 WSL，Docker Engine 和 Compose 已安装。约 8 GB 的 WSL 内存会比较紧；若 Harbor 与现有 Kafka、Flink 等中间件同时运行导致内存不足，先检查占用，再决定是否手动停止不需要的容器。

## 2. 准备个人 GitHub 仓库

个人仓库 `https://github.com/hxy123-google/ci-cd` 已创建并完成首次推送，默认分支是 `main`。本地 `origin` 仍指向项目作者 `ZhongFuCheng3y/austin`，个人仓库已作为 `myrepo` 远程添加。检查远程：

```bash
git remote -v
```

当前个人仓库的默认分支是 `main`，原工作区本地分支是 `master`，仓库已经由 Git 初始化，因此不要再执行 GitHub 页面上的 `git init`、`git branch -M main` 或覆盖上游 `origin`。首次提交已在独立工作区完成，提交号为 `1e733713eae8bb6b42841849f2aebe167c14d364`；原工作区的大量包名迁移、Kafka 等未提交改动没有进入个人仓库。后续提交仍应先核对范围。CI 运行部署回退脚本测试与 Maven 打包；现有 Java 测试依赖外部服务，演练阶段没有纳入自动测试。

## 3. 在 WSL 安装本地 Harbor

本项目的 `deploy/prepare-harbor-wsl.sh` 从 [Harbor 官方发布页](https://github.com/goharbor/harbor/releases)下载 v2.15.4 在线安装器，在 `~/austin-harbor` 生成实验 CA、`harbor.local` 证书、随机初始密码和配置。证书与密码都留在 WSL 用户目录，不进入 Git。Harbor 使用 `https://harbor.local:8443`；`harbor.local` 是本机实验域名，不需要购买公网域名。

在 WSL 中进入本项目目录后执行：

```bash
bash deploy/prepare-harbor-wsl.sh
sudo bash deploy/trust-harbor-wsl.sh "$HOME/austin-harbor/certs/ca.crt"
```

然后在 Windows PowerShell 执行一次 `wsl --shutdown`，重新打开 WSL，让 `harbor.local` 的 hosts 配置持久生效。这个命令会暂时中断 WSL 内的所有容器；在不影响其他工作时执行。重新进入 WSL 后运行：

```bash
cd "$HOME/austin-harbor/harbor"
sudo ./install.sh
curl -fsS https://harbor.local:8443/api/v2.0/health
```

安装器会拉取多个 Harbor 镜像，首次启动需要一些时间。若 WSL 再次停止，重新打开后在 `~/austin-harbor/harbor` 执行 `sudo docker compose up -d`。`trust-harbor-wsl.sh` 配置 WSL 的 hosts 和实验 CA 信任；若 `docker login harbor.local:8443` 报证书错误，核对 `/etc/docker/certs.d/harbor.local:8443/ca.crt` 和 Docker 状态。管理员初始密码保存在 `~/austin-harbor/admin-password`。

在 Windows 宿主机打开 Harbor 网页时，使用系统 Edge/Chrome 访问 `https://127.0.0.1:8443`。浏览器如果提示 `ERR_CERT_AUTHORITY_INVALID`，是因为 Windows 尚未信任这次实验生成的 CA。在 Windows PowerShell 中执行以下命令，仅将公有 CA 证书导入当前用户的信任库；私钥仍留在 WSL：

```powershell
$ca = Join-Path $env:TEMP 'austin-harbor-lab-ca.crt'
wsl -e bash -lc 'cat "$HOME/austin-harbor/certs/ca.crt"' | Set-Content -LiteralPath $ca -Encoding ascii
certutil -user -f -addstore Root $ca
```

然后重新打开 `https://127.0.0.1:8443`，用户名为 `admin`，在 WSL 执行 `cat ~/austin-harbor/admin-password` 查看初始密码。安装脚本签发的证书同时包含 `harbor.local`、`localhost` 和 `127.0.0.1`；旧安装若没有这些名称，需要重新签发服务证书。实验结束后，可从 Windows 当前用户的“受信任的根证书颁发机构”中删除 `Austin Harbor Lab CA`。WSL 内仍使用 `https://harbor.local:8443` 供 Docker 推送和拉取镜像。

先在 Windows PowerShell 的项目目录打包：

```bash
mvn -B -ntp -pl austin-web -am clean package -DskipTests
```

再从 WSL 进入同一个项目目录构建实验镜像，创建私有 `demo` 项目并完成一次推送和拉取。源码位于 Windows 磁盘，在 WSL 的 `/mnt/d` 路径运行 Maven 会明显慢一些；镜像构建仍在 WSL 中执行：

```bash
docker build -t austin-cicd:local .
bash deploy/smoke-harbor-wsl.sh
```

再创建两个[项目 Robot Account](https://goharbor.io/docs/main/working-with-projects/project-configuration/create-robot-accounts/)：CI 账号允许 Pull + Push Repository，部署账号只允许 Pull Repository。脚本通过 Harbor API 创建账号，将一次性返回的用户名和 secret 存在 WSL 用户目录的 `~/austin-harbor/robots/ci-push.json`、`deploy-pull.json`，不会输出 secret，也不会写进 Git：

```bash
bash deploy/prepare-harbor-robots-wsl.sh
docker tag austin-cicd:local austin-cicd:local-fixed
bash deploy/verify-harbor-robots-wsl.sh
```

第二个脚本确认 CI 账号能推送、部署账号能拉取且推送被拒绝。这两个账号有效期 365 天，过期前需要在 Harbor 刷新 secret 并更新 GitHub Secrets。若在 Web 界面管理 Harbor，建议给 `sha-*` 标签设置[不可变规则](https://goharbor.io/docs/main/working-with-projects/working-with-images/create-tag-immutability-rules/)，并保留至少两个历史镜像供回退。

## 4. 后续可选：注册 WSL 自托管 Runner

当前仓库保持公开，本节暂不执行。若将仓库改为私有，可进入 **Settings → Actions → Runners → New self-hosted runner**，选择 Linux x64。按照 GitHub 页面给出的命令在 WSL 用户目录下载安装 Runner；注册时添加自定义标签 `austin-lab`，然后用 `./run.sh` 启动。工作流的发布和部署作业使用 `runs-on: [self-hosted, linux, x64, austin-lab]`，这四个标签都必须匹配。注册令牌和命令中的密钥不要发到聊天或写进 Git。Runner 用户必须能执行 `docker`；本机用户已经属于 `docker` 组。详见 [GitHub Runner 标签文档](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/use-in-a-workflow)。

## 5. 准备应用数据；GitHub 变量留待接入 Runner 时设置

在本项目目录执行 `bash deploy/prepare-local-app-wsl.sh`，脚本会在 WSL 用户目录创建 `~/austin-cicd/.env`，只存放实验环境的随机密码，并复制 Compose、部署脚本和初始化 SQL。已有 `.env` 会被保留。等价的手动创建方式是：

```bash
mkdir -p "$HOME/austin-cicd"
chmod 700 "$HOME/austin-cicd"
umask 077
printf 'MYSQL_ROOT_PASSWORD=%s\nREDIS_PASSWORD=%s\n' \
  "$(openssl rand -hex 24)" "$(openssl rand -hex 24)" > "$HOME/austin-cicd/.env"
chmod 600 "$HOME/austin-cicd/.env"
```

当前公开仓库不设置 `HARBOR_REGISTRY`、`HARBOR_PROJECT` 和 `DEPLOY_ENABLED`，让发布与部署作业保持跳过状态。以后改为私有仓库并注册 Runner 后，在 **Settings → Secrets and variables → Actions** 中设置：

| 类型 | 名称 | 值 |
| --- | --- | --- |
| Variable | `HARBOR_REGISTRY` | `harbor.local:8443` |
| Variable | `HARBOR_PROJECT` | `demo` |
| Repository secret | `HARBOR_PUSH_USERNAME` / `HARBOR_PUSH_PASSWORD` | `~/austin-harbor/robots/ci-push.json` 中的 `name` 与 `secret` |
| `production` environment secret | `HARBOR_PULL_USERNAME` / `HARBOR_PULL_PASSWORD` | `~/austin-harbor/robots/deploy-pull.json` 中的 `name` 与 `secret` |

将来接入 Runner 时，第一次默认分支 push 先验证 CI 和发布成功，再把 `DEPLOY_ENABLED` 设为 `true` 并推送第二个版本触发自动部署。也可以在 Actions 里手动运行 **Deploy or roll back**，输入已有镜像的 `sha-<完整 40 位提交 SHA>`。本机部署工作流把 Compose 文件和 SQL 复制到 `~/austin-cicd`，无需 SSH 密钥。MySQL 只在空数据卷初始化时运行 `doc/sql/austin.sql`；该文件包含 `drop database`，不要对已有数据库手工重放。

## 6. 验证与回退

本地先检查脚本和打包；Maven 命令可在 Windows PowerShell 执行，Bash 命令在 WSL 执行：

```bash
bash deploy/test-deploy.sh
mvn -B -ntp -pl austin-web -am clean package -DskipTests
```

首次发布后在 Harbor 项目中确认 `austin:sha-<SHA>`。部署成功后在 WSL 检查：

```bash
cat "$HOME/austin-cicd/current-image"
cd "$HOME/austin-cicd"
docker compose -f compose.yml ps
curl -fsS http://127.0.0.1:7777/actuator/health
```

再发布一个新版本，确认 `previous-image` 记录旧镜像。在 Actions 中手动运行 **Deploy or roll back**，填入旧 `sha-<SHA>`，验证 `current-image` 和健康检查恢复。部署脚本在新版本健康检查失败时也会尝试恢复原镜像；`deploy/test-deploy.sh` 用模拟 Docker 和健康响应覆盖这个路径。想在接入 GitHub 前验证真实 Compose 回退，可先构建 `austin-cicd:local-fixed` 并运行：

```bash
docker tag austin-cicd:local austin-cicd:local-fixed
bash deploy/prepare-local-app-wsl.sh
bash deploy/exercise-local-rollback-wsl.sh
```

此脚本在 Harbor 的私有 `lab-test` 项目中推送一个可用 Austin 镜像和一个故意错误的镜像，再调用同一个 `deploy.sh`，核对坏版本失败后 `current-image` 与健康状态恢复。`sha-111…`、`sha-222…` 是**演练专用的合成标签**，不对应 Git 提交，不应作为正式发布版本。执行后本机应用停留在 `lab-test` 的可用镜像上；本次正式发布已切换至 `demo` 项目的提交 SHA 镜像。若重新运行该脚本，当前应用会再次切换到演练镜像。初次部署没有旧镜像可恢复。Compose 单机更新会有短暂中断；镜像回退也不会回滚数据库结构或内容。

## 7. 面试时如实说明

“我用 GitHub Actions 的托管 Runner 验证构建与部署回退脚本。本机 WSL 中，我搭了 Harbor，用 Docker Compose 部署 Austin，并故意部署坏镜像验证了健康检查失败时自动恢复旧版。当前 GitHub 仓库是公开的，所以没有把个人电脑注册为自托管 Runner，GitHub 还不会自动发布到本机 Harbor。后续若接通自动 CD，我会使用私有仓库的 Runner 和按提交 SHA 标记的镜像；在公司环境还会让 Runner、Harbor、部署机分开，并单独处理数据库迁移。”
