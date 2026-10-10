import { invoke } from "@tauri-apps/api/core";
import type {
  Credentials,
  EmbyItem,
  HomeData,
  LibraryQuery,
  LibraryResult,
  MediaItem,
  PlaybackEvent,
  PlaybackInfo,
  Preferences,
  Session,
} from "../types";
import {
  getDemoEpisodes,
  getDemoHome,
  getDemoItem,
  getDemoLibrary,
  setDemoFavorite,
} from "./demo";
import { normalizeItem } from "./normalize";

const PREFERENCES_KEY = "luma.preferences.v1";
const DEFAULT_PREFERENCES: Preferences = {
  maxBitrateMbps: 40,
  autoplayNext: true,
  defaultSubtitle: false,
  reduceMotion: false,
};

export class ApiError extends Error {
  readonly code: string;
  constructor(code: string, message: string) {
    super(message);
    this.name = "ApiError";
    this.code = code;
  }
}

export function getErrorMessage(error: unknown): string {
  if (error instanceof Error) return error.message;
  if (
    typeof error === "object" &&
    error !== null &&
    "message" in error &&
    typeof error.message === "string"
  )
    return error.message;
  if (typeof error === "string") return error;
  return "操作未完成，请稍后重试。";
}

async function command<T>(
  name: string,
  args?: Record<string, unknown>,
): Promise<T> {
  try {
    return await invoke<T>(name, args);
  } catch (error) {
    const code =
      typeof error === "object" &&
      error !== null &&
      "code" in error &&
      typeof error.code === "string"
        ? error.code
        : "REQUEST_FAILED";
    throw new ApiError(code, getErrorMessage(error));
  }
}

function validatePreferences(candidate: unknown): Preferences {
  const source =
    typeof candidate === "object" && candidate !== null
      ? (candidate as Record<string, unknown>)
      : {};
  const bitrate =
    typeof source.maxBitrateMbps === "number" &&
    Number.isFinite(source.maxBitrateMbps)
      ? Math.min(200, Math.max(1, source.maxBitrateMbps))
      : DEFAULT_PREFERENCES.maxBitrateMbps;
  return {
    maxBitrateMbps: bitrate,
    autoplayNext:
      typeof source.autoplayNext === "boolean"
        ? source.autoplayNext
        : DEFAULT_PREFERENCES.autoplayNext,
    defaultSubtitle:
      typeof source.defaultSubtitle === "boolean"
        ? source.defaultSubtitle
        : DEFAULT_PREFERENCES.defaultSubtitle,
    reduceMotion:
      typeof source.reduceMotion === "boolean"
        ? source.reduceMotion
        : DEFAULT_PREFERENCES.reduceMotion,
  };
}

export function getPreferences(): Preferences {
  try {
    return validatePreferences(
      JSON.parse(localStorage.getItem(PREFERENCES_KEY) || "null"),
    );
  } catch {
    return { ...DEFAULT_PREFERENCES };
  }
}

export function savePreferences(update: Partial<Preferences>): Preferences {
  const preferences = validatePreferences({ ...getPreferences(), ...update });
  try {
    localStorage.setItem(PREFERENCES_KEY, JSON.stringify(preferences));
  } catch {
    /* A locked-down browser can still use preferences for this render. */
  }
  return preferences;
}

const isDesktop =
  typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;
let currentSession: Session | null = null;
let sessionLoaded = !isDesktop;
let sessionRequest: Promise<Session | null> | undefined;
let sessionEpoch = 0;

async function getSession(): Promise<Session | null> {
  if (sessionLoaded) return currentSession;
  if (!sessionRequest) {
    const requestEpoch = sessionEpoch;
    sessionRequest = command<Session | null>("session")
      .then((session) => {
        if (requestEpoch === sessionEpoch) {
          currentSession = session;
          sessionLoaded = true;
        }
        return currentSession;
      })
      .finally(() => {
        sessionRequest = undefined;
      });
  }
  return sessionRequest;
}

async function isDemo(): Promise<boolean> {
  return (await getSession()) === null;
}

function requireDemoItem(id: string): MediaItem {
  const item = getDemoItem(id);
  if (!item) throw new ApiError("NOT_FOUND", "找不到这个演示条目。");
  return item;
}

