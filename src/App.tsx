import {
  lazy,
  Suspense,
  useCallback,
  useEffect,
  useRef,
  useState,
} from "react";
import {
  ArrowRight,
  Check,
  Clapperboard,
  Compass,
  Film,
  Heart,
  Info,
  LoaderCircle,
  Menu,
  Play,
  Plus,
  Search,
  Server,
  Settings,
  SlidersHorizontal,
  Tv,
  X,
} from "lucide-react";
import { api, getPreferences, savePreferences } from "./lib/api";
import { formatDuration } from "./lib/format";
import type {
  HomeData,
  LibraryQuery,
  MediaItem,
  Preferences,
  Session,
} from "./types";
import { MediaCard } from "./components/MediaCard";
import { ConnectDialog, errorText } from "./components/ConnectDialog";
import { DetailDialog } from "./components/DetailDialog";
import { SettingsDialog } from "./components/SettingsDialog";
const Player = lazy(() => import("./components/Player"));

type Page =
  "home" | "movies" | "series" | "favorites" | "library" | "resume" | "search";
const titles: Record<Page, string> = {
  home: "发现",
  movies: "电影",
  series: "剧集",
  favorites: "我的收藏",
  library: "媒体库",
  resume: "继续观看",
  search: "搜索",
};
const navigation = [
  { id: "home", title: "发现", icon: Compass },
  { id: "movies", title: "电影", icon: Film },
  { id: "series", title: "剧集", icon: Tv },
  { id: "favorites", title: "我的收藏", icon: Heart },
] as const;

type DashboardState = {
  key: string;
  sessionKey: string;
  data: HomeData | null;
  loading: boolean;
  error: string;
};
type LibraryState = {
  key: string;
  items: MediaItem[];
  total: number;
  nextIndex: number;
  loading: boolean;
  error: string;
};

