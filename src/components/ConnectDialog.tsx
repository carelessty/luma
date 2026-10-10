import { useState, type FormEvent } from "react";
import {
  ArrowRight,
  LoaderCircle,
  Server,
  ShieldCheck,
  Eye,
  EyeOff,
} from "lucide-react";
import { Modal } from "./Modal";
import { api } from "../lib/api";
import type { Session } from "../types";

export const errorText = (e: unknown) =>
  typeof e === "object" && e !== null && "message" in e
    ? String(e.message)
    : typeof e === "string"
      ? e
      : "操作未完成，请稍后重试。";
export function ConnectDialog({
  onClose,
  onConnect,
}: {
  onClose: () => void;
  onConnect: (session: Session) => void;
}) {
  const [serverUrl, setServerUrl] = useState("");
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [show, setShow] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  async function submit(e: FormEvent) {
    e.preventDefault();
    setError("");
    setBusy(true);
    try {
      const session = await api.connect({
        serverUrl: serverUrl.trim(),
        username: username.trim(),
        password,
      });
      setPassword("");
      onConnect(session);
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(false);
    }
  }
  return (
    <Modal
      title="连接 Emby 服务器"
      onClose={busy ? () => {} : onClose}
      className="connect-dialog"
    >
      <div className="dialog-symbol">
        <Server size={27} />
      </div>
      <h2>每个好故事，都在这里。</h2>
      <p className="dialog-intro">连接你的 Emby 服务器，让私人影院触手可及。</p>
      {!api.isDesktop && (
        <div className="info-message">
          你正在浏览网页版演示。请运行桌面客户端，以安全连接 Emby 服务器。
        </div>
      )}
      <form onSubmit={submit}>
        <label>
          服务器地址
          <input
            type="url"
            required
            placeholder="http://192.168.1.100:8096"
            value={serverUrl}
            onChange={(e) => setServerUrl(e.target.value)}
            autoComplete="url"
            disabled={busy}
          />
          <span className="field-hint">
            支持 HTTPS 和反向代理路径，例如 https://media.example.com/emby
          </span>
        </label>
        <label>
          用户名
          <input
            required
            placeholder="你的 Emby 用户名"
            value={username}
            onChange={(e) => setUsername(e.target.value)}
            autoComplete="username"
            disabled={busy}
          />
        </label>
        <label>
          密码
          <div className="password-field">
            <input
              type={show ? "text" : "password"}
              placeholder="输入密码（可为空）"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              autoComplete="current-password"
              disabled={busy}
            />
            <button
              type="button"
              aria-label={show ? "隐藏密码" : "显示密码"}
              onClick={() => setShow(!show)}
            >
              {show ? <EyeOff size={18} /> : <Eye size={18} />}
            </button>
          </div>
        </label>
        {error && (
          <p className="error-message" role="alert">
            {error}
          </p>
        )}
        <button
          className="button primary full-width"
          type="submit"
          disabled={busy || !api.isDesktop}
        >
          {busy ? (
            <LoaderCircle size={18} className="spin" />
          ) : (
            <ArrowRight size={18} />
          )}{" "}
          {busy ? "正在连接…" : "连接服务器"}
        </button>
      </form>
      <p className="privacy-note">
        <ShieldCheck size={15} /> 凭据仅用于本次会话，不保存你的密码。
      </p>
      <button
        className="text-button demo-link"
        onClick={onClose}
        disabled={busy}
      >
        先逛逛演示媒体库
      </button>
    </Modal>
  );
}
