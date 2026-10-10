/**
 * Local integration fixture, NOT an Emby Server implementation.
 * Run: node scripts/mock-emby.mjs
 * Login: http://127.0.0.1:8097 — demo / demo
 * Offline MKV fixture: LUMA_QA_SYNTHETIC_MKV=1 node scripts/mock-emby.mjs
 * Optional LUMA_QA_FFMPEG executable and LUMA_QA_PORT override.
 * LUMA_QA_VIDEO_CODEC=hevc enables synthetic HEVC Main 10 + FLAC (default H.264 + AAC).
 * LUMA_QA_SAMPLE_FILE serves a pre-generated local sample instead (maximum 30 MiB).
 * LUMA_QA_MULTITRACK=1 describes a synthetic sample with two FLAC tone tracks
 * and an embedded English SRT; requires SYNTHETIC_MKV=1 and SAMPLE_FILE.
 * Only synthetic metadata is exposed. State is discarded on process exit.
 */
import http from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const HOST = '127.0.0.1';
const PORT = Number(process.env.LUMA_QA_PORT || 8097);
if (!Number.isInteger(PORT) || PORT < 1 || PORT > 65535) throw new Error('Invalid fixture port');
const SYNTHETIC_MKV = process.env.LUMA_QA_SYNTHETIC_MKV === '1';
const SAMPLE_FILE = process.env.LUMA_QA_SAMPLE_FILE || null;
const MULTITRACK = process.env.LUMA_QA_MULTITRACK === '1';
const SAMPLE_LIMIT = 30 * 1024 * 1024;
if (MULTITRACK && (!SYNTHETIC_MKV || !SAMPLE_FILE)) throw new Error('Multitrack fixture requires SYNTHETIC_MKV=1 and a matching LUMA_QA_SAMPLE_FILE');
const VIDEO_CODEC = SYNTHETIC_MKV ? (process.env.LUMA_QA_VIDEO_CODEC || 'h264') : 'h264';
if (!['h264', 'hevc'].includes(VIDEO_CODEC)) throw new Error('Unsupported LUMA_QA_VIDEO_CODEC; use h264 or hevc');
const AUDIO_CODEC = VIDEO_CODEC === 'hevc' || MULTITRACK ? 'flac' : 'aac';
const videoDescription = SYNTHETIC_MKV ? '本机合成的彩色测试图与低音量提示音' : 'Blender Foundation 的 Sintel 预告片';
const USER_ID = 'qa-user';
const TICKS = 10_000_000;
const SAMPLE_URL = 'https://media.w3.org/2010/05/sintel/trailer.mp4';
const mediaRoot = new URL('../macos/Resources/Media/', import.meta.url);
const tokens = new Set();
const events = [];
const requests = new Map();
let sample;

const catalog = Array.from({ length: 60 }, (_, index) => ({
  Id: `qa-movie-${String(index + 1).padStart(3, '0')}`,
  Name: `联调电影 ${String(index + 1).padStart(3, '0')} · ${['星海', '沙丘', '夜行', '群山', '蔚蓝', '森林'][index % 6]}`,
  OriginalTitle: `Integration Fixture ${String(index + 1).padStart(3, '0')}`,
  Type: 'Movie',
  Overview: `这是本地联调服务器的虚构测试条目，用来验证原生客户端请求、分页、搜索、收藏与播放进度。播放内容是${videoDescription}，不是所选片名对应的电影。`,
  ProductionYear: 2020 + (index % 6),
  RunTimeTicks: 52 * TICKS,
  CommunityRating: 7 + (index % 20) / 10,
  Genres: index % 2 ? ['冒险', '测试内容'] : ['科幻', '测试内容'],
  DateCreated: new Date(Date.UTC(2025, 0, index + 1)).toISOString(),
  ImageTags: { Primary: `fixture-poster-${index % 6 + 1}` },
  BackdropImageTags: ['fixture-hero'],
  UserData: { IsFavorite: index === 0 || index === 2, Played: false, PlaybackPositionTicks: index < 3 ? (index + 1) * 10 * TICKS : 0 },
  ParentId: 'qa-movies',
  PosterNumber: index % 6 + 1,
}));

