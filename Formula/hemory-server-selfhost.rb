class HemoryServerSelfhost < Formula
  desc "Hemory Self-Host Server — vault + worker + pi-bridge 一键部署"
  homepage "https://hemory.net"
  url "https://github.com/openhemory/hemory-server-selfhost/releases/download/v0.9.42/hemory-server-0.9.42.tar.gz"
  sha256 "d1324947fa403e68189f0c1ef46ca053718715e7a4c90d7a93431da96715946f"
  version "0.9.42"
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

    # 安装 hemory-shared + vault + worker 到共享 venv
    # 强制从源码编译 cryptography 以避免 dylib headerpad 问题，其他依赖使用二进制包
    system pip, "install", "--only-binary", ":all:", "--no-binary", "cryptography", "./shared/python"
    system pip, "install", "--only-binary", ":all:", "--no-binary", "cryptography", "./vault"
    system pip, "install", "--only-binary", ":all:", "--no-binary", "cryptography", "./worker"

    # wespeaker 不在 PyPI，需要 --no-deps 单独安装（避免拉入不兼容的依赖）
    system pip, "install", "--no-deps", "git+https://github.com/wenet-e2e/wespeaker.git"

    # 安装 pi-bridge
    pi_bridge = libexec / "pi-bridge"
    pi_bridge.mkpath
    cp buildpath / "pi-bridge" / "package.json", pi_bridge
    cp buildpath / "pi-bridge" / "package-lock.json", pi_bridge
    cp buildpath / "pi-bridge" / "server.mjs", pi_bridge
    cp_r buildpath / "pi-bridge" / "scripts", pi_bridge / "scripts"
    system "npm", "ci", "--production", "--prefix", pi_bridge

    # 复制默认配置模板（含 prompts）
    defaults = libexec / "defaults"
    defaults.mkpath
    cp buildpath / "pi-bridge" / "defaults" / "providers.example.json", defaults
    cp_r buildpath / "pi-bridge" / "defaults" / "prompts", defaults / "prompts" if (buildpath / "pi-bridge" / "defaults" / "prompts").exist?

    # 同时复制 defaults 到 pi-bridge 目录下，供 server.mjs initializePrompts() 使用
    cp_r buildpath / "pi-bridge" / "defaults", pi_bridge / "defaults"

    # 复制 agent_prompt_template（vault 代码通过相对路径引用）
    apt_dst = venv / "lib" / "python3.11" / "agent_prompt_template"
    cp_r buildpath / "vault" / "agent_prompt_template", apt_dst if (buildpath / "vault" / "agent_prompt_template").exist?

    # 复制静态文件（含 docs/、qrcode.min.js、favicon 等）
    cp_r buildpath / "vault" / "static", libexec / "static" if (buildpath / "vault" / "static").exist?

    # 内嵌 ASR 模型（paraformer），安装后无需联网下载
    model_src = buildpath / "models" / "sherpa-onnx-paraformer-zh-small-2024-03-09"
    if model_src.exist?
      model_dst = libexec / "models" / "sherpa-onnx-paraformer-zh-small-2024-03-09"
      model_dst.mkpath
      cp model_src / "model.int8.onnx", model_dst
      cp model_src / "tokens.txt", model_dst
    end

    # 内嵌 VAD 模型（silero_vad.onnx），安装后无需联网下载
    vad_src = buildpath / "models" / "silero_vad.onnx"
    if vad_src.exist?
      (libexec / "models").mkpath
      cp vad_src, libexec / "models" / "silero_vad.onnx"
    end

    # 安装服务管理脚本到 libexec（内部实现，不直接暴露给用户）
    cp buildpath / "selfhost" / "hemory-server-selfhost", libexec / "hemory-server-selfhost"
    chmod 0755, libexec / "hemory-server-selfhost"

    # 安装 hemory CLI（ops 目录）— 统一入口
    ops = libexec / "ops"
    ops.mkpath
    cp buildpath / "vault" / "ops" / "hemory", ops / "hemory"
    cp_r buildpath / "vault" / "ops" / "commands", ops / "commands"
    cp_r buildpath / "vault" / "ops" / "lib", ops / "lib"
    chmod 0755, ops / "hemory"

    # hemory 作为唯一的 bin 命令
    (bin / "hemory").write <<~SH
      #!/bin/bash
      exec "#{libexec}/ops/hemory" "$@"
    SH
    chmod 0755, bin / "hemory"

    # 安装 worker.json.example
    (etc / "hemory-server-selfhost").mkpath
    cp buildpath / "worker" / "worker.json.example", etc / "hemory-server-selfhost" / "worker.json.example"
  end

  def caveats
    <<~EOS
      系统依赖:
        ✓ Python 3.11+  (已安装)
        ✓ Node.js 20+   (已安装)
        ✓ FFmpeg        (已安装)

      配置文件:
        ~/.hemory/vault/.hemoryserver/worker.json

      首次使用:
        1. 启动服务:
           hemory start

        2. 或设为开机自启:
           brew services start hemory-server-selfhost

        3. 初始化与管理:
           hemory init --password "your-password"
           hemory config show --password "your-password"
           hemory health

        4. 停止服务:
           hemory stop

        5. 查看状态:
           hemory status

      所有操作通过统一的 hemory 命令完成，输入 hemory --help 查看全部子命令。

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
    run [opt_bin / "hemory", "start", "--foreground"]
    keep_alive true
    log_path var / "log" / "hemory-server-selfhost.log"
    error_log_path var / "log" / "hemory-server-selfhost.log"
    working_dir HOMEBREW_PREFIX
  end

  test do
    assert_match "Hemory Selfhost CLI", shell_output("#{bin}/hemory --help")
  end
end
