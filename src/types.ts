export type MediaKind = "movie" | "series" | "episode" | "collection" | "other";

/** UI model. Progress is a percentage; Emby ticks are 100 ns. */
export interface MediaItem {
  id: string;
  title: string;
  originalTitle?: string;
  type: MediaKind;
  overview: string;
  year?: number;
  durationTicks: number;
  durationMinutes: number;
  rating?: number;
  genres: string[];
  imageUrl?: string;
  backdropUrl?: string;
  progress: number;
  positionTicks: number;
  isFavorite: boolean;
  isPlayed: boolean;
  tagline?: string;
  seriesId?: string;
  seriesTitle?: string;
  seasonNumber?: number;
  episodeNumber?: number;
  childCount?: number;
}

export interface Session {
  serverUrl: string;
  userId: string;
  userName: string;
  serverName: string;
  deviceId: string;
}

export interface Credentials {
  serverUrl: string;
  username: string;
  password: string;
}

export interface HomeData {
  featured: MediaItem | null;
  resume: MediaItem[];
  latest: MediaItem[];
  movies: MediaItem[];
  series: MediaItem[];
  views: MediaItem[];
}

export interface LibraryQuery {
  kind?: "all" | "movie" | "series";
  parentId?: string;
  search?: string;
  favorites?: boolean;
  startIndex?: number;
  limit?: number;
  sortBy?: "SortName" | "DateCreated" | "ProductionYear" | "CommunityRating";
  sortOrder?: "Ascending" | "Descending";
}

export interface LibraryResult {
  items: MediaItem[];
  total: number;
}

export interface PlaybackInfo {
  isDemo?: boolean;
  label?: string;
  url: string;
  itemId: string;
  mediaSourceId: string;
  playSessionId: string;
  playMethod: "DirectPlay" | "DirectStream" | "Transcode";
  mimeType: string;
  startTicks: number;
  subtitles: Array<{
    index: number;
    title: string;
    url: string;
    language?: string;
    isDefault: boolean;
  }>;
  audioTracks: Array<{ index: number; title: string; language?: string }>;
}

export interface PlaybackEvent {
  type: "start" | "progress" | "stop";
  itemId: string;
  mediaSourceId: string;
  playSessionId: string;
  playMethod: PlaybackInfo["playMethod"];
  positionTicks: number;
  isPaused?: boolean;
  isMuted?: boolean;
  volumeLevel?: number;
}

/** Only non-secret preferences and demo favorites are persisted in the webview. */
export interface Preferences {
  maxBitrateMbps: number;
  autoplayNext: boolean;
  defaultSubtitle: boolean;
  reduceMotion: boolean;
}

export interface EmbyUserData {
  PlaybackPositionTicks?: number;
  PlayedPercentage?: number;
  IsFavorite?: boolean;
  Played?: boolean;
}

/** Only the Emby fields consumed by this client are declared here. */
export interface EmbyItem {
  Id: string;
  Name?: string;
  OriginalTitle?: string;
  Type?: string;
  Overview?: string;
  ProductionYear?: number;
  RunTimeTicks?: number;
  CommunityRating?: number;
  Genres?: string[];
  Taglines?: string[];
  PrimaryImageUrl?: string | null;
  BackdropImageUrl?: string | null;
  UserData?: EmbyUserData | null;
  SeriesId?: string;
  SeriesName?: string;
  ParentIndexNumber?: number;
  IndexNumber?: number;
  ChildCount?: number;
}
