function stableScopeHash(value){
  let hash=2166136261;
  for(const character of String(value||"")){hash^=character.charCodeAt(0);hash=Math.imul(hash,16777619);}
  return (hash>>>0).toString(36);
}
const CACHE_SCOPE_KEY=stableScopeHash(self.registration?.scope||self.location.href);
const CACHE_FAMILY=`rce-report-card-${CACHE_SCOPE_KEY}-`;
const CACHE_NAME=`${CACHE_FAMILY}v7-3-9-final-r1`;
const matchCurrentCache=request=>caches.open(CACHE_NAME).then(cache=>cache.match(request));
const STATIC_ASSETS = [
  "./","index.html","style.css","app.js","config.js","manifest.webmanifest",
  "assets/nipe-school-logo.png","assets/approved-terminal-report-template.png","assets/approved-terminal-report-template.pdf",
  "assets/vendor/supabase-2.110.5.js","assets/vendor/qrcode-1.0.0.min.js",
  "assets/vendor/pdfjs-3.11.174.min.js","assets/vendor/pdfjs-3.11.174.worker.min.js",
  "assets/vendor/jszip-3.10.1.min.js","assets/vendor/docx-preview-0.4.0.min.js",
  "assets/vendor/html2canvas-1.4.1.min.js"
];
self.addEventListener("install",event=>{
  event.waitUntil(caches.open(CACHE_NAME).then(cache=>cache.addAll(STATIC_ASSETS)).then(()=>self.skipWaiting()));
});
self.addEventListener("activate",event=>{
  event.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(key=>key.startsWith(CACHE_FAMILY)&&key!==CACHE_NAME).map(key=>caches.delete(key)))).then(()=>self.clients.claim()));
});
self.addEventListener("fetch",event=>{
  const request=event.request;
  if(request.method!=="GET")return;
  const url=new URL(request.url);
  if(url.hostname.endsWith(".supabase.co")){
    event.respondWith(fetch(request).catch(()=>new Response(JSON.stringify({message:"offline"}),{status:503,headers:{"Content-Type":"application/json"}})));
    return;
  }
  if(url.pathname.endsWith("/config.js")){
    event.respondWith(fetch(request,{cache:"no-store"}).then(response=>{
      if(response.ok){const clone=response.clone();caches.open(CACHE_NAME).then(cache=>cache.put(request,clone));}
      return response;
    }).catch(()=>matchCurrentCache(request)));
    return;
  }
  if(request.mode==="navigate"){
    event.respondWith(fetch(request).then(response=>{
      const clone=response.clone();caches.open(CACHE_NAME).then(cache=>cache.put("index.html",clone));return response;
    }).catch(()=>matchCurrentCache("index.html")));
    return;
  }
  event.respondWith(matchCurrentCache(request).then(cached=>cached||fetch(request).then(response=>{
    if(response.ok&&(url.origin===self.location.origin||url.hostname.includes("cdn"))) {
      const clone=response.clone();caches.open(CACHE_NAME).then(cache=>cache.put(request,clone));
    }
    return response;
  })));
});
self.addEventListener("sync",event=>{
  if(event.tag==="rce-outbox"||event.tag==="nis-outbox")event.waitUntil(self.clients.matchAll({type:"window",includeUncontrolled:true}).then(clients=>clients.forEach(client=>client.postMessage({type:"FLUSH_OUTBOX"}))));
});
self.addEventListener("message",event=>{
  if(event.data?.type==="SKIP_WAITING")self.skipWaiting();
});
