import type {
  HomeData,
  LibraryQuery,
  LibraryResult,
  MediaItem,
} from "../types";
import { secondsToTicks } from "./format";

const FAVORITES_KEY = "luma.demo.favorites.v1";
const DEFAULT_FAVORITES = ["demo-dune", "demo-mountains"];

function movie(
  id: string,
  title: string,
  originalTitle: string,
  year: number,
  durationMinutes: number,
  rating: number,
  genres: string[],
  poster: number,
  overview: string,
  additions: Partial<MediaItem> = {},
): MediaItem {
  return {
    id: `demo-${id}`,
    title,
    originalTitle,
    year,
    durationMinutes,
    rating,
    genres,
    overview,
    type: "movie",
    durationTicks: secondsToTicks(durationMinutes * 60),
    imageUrl: `/media/poster-${poster}.jpg`,
    backdropUrl: `/media/poster-${poster}.jpg`,
    progress: 0,
    positionTicks: 0,
    isFavorite: false,
    isPlayed: false,
    ...additions,
  };
}

/** Fictional titles shown only while the interface explicitly displays demo mode. */
const CATALOG: MediaItem[] = [
  movie(
    "voyage",
    "星际漫游",
    "Interstellar Voyage",
    2025,
    148,
    8.9,
    ["科幻", "冒险", "剧情"],
    4,
    "在地球最后一座灯塔熄灭之前，一名宇航员接到了来自遥远星系的讯号。她踏上穿越星海的旅程，寻找人类失落的家园，也寻找关于自己的答案。",
    { tagline: "越过星海，寻找归途。", backdropUrl: "/media/hero.jpg" },
  ),
  movie(
    "dune",
    "沙丘之旅",
    "Beyond the Dunes",
    2024,
    132,
    8.6,
    ["科幻", "冒险"],
    1,
    "无边的沙海隐藏着古老文明的秘密。一位年轻的旅人跟随风的方向，走向一场关乎家园与信念的远征。",
    {
      tagline: "每一粒沙，都记得来时的路。",
      progress: 56,
      positionTicks: secondsToTicks(4446),
    },
  ),
  movie(
    "tokyo",
    "东京夜行",
    "Tokyo After Dark",
    2025,
    46,
    8.4,
    ["悬疑", "都市", "剧情"],
    2,
    "霓虹灯映照着城市的另一面。一个夜班摄影师在最后一班列车上，意外卷入一连串看似无关的故事。每一个陌生人，都藏着一个等待被发现的秘密。",
    {
      type: "series",
      childCount: 8,
      progress: 64,
      positionTicks: secondsToTicks(1766),
      tagline: "午夜之后，故事才刚刚开始。",
    },
  ),
  movie(
    "mountains",
    "群山之间",
    "Between the Mountains",
    2024,
    108,
    8.7,
    ["剧情", "旅行"],
    3,
    "在远离喧嚣的山间，一位返乡的建筑师与童年的好友再次相遇。他们沿着一条旧山路，重新认识故乡，也重新理解生命中那些未曾说出口的告别。",
    {
      tagline: "有些答案，藏在寂静的山里。",
      progress: 28,
      positionTicks: secondsToTicks(1814),
    },
  ),
  movie(
    "ocean",
    "蔚蓝深处",
    "Into the Blue",
    2025,
    96,
    9.1,
    ["纪录片", "自然"],
    5,
    "跟随一支深海探险队，潜入阳光无法抵达的水域。从微小的发光生命到宏伟的海底峡谷，一段关于海洋、时间与生命的旅程徐徐展开。",
    { tagline: "在世界的深处，发现生命的光。" },
  ),
  movie(
    "forest",
    "最后的森林",
    "The Last Forest",
    2023,
    52,
    8.8,
    ["纪录片", "自然", "探索"],
    6,
    "从第一缕晨光到星光下的林间，一位自然记录者守候在古老森林里，记录四季流转中的生命奇迹，以及守护这片土地的人们。",
    { type: "series", childCount: 6, tagline: "听见森林，也听见自己。" },
  ),
];

function loadFavorites(): Set<string> {
  try {
    const value = localStorage.getItem(FAVORITES_KEY);
    if (value === null) return new Set(DEFAULT_FAVORITES);
    const parsed: unknown = JSON.parse(value);
    if (Array.isArray(parsed)) {
      return new Set(
        parsed.filter(
          (id): id is string =>
            typeof id === "string" && /^demo-[a-z0-9-]+$/.test(id),
        ),
      );
    }
  } catch {
    /* Storage may be unavailable in a private webview. */
  }
  return new Set(DEFAULT_FAVORITES);
}

