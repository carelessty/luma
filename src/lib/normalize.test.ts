import { describe, expect, it } from "vitest";
import { normalizeItem } from "./normalize";
import {
  formatDuration,
  formatTime,
  secondsToTicks,
  ticksToSeconds,
} from "./format";

describe("media normalization", () => {
  it("converts Emby ticks and computes resume progress from playback position", () => {
    const item = normalizeItem({
      Id: "movie-1",
      Name: "真实影片",
      Type: "Movie",
      RunTimeTicks: 72_000_000_000,
      UserData: { PlaybackPositionTicks: 18_000_000_000, IsFavorite: true },
    });
    expect(item.durationMinutes).toBe(120);
    expect(item.progress).toBe(25);
    expect(item.isFavorite).toBe(true);
  });

  it("handles incomplete and corrupt server runtime without NaN in the UI", () => {
    const item = normalizeItem({
      Id: "unknown",
      RunTimeTicks: Number.NaN,
      UserData: { PlaybackPositionTicks: -1, PlayedPercentage: 140 },
    });
    expect(item.durationTicks).toBe(0);
    expect(item.positionTicks).toBe(0);
    expect(item.progress).toBe(100);
    expect(item.genres).toEqual([]);
    expect(item.imageUrl).toBeUndefined();
  });

  it("keeps episode identity for next-episode playback", () => {
    const item = normalizeItem({
      Id: "episode-1",
      Type: "Episode",
      SeriesId: "series-1",
      SeriesName: "剧集",
      ParentIndexNumber: 2,
      IndexNumber: 3,
    });
    expect(item).toMatchObject({
      type: "episode",
      seriesId: "series-1",
      seriesTitle: "剧集",
      seasonNumber: 2,
      episodeNumber: 3,
    });
  });
});

describe("playback time formatting", () => {
  it("preserves fractional resume positions and formats long playbacks", () => {
    expect(ticksToSeconds(secondsToTicks(3670.25))).toBe(3670.25);
    expect(formatTime(3670.25)).toBe("1:01:10");
    expect(formatDuration(148)).toBe("2 小时 28 分钟");
    expect(formatTime(Number.NaN)).toBe("0:00");
  });
});
