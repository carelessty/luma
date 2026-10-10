import { useEffect, useRef, useState } from "react";
import {
  ArrowLeft,
  LoaderCircle,
  AlertCircle,
  Maximize,
  SkipForward,
  RotateCcw,
  Subtitles,
} from "lucide-react";
import { api } from "../lib/api";
import { secondsToTicks, ticksToSeconds } from "../lib/format";
import { errorText } from "./ConnectDialog";
import { Modal } from "./Modal";
import type {
  MediaItem,
  PlaybackInfo,
  PlaybackEvent,
  Preferences,
} from "../types";

export default function Player({
  item,
  preferences,
  onClose,
  onNext,
}: {
  item: MediaItem;
  preferences: Preferences;
  onClose: () => void;
  onNext: (item: MediaItem) => void;
}) {
  const video = useRef<HTMLVideoElement>(null);
  const [info, setInfo] = useState<PlaybackInfo | null>(null);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [busy, setBusy] = useState(true);
  const [retry, setRetry] = useState(0);
  const [next, setNext] = useState<MediaItem | null>(null);
  const [subtitle, setSubtitle] = useState(-1);
  const [ended, setEnded] = useState(false);
  const nextRef = useRef(next);
  nextRef.current = next;
  const prefsRef = useRef(preferences);
  prefsRef.current = preferences;
  const onNextRef = useRef(onNext);
  onNextRef.current = onNext;
  useEffect(() => {
    let active = true;
    setInfo(null);
    setError("");
    setNotice("");
    setBusy(true);
    setEnded(false);
    setNext(null);
    api
      .getPlayback(item.id, {
        maxBitrate: preferences.maxBitrateMbps * 1_000_000,
        startTicks: item.positionTicks,
      })
      .then((data) => {
        if (active) setInfo(data);
      })
      .catch((e) => {
        if (active) {
          setError(errorText(e));
          setBusy(false);
        }
      });
    if (item.seriesId)
      api
        .getEpisodes(item.seriesId)
        .then((episodes) => {
          if (active) {
            const i = episodes.findIndex((e) => e.id === item.id);
            setNext(i >= 0 ? (episodes[i + 1] ?? null) : null);
          }
        })
        .catch(() => {});
    return () => {
      active = false;
    };
  }, [
    item.id,
    item.positionTicks,
    item.seriesId,
    preferences.maxBitrateMbps,
    retry,
  ]);
  useEffect(() => {
    const el = video.current;
    if (!el || !info) return;
    let disposed = false;
    let hls: import("hls.js").default | undefined;
    let started = false;
    let stopped = false;
    let lastReport = 0;
    let sendChain = Promise.resolve();
    const report = (type: PlaybackEvent["type"]) => {
      if (
        (disposed && type !== "stop") ||
        (type !== "start" && !started) ||
        (type === "stop" && stopped)
      )
        return;
      if (type === "stop") stopped = true;
      const event: PlaybackEvent = {
        type,
        itemId: info.itemId,
        mediaSourceId: info.mediaSourceId,
        playSessionId: info.playSessionId,
        playMethod: info.playMethod,
        positionTicks: secondsToTicks(el.currentTime),
        isPaused: el.paused,
        isMuted: el.muted,
        volumeLevel: Math.round(el.volume * 100),
      };
      sendChain = sendChain
        .then(() => api.reportPlayback(event))
        .catch(() => {
          if (!disposed) setNotice("播放正常，但进度同步暂时失败。");
        });
    };
    const playing = () => {
      setBusy(false);
      setNotice("");
      if (!started) {
        started = true;
        report("start");
      } else report("progress");
    };
    const metadata = () => {
      if (info.startTicks > 0 && Number.isFinite(el.duration))
        el.currentTime = Math.min(
          ticksToSeconds(info.startTicks),
          Math.max(0, el.duration - 1),
        );
      setBusy(false);
      void el.play().catch(() => {
        if (!disposed) setNotice("点击播放器中的播放按钮开始观看。");
      });
    };
    const tick = () => {
      if (Date.now() - lastReport > 10_000) {
        lastReport = Date.now();
        report("progress");
      }
    };
    const pause = () => report("progress");
    const seek = () => report("progress");
    const endedHandler = () => {
      report("stop");
      setEnded(true);
      if (nextRef.current && prefsRef.current.autoplayNext)
        onNextRef.current(nextRef.current);
    };
    const errorHandler = () => {
      if (disposed) return;
      setBusy(false);
      setError(
        "视频无法播放。请检查网络、服务器转码权限，或在设置中降低最高播放码率。",
      );
    };
    el.addEventListener("loadedmetadata", metadata);
    el.addEventListener("playing", playing);
    el.addEventListener("timeupdate", tick);
    el.addEventListener("pause", pause);
    el.addEventListener("seeked", seek);
    el.addEventListener("ended", endedHandler);
    el.addEventListener("error", errorHandler);
    async function attach() {
      const isHls =
        info!.mimeType.includes("mpegurl") || /\.m3u8(?:\?|$)/i.test(info!.url);
      if (isHls && !el!.canPlayType("application/vnd.apple.mpegurl")) {
        const { default: Hls } = await import("hls.js");
        if (disposed) return;
        if (!Hls.isSupported()) {
          errorHandler();
          return;
        }
        hls = new Hls({
          maxBufferLength: 30,
          backBufferLength: 30,
          enableWorker: true,
        });
        hls.on(Hls.Events.ERROR, (_event, data) => {
          if (data.fatal) errorHandler();
        });
        hls.loadSource(info!.url);
        hls.attachMedia(el!);
      } else {
        el!.src = info!.url;
        el!.load();
      }
    }
    void attach().catch(errorHandler);
    return () => {
      if (!started && info.playMethod === "Transcode")
        void api.cancelPlayback(info.playSessionId).catch(() => {});
      report("stop");
      disposed = true;
      el.removeEventListener("loadedmetadata", metadata);
      el.removeEventListener("playing", playing);
      el.removeEventListener("timeupdate", tick);
      el.removeEventListener("pause", pause);
      el.removeEventListener("seeked", seek);
      el.removeEventListener("ended", endedHandler);
      el.removeEventListener("error", errorHandler);
      el.pause();
      hls?.destroy();
      el.removeAttribute("src");
      el.load();
    };
  }, [info]);
  useEffect(() => {
    if (!info) return;
    setSubtitle(
      preferences.defaultSubtitle
        ? ((info.subtitles.find((s) => s.isDefault) ?? info.subtitles[0])
            ?.index ?? -1)
        : -1,
    );
  }, [info, preferences.defaultSubtitle]);
  useEffect(() => {
    const tracks = video.current?.textTracks;
    if (tracks && info)
      for (let i = 0; i < tracks.length; i++)
        tracks[i].mode =
          info.subtitles[i]?.index === subtitle ? "showing" : "disabled";
  }, [subtitle, info]);
  return (
    <Modal
      title={`正在播放 ${item.title}`}
      onClose={onClose}
      className="player-dialog"
    >
      <header className="player-header">
        <button className="icon-button" aria-label="退出播放" onClick={onClose}>
          <ArrowLeft size={21} />
        </button>
        <div>
          <h2>{item.title}</h2>
          <p>
            {info?.isDemo
              ? info.label
              : (item.seriesTitle ?? "享受此刻，故事正在发生。")}
          </p>
        </div>
        {info && !info.isDemo && (
          <span className="play-method">
            {info.playMethod === "Transcode" ? "服务器转码" : "直接播放"}
          </span>
        )}
      </header>
      <div className="video-stage">
        <video
          ref={video}
          controls
          playsInline
          crossOrigin={info?.isDemo ? undefined : "anonymous"}
          poster={item.backdropUrl ?? item.imageUrl}
          aria-label={`${item.title} 视频播放器`}
        >
          {info?.subtitles.map((track) => (
            <track
              key={track.index}
              kind="subtitles"
              src={track.url}
              srcLang={track.language ?? "und"}
              label={track.title}
            />
          ))}
        </video>
        {busy && !error && (
          <div className="player-loading">
            <LoaderCircle size={32} className="spin" />
            <p>正在准备影片…</p>
          </div>
        )}
        {error && (
          <div className="player-error">
            <AlertCircle size={32} />
            <h3>暂时无法播放</h3>
            <p>{error}</p>
            <button
              className="button primary"
              onClick={() => setRetry((v) => v + 1)}
            >
              <RotateCcw size={17} />
              重新尝试
            </button>
          </div>
        )}
        {ended && !next && (
          <div className="player-ended">
            <h3>故事暂告一段落。</h3>
            <button className="button secondary" onClick={onClose}>
              回到媒体库
            </button>
          </div>
        )}
      </div>
      <footer className="player-footer">
        <span>
          {notice ||
            (info?.isDemo
              ? "演示影片来自 Blender Foundation，不代表所选电影的实际内容。"
              : "观看进度每 10 秒同步至 Emby。")}
        </span>
        <div>
          {info && info.subtitles.length > 0 && (
            <label className="subtitle-select">
              <Subtitles size={17} />
              <select
                aria-label="字幕"
                value={subtitle}
                onChange={(e) => setSubtitle(Number(e.target.value))}
              >
                <option value={-1}>关闭字幕</option>
                {info.subtitles.map((s) => (
                  <option key={s.index} value={s.index}>
                    {s.title}
                  </option>
                ))}
              </select>
            </label>
          )}
          {next && (
            <button
              className="icon-button"
              aria-label="下一集"
              onClick={() => onNext(next)}
            >
              <SkipForward size={19} />
            </button>
          )}
          <button
            className="icon-button"
            aria-label="全屏播放"
            onClick={() => {
              void video.current
                ?.requestFullscreen()
                .catch(() =>
                  setNotice(
                    "当前环境不支持此全屏方式，请使用播放器内的全屏按钮。",
                  ),
                );
            }}
          >
            <Maximize size={19} />
          </button>
        </div>
      </footer>
    </Modal>
  );
}
