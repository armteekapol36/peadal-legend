// PEADAL LEGEND — service worker
// Exists only so Android/Chrome will offer "Add to Home Screen / Install app". It deliberately caches nothing:
// this page and its data change often (new features, live leaderboard), so the app must always fetch fresh from
// the network. If you ever want real offline support, add a cache here — but that also means every future update
// needs a cache-busting step, or people get stuck on an old version.
self.addEventListener('install', (e)=>{ self.skipWaiting(); });
self.addEventListener('activate', (e)=>{ e.waitUntil(self.clients.claim()); });
self.addEventListener('fetch', (e)=>{ e.respondWith(fetch(e.request)); });
