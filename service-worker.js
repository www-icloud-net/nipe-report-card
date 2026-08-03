function stableScopeHash(value){
  let hash=2166136261;
  for(const character of String(value||"")){hash^=character.charCodeAt(0);hash=Math.imul(hash,16777619);}
  return (hash>>>0).toString(36);
}
const CACHE_SCOPE_KEY=stableScopeHash(self.registration?.scope||self.location.href);
const CACHE_FAMILY=`rce-report-card-${CACHE_SCOPE_KEY}-`;
const CACHE_NAME=`${CACHE_FAMILY}v7-4-0-final-r1-production-stability`;
const STATIC_ASSETS=[
  "./","index.html","style.css","app.js","config.js","manifest.webmanifest",
  "assets/school-logo.png","assets/rce-master-logo.png","assets/rce-master-logo-192.png","assets/rce-master-logo-512.png","assets/rce-master-logo-maskable-512.png","assets/favicon-32.png","assets/approved-terminal-report-template.png","assets/approved-terminal-report-template.pdf",
  "assets/vendor/supabase-2.110.5.js","assets/vendor/qrcode-1.0.0.min.js",
  "assets/vendor/pdfjs-3.11.174.min.js","assets/vendor/pdfjs-3.11.174.worker.min.js",
  "assets/vendor/jszip-3.10.1.min.js","assets/vendor/docx-preview-0.4.0.min.js",
  "assets/vendor/html2canvas-1.4.1.min.js"
];
async function cacheMatch(request){return (await caches.open(CACHE_NAME)).match(request);}
async function cachePut(request,response){
  if(!response||!response.ok||response.type!=="basic")return;
  try{await (await caches.open(CACHE_NAME)).put(request,response.clone());}catch{}
}
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
    event.respondWith(fetch(request).catch(()=>new Response(JSON.stringify({message:"offline"}),{status:503,headers:{"Content-Type":"application/json","Cache-Control":"no-store"}})));
    return;
  }
  if(url.origin!==self.location.origin){event.respondWith(fetch(request));return;}
  if(url.pathname.endsWith("/config.js")){
    event.respondWith((async()=>{
      try{const response=await fetch(request,{cache:"no-store"});await cachePut(request,response);return response;}
      catch{return await cacheMatch(request)||new Response('window.RCE_CONFIG=Object.freeze({supabaseUrl:"YOUR_SUPABASE_URL",supabaseAnonKey:"YOUR_SUPABASE_PUBLISHABLE_KEY"});',{status:503,headers:{"Content-Type":"application/javascript","Cache-Control":"no-store"}});}
    })());
    return;
  }
  if(request.mode==="navigate"){
    const fallback=new URL("index.html",self.registration.scope).href;
    event.respondWith((async()=>{
      try{const response=await fetch(request);await cachePut(fallback,response);return response;}
      catch{return await cacheMatch(fallback)||new Response("Report Card Enterprise is offline and has not completed its first installation.",{status:503,headers:{"Content-Type":"text/plain; charset=utf-8","Cache-Control":"no-store"}});}
    })());
    return;
  }
  event.respondWith((async()=>{
    const cached=await cacheMatch(request);
    if(cached)return cached;
    const response=await fetch(request);
    await cachePut(request,response);
    return response;
  })());
});
self.addEventListener("sync",event=>{if(event.tag==="rce-outbox"||event.tag==="nis-outbox")event.waitUntil(self.clients.matchAll({type:"window",includeUncontrolled:true}).then(clients=>clients.forEach(client=>client.postMessage({type:"FLUSH_OUTBOX"}))));});
self.addEventListener("message",event=>{if(event.data?.type==="SKIP_WAITING")self.skipWaiting();});
