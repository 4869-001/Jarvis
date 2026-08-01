"""网易云音乐控制：播放/暂停/切歌/打开我喜欢。

media_control 改用 osascript 直接发按键给网易云，不再依赖 CGEvent 系统媒体键。
原因：网易云不一定注册为 macOS "正在播放" App，系统媒体键事件可能不被路由到它。
"""
import subprocess
import time


def media_control(args, cfg):
    """播放/暂停/下一首/上一首。直接发送键盘快捷键到网易云音乐。"""
    action = args.get("action")
    if not action:
        return {"error": "缺少 action（play_pause / next / previous）"}

    # macOS 媒体键对网易云不稳定，改用 System Events 直接发按键
    shortcuts = {
        "play_pause": "keystroke space",
        "next":        "key code 124 using command down",   # Cmd+Right
        "previous":    "key code 123 using command down",   # Cmd+Left
    }
    keystroke = shortcuts.get(action)
    if not keystroke:
        return {"error": "未知操作：%s，可选 play_pause / next / previous" % action}

    script = '''
tell application "System Events"
    tell process "NeteaseMusic"
        %s
    end tell
end tell
''' % keystroke

    try:
        subprocess.run(
            ["osascript", "-e", script],
            capture_output=True, text=True, timeout=10, check=True)
        return {"action": action}
    except subprocess.CalledProcessError as exc:
        return {"error": "媒体控制失败：%s" % (exc.stderr.strip() or str(exc))}
    except Exception as exc:
        return {"error": "媒体控制异常：%s" % exc}


def music_play_favorite(args, cfg):
    """打开网易云，导航到「我喜欢的音乐」并开始播放。"""
    script = '''
-- 1. 确保网易云在运行
tell application "NetEaseMusic" to activate
delay 0.3

-- 2. 用搜索定位「我喜欢的音乐」
tell application "System Events"
    tell process "NeteaseMusic"
        -- Cmd+F 打开搜索
        keystroke "f" using command down
        delay 0.3
        -- 输入「我喜欢的音乐」
        keystroke "我喜欢的音乐"
        delay 0.5
        -- 回车选中第一个结果（通常就是我喜欢的音乐歌单）
        keystroke return
        delay 0.8
        -- 再回车开始播放
        keystroke return
    end tell
end tell
'''
    try:
        # 先检查网易云是否已在运行
        check = subprocess.run(
            ["pgrep", "-f", "NeteaseMusic"],
            capture_output=True, text=True, timeout=5)
        was_running = check.returncode == 0

        subprocess.run(
            ["osascript", "-e", script],
            capture_output=True, text=True, timeout=15, check=True)

        return {
            "opened": True,
            "was_running": was_running,
            "playlist": "我喜欢的音乐",
        }
    except subprocess.CalledProcessError as exc:
        return {"error": "无法控制网易云音乐：%s" % (exc.stderr.strip() or str(exc))}
    except Exception as exc:
        return {"error": "播放失败：%s" % exc}
