import { useEffect, useState } from "react";
import { Play, Heart, Star, LoaderCircle, Clapperboard } from "lucide-react";
import { Modal } from "./Modal";
import { Artwork } from "./MediaCard";
import { api } from "../lib/api";
import { formatDuration } from "../lib/format";
import { errorText } from "./ConnectDialog";
import type { MediaItem } from "../types";

export function DetailDialog({
  initial,
  onClose,
  onPlay,
  onFavorite,
}: {
  initial: MediaItem;
  onClose: () => void;
  onPlay: (item: MediaItem) => void;
  onFavorite: (item: MediaItem) => Promise<void>;
}) {
  const [item, setItem] = useState(initial);
  const [episodes, setEpisodes] = useState<MediaItem[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [saving, setSaving] = useState(false);
  useEffect(() => {
    let alive = true;
    setLoading(true);
    Promise.all([
      api.getItem(initial.id),
      initial.type === "series"
        ? api.getEpisodes(initial.id)
        : Promise.resolve([]),
    ])
      .then(([data, eps]) => {
        if (alive) {
          setItem(data);
          setEpisodes(eps);
        }
      })
      .catch((e) => {
        if (alive) setError(errorText(e));
      })
      .finally(() => {
        if (alive) setLoading(false);
      });
    return () => {
      alive = false;
    };
  }, [initial.id, initial.type]);
  async function toggle() {
    setSaving(true);
    try {
      await onFavorite(item);
      setItem({ ...item, isFavorite: !item.isFavorite });
    } catch (e) {
      setError(errorText(e));
    } finally {
      setSaving(false);
    }
  }
  return (
    <Modal title={item.title} onClose={onClose} className="detail-dialog">
      <div className="detail-backdrop">
        <Artwork src={item.backdropUrl ?? item.imageUrl} alt={item.title} />
        <div />
      </div>
      <div className="detail-content">
        <div className="detail-heading">
          <div>
            <h2>{item.title}</h2>
            {item.originalTitle && (
              <p className="original-title">{item.originalTitle}</p>
            )}
          </div>
          {item.rating !== undefined && (
            <span className="detail-rating">
              <Star size={17} fill="currentColor" />
              {item.rating.toFixed(1)}
            </span>
          )}
        </div>
        <p className="meta-line">
          {item.year}
          <span>·</span>
          {item.genres.join(" / ") || "媒体"}
          <span>·</span>
          {item.type === "series"
            ? "系列剧集"
            : formatDuration(item.durationMinutes)}
        </p>
        <div className="hero-actions">
          <button
            className="button primary"
            disabled={
              (loading && item.type === "series") ||
              (item.type === "series" && !episodes.length)
            }
            onClick={() =>
              onPlay(
                item.type === "series"
                  ? (episodes.find((e) => !e.isPlayed) ?? episodes[0])
                  : item,
              )
            }
          >
            <Play size={18} fill="currentColor" />
            {item.positionTicks > 0 ? "继续播放" : "立即播放"}
          </button>
          <button
            className="button secondary"
            onClick={toggle}
            disabled={saving}
          >
            <Heart size={18} fill={item.isFavorite ? "currentColor" : "none"} />
            {item.isFavorite ? "已收藏" : "我的收藏"}
          </button>
        </div>
        <h3>剧情简介</h3>
        <p className="overview">{item.overview || "这部影片还没有简介。"}</p>
        {error && (
          <p role="alert" className="error-message">
            {error}
          </p>
        )}
        {item.type === "series" && (
          <section className="episode-section">
            <h3>
              <Clapperboard size={18} /> 剧集列表
            </h3>
            {loading ? (
              <div className="loading-inline">
                <LoaderCircle className="spin" size={18} />
                正在加载剧集…
              </div>
            ) : episodes.length ? (
              episodes.map((ep) => (
                <button
                  className="episode-row"
                  key={ep.id}
                  onClick={() => onPlay(ep)}
                >
                  <span className="episode-number">
                    {String(ep.episodeNumber ?? 1).padStart(2, "0")}
                  </span>
                  <Artwork src={ep.backdropUrl ?? ep.imageUrl} alt={ep.title} />
                  <span>
                    <strong>{ep.title}</strong>
                    <small>
                      第 {ep.seasonNumber ?? 1} 季 ·{" "}
                      {formatDuration(ep.durationMinutes)}
                      {ep.isPlayed ? " · 已看完" : ""}
                    </small>
                  </span>
                  <Play size={18} />
                </button>
              ))
            ) : (
              <p className="muted">暂无可播放剧集。</p>
            )}
          </section>
        )}
      </div>
    </Modal>
  );
}
