// humm.. search: free full songs from Audius (no key needed), plus YouTube when YT_API_KEY is set in Vercel.
const dec = s => String(s || '').replace(/&amp;/g, '&').replace(/&#39;/g, "'").replace(/&quot;/g, '"').replace(/&lt;/g, '<').replace(/&gt;/g, '>');
module.exports = async (req, res) => {
  const q = String((req.query && req.query.q) || '').trim().slice(0, 100);
  res.setHeader('content-type', 'application/json; charset=utf-8');
  res.setHeader('cache-control', 'public, s-maxage=600, stale-while-revalidate=3600');
  if (!q) return res.end(JSON.stringify({ results: [] }));
  const enc = encodeURIComponent(q), au = [], yt = [], key = process.env.YT_API_KEY;
  const withTimeout = (p, ms) => Promise.race([p, new Promise(r => setTimeout(r, ms))]);
  await Promise.all([
    withTimeout(fetch(`https://api.audius.co/v1/tracks/search?query=${enc}&app_name=humm&limit=20`).then(r => r.json()).then(j => {
      (j.data || []).filter(t => t && t.id && t.is_streamable !== false && (t.duration || 0) >= 40).slice(0, 15).forEach(t => au.push({
        id: 'au:' + t.id, title: t.title || 'Untitled', artist: (t.user && t.user.name) || '',
        thumb: (t.artwork && (t.artwork['480x480'] || t.artwork['150x150'])) || '', secs: t.duration || 0
      }));
    }).catch(() => {}), 6000),
    key ? withTimeout(fetch(`https://www.googleapis.com/youtube/v3/search?part=snippet&type=video&videoEmbeddable=true&videoCategoryId=10&maxResults=12&safeSearch=moderate&q=${enc}&key=${key}`).then(r => r.json()).then(j => {
      (j.items || []).forEach(x => { if (x.id && x.id.videoId) yt.push({
        id: x.id.videoId, title: dec(x.snippet.title), artist: dec(x.snippet.channelTitle).replace(/ - Topic$/, ''),
        thumb: (x.snippet.thumbnails && (x.snippet.thumbnails.medium || x.snippet.thumbnails.default) || {}).url || `https://i.ytimg.com/vi/${x.id.videoId}/mqdefault.jpg`
      }); });
    }).catch(() => {}), 6000) : null
  ]);
  res.end(JSON.stringify({ results: [...yt, ...au], youtube: !!key }));
};
