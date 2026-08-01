"""python3 -m jarvis_brain [serve|chat|doctor]

serve   给 Jarvis.app 用的常驻模式（默认）
chat    终端里直接对话，不需要起 App —— 调工具、调 prompt 时用这个最快
doctor  自检：配置、Key、网络、搜索后端
"""
import json
import os
import sys
import time

from . import config
from .server import BrainServer
from .session import SessionCoordinator
from .tools import registry


def _watch_parent(server, interval=2.0):
    """父进程没了就自杀。

    宿主被 `launchctl bootout` 或 SIGKILL 掉时来不及回收子进程，Brain 会变成孤儿
    挂在那儿；下一个宿主起来后两个 Brain 抢同一个 socket，症状是"连上了但没反应"。
    macOS 没有 PDEATHSIG，只能自己盯 ppid。
    """
    import threading

    original = os.getppid()
    server.log("看门狗启动：ppid=%d" % original)

    def loop():
        while True:
            time.sleep(interval)
            current = os.getppid()
            if current == original and current != 1:
                continue
            server.log("看门狗触发：父进程已退出（ppid %d → %d），Brain 一并退出" % (original, current))
            # 只删 socket 文件，不 close listener——从别的线程关掉它会让
            # 主线程的 accept() 抛异常，在 os._exit 落地前刷出半截 traceback。
            try:
                if os.path.exists(server.socket_path):
                    server.log("看门狗清理 socket：%s" % server.socket_path)
                    os.unlink(server.socket_path)
            except Exception:
                pass
            os._exit(0)

    thread = threading.Thread(target=loop, daemon=True)
    thread.start()


def _serve():
    import signal

    config.write_template()
    server = BrainServer(config.load())
    _watch_parent(server)

    # 宿主退出时发的是 SIGTERM，默认行为会直接杀掉进程、留下一个连不上的
    # socket 文件，下一次启动的宿主会先撞上它再退避重连。收干净一点。
    def bye(signum, frame):
        server.shutdown()
        sys.exit(0)

    signal.signal(signal.SIGTERM, bye)
    signal.signal(signal.SIGINT, bye)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.shutdown()


def _chat():
    """终端 REPL。原生工具在这里没有宿主执行，直接返回不可用。"""
    config.write_template()
    cfg = config.load()
    done = {"flag": False}

    def emit(message):
        kind = message.get("type")
        if kind == "assistant_delta":
            sys.stdout.write(message["text"])
            sys.stdout.flush()
        elif kind == "assistant_delta_zh":
            sys.stdout.write("\033[36m" + message["text"] + "\033[0m")
            sys.stdout.flush()
        elif kind == "assistant_reasoning_delta":
            sys.stdout.write("\033[2m" + message["text"] + "\033[0m")
            sys.stdout.flush()
        elif kind == "tool_started":
            print("\n\033[36m⚙ %s\033[0m" % message["summary"], flush=True)
        elif kind == "tool_result":
            mark = "✓" if message["success"] else "✗"
            print("\033[36m%s %s\033[0m" % (mark, message["summary"]), flush=True)
        elif kind == "tool_confirm_request":
            answer = input("\n\033[33m需要确认：%s  [y/N] \033[0m" % message["summary"])
            session.resolve_pending(message["request_id"],
                                    {"approved": answer.strip().lower() in ("y", "yes", "是")})
        elif kind == "native_tool_request":
            session.resolve_pending(message["request_id"],
                                    {"error": "终端模式没有宿主 App，原生工具不可用"})
        elif kind == "error":
            print("\n\033[31m! %s\033[0m" % message["message"], flush=True)
        elif kind == "turn_done":
            done["flag"] = True

    session = SessionCoordinator(cfg, emit, lambda m: None)
    print("J.A.R.V.I.S. 终端模式（%s）。Ctrl-C 退出，:new 清空上下文。\n" % cfg["deepseek"]["model"])

    while True:
        try:
            text = input("\033[1m› \033[0m").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            return
        if not text:
            continue
        if text == ":new":
            session.reset()
            print("（上下文已清空）")
            continue

        done["flag"] = False
        session.handle_user_message(text, "cli")
        while not done["flag"]:
            time.sleep(0.05)
        print("\n")