let favorites = loadFavorites();

function copyItem(item: MediaItem): MediaItem {
  return {
    ...item,
    genres: [...item.genres],
    isFavorite: favorites.has(item.id),
  };
}

export function getDemoHome(): HomeData {
  const items = CATALOG.map(copyItem);
  return {
    featured: items[0] ?? null,
    resume: items.filter((item) => item.progress > 0 && item.progress < 100),
    latest: [items[1], items[2], items[3], items[0], items[4], items[5]],
    movies: items.filter((item) => item.type === "movie"),
    series: items.filter((item) => item.type === "series"),
    views: [
      movie("library-movies", "小影院", "", 2025, 0, 0, [], 1, "", {
        type: "collection",
      }),
      movie("library-series", "剧集时光", "", 2025, 0, 0, [], 2, "", {
        type: "collection",
      }),
    ],
  };
}

export function getDemoLibrary(query: LibraryQuery = {}): LibraryResult {
  const terms = (query.search ?? "")
    .trim()
    .toLocaleLowerCase()
    .split(/\s+/)
    .filter(Boolean);
  let items = CATALOG.map(copyItem).filter((item) => {
    if (query.kind && query.kind !== "all" && item.type !== query.kind)
      return false;
    if (query.parentId === "demo-library-movies" && item.type !== "movie")
      return false;
    if (query.parentId === "demo-library-series" && item.type !== "series")
      return false;
    if (query.favorites && !item.isFavorite) return false;
    const text =
      `${item.title} ${item.originalTitle ?? ""} ${item.overview} ${item.genres.join(" ")} ${item.year ?? ""}`.toLocaleLowerCase();
    return terms.every((term) => text.includes(term));
  });

  const direction = query.sortOrder === "Ascending" ? 1 : -1;
  if (query.sortBy === "SortName") {
    items.sort((a, b) => direction * a.title.localeCompare(b.title, "zh-CN"));
  } else if (query.sortBy === "ProductionYear") {
    items.sort((a, b) => direction * ((a.year ?? 0) - (b.year ?? 0)));
  } else if (query.sortBy === "CommunityRating") {
    items.sort((a, b) => direction * ((a.rating ?? 0) - (b.rating ?? 0)));
  } else if (query.sortOrder === "Ascending") {
    items.reverse();
  }

  const total = items.length;
  const start = Math.max(0, query.startIndex ?? 0);
  items = items.slice(start, start + Math.max(1, query.limit ?? 100));
  return { items, total };
}

export function getDemoEpisodes(seriesId: string): MediaItem[] {
  const series = CATALOG.find(
    (item) => item.id === seriesId && item.type === "series",
  );
  if (!series) return [];
  const titles =
    seriesId === "demo-tokyo"
      ? [
          "最后一班列车",
          "陌生来电",
          "雨夜来客",
          "消失的照片",
          "灯火阑珊",
          "城市边缘",
          "天亮之前",
          "归途",
        ]
      : [
          "森林苏醒",
          "隐秘的世界",
          "树冠之上",
          "雨季来临",
          "夜的声音",
          "生生不息",
        ];
  return titles.map((title, index) =>
    copyItem({
      ...series,
      id: `${series.id}-episode-${index + 1}`,
      title,
      type: "episode",
      originalTitle: undefined,
      seriesId: series.id,
      seriesTitle: series.title,
      seasonNumber: 1,
      episodeNumber: index + 1,
      childCount: undefined,
      progress: index === 0 ? series.progress : 0,
      positionTicks: index === 0 ? series.positionTicks : 0,
    }),
  );
}

export function getDemoItem(id: string): MediaItem | undefined {
  const item = CATALOG.find((entry) => entry.id === id);
  if (item) return copyItem(item);
  const seriesId = id.split("-episode-")[0];
  return getDemoEpisodes(seriesId).find((episode) => episode.id === id);
}

export function setDemoFavorite(id: string, value: boolean): void {
  if (value) favorites.add(id);
  else favorites.delete(id);
  try {
    localStorage.setItem(FAVORITES_KEY, JSON.stringify([...favorites]));
  } catch {
    /* In-memory favorites still work when storage is unavailable. */
  }
}
