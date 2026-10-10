import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const invoke = vi.hoisted(() => vi.fn());
vi.mock("@tauri-apps/api/core", () => ({ invoke }));

let storage: Map<string, string>;

beforeEach(() => {
  vi.resetModules();
  invoke.mockReset();
  storage = new Map();
  vi.stubGlobal("window", {});
  vi.stubGlobal("localStorage", {
    getItem: (key: string) => storage.get(key) ?? null,
    setItem: (key: string, value: string) => storage.set(key, value),
  });
});

afterEach(() => vi.unstubAllGlobals());

describe("offline demo mode", () => {
  it("supports search, type filtering, and pagination without contacting a server", async () => {
    const { api } = await import("./api");
    const search = await api.getLibrary({ search: "Tokyo", kind: "series" });
    expect(search.total).toBe(1);
    expect(search.items[0]?.title).toBe("东京夜行");
    expect(await api.getLibrary({ kind: "movie", limit: 2 })).toMatchObject({
      total: 4,
    });
    expect(
      (await api.getLibrary({ kind: "movie", limit: 2 })).items,
    ).toHaveLength(2);
    expect(invoke).not.toHaveBeenCalled();
  });

  it("persists only demo favorite IDs and labels sample playback honestly", async () => {
    const { api } = await import("./api");
    await api.setFavorite("demo-voyage", true);
    expect((await api.getItem("demo-voyage")).isFavorite).toBe(true);
    const playback = await api.getPlayback("demo-voyage", {
      startTicks: 12345,
    });
    expect(playback).toMatchObject({ isDemo: true, startTicks: 0 });
    expect(playback.label).toContain("Sintel");
    await api.reportPlayback({ ...playback, type: "start", positionTicks: 0 });
    await api.cancelPlayback(playback.playSessionId);
    expect([...storage.keys()]).toEqual(["luma.demo.favorites.v1"]);
    expect(invoke).not.toHaveBeenCalled();
  });

  it("rejects browser authentication with a desktop requirement", async () => {
    const { api } = await import("./api");
    await expect(
      api.connect({
        serverUrl: "https://example.com",
        username: "alice",
        password: "private",
      }),
    ).rejects.toMatchObject({ code: "DESKTOP_REQUIRED" });
    expect(storage.size).toBe(0);
  });
});

describe("desktop session", () => {
  it("normalizes server results while keeping credentials and authenticated URLs out of storage", async () => {
    vi.stubGlobal("window", { __TAURI_INTERNALS__: {} });
    const session = {
      serverUrl: "https://example.com",
      userId: "u1",
      userName: "alice",
      serverName: "My Emby",
      deviceId: "d1",
    };
    invoke.mockResolvedValueOnce(session);
    const { api } = await import("./api");
    await api.connect({
      serverUrl: session.serverUrl,
      username: "alice",
      password: "private",
    });
    invoke.mockResolvedValueOnce({
      Items: [
        {
          Id: "m1",
          Name: "Server Movie",
          Type: "Movie",
          PrimaryImageUrl: "https://example.com/image?api_key=secret",
        },
      ],
      TotalRecordCount: 1,
    });
    expect((await api.getLibrary({ kind: "movie" })).items[0]?.title).toBe(
      "Server Movie",
    );
    expect(invoke).toHaveBeenLastCalledWith("library", {
      query: { types: "Movie", limit: 60 },
    });
    expect(api.isDemo).toBe(false);
    expect(storage.size).toBe(0);
  });

  it("preserves structured authentication errors without entering a fake session", async () => {
    vi.stubGlobal("window", { __TAURI_INTERNALS__: {} });
    invoke.mockRejectedValueOnce({
      code: "UNAUTHORIZED",
      message: "用户名或密码不正确。",
    });
    const { api } = await import("./api");
    await expect(
      api.connect({
        serverUrl: "https://example.com",
        username: "alice",
        password: "wrong",
      }),
    ).rejects.toMatchObject({ code: "UNAUTHORIZED" });
    expect(api.isDemo).toBe(true);
  });

  it("clears the local session even when logout cannot reach the server", async () => {
    vi.stubGlobal("window", { __TAURI_INTERNALS__: {} });
    const session = {
      serverUrl: "https://example.com",
      userId: "u1",
      userName: "alice",
      serverName: "My Emby",
      deviceId: "d1",
    };
    invoke.mockResolvedValueOnce(session);
    const { api } = await import("./api");
    await api.connect({
      serverUrl: session.serverUrl,
      username: "alice",
      password: "private",
    });
    invoke.mockRejectedValueOnce({ code: "NETWORK", message: "服务器离线。" });
    await expect(api.disconnect()).rejects.toMatchObject({ code: "NETWORK" });
    expect(api.isDemo).toBe(true);
    expect(await api.getSession()).toBeNull();
    expect((await api.getHome()).featured?.id).toBe("demo-voyage");
    expect(invoke).toHaveBeenCalledTimes(2);
  });

  it("does not restore a session when a pending login finishes after logout", async () => {
    vi.stubGlobal("window", { __TAURI_INTERNALS__: {} });
    const session = {
      serverUrl: "https://example.com",
      userId: "u1",
      userName: "alice",
      serverName: "My Emby",
      deviceId: "d1",
    };
    let completeLogin!: (value: typeof session) => void;
    invoke.mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          completeLogin = resolve;
        }),
    );
    const { api } = await import("./api");
    const connecting = api.connect({
      serverUrl: session.serverUrl,
      username: "alice",
      password: "private",
    });
    await api.disconnect();
    completeLogin(session);
    await expect(connecting).rejects.toMatchObject({
      code: "SESSION_CANCELLED",
    });
    expect(await api.getSession()).toBeNull();
  });

  it("cancels abandoned real playback sessions and ignores the demo session", async () => {
    vi.stubGlobal("window", { __TAURI_INTERNALS__: {} });
    const { api } = await import("./api");
    await api.cancelPlayback("demo");
    expect(invoke).not.toHaveBeenCalled();
    await api.cancelPlayback("playback-123");
    expect(invoke).toHaveBeenCalledExactlyOnceWith("cancel_playback", {
      playSessionId: "playback-123",
    });
  });
});

describe("non-secret preferences", () => {
  it("drops unknown fields and clamps corrupt bitrates before persistence", async () => {
    const { getPreferences, savePreferences } = await import("./api");
    storage.set(
      "luma.preferences.v1",
      JSON.stringify({
        maxBitrateMbps: -40,
        password: "not-allowed",
        autoplayNext: false,
      }),
    );
    expect(getPreferences().maxBitrateMbps).toBe(1);
    savePreferences({ reduceMotion: true });
    expect(storage.get("luma.preferences.v1")).not.toContain("password");
    expect(getPreferences()).toMatchObject({
      reduceMotion: true,
      autoplayNext: false,
    });
  });
});