const series = {
  ...catalog[2], Id: 'qa-series', Name: '联调剧集 · 夜行三章', OriginalTitle: 'Integration Series',
  Type: 'Series', ChildCount: 3, ParentId: 'qa-shows',
  Overview: `本地联调用虚构剧集，共三集，供剧集列表和下一集测试使用。每集播放同一段${videoDescription}。`,
  UserData: { IsFavorite: false, Played: false, PlaybackPositionTicks: 0 },
};
catalog.push(series);
for (let index = 0; index < 3; index += 1) {
  catalog.push({
    ...series, Id: `qa-episode-${index + 1}`, Type: 'Episode',
    Name: `第 ${index + 1} 集 · 联调测试`, ParentId: 'qa-series', SeriesId: 'qa-series',
    SeriesName: series.Name, ParentIndexNumber: 1, IndexNumber: index + 1,
    ChildCount: undefined,
    UserData: { IsFavorite: false, Played: false, PlaybackPositionTicks: index === 0 ? 5 * TICKS : 0 },
  });
}

const views = [
  { Id: 'qa-movies', Name: '测试电影库', Type: 'CollectionFolder', CollectionType: 'movies', ChildCount: 60 },
  { Id: 'qa-shows', Name: '测试剧集库', Type: 'CollectionFolder', CollectionType: 'tvshows', ChildCount: 1 },
];

function publicItem(item) {
  const { PosterNumber: _poster, ParentId: _parent, ...result } = item;
  return { ...result, UserData: { ...item.UserData, PlayedPercentage: item.UserData.PlaybackPositionTicks / item.RunTimeTicks * 100 } };
}

function json(res, status, body) {
  const content = JSON.stringify(body);
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': Buffer.byteLength(content), 'Cache-Control': 'no-store' });
  res.end(content);
}

async function body(req) {
  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > 64 * 1024) throw new Error('Fixture request body is too large');
    chunks.push(chunk);
  }
  return chunks.length ? JSON.parse(Buffer.concat(chunks).toString('utf8')) : {};
}

function results(items, query) {
  const start = Math.max(0, Number(query.get('StartIndex')) || 0);
  const limit = Math.max(1, Math.min(200, Number(query.get('Limit')) || 60));
  return { Items: items.slice(start, start + limit).map(publicItem), TotalRecordCount: items.length, StartIndex: start };
}

function filterItems(query) {
  const types = (query.get('IncludeItemTypes') || 'Movie,Series').split(',');
  const search = (query.get('SearchTerm') || '').toLocaleLowerCase().trim();
  const parent = query.get('ParentId');
  const favorite = (query.get('Filters') || '').includes('IsFavorite');
  const items = catalog.filter(item => types.includes(item.Type)
    && (!parent || item.ParentId === parent)
    && (!favorite || item.UserData.IsFavorite)
    && (!search || `${item.Name} ${item.OriginalTitle} ${item.Overview}`.toLocaleLowerCase().includes(search)));
  const property = query.get('SortBy') || 'SortName';
  const direction = query.get('SortOrder') === 'Descending' ? -1 : 1;
  const value = item => property === 'SortName' ? item.Name : item[property] ?? item.Name;
  return items.sort((a, b) => direction * (typeof value(a) === 'number' ? value(a) - value(b) : String(value(a)).localeCompare(String(value(b)), 'zh-CN')));
}

async function sendImage(req, res, name) {
  if (!/^(?:hero|poster-[1-6])\.jpg$/.test(name)) return json(res, 404, { error: 'Unknown fixture image' });
  const content = await readFile(new URL(name, mediaRoot));
  res.writeHead(200, { 'Content-Type': 'image/jpeg', 'Content-Length': content.length, 'Cache-Control': 'public, max-age=3600' });
  res.end(req.method === 'HEAD' ? undefined : content);
}

