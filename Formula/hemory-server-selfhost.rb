class HemoryServerSelfhost < Formula
  desc "Hemory Self-Host Server — vault + worker + pi-bridge 一键部署"
  homepage "https://hemory.net"
  url "https://github.com/openhemory/hemory-server-selfhost/releases/download/v0.9.3/hemory-server-0.9.3.tar.gz"
  sha256 "ea9d65c8d318d5e37094409e6546ef4b0443c99e75f85f6bcf7c4d83ccb46fbd"
  version "0.9.3"
  license "MIT"

  depends_on "python@3.11"
  depends_on "node@20"
  depends_on "ffmpeg"
  depends_on "rust" => :build  # 从源码编译 cryptography 需要

  def install
    venv = libexec / "venv"

    # 创建共享 Python venv
    system Formula["python@3.11"].opt_bin / "python3.11", "-m", "venv", venv
    pip = venv / "bin" / "pip"

    # 升级 pip 和安装构建工具
    system pip, "install", "--upgrade", "pip", "setuptools", "wheel"

    # 安装 vault + worker 到共享 venv
    # 强制从源码编译 cryptography 以避免 dylib headerpad 问题
    system pip, "install", "--no-cache-dir", "--no-binary", "cryptography", "./vault"
    system pip, "install", "--no-cache-dir", "--no-binary", "cryptography", "./worker"

    # 安装 pi-bridge
    pi_bridge = libexec / "pi-bridge"
    pi_bridge.mkpath
    cp buildpath / "pi-bridge" / "package.json", pi_bridge
    cp buildpath / "pi-bridge" / "package-lock.json", pi_bridge
    cp buildpath / "pi-bridge" / "server.mjs", pi_bridge
    system "npm", "ci", "--production", "--prefix", pi_bridge

    # 复制默认配置模板
    defaults = libexec / "defaults"
    defaults.mkpath
    cp buildpath / "pi-bridge" / "defaults" / "providers.example.json", defaults

    # 复制静态文件
    (libexec / "static").mkpath
    cp_r buildpath / "vault" / "static" / "docs", libexec / "static" / "docs" if (buildpath / "vault" / "static" / "docs").exist?

    # 安装启动脚本
    bin.install buildpath / "selfhost" / "hemory-server-selfhost"

    # 安装 .env.example
    (etc / "hemory-server-selfhost").mkpath
    cp buildpath / "selfhost" / ".env.example", etc / "hemory-server-selfhost" / ".env.example"
  end

  def caveats
    <<~EOS
      配置文件:
        #{etc}/hemory-server-selfhost/.env.example

      首次使用:
        1. 设置管理密码:
           export HEMORY_ADMIN_PASSWORD=your-password

        2. (可选) 设置 LLM API Key:
           export LLM_API_KEY=sk-xxx

        3. 启动服务:
           hemory-server-selfhost start

        4. 或设为开机自启:
           brew services start hemory-server-selfhost

      数据目录: ~/.hemory/vault/
      配置目录: ~/.hemory/vault/.hemoryserver/
      日志目录: ~/.hemory/vault/.hemoryserver/logs/
    EOS
  end

  service do
    run [opt_bin / "hemory-server-selfhost", "start", "--foreground"]
    keep_alive true
    log_path var / "log" / "hemory-server-selfhost.log"
    error_log_path var / "log" / "hemory-server-selfhost.log"
    working_dir HOMEBREW_PREFIX
  end

  test do
    assert_match "hemory-server-selfhost", shell_output("#{bin}/hemory-server-selfhost 2>&1", 1)
  end
end
