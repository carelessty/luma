import type { EmbyItem, MediaItem, MediaKind } from "../types";
import { ticksToSeconds } from "./format";

const KINDS: Record<string, MediaKind> = {
  Movie: "movie",
  Series: "series",
  Episode: "episode",
  CollectionFolder: "collection",
  Folder: "collection",
  BoxSet: "collection",
};

export function normalizeItem(item: EmbyItem): MediaItem {
  const rawDuration = item.RunTimeTicks ?? 0;
  const rawPosition = item.UserData?.PlaybackPositionTicks ?? 0;
  const durationTicks = Math.max(
    0,
    Number.isFinite(rawDuration) ? rawDuration : 0,
  );
  const positionTicks = Math.max(
    0,
    Number.isFinite(rawPosition) ? rawPosition : 0,
  );
  const progress =
    item.UserData?.PlayedPercentage ??
    (durationTicks ? (positionTicks / durationTicks) * 100 : 0);

  return {
    id: item.Id,
    title: item.Name || "未命名影片",
    originalTitle: item.OriginalTitle,
    type: KINDS[item.Type ?? ""] ?? "other",
    overview: item.Overview || "暂无简介。",
    year: item.ProductionYear,
    durationTicks,
    durationMinutes: Math.round(ticksToSeconds(durationTicks) / 60),
    rating: item.CommunityRating,
    genres: item.Genres ?? [],
    imageUrl: item.PrimaryImageUrl || undefined,
    backdropUrl: item.BackdropImageUrl || undefined,
    progress: Math.max(
      0,
      Math.min(100, Number.isFinite(progress) ? progress : 0),
    ),
    positionTicks,
    isFavorite: item.UserData?.IsFavorite ?? false,
    isPlayed: item.UserData?.Played ?? false,
    tagline: item.Taglines?.[0],
    seriesId: item.SeriesId,
    seriesTitle: item.SeriesName,
    seasonNumber: item.ParentIndexNumber,
    episodeNumber: item.IndexNumber,
    childCount: item.ChildCount,
  };
}