def _doctor():
    cfg = config.load()
    print("配置文件      %s%s" % (
        config.CONFIG_PATH,
        "" if os.path.exists(config.CONFIG_PATH) else "（不存在，将用默认值）"))
    print("模型          %s @ %s" % (cfg["deepseek"]["model"], cfg["deepseek"]["base_url"]))
    key = cfg["deepseek"]["api_key"]
    print("API Key       %s" % ("已配置 %s…%s" % (key[:6], key[-4:]) if len(key) > 12 else
                                ("已配置（很短，可能有误）" if key else "\033[31m未配置\033[0m")))
    print("文件访问范围  %s" % "、".join(cfg["tools"]["fs_roots"]))
    print("shell_run     %s" % ("已启用" if cfg["tools"]["allow_shell"] else "已禁用"))
    print("工具数量      %d（原生 %d / 本地 %d）" % (
        len(registry.TOOLS),
        sum(1 for t in registry.TOOLS if t["executor"] == "native"),
        sum(1 for t in registry.TOOLS if t["executor"] == "python"),
    ))

    print("\n— 联网搜索自检 —")
    from .tools.web import web_search
    result = web_search({"query": "DeepSeek API", "count": 3},
                        {"search": cfg["search"], "max_output_chars": 4000})
    if result.get("error"):
        print("\033[31m%s\033[0m" % result["error"])
    else:
        print("后端 %s，%d 条结果：" % (result["backend"], result["count"]))
        for item in result["results"]:
            print("  · %s\n    %s" % (item["title"][:70], item["url"][:90]))

    if key:
        print("\n— 模型连通性自检 —")
        from .providers.deepseek import DeepSeekProvider, ProviderError
        provider = DeepSeekProvider(cfg["deepseek"])
        try:
            chunks = []
            for kind, value in provider.stream(
                    [{"role": "user", "content": "只回复两个字：在的"}], tools=None):
                if kind == "text":
                    chunks.append(value)
            print("\033[32m通\033[0m — 模型回复：%s" % "".join(chunks).strip()[:40])
        except ProviderError as exc:
            print("\033[31m%s\033[0m" % exc)


def _set_key():
    """把 API Key 存进 Keychain。

    App 是 LaunchAgent 拉起的，拿不到你 shell 里的环境变量，
    所以 Key 必须落到 Keychain 或 config.json，否则 App 里永远是"未配置"。
    """
    import getpass
    import subprocess

    key = (sys.argv[2] if len(sys.argv) > 2 else "").strip()
    if not key:
        key = os.environ.get("DEEPSEEK_API_KEY", "").strip()
        if key:
            print("从环境变量 DEEPSEEK_API_KEY 读到 %s…%s" % (key[:6], key[-4:]))
        else:
            key = getpass.getpass("DeepSeek API Key: ").strip()
    if not key:
        print("没给 Key，放弃。")
        sys.exit(1)

    subprocess.run(["security", "delete-generic-password", "-s", config.KEYCHAIN_SERVICE],
                   capture_output=True)
    result = subprocess.run(
        ["security", "add-generic-password", "-U", "-a", os.environ.get("USER", "jarvis"),
         "-s", config.KEYCHAIN_SERVICE, "-w", key, "-T", ""],
        capture_output=True, text=True)
    if result.returncode != 0:
        print("写入 Keychain 失败：%s" % result.stderr.strip())
        sys.exit(1)
    print("已存入 Keychain（服务名 %s）。删除用："
          "security delete-generic-password -s %s" % (config.KEYCHAIN_SERVICE,
                                                      config.KEYCHAIN_SERVICE))


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else "serve"
    if command == "serve":
        _serve()
    elif command == "chat":
        _chat()
    elif command == "doctor":
        _doctor()
    elif command == "set-key":
        _set_key()
    elif command == "schema":
        print(json.dumps(registry.openai_schema(), ensure_ascii=False, indent=2))
    else:
        print(__doc__)
        sys.exit(1)


if __name__ == "__main__":
    main()
