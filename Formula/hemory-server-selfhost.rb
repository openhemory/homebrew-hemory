class HemoryServerSelfhost < Formula
  desc "Hemory Self-Host Server — vault + worker + pi-bridge 一键部署"
  homepage "https://hemory.net"
  url "https://github.com/openhemory/hemory-server-selfhost/releases/download/v0.9.88/hemory-server-0.9.88.tar.gz"
  sha256 "e6602f63133616a8fd4ffbb9c9f7c168f48c22e822a7cf31dfb35a8853ca344f"
  version "0.9.88"
  license "MIT"

  depends_on "python@3.11"
  depends_on "node@20"
  depends_on "ffmpeg"
  depends_on "rust" => :build  # 从源码编译 cryptography 需要

  # venv 内的预编译 .so (pydantic_core 等) Mach-O header 空间不足，
  # Homebrew relocate 会失败；venv 内的 .so 不需要被外部链接，跳过即可
  skip_clean "libexec"

  def install
    # 升级前停止正在运行的旧服务，避免端口占用和文件锁冲突
    hemory_bin = HOMEBREW_PREFIX / "bin" / "hemory"
    if hemory_bin.exist?
      system hemory_bin, "stop" rescue nil
      sleep 1
    end
    # 兜底：如果 PID 文件方式未能停止，按端口查找并仅杀 Hemory 相关进程
    [8032, 8034, 8035, 8434].each do |port|
      pids = `lsof -ti :#{port} 2>/dev/null`.strip
      next if pids.empty?
      pids.split("\n").each do |pid|
        pid = pid.strip.to_i
        next if pid <= 0
        cmd = `ps -p #{pid} -o command= 2>/dev/null`.strip
        next unless cmd.match?(/hemory|pi-bridge|server\.mjs/)
        Process.kill("TERM", pid) rescue nil
      end
    end
    sleep 1

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

    # wespeaker（从本地 wheel 安装，--no-deps 避免拉入 hdbscan/umap 等不兼容依赖）
    wespeaker_whl = Dir[buildpath / "vendor" / "wespeaker-*.whl"].first
    if wespeaker_whl
      system pip, "install", "--no-deps", wespeaker_whl
    else
      system pip, "install", "--no-deps", "git+https://github.com/wenet-e2e/wespeaker.git"
    end

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

    # 复制 vault 数据文件（genvoiceprint.json 等）
    cp_r buildpath / "vault" / "data", libexec / "data" if (buildpath / "vault" / "data").exist?

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

    # 内嵌 WeSpeaker 中文声纹模型（cnceleb_resnet34），安装后无需联网下载
    wespeaker_src = buildpath / "models" / "wespeaker-chinese"
    if wespeaker_src.exist?
      wespeaker_dst = libexec / "models" / "wespeaker-chinese"
      wespeaker_dst.mkpath
      cp wespeaker_src / "avg_model.pt", wespeaker_dst
      cp wespeaker_src / "config.yaml", wespeaker_dst
    end

    # 内嵌 ECAPA gender 模型（voice-gender-classifier），安装后无需联网下载
    gender_src = buildpath / "models" / "voice-gender-classifier"
    if gender_src.exist?
      gender_dst = libexec / "models" / "voice-gender-classifier"
      gender_dst.mkpath
      cp gender_src / "model.safetensors", gender_dst
      cp gender_src / "config.json", gender_dst
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