export const api = {
  isDesktop,
  get isDemo(): boolean {
    return currentSession === null;
  },
  getSession,

  async connect(credentials: Credentials): Promise<Session> {
    if (!isDesktop) {
      throw new ApiError(
        "DESKTOP_REQUIRED",
        "连接 Emby 服务器需要打开 macOS 或 Windows 桌面客户端。浏览器预览目前为演示模式。",
      );
    }
    const requestEpoch = ++sessionEpoch;
    const session = await command<Session>("connect", { ...credentials });
    if (requestEpoch !== sessionEpoch)
      throw new ApiError("SESSION_CANCELLED", "连接操作已取消。");
    currentSession = session;
    sessionLoaded = true;
    return session;
  },

  async disconnect(): Promise<void> {
    ++sessionEpoch;
    try {
      if (isDesktop) await command<void>("logout");
    } finally {
      currentSession = null;
      sessionLoaded = true;
    }
  },

  async getHome(): Promise<HomeData> {
    if (await isDemo()) return getDemoHome();
    const data =
      await command<
        Record<"resume" | "latest" | "movies" | "series" | "views", EmbyItem[]>
      >("dashboard");
    const home = {
      resume: data.resume.map(normalizeItem),
      latest: data.latest.map(normalizeItem),
      movies: data.movies.map(normalizeItem),
      series: data.series.map(normalizeItem),
      views: data.views.map(normalizeItem),
    };
    return {
      ...home,
      featured:
        [...home.resume, ...home.latest, ...home.movies].find(
          (item) => item.backdropUrl,
        ) ??
        home.latest[0] ??
        home.movies[0] ??
        null,
    };
  },

  async getLibrary(query: LibraryQuery = {}): Promise<LibraryResult> {
    if (await isDemo()) return getDemoLibrary(query);
    const { kind, ...filters } = query;
    const types =
      kind === "movie"
        ? "Movie"
        : kind === "series"
          ? "Series"
          : "Movie,Series";
    const result = await command<{
      Items: EmbyItem[];
      TotalRecordCount: number;
    }>("library", {
      query: { ...filters, types, limit: query.limit ?? 60 },
    });
    return {
      items: result.Items.map(normalizeItem),
      total: result.TotalRecordCount,
    };
  },

  async getItem(id: string): Promise<MediaItem> {
    return (await isDemo())
      ? requireDemoItem(id)
      : normalizeItem(await command<EmbyItem>("item", { id }));
  },

  async getEpisodes(id: string): Promise<MediaItem[]> {
    if (await isDemo()) return getDemoEpisodes(id);
    return (await command<EmbyItem[]>("episodes", { id })).map(normalizeItem);
  },

  async setFavorite(id: string, value: boolean): Promise<void> {
    if (await isDemo()) {
      requireDemoItem(id);
      setDemoFavorite(id, value);
      return;
    }
    await command("favorite", { id, value });
  },

  async getPlayback(
    id: string,
    options: { maxBitrate?: number; startTicks?: number } = {},
  ): Promise<PlaybackInfo> {
    if (await isDemo()) {
      requireDemoItem(id);
      return {
        isDemo: true,
        label: "演示片段 · Sintel（Blender Foundation）",
        url: "https://media.w3.org/2010/05/sintel/trailer.mp4",
        itemId: id,
        mediaSourceId: "demo-sintel-trailer",
        playSessionId: "demo",
        playMethod: "DirectPlay",
        mimeType: "video/mp4",
        startTicks: 0,
        subtitles: [],
        audioTracks: [],
      };
    }
    return command<PlaybackInfo>("playback", {
      id,
      maxBitrate:
        options.maxBitrate ?? getPreferences().maxBitrateMbps * 1_000_000,
      startTicks: options.startTicks ?? 0,
    });
  },

  async reportPlayback(event: PlaybackEvent): Promise<void> {
    if (event.playSessionId === "demo" || (await isDemo())) return;
    await command<void>("report_playback", { event });
  },

  async cancelPlayback(playSessionId: string): Promise<void> {
    if (!isDesktop || playSessionId === "demo") return;
    await command<void>("cancel_playback", { playSessionId });
  },
};