export default function App() {
  const [session, setSession] = useState<Session | null>(null);
  const [ready, setReady] = useState(false);
  const [sessionError, setSessionError] = useState("");
  const [sessionRetry, setSessionRetry] = useState(0);
  const [page, setPage] = useState<Page>("home");
  const [parent, setParent] = useState<MediaItem | null>(null);
  const [search, setSearch] = useState("");
  const [debounced, setDebounced] = useState("");
  const [sort, setSort] = useState<LibraryQuery["sortBy"]>("DateCreated");
  const [dashboard, setDashboard] = useState<DashboardState>({
    key: "",
    sessionKey: "",
    data: null,
    loading: true,
    error: "",
  });
  const [library, setLibrary] = useState<LibraryState>({
    key: "",
    items: [],
    total: 0,
    nextIndex: 0,
    loading: true,
    error: "",
  });
  const [loadingMoreKey, setLoadingMoreKey] = useState<string | null>(null);
  const [revision, setRevision] = useState(0);
  const [toast, setToast] = useState("");
  const [connect, setConnect] = useState(false);
  const [settings, setSettings] = useState(false);
  const [detail, setDetail] = useState<MediaItem | null>(null);
  const [playing, setPlaying] = useState<MediaItem | null>(null);
  const [sidebar, setSidebar] = useState(false);
  const [preferences, setPreferences] = useState(getPreferences);
  const searchRef = useRef<HTMLInputElement>(null);
  const scrollRef = useRef<HTMLDivElement>(null);
  const queryId = useRef(0);
  const favoritePending = useRef(new Set<string>());
  const dashboardRequest = useRef<{
    key: string;
    promise: Promise<HomeData>;
  } | null>(null);
  const activeListKey = useRef("");
  const moreRequest = useRef<object | null>(null);
  useEffect(() => {
    let alive = true;
    setReady(false);
    setSessionError("");
    api
      .getSession()
      .then((value) => {
        if (alive) setSession(value);
      })
      .catch((e) => {
        if (alive) setSessionError(errorText(e));
      })
      .finally(() => {
        if (alive) setReady(true);
      });
    return () => {
      alive = false;
    };
  }, [sessionRetry]);
  useEffect(() => {
    const timer = setTimeout(() => setDebounced(search.trim()), 250);
    return () => clearTimeout(timer);
  }, [search]);
  useEffect(() => {
    if (!toast) return;
    const timer = setTimeout(() => setToast(""), 3500);
    return () => clearTimeout(timer);
  }, [toast]);
  useEffect(() => {
    document.documentElement.dataset.reduceMotion = String(
      preferences.reduceMotion,
    );
  }, [preferences.reduceMotion]);
  useEffect(() => {
    const key = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") {
        e.preventDefault();
        searchRef.current?.focus();
      }
    };
    document.addEventListener("keydown", key);
    return () => document.removeEventListener("keydown", key);
  }, []);
  const navigate = useCallback(
    (value: Page, library: MediaItem | null = null) => {
      setPage(value);
      setParent(library);
      setSearch("");
      setDebounced("");
      setSidebar(false);
      scrollRef.current?.scrollTo({ top: 0 });
    },
    [],
  );
  const trimmedSearch = search.trim();
  const activePage = trimmedSearch ? "search" : page;
  const searchPending = activePage === "search" && trimmedSearch !== debounced;
  const sessionKey = session
    ? JSON.stringify([session.serverUrl, session.userId, session.deviceId])
    : "demo";
  const dashboardKey = JSON.stringify([sessionKey, revision]);
  const query: LibraryQuery = {
    kind:
      activePage === "movies"
        ? "movie"
        : activePage === "series"
          ? "series"
          : "all",
    parentId: activePage === "library" ? parent?.id : undefined,
    search: activePage === "search" ? debounced : undefined,
    favorites: activePage === "favorites",
    sortBy: sort,
    sortOrder: sort === "SortName" ? "Ascending" : "Descending",
    limit: 40,
  };
  const queryKey = JSON.stringify(query);
  const listKey = JSON.stringify([
    sessionKey,
    revision,
    activePage,
    queryKey,
    trimmedSearch,
  ]);
  activeListKey.current = listKey;

  // The dashboard is shared by discovery, resume, and sidebar views. Navigation
  // never refetches it; an in-flight promise also survives StrictMode effect replay.
  useEffect(() => {
    if (!ready || sessionError) return;
    let alive = true;
    setDashboard((previous) => ({
      key: dashboardKey,
      sessionKey,
      data: previous.sessionKey === sessionKey ? previous.data : null,
      loading: true,
      error: "",
    }));
    if (dashboardRequest.current?.key !== dashboardKey) {
      dashboardRequest.current = { key: dashboardKey, promise: api.getHome() };
    }
    dashboardRequest.current.promise
      .then((data) => {
        if (alive)
          setDashboard({
            key: dashboardKey,
            sessionKey,
            data,
            loading: false,
            error: "",
          });
      })
      .catch((e) => {
        if (alive)
          setDashboard((previous) => ({
            ...previous,
            loading: false,
            error: errorText(e),
          }));
      });
    return () => {
      alive = false;
    };
  }, [ready, sessionError, sessionKey, dashboardKey]);

  // Keyed state hides the previous page immediately, before an effect can run.
  // Search waits for its own non-empty, current debounced text before requesting.
  useEffect(() => {
    const id = ++queryId.current;
    moreRequest.current = null;
    setLoadingMoreKey(null);
    if (
      !ready ||
      sessionError ||
      activePage === "home" ||
      activePage === "resume" ||
      searchPending
    )
      return;
    let alive = true;
    const isCurrent = () =>
      alive && id === queryId.current && activeListKey.current === listKey;
    setLibrary({
      key: listKey,
      items: [],
      total: 0,
      nextIndex: 0,
      loading: true,
      error: "",
    });
    api
      .getLibrary(JSON.parse(queryKey) as LibraryQuery)
      .then((data) => {
        if (isCurrent())
          setLibrary({
            key: listKey,
            items: data.items,
            total: data.total,
            nextIndex: data.items.length || data.total,
            loading: false,
            error: "",
          });
      })
      .catch((e) => {
        if (isCurrent())
          setLibrary({
            key: listKey,
            items: [],
            total: 0,
            nextIndex: 0,
            loading: false,
            error: errorText(e),
          });
      });
    return () => {
      alive = false;
    };
  }, [ready, sessionError, activePage, searchPending, listKey, queryKey]);

  const home = dashboard.sessionKey === sessionKey ? dashboard.data : null;
  const dashboardPage = activePage === "home" || activePage === "resume";
  const homeLoading = dashboard.key !== dashboardKey || dashboard.loading;
  const listCurrent = library.key === listKey;
  const items =
    activePage === "resume"
      ? (home?.resume ?? [])
      : !dashboardPage && listCurrent
        ? library.items
        : [];
  const total =
    activePage === "resume"
      ? items.length
      : !dashboardPage && listCurrent
        ? library.total
        : 0;
  const loading =
    !ready ||
    (dashboardPage
      ? homeLoading
      : searchPending || !listCurrent || library.loading);
  const error =
    sessionError ||
    (dashboardPage
      ? dashboard.key === dashboardKey
        ? dashboard.error
        : ""
      : !searchPending && listCurrent
        ? library.error
        : "");
  const loadingMore = loadingMoreKey === listKey;
  const hasMore =
    !dashboardPage && listCurrent && library.nextIndex < library.total;

  async function loadMore() {
    if (loading || !hasMore || moreRequest.current) return;
    const id = queryId.current;
    const request = {};
    moreRequest.current = request;
    setLoadingMoreKey(listKey);
    const isCurrent = () =>
      id === queryId.current &&
      activeListKey.current === listKey &&
      moreRequest.current === request;
    try {
      const data = await api.getLibrary({
        ...query,
        startIndex: library.nextIndex,
      });
      if (isCurrent())
        setLibrary((previous) => {
          if (previous.key !== listKey) return previous;
          const knownIds = new Set(previous.items.map((item) => item.id));
          const additions = data.items.filter((item) => {
            if (knownIds.has(item.id)) return false;
            knownIds.add(item.id);
            return true;
          });
          return {
            ...previous,
            items: [...previous.items, ...additions],
            total: data.total,
            nextIndex: data.items.length
              ? previous.nextIndex + data.items.length
              : data.total,
          };
        });
    } catch (e) {
      if (isCurrent()) setToast(errorText(e));
    } finally {
      if (isCurrent()) {
        moreRequest.current = null;
        setLoadingMoreKey(null);
      }
    }
  }
  function reload() {
    if (sessionError) setSessionRetry((value) => value + 1);
    else setRevision((value) => value + 1);
  }
  const favorite = useCallback(async (item: MediaItem) => {
    if (favoritePending.current.has(item.id)) return;
    favoritePending.current.add(item.id);
    try {
      await api.setFavorite(item.id, !item.isFavorite);
      setRevision((v) => v + 1);
      setToast(item.isFavorite ? "已从收藏中移除" : "已加入我的收藏");
    } catch (e) {
      setToast(errorText(e));
      throw e;
    } finally {
      favoritePending.current.delete(item.id);
    }
  }, []);
  const cardFavorite = useCallback(
    (item: MediaItem) => {
      void favorite(item).catch(() => {});
    },
    [favorite],
  );
  const play = useCallback((item: MediaItem) => {
    if (item.type === "series") {
      setDetail(item);
      return;
    }
    setDetail(null);
    setPlaying(item);
  }, []);
  function changePreferences(patch: Partial<Preferences>) {
    setPreferences(savePreferences(patch));
  }
  async function disconnect() {
    try {
      await api.disconnect();
    } catch (e) {
      setToast(errorText(e));
    } finally {
      setSession(null);
      setSessionError("");
      setSettings(false);
      setDetail(null);
      setPlaying(null);
      navigate("home");
      setRevision((v) => v + 1);
    }
  }
  const featured =
    home?.featured ??
    home?.movies[0] ??
    home?.series[0] ??
    home?.latest[0] ??
    home?.resume[0];
  const mediaProps = {
    onOpen: setDetail,
    onPlay: play,
    onFavorite: cardFavorite,
  };
  const displayTitle =
    activePage === "library"
      ? (parent?.title ?? "媒体库")
      : activePage === "search"
        ? `“${search.trim()}”`
        : titles[activePage];
  return (
    <div className="app-shell">
      <button
        className={`sidebar-scrim ${sidebar ? "visible" : ""}`}
        aria-label="收起导航"
        onClick={() => setSidebar(false)}
      />
      <aside className={`sidebar ${sidebar ? "expanded" : ""}`}>
        <button
          className="brand"
          aria-label="Luma 首页"
          onClick={() => navigate("home")}
        >
          <span className="brand-mark">
            <Play size={17} fill="currentColor" />
          </span>
          <span>Luma</span>
        </button>
        <nav aria-label="主要导航">
          {navigation.map(({ id, title, icon: Icon }) => (
            <button
              key={id}
              aria-label={title}
              className={`nav-item ${activePage === id ? "active" : ""}`}
              aria-current={activePage === id ? "page" : undefined}
              onClick={() => navigate(id)}
            >
              <Icon size={20} />
              <span>{title}</span>
              {id === "favorites" && <span className="nav-hover-dot" />}
            </button>
          ))}
        </nav>
        <div className="library-nav">
          <h2>媒体库</h2>
          {(home?.views ?? []).map((view) => (
            <button
              key={view.id}
              aria-label={view.title}
              className={`nav-item ${page === "library" && parent?.id === view.id ? "active" : ""}`}
              onClick={() => navigate("library", view)}
            >
              <Clapperboard size={19} />
              <span>{view.title}</span>
            </button>
          ))}
        </div>
        <div className="sidebar-bottom">
          <button
            className="server-status"
            aria-label={session ? "服务器与账户" : "连接服务器"}
            onClick={() => (session ? setSettings(true) : setConnect(true))}
          >
            <i className={session ? "online" : "demo"} />
            <span>
              <strong>{session?.serverName ?? "演示媒体库"}</strong>
              <small>
                {session ? `已连接 · ${session.userName}` : "未连接服务器"}
              </small>
            </span>
            {!session && <Plus size={16} />}
          </button>
          <button
            className="nav-item"
            aria-label="设置"
            onClick={() => setSettings(true)}
          >
            <Settings size={20} />
            <span>设置</span>
          </button>
          <p className="sidebar-footnote">你的故事，随时开场。</p>
        </div>
      </aside>
      <div className="main-scroll" ref={scrollRef}>
        <header
          className={`topbar ${activePage === "home" ? "over-hero" : ""}`}
        >
          <div className="breadcrumbs">
            <button
              className="icon-button mobile-menu"
              aria-label="展开导航"
              onClick={() => setSidebar(true)}
            >
              <Menu size={20} />
            </button>
            <span>我的媒体</span>
            <span className="breadcrumb-divider">/</span>
            <strong>{activePage === "search" ? "搜索" : displayTitle}</strong>
          </div>
          <div className="topbar-right">
            <div className="search-box">
              <Search size={17} />
              <input
                ref={searchRef}
                aria-label="搜索电影、剧集"
                placeholder="搜索电影、剧集…"
                value={search}
                onChange={(e) => setSearch(e.target.value)}
              />
              {search ? (
                <button
                  className="icon-button"
                  aria-label="清空搜索"
                  onClick={() => setSearch("")}
                >
                  <X size={15} />
                </button>
              ) : (
                <kbd>⌘ K</kbd>
              )}
            </div>
            <button
              className="profile-avatar"
              aria-label={session ? "账户与设置" : "连接服务器"}
              onClick={() => (session ? setSettings(true) : setConnect(true))}
            >
              {session?.userName.slice(0, 1).toUpperCase() ?? "L"}
            </button>
          </div>
        </header>
        {activePage === "home" && loading && !home && !error && (
          <div className="page-loading">
            <LoaderCircle size={30} className="spin" />
            <span>正在打开你的影院…</span>
          </div>
        )}
        {error ? (
          <div className="page-error">
            <Server size={36} />
            <h1>暂时无法加载媒体</h1>
            <p>{error}</p>
            <div className="hero-actions">
              <button className="button primary" onClick={reload}>
                重新加载
              </button>
              <button
                className="button secondary"
                onClick={() => setConnect(true)}
              >
                连接服务器
              </button>
            </div>
          </div>
        ) : activePage === "home" && featured ? (
          <>
            <section className="hero" aria-label="精选影片">
              <img
                className="hero-art"
                src={featured.backdropUrl ?? featured.imageUrl}
                alt=""
                fetchPriority="high"
              />
              <div className="hero-fade" />
              <div className="hero-copy">
                <h1>{featured.title}</h1>
                {featured.originalTitle && (
                  <p className="hero-original">{featured.originalTitle}</p>
                )}
                <p className="meta-line">
                  {featured.year}
                  <span>·</span>
                  {featured.genres.slice(0, 2).join(" / ")}
                  <span>·</span>
                  {formatDuration(featured.durationMinutes)}
                </p>
                <p className="hero-overview">{featured.overview}</p>
                <div className="hero-actions">
                  <button
                    className="button primary hero-play"
                    onClick={() => play(featured)}
                  >
                    <Play size={19} fill="currentColor" />
                    播放
                  </button>
                  <button
                    className="button glass"
                    onClick={() => cardFavorite(featured)}
                  >
                    <Heart
                      size={19}
                      fill={featured.isFavorite ? "currentColor" : "none"}
                    />
                    {featured.isFavorite ? "已收藏" : "我的收藏"}
                  </button>
                  <button
                    className="icon-button hero-info"
                    onClick={() => setDetail(featured)}
                    aria-label={`查看 ${featured.title} 详情`}
                  >
                    <Info size={22} />
                  </button>
                </div>
              </div>
            </section>
            <div className="home-content">
              {home!.resume.length > 0 && (
                <section className="media-section resume-section">
                  <div className="section-heading">
                    <h2>继续观看</h2>
                    <button
                      className="text-button"
                      onClick={() => navigate("resume")}
                    >
                      查看全部
                      <ArrowRight size={17} />
                    </button>
                  </div>
                  <div className="resume-grid">
                    {home!.resume.slice(0, 3).map((item) => (
                      <MediaCard
                        key={item.id}
                        item={item}
                        wide
                        {...mediaProps}
                      />
                    ))}
                  </div>
                </section>
              )}
              <section className="media-section">
                <div className="section-heading">
                  <h2>为你精选</h2>
                  <button
                    className="text-button"
                    onClick={() => navigate("movies")}
                  >
                    查看全部
                    <ArrowRight size={17} />
                  </button>
                </div>
                <div className="featured-grid">
                  {home!.latest.slice(0, 5).map((item) => (
                    <MediaCard key={item.id} item={item} {...mediaProps} />
                  ))}
                </div>
              </section>
              {home!.series.length > 0 && (
                <section className="media-section">
                  <div className="section-heading">
                    <h2>值得追的好故事</h2>
                    <button
                      className="text-button"
                      onClick={() => navigate("series")}
                    >
                      探索剧集
                      <ArrowRight size={17} />
                    </button>
                  </div>
                  <div className="featured-grid">
                    {home!.series.slice(0, 5).map((item) => (
                      <MediaCard key={item.id} item={item} {...mediaProps} />
                    ))}
                  </div>
                </section>
              )}
              {!session && (
                <div className="demo-banner">
                  <span className="demo-symbol">
                    <Server size={22} />
                  </span>
                  <div>
                    <strong>好看的界面，装得下你的整个影院。</strong>
                    <p>当前为演示内容。连接 Emby，发现属于你的电影与剧集。</p>
                  </div>
                  <button
                    className="button secondary small"
                    onClick={() => setConnect(true)}
                  >
                    连接服务器
                    <ArrowRight size={16} />
                  </button>
                </div>
              )}
              <footer className="page-footer">
                <span>Luma</span>
                <p>留一点时间，给好故事。</p>
              </footer>
            </div>
          </>
        ) : activePage === "home" ? (
          !loading ? (
            <div className="library-content">
              <div className="empty-state">
                <Film size={40} />
                <h1>你的影院，等待第一部好故事</h1>
                <p>在 Emby 中添加电影或剧集，刷新后即可在这里发现它们。</p>
                <button className="button secondary" onClick={reload}>
                  刷新媒体库
                  <ArrowRight size={17} />
                </button>
              </div>
            </div>
          ) : null
        ) : (
          <div className="library-content">
            <div className="library-heading">
              <div>
                <h1>{displayTitle}</h1>
                <p>
                  {loading
                    ? activePage === "search"
                      ? "正在查找相关作品…"
                      : "正在加载你的媒体…"
                    : activePage === "search"
                      ? `找到 ${total} 个相关结果`
                      : activePage === "favorites"
                        ? "把喜欢的故事，留在身边。"
                        : `${total} ${activePage === "series" ? "部剧集" : "部作品"}，等一个好时光。`}
                </p>
              </div>
              {activePage !== "resume" && (
                <label className="sort-control">
                  <SlidersHorizontal size={16} />
                  <select
                    aria-label="排序方式"
                    value={sort}
                    onChange={(e) =>
                      setSort(e.target.value as LibraryQuery["sortBy"])
                    }
                  >
                    <option value="DateCreated">最近添加</option>
                    <option value="SortName">名称顺序</option>
                    <option value="ProductionYear">上映年份</option>
                    <option value="CommunityRating">评分最高</option>
                  </select>
                </label>
              )}
            </div>
            {loading ? (
              <div className="skeleton-grid">
                {Array.from({ length: 10 }, (_, i) => (
                  <div className="skeleton" key={i} />
                ))}
              </div>
            ) : items.length ? (
              <>
                <div
                  className={`library-grid ${activePage === "resume" ? "resume-library" : ""}`}
                >
                  {items.map((item) => (
                    <MediaCard
                      key={item.id}
                      item={item}
                      wide={activePage === "resume"}
                      {...mediaProps}
                    />
                  ))}
                </div>
                {hasMore && (
                  <button
                    className="button secondary load-more"
                    disabled={loadingMore}
                    onClick={loadMore}
                  >
                    {loadingMore ? (
                      <LoaderCircle className="spin" size={17} />
                    ) : (
                      <Plus size={17} />
                    )}
                    加载更多（{items.length} / {total}）
                  </button>
                )}
              </>
            ) : (
              <div className="empty-state">
                {activePage === "favorites" ? (
                  <Heart size={40} />
                ) : activePage === "search" ? (
                  <Search size={40} />
                ) : (
                  <Film size={40} />
                )}
                <h2>
                  {activePage === "favorites"
                    ? "收藏，让好故事不再错过"
                    : activePage === "search"
                      ? "暂时没有找到这部作品"
                      : "这里还没有影片"}
                </h2>
                <p>
                  {activePage === "favorites"
                    ? "点击影片上的爱心，它就会出现在这里。"
                    : activePage === "search"
                      ? "试试其他片名，或缩短搜索关键词。"
                      : "在 Emby 中添加媒体，刷新后即可浏览。"}
                </p>
                <button
                  className="button secondary"
                  onClick={() => navigate("home")}
                >
                  回到发现
                  <ArrowRight size={17} />
                </button>
              </div>
            )}
          </div>
        )}
      </div>
      {toast && (
        <div role="status" className="toast">
          <Check size={17} />
          {toast}
        </div>
      )}
      {connect && (
        <ConnectDialog
          onClose={() => setConnect(false)}
          onConnect={(value) => {
            setSession(value);
            setSessionError("");
            setReady(true);
            setConnect(false);
            navigate("home");
            setRevision((v) => v + 1);
            setToast(`已连接 ${value.serverName}`);
          }}
        />
      )}
      {settings && (
        <SettingsDialog
          session={session}
          preferences={preferences}
          onChange={changePreferences}
          onClose={() => setSettings(false)}
          onConnect={() => {
            setSettings(false);
            setConnect(true);
          }}
          onDisconnect={() => {
            void disconnect();
          }}
        />
      )}
      {detail && (
        <DetailDialog
          initial={detail}
          onClose={() => setDetail(null)}
          onPlay={play}
          onFavorite={favorite}
        />
      )}
      {playing && (
        <Suspense
          fallback={
            <div className="modal-backdrop">
              <LoaderCircle className="spin" size={36} />
            </div>
          }
        >
          <Player
            key={playing.id}
            item={playing}
            preferences={preferences}
            onClose={() => {
              setPlaying(null);
              setRevision((v) => v + 1);
            }}
            onNext={setPlaying}
          />
        </Suspense>
      )}
    </div>
  );
}
