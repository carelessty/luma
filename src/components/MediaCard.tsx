import { memo, useState } from "react";
import { Heart, Play, Film } from "lucide-react";
import type { MediaItem } from "../types";
import { formatTime, ticksToSeconds } from "../lib/format";

export function Artwork({
  src,
  alt,
  className = "",
}: {
  src?: string;
  alt: string;
  className?: string;
}) {
  const [failed, setFailed] = useState(false);
  return src && !failed ? (
    <img
      className={className}
      src={src}
      alt={alt}
      loading="lazy"
      decoding="async"
      onError={() => setFailed(true)}
    />
  ) : (
    <div className={`artwork-fallback ${className}`}>
      <Film size={32} />
      <span>{alt}</span>
    </div>
  );
}

export const MediaCard = memo(function MediaCard({
  item,
  wide = false,
  onOpen,
  onPlay,
  onFavorite,
}: {
  item: MediaItem;
  wide?: boolean;
  onOpen: (item: MediaItem) => void;
  onPlay: (item: MediaItem) => void;
  onFavorite: (item: MediaItem) => void;
}) {
  return (
    <article className={`media-card ${wide ? "wide-card" : "poster-card"}`}>
      <div className="media-image">
        <button
          className="artwork-button"
          aria-label={`查看 ${item.title}`}
          onClick={() => onOpen(item)}
        >
          <Artwork
            src={wide ? (item.backdropUrl ?? item.imageUrl) : item.imageUrl}
            alt={item.title}
          />
        </button>
        <div className="card-shade" />
        <button
          className="card-play"
          aria-label={`播放 ${item.title}`}
          onClick={() => onPlay(item)}
        >
          <Play size={wide ? 24 : 28} fill="currentColor" />
        </button>
        <button
          className={`card-favorite ${item.isFavorite ? "saved" : ""}`}
          aria-label={`${item.isFavorite ? "取消收藏" : "收藏"} ${item.title}`}
          aria-pressed={item.isFavorite}
          onClick={() => onFavorite(item)}
        >
          <Heart size={17} fill={item.isFavorite ? "currentColor" : "none"} />
        </button>
        {wide && (
          <>
            <span className="watch-time">
              {formatTime(ticksToSeconds(item.positionTicks))} <span>/</span>{" "}
              {formatTime(ticksToSeconds(item.durationTicks))}
            </span>
            <div className="progress-track">
              <i style={{ width: `${item.progress}%` }} />
            </div>
          </>
        )}
        {!wide && item.rating !== undefined && (
          <span className="rating-label">{item.rating.toFixed(1)}</span>
        )}
      </div>
      <button className="card-title" onClick={() => onOpen(item)}>
        {item.title}
      </button>
      {!wide && (
        <p className="card-meta">
          {item.year ?? "年份未知"}
          <span>·</span>
          {item.type === "series" ? "剧集" : (item.genres[0] ?? "电影")}
        </p>
      )}
    </article>
  );
});
