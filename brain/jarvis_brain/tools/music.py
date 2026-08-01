"""music_play_favorite —— 打开网易云音乐并播放「我喜欢的音乐」。

用 osascript 发键盘序列导航到「我喜欢的音乐」歌单。
URL scheme 需要知道歌单 ID（因人而异），键盘方案是通用兜底。
"""
import subprocess
import time


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
