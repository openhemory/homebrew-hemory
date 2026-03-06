class HemoryServerSelfhost < Formula
  desc "Hemory Self-Host Server — vault + worker + pi-bridge 一键部署"
  homepage "https://hemory.net"
  url "https://github.com/openhemory/hemory-server-selfhost/releases/download/v0.9.28/hemory-server-0.9.28.tar.gz"
  sha256 "f759915dda03dcf62abe6664a205df4f3bd9feb0066213c001cfd2833e60391b"
  version "0.9.28"
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
    # 强制从源码编译 cryptography 以避免 dylib headerpad 问题，其他依赖使用二进制包
    system pip, "install", "--only-binary", ":all:", "--no-binary", "cryptography", "./vault"
    system pip, "install", "--only-binary", ":all:", "--no-binary", "cryptography", "./worker"

    # 安装 pi-bridge
    pi_bridge = libexec / "pi-bridge"
    pi_bridge.mkpath
    cp buildpath / "pi-bridge" / "package.json", pi_bridge
    cp buildpath / "pi-bridge" / "package-lock.json", pi_bridge
    cp buildpath / "pi-bridge" / "server.mjs", pi_bridge
    system "npm", "ci", "--production", "--prefix", pi_bridge

    # 复制默认配置模板（含 prompts）
    defaults = libexec / "defaults"
    defaults.mkpath
    cp buildpath / "pi-bridge" / "defaults" / "providers.example.json", defaults
    cp_r buildpath / "pi-bridge" / "defaults" / "prompts", defaults / "prompts" if (buildpath / "pi-bridge" / "defaults" / "prompts").exist?

    # 同时复制 defaults 到 pi-bridge 目录下，供 server.mjs initializePrompts() 使用
    cp_r buildpath / "pi-bridge" / "defaults", pi_bridge / "defaults"

    # 复制静态文件
    (libexec / "static").mkpath
    cp_r buildpath / "vault" / "static" / "docs", libexec / "static" / "docs" if (buildpath / "vault" / "static" / "docs").exist?

    # 安装启动脚本
    bin.install buildpath / "selfhost" / "hemory-server-selfhost"

    # 安装 worker.conf.example
    (etc / "hemory-server-selfhost").mkpath
    cp buildpath / "worker" / "worker.conf.example", etc / "hemory-server-selfhost" / "worker.conf.example"
  end

  def caveats
    <<~EOS
      系统依赖:
        ✓ Python 3.11+  (已安装)
        ✓ Node.js 20+   (已安装)
        ✓ FFmpeg        (已安装)

      配置文件:
        ~/.hemory/vault/.hemoryserver/worker.conf

      首次使用:
        1. 启动服务:
           hemory-server-selfhost start

        2. 或设为开机自启:
           brew services start hemory-server-selfhost

      数据目录: ~/.hemory/vault/
      配置目录: ~/.hemory/vault/.hemoryserver/
      日志目录: ~/.hemory/vault/.hemoryserver/logs/

      故障排查:
        如果 Worker 报错 "FFmpeg not found"，请确保 FFmpeg 在 PATH 中：
          which ffmpeg
        
        如果未找到，请重新安装：
          brew reinstall ffmpeg
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
