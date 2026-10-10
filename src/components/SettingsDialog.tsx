import { MonitorPlay, LogOut, Server, Sparkles } from "lucide-react";
import { Modal } from "./Modal";
import type { Preferences, Session } from "../types";

function Switch({
  checked,
  onChange,
  label,
}: {
  checked: boolean;
  onChange: (value: boolean) => void;
  label: string;
}) {
  return (
    <button
      role="switch"
      aria-checked={checked}
      aria-label={label}
      className={`switch ${checked ? "on" : ""}`}
      onClick={() => onChange(!checked)}
    >
      <i />
    </button>
  );
}
export function SettingsDialog({
  session,
  preferences,
  onChange,
  onClose,
  onConnect,
  onDisconnect,
}: {
  session: Session | null;
  preferences: Preferences;
  onChange: (patch: Partial<Preferences>) => void;
  onClose: () => void;
  onConnect: () => void;
  onDisconnect: () => void;
}) {
  return (
    <Modal title="设置" onClose={onClose} className="settings-dialog">
      <h2>恰到好处，才是你的影院。</h2>
      <p className="dialog-intro">让 Luma 更合你的习惯。</p>
      <h3 className="settings-section">
        <Server size={17} />
        服务器
      </h3>
      <div className="server-setting">
        <div className="server-avatar">
          {session?.serverName?.slice(0, 1) ?? "L"}
        </div>
        <div>
          <strong>{session?.serverName ?? "演示媒体库"}</strong>
          <p>
            {session
              ? `${session.userName} · ${session.serverUrl}`
              : "连接 Emby，开始观看你的收藏"}
          </p>
        </div>
        <button
          className="button secondary small"
          onClick={session ? onDisconnect : onConnect}
        >
          {session ? (
            <>
              <LogOut size={15} />
              断开连接
            </>
          ) : (
            "连接"
          )}
        </button>
      </div>
      <h3 className="settings-section">
        <MonitorPlay size={17} />
        播放
      </h3>
      <label className="setting-row">
        <span>
          <strong>最高播放码率</strong>
          <small>带宽不足时，服务器可按此上限转码</small>
        </span>
        <select
          value={preferences.maxBitrateMbps}
          onChange={(e) => onChange({ maxBitrateMbps: Number(e.target.value) })}
        >
          <option value={8}>8 Mbps</option>
          <option value={20}>20 Mbps</option>
          <option value={40}>40 Mbps</option>
          <option value={80}>80 Mbps</option>
          <option value={120}>120 Mbps</option>
        </select>
      </label>
      <div className="setting-row">
        <span>
          <strong>自动播放下一集</strong>
          <small>当前剧集结束后继续播放</small>
        </span>
        <Switch
          label="自动播放下一集"
          checked={preferences.autoplayNext}
          onChange={(autoplayNext) => onChange({ autoplayNext })}
        />
      </div>
      <div className="setting-row">
        <span>
          <strong>优先显示字幕</strong>
          <small>有可用文本字幕时自动开启</small>
        </span>
        <Switch
          label="优先显示字幕"
          checked={preferences.defaultSubtitle}
          onChange={(defaultSubtitle) => onChange({ defaultSubtitle })}
        />
      </div>
      <h3 className="settings-section">
        <Sparkles size={17} />
        外观
      </h3>
      <div className="setting-row">
        <span>
          <strong>减少动态效果</strong>
          <small>也会遵循系统的辅助功能设置</small>
        </span>
        <Switch
          label="减少动态效果"
          checked={preferences.reduceMotion}
          onChange={(reduceMotion) => onChange({ reduceMotion })}
        />
      </div>
      <div className="about-luma">
        <span className="wordmark">Luma</span>
        <p>0.1.0 · 为每一份热爱，留一束光。</p>
        <span>基于 Rust 与 Tauri 构建</span>
      </div>
    </Modal>
  );
}