async function sampleVideo() {
  if (!sample) {
    const videoEncoding = VIDEO_CODEC === 'hevc'
      ? ['-c:v', 'libx265', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p10le', '-x265-params', 'log-level=error:keyint=48:min-keyint=48:scenecut=0:pools=1:frame-threads=1']
      : ['-c:v', 'libx264', '-preset', 'ultrafast', '-g', '48', '-pix_fmt', 'yuv420p'];
    sample = (SAMPLE_FILE ? (async () => {
      const info = await stat(SAMPLE_FILE);
      if (!info.isFile() || info.size < 1 || info.size > SAMPLE_LIMIT) throw new Error('Local sample exceeds fixture limit or is not a regular file');
      const content = await readFile(SAMPLE_FILE);
      if (content.length > SAMPLE_LIMIT) throw new Error('Local sample exceeds fixture limit');
      return content;
    })() : SYNTHETIC_MKV ? promisify(execFile)(process.env.LUMA_QA_FFMPEG || 'ffmpeg', [
      // testsrc includes a burned-in PTS clock without the optional drawtext filter.
      '-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i', 'testsrc=size=640x360:rate=24:decimals=3',
      '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000', '-t', '52',
      ...videoEncoding, '-c:a', AUDIO_CODEC, '-af', 'volume=0.05', '-f', 'matroska', 'pipe:1',
    ], { encoding: 'buffer', maxBuffer: SAMPLE_LIMIT, timeout: 45_000 }).then(result => result.stdout)
      : fetch(SAMPLE_URL, { signal: AbortSignal.timeout(30_000) }).then(async response => {
      if (!response.ok) throw new Error('Sample video unavailable');
      const content = Buffer.from(await response.arrayBuffer());
      if (content.length > SAMPLE_LIMIT) throw new Error('Sample video exceeds fixture limit');
      return content;
    })).catch(error => { sample = undefined; throw error; });
  }
  return sample;
}

async function sendVideo(req, res) {
  let content;
  try { content = await sampleVideo(); }
  catch { return json(res, 503, { error: SAMPLE_FILE ? 'Local sample unavailable or exceeds the 30 MiB fixture limit.' : SYNTHETIC_MKV ? 'Synthetic MKV unavailable; check LUMA_QA_FFMPEG.' : 'Online Sintel sample unavailable; library integration can still be tested.' }); }
  const range = req.headers.range;
  let start = 0;
  let end = content.length - 1;
  if (range) {
    const match = /^bytes=(\d*)-(\d*)$/.exec(range);
    if (!match || (!match[1] && !match[2])) {
      res.writeHead(416, { 'Content-Range': `bytes */${content.length}` });
      return res.end();
    }
    if (!match[1]) start = Math.max(0, content.length - Number(match[2]));
    else {
      start = Number(match[1]);
      if (match[2]) end = Math.min(end, Number(match[2]));
    }
    if (start > end || start >= content.length) {
      res.writeHead(416, { 'Content-Range': `bytes */${content.length}` });
      return res.end();
    }
  }
  const headers = { 'Content-Type': SYNTHETIC_MKV ? 'video/x-matroska' : 'video/mp4', 'Content-Length': end - start + 1, 'Accept-Ranges': 'bytes', 'Cache-Control': 'no-store' };
  if (range) headers['Content-Range'] = `bytes ${start}-${end}/${content.length}`;
  res.writeHead(range ? 206 : 200, headers);
  res.end(req.method === 'HEAD' ? undefined : content.subarray(start, end + 1));
}

const server = http.createServer(async (req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, HEAD, POST, DELETE, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, X-Emby-Token, X-Emby-Authorization, Range');
  res.setHeader('Access-Control-Expose-Headers', 'Content-Length, Content-Range, Accept-Ranges');
  res.setHeader('Access-Control-Allow-Private-Network', 'true');
  if (req.method === 'OPTIONS') { res.writeHead(204); res.end(); return; }
  try {
    const url = new URL(req.url, `http://${HOST}:${PORT}`);
    const route = url.pathname.replace(/^\/emby(?=\/)/, '');
    // Record only methods and paths, never credentials, headers, or query strings.
    const requestKey = `${req.method} ${route}`;
    requests.set(requestKey, (requests.get(requestKey) || 0) + 1);
    if (route === '/__qa/state' && req.method === 'GET') {
      return json(res, 200, { fixture: true, syntheticMKV: SYNTHETIC_MKV, localSample: !!SAMPLE_FILE, multitrack: MULTITRACK, videoCodec: VIDEO_CODEC, audioCodec: AUDIO_CODEC, serverName: 'Luma 测试影院', movieCount: 60, seriesCount: 1, episodeCount: 3, requests: Object.fromEntries(requests), favorites: catalog.filter(item => item.UserData.IsFavorite).map(item => item.Id), events: events.slice(-100), resume: catalog.filter(item => item.UserData.PlaybackPositionTicks > 0).map(item => ({ id: item.Id, positionTicks: item.UserData.PlaybackPositionTicks })) });
    }
    if (route === '/System/Info/Public' && req.method === 'GET') {
      return json(res, 200, { ServerName: 'Luma 测试影院', Version: 'fixture-0.1', Id: 'luma-integration-fixture' });
    }
    if (route === '/Users/AuthenticateByName' && req.method === 'POST') {
      const credentials = await body(req);
      if (credentials.Username !== 'demo' || credentials.Pw !== 'demo') return json(res, 401, { error: 'Fixture login rejected' });
      const token = `fixture-${randomUUID()}`;
      tokens.add(token);
      return json(res, 200, { AccessToken: token, User: { Id: USER_ID, Name: 'demo' }, ServerId: 'luma-integration-fixture' });
    }
    if (/^\/media\/(?:hero|poster-[1-6])\.jpg$/.test(route) && ['GET', 'HEAD'].includes(req.method)) {
      return await sendImage(req, res, route.split('/').at(-1));
    }
    const token = req.headers['x-emby-token'] || url.searchParams.get('api_key');
    if (!tokens.has(token)) return json(res, 401, { error: 'Fixture authentication required' });
    if (route === '/Sessions/Logout' && req.method === 'POST') {
      tokens.delete(token); res.writeHead(204); return res.end();
    }
    if (route === `/Users/${USER_ID}/Views` && req.method === 'GET') return json(res, 200, { Items: views, TotalRecordCount: views.length });
    if (route === `/Users/${USER_ID}/Items/Resume` && req.method === 'GET') return json(res, 200, results(catalog.filter(item => item.Type !== 'Series' && !item.UserData.Played && item.UserData.PlaybackPositionTicks > 0), url.searchParams));
    if (route === `/Users/${USER_ID}/Items/Latest` && req.method === 'GET') return json(res, 200, results(filterItems(url.searchParams).reverse(), url.searchParams).Items);
    if (route === `/Users/${USER_ID}/Items` && req.method === 'GET') return json(res, 200, results(filterItems(url.searchParams), url.searchParams));
    if (route === '/Shows/qa-series/Episodes' && req.method === 'GET') return json(res, 200, results(catalog.filter(item => item.Type === 'Episode'), url.searchParams));
    let match = new RegExp(`^/Users/${USER_ID}/Items/([A-Za-z0-9_-]+)$`).exec(route);
    if (match && req.method === 'GET') {
      const item = catalog.find(item => item.Id === match[1]);
      return item ? json(res, 200, publicItem(item)) : json(res, 404, { error: 'Unknown fixture item' });
    }
    match = new RegExp(`^/Users/${USER_ID}/FavoriteItems/([A-Za-z0-9_-]+)$`).exec(route);
    if (match && ['POST', 'DELETE'].includes(req.method)) {
      const item = catalog.find(item => item.Id === match[1]);
      if (!item) return json(res, 404, { error: 'Unknown fixture item' });
      item.UserData.IsFavorite = req.method === 'POST';
      return json(res, 200, item.UserData);
    }
    match = /^\/Items\/([A-Za-z0-9_-]+)\/Images\/(Primary|Backdrop)(?:\/0)?$/.exec(route);
    if (match && ['GET', 'HEAD'].includes(req.method)) {
      const item = catalog.find(item => item.Id === match[1]);
      if (!item) return json(res, 404, { error: 'Unknown fixture image' });
      return await sendImage(req, res, match[2] === 'Backdrop' ? 'hero.jpg' : `poster-${item.PosterNumber}.jpg`);
    }
    match = /^\/Items\/([A-Za-z0-9_-]+)\/PlaybackInfo$/.exec(route);
    if (match && req.method === 'POST') {
      await body(req);
      const item = catalog.find(item => item.Id === match[1] && item.Type !== 'Series');
      if (!item) return json(res, 404, { error: 'Unknown playable fixture item' });
      const streams = [{ Type: 'Video', Index: 0, Codec: VIDEO_CODEC, BitDepth: VIDEO_CODEC === 'hevc' ? 10 : 8 }];
      if (MULTITRACK) {
        streams.push(
          { Type: 'Audio', Index: 1, Codec: 'flac', Channels: 1, Language: 'zho', DisplayTitle: '中文标记 · 440 Hz 合成提示音', IsDefault: true },
          { Type: 'Audio', Index: 2, Codec: 'flac', Channels: 1, Language: 'eng', DisplayTitle: 'English label · 660 Hz synthetic tone', IsDefault: false },
          { Type: 'Subtitle', Index: 3, Codec: 'subrip', Language: 'eng', DisplayTitle: 'English · Embedded test captions', IsTextSubtitleStream: true, IsExternal: false, IsDefault: true },
        );
      } else {
        streams.push({ Type: 'Audio', Index: 1, Codec: AUDIO_CODEC, Channels: SYNTHETIC_MKV ? 1 : 2, DisplayTitle: SYNTHETIC_MKV ? `合成测试音 · ${AUDIO_CODEC.toUpperCase()}` : 'Sintel 预告片 · AAC' });
      }
      return json(res, 200, { PlaySessionId: `qa-play-${randomUUID()}`, MediaSources: [{ Id: `source-${item.Id}`, Container: SYNTHETIC_MKV ? 'mkv' : 'mp4', RunTimeTicks: item.RunTimeTicks, SupportsDirectPlay: true, SupportsDirectStream: true, SupportsTranscoding: false, DirectStreamUrl: `/emby/Videos/${item.Id}/stream.${SYNTHETIC_MKV ? 'mkv' : 'mp4'}`, MediaStreams: streams }] });
    }
    match = /^\/Videos\/([A-Za-z0-9_-]+)\/stream\.(?:mp4|mkv)$/.exec(route);
    if (match && ['GET', 'HEAD'].includes(req.method)) {
      if (!catalog.some(item => item.Id === match[1])) return json(res, 404, { error: 'Unknown fixture video' });
      return await sendVideo(req, res);
    }
    if (/^\/Sessions\/Playing(?:\/Progress|\/Stopped)?$/.test(route) && req.method === 'POST') {
      const event = await body(req);
      const item = catalog.find(item => item.Id === event.ItemId);
      if (!item) return json(res, 404, { error: 'Unknown playback item' });
      const positionTicks = Math.max(0, Number.isFinite(event.PositionTicks) ? event.PositionTicks : 0);
      item.UserData.PlaybackPositionTicks = Math.min(item.RunTimeTicks, positionTicks);
      item.UserData.Played = item.UserData.PlaybackPositionTicks / item.RunTimeTicks >= 0.95;
      events.push({ type: route.endsWith('/Stopped') ? 'stop' : route.endsWith('/Progress') ? 'progress' : 'start', itemId: item.Id, positionTicks, isPaused: !!event.IsPaused });
      if (events.length > 100) events.shift();
      res.writeHead(204); return res.end();
    }
    if (route === '/Videos/ActiveEncodings' && req.method === 'DELETE') { res.writeHead(204); return res.end(); }
    return json(res, 404, { error: 'Endpoint not implemented by local integration fixture' });
  } catch {
    if (!res.headersSent) json(res, 400, { error: 'Fixture could not process this request' });
    else res.end();
  }
});

server.on('error', error => { console.error(`Fixture failed to start (${error.code || 'unknown error'}).`); process.exitCode = 1; });
server.listen(PORT, HOST, () => {
  console.log(`Luma 测试影院 — local QA fixture listening at http://${HOST}:${PORT}`);
  console.log('Synthetic data: 60 movies, 1 series, 3 episodes.');
  console.log(`Inspection: /__qa/state (no tokens). Video is ${SAMPLE_FILE ? `read from a local sample (${MULTITRACK ? 'two FLAC tracks and embedded SRT' : 'single audio track'})` : SYNTHETIC_MKV ? `generated locally as ${VIDEO_CODEC.toUpperCase()} / ${AUDIO_CODEC.toUpperCase()} MKV with a burned-in clock` : 'fetched from the Sintel sample'} into memory on first playback.`);
});

for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => server.close(() => process.exit(0)));
