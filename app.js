(() => {
  "use strict";

  const CONFIG = Object.freeze({
    supabaseUrl: window.NIS_CONFIG?.supabaseUrl || "YOUR_SUPABASE_URL",
    supabaseAnonKey: window.NIS_CONFIG?.supabaseAnonKey || "YOUR_SUPABASE_ANON_KEY",
    appName: window.NIS_CONFIG?.appName || "Nipe International School Report Card System",
    schoolName: window.NIS_CONFIG?.schoolName || "Nipe International School",
    schoolShortName: window.NIS_CONFIG?.schoolShortName || "Nipe Reports",
    userEmailDomain: window.NIS_CONFIG?.userEmailDomain || "nip.com",
    reportNumberPrefix: window.NIS_CONFIG?.reportNumberPrefix || "NIS",
    generatedSchoolPackage: Boolean(window.NIS_CONFIG?.generatedSchoolPackage),
    logoPath: window.NIS_CONFIG?.logoPath || "assets/nipe-school-logo.png",
    defaultReportTemplatePath: window.NIS_CONFIG?.defaultReportTemplatePath || "assets/approved-terminal-report-template.png",
    photoBucket: "student-photos",
    pdfBucket: "report-pdfs",
    backupBucket: "system-backups",
    signatureBucket: "headteacher-signatures",
    templateBucket: "report-card-templates",
    pageSize: 20
  });

  const ROLE_LABELS = {
    platform_super_admin: "Platform Super Administrator",
    system_admin: "System Administrator",
    principal: "Principal (Headmaster/Headmistress)",
    class_teacher: "Class Teacher",
    subject_teacher: "Subject Teacher",
    parent_guardian: "Parent or Guardian"
  };

  const REPORT_TEMPLATE_GROUPS = Object.freeze([
    {key:"early_years",label:"Creche to Kindergarten (KG 1 and KG 2)",shortLabel:"Creche to KG 2"},
    {key:"basic_1_6",label:"Basic 1 to Basic 6",shortLabel:"Basic 1-6"},
    {key:"basic_7_9",label:"Basic 7 to Basic 9",shortLabel:"Basic 7-9"}
  ]);
  const REPORT_TEMPLATE_MAX_BYTES = 20*1024*1024;
  const REPORT_TEMPLATE_MIME_TYPES = Object.freeze({
    "application/pdf":"pdf",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document":"docx"
  });

  const NAV = [
    {id:"dashboard",label:"Dashboard",icon:"▦",subtitle:"Academic performance overview"},
    {id:"licensing",label:"Platform Licensing",icon:"◇",subtitle:"Licence plans, lifecycle, compliance, and access controls",roles:["platform_super_admin"]},
    {id:"my_class",label:"My Class",icon:"▣",subtitle:"Assigned class, learners, and report progress",roles:["class_teacher"]},
    {id:"attendance",label:"Attendance",icon:"✓",subtitle:"Daily class attendance and automatic term totals",roles:["class_teacher"]},
    {id:"my_subjects",label:"My Subjects",icon:"⌘",subtitle:"Assigned subjects, classes, and assessment progress",roles:["class_teacher","subject_teacher"]},
    {id:"students",label:"Students",icon:"◉",subtitle:"Student records and enrolment",roles:["system_admin","class_teacher","subject_teacher"]},
    {id:"teachers",label:"Teachers",icon:"♜",subtitle:"Teacher records and assignments",permission:"manage_teachers"},
    {id:"headteachers",label:"Principals",icon:"★",subtitle:"Principal records and appointments",permission:"manage_headteachers"},
    {id:"academics",label:"Academics",icon:"⌘",subtitle:"Academic structure and assessment",permission:"manage_academics"},
    {id:"reports",label:"Report Cards",icon:"▤",subtitle:"Assessment, approval, and publication",hideFor:["parent_guardian"]},
    {id:"children",label:"My Children",icon:"♥",subtitle:"Published academic records",roles:["parent_guardian"]},
    {id:"users",label:"Users and Access",icon:"♟",subtitle:"Roles, classes, and security",permission:"manage_users"},
    {id:"notifications",label:"Notifications",icon:"◆",subtitle:"School and workflow alerts"},
    {id:"audit",label:"Audit Trail",icon:"◎",subtitle:"Record changes and accountability",permission:"view_audit"},
    {id:"settings",label:"Settings",icon:"⚙",subtitle:"School identity, security, and resilience",roles:["system_admin"]},
    {id:"github",label:"GitHub Navigator",icon:"⌁",subtitle:"Generate and deploy a reusable school package",roles:["system_admin"]}
  ];

  const ROLE_NAV_IDS = Object.freeze({
    platform_super_admin:["licensing"],
    system_admin:["dashboard","students","teachers","headteachers","academics","reports","users","notifications","audit","settings","github"],
    principal:["dashboard","reports","notifications"],
    class_teacher:["dashboard","my_class","attendance","my_subjects","students","reports","notifications"],
    subject_teacher:["dashboard","my_subjects","students","reports","notifications"],
    parent_guardian:["dashboard","children","notifications"]
  });

  const state = {
    client:null, session:null, boot:null, view:"dashboard", viewToken:0,
    channels:[], photoUrls:new Map(), pdfUrls:new Map(), signatureUrls:new Map(), templateUrls:new Map(), templateCanvases:new Map(), online:navigator.onLine,
    studentPage:1, teacherPage:1, headteacherPage:1, reportPage:1, currentStudent:null, reportEditor:null,
    academicTab:"periods", notifications:[], mfaFactorId:null, mfaEnrollment:null,
    teacherAdmin:null, headteacherAdmin:null, userAdmin:null, userAccessRows:[], assignmentClassSelections:new Set(), assignmentSubjectSelections:new Set(),
    userAccessClassSelections:new Set(), userAccessSubjectSelections:new Set(), userAccessAllSubjects:false, guardianAccounts:[], autoComments:null,
    passwordChangeRequired:false, userAccessEditingUserId:"",
    workspace:null, studentClassFilter:"", reportClassFilter:"", reportTemplates:null, reportTemplatesLoadedAt:0,
    initialized:false, realtimeConnected:0, lastSync:null, pending:0, conflicts:0,
    packageLogoPreviewUrl:"", packageGeneratorBusy:false, bulkReportPackageBusy:false,
    attendanceTermId:"", attendanceClassId:"", attendanceDate:"", attendanceData:null,
    licenseConsole:null
  };

  const $ = (selector, root=document) => root.querySelector(selector);
  const $$ = (selector, root=document) => [...root.querySelectorAll(selector)];
  const byId = id => document.getElementById(id);
  const esc = value => String(value ?? "").replace(/[&<>"']/g, ch => ({
    "&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#039;"
  })[ch]);
  const attr = esc;
  const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
  const uuid = () => crypto.randomUUID();
  const isoDate = value => value ? new Date(value).toLocaleDateString("en-GH",{year:"numeric",month:"short",day:"numeric"}) : "—";
  const isoDateTime = value => value ? new Date(value).toLocaleString("en-GH",{year:"numeric",month:"short",day:"numeric",hour:"2-digit",minute:"2-digit"}) : "—";
  const number = (value,digits=0) => Number(value || 0).toLocaleString("en-GH",{minimumFractionDigits:digits,maximumFractionDigits:digits});
  const fullName = row => [row?.first_name,row?.middle_name,row?.last_name].filter(Boolean).join(" ");
  const activeYear = () => state.boot?.academic_years?.find(x=>x.is_active) || null;
  const activeTerm = () => state.boot?.terms?.find(x=>x.is_active) || null;
  const role = () => state.boot?.profile?.role || "";
  const can = key => Boolean(state.boot?.permissions?.[key]);
  const licenseState = () => state.boot?.license || {};
  const licenseCanWrite = () => licenseState().write_allowed !== false;
  function dateTimeLocalValue(value) {
    if(!value)return "";
    const date=new Date(value);if(Number.isNaN(date.getTime()))return "";
    const offset=date.getTimezoneOffset()*60000;
    return new Date(date.getTime()-offset).toISOString().slice(0,16);
  }
  function licenseStatusLabel(value="") {
    return ({pending_activation:"Pending activation",active:"Active",grace_period:"Grace period",expired:"Expired",suspended:"Suspended",revoked:"Revoked",perpetual:"Perpetual"})[value]||String(value||"Unknown").replaceAll("_"," ");
  }
  function licenseBannerHtml() {
    if(role()==="platform_super_admin")return "";
    const license=licenseState(),warning=String(license.warning||"").trim();
    if(!warning&&license.access_mode!=="read_only")return "";
    const readOnly=license.access_mode==="read_only";
    return `<section class="license-banner ${readOnly?"restricted":"warning"}"><div><strong>${readOnly?"Read-only licensing mode":licenseStatusLabel(license.computed_status)}</strong><span>${esc(warning||"The platform licence requires attention.")}</span></div>${license.expires_at?`<small>Expiry: ${esc(isoDateTime(license.expires_at))}</small>`:""}</section>`;
  }
  const isConfigured = () => /^https:\/\/.+\.supabase\.co$/i.test(CONFIG.supabaseUrl) && !CONFIG.supabaseAnonKey.startsWith("YOUR_");
  const legacyDefaultSchoolName = value => /^nipe international school$/i.test(String(value||"").trim());
  const legacyDefaultLogo = value => !value || /(?:^|\/)nipe-school-logo\.png(?:$|\?)/i.test(String(value));
  function schoolDisplayName(school=state.boot?.school||{}) {
    const databaseName=String(school?.school_name||"").trim();
    if(CONFIG.generatedSchoolPackage&&legacyDefaultSchoolName(databaseName))return CONFIG.schoolName;
    return databaseName||CONFIG.schoolName;
  }
  function schoolDisplayLogo(school=state.boot?.school||{}) {
    const databaseLogo=String(school?.logo_url||"").trim();
    if(CONFIG.generatedSchoolPackage&&legacyDefaultLogo(databaseLogo))return CONFIG.logoPath;
    return databaseLogo||CONFIG.logoPath;
  }
  function schoolEmailDomain(school=state.boot?.school||{}) {
    const databaseDomain=String(school?.user_email_domain||"").trim().toLowerCase();
    if(CONFIG.generatedSchoolPackage&&(!databaseDomain||databaseDomain==="nip.com"))return String(CONFIG.userEmailDomain||"nip.com").trim().toLowerCase();
    return databaseDomain||String(CONFIG.userEmailDomain||"nip.com").trim().toLowerCase();
  }
  function schoolReportPrefix(school=state.boot?.school||{}) {
    const databasePrefix=String(school?.report_number_prefix||"").trim().toUpperCase();
    if(CONFIG.generatedSchoolPackage&&(!databasePrefix||databasePrefix==="NIS"))return String(CONFIG.reportNumberPrefix||"NIS").trim().toUpperCase();
    return databasePrefix||String(CONFIG.reportNumberPrefix||"NIS").trim().toUpperCase();
  }
  function slugify(value,fallback="school") {
    return String(value||"").normalize("NFKD").replace(/[\u0300-\u036f]/g,"").toLowerCase().replace(/[^a-z0-9]+/g,"-").replace(/^-+|-+$/g,"").slice(0,70)||fallback;
  }
  function renderStaticBrand() {
    document.title=`${CONFIG.schoolName} | Report Cards`;
    $$('[data-school-logo]').forEach(image=>{image.src=CONFIG.logoPath;image.alt=CONFIG.schoolName});
    $$('[data-school-name]').forEach(node=>{node.textContent=CONFIG.schoolName});
  }

  function toast(title, message="", type="success", timeout=4200) {
    const node=document.createElement("div");
    node.className=`toast ${type}`;
    node.innerHTML=`<div><strong>${esc(title)}</strong>${message?`<span>${esc(message)}</span>`:""}</div>`;
    byId("toastStack").append(node);
    setTimeout(()=>node.remove(),timeout);
  }

  function setLoading(show) { byId("loader").classList.toggle("hidden",!show); }
  function setAuthMessage(message="") { byId("authMessage").textContent=message; }
  function setMfaMessage(message="") { byId("mfaMessage").textContent=message; }
  function setSync(mode,label) {
    const pill=byId("syncIndicator");
    pill.className=`sync-pill ${mode}`;
    if(mode==="online") state.lastSync=new Date();
    const stamp=state.lastSync?.toLocaleTimeString("en-GH",{hour:"2-digit",minute:"2-digit"})||"";
    const display=mode==="online"&&stamp?`${label} • ${stamp}`:label;
    byId("syncLabel").textContent=display;
    pill.title=mode==="online"&&state.lastSync?`Last synchronised ${state.lastSync.toLocaleString("en-GH")}`:label;
  }
  function showOnly(id) {
    ["verifyView","authView","mfaView","appShell"].forEach(name=>byId(name).classList.toggle("hidden",name!==id));
  }
  function statusBadge(status) {
    const value=String(status||"draft");
    return `<span class="status ${attr(value)}">${esc(value.replaceAll("_"," "))}</span>`;
  }
  function optionList(rows,valueKey,labelKey,selected="",blank="Select") {
    return `<option value="">${esc(blank)}</option>`+rows.map(row=>
      `<option value="${attr(row[valueKey])}" ${String(row[valueKey])===String(selected)?"selected":""}>${esc(row[labelKey])}</option>`
    ).join("");
  }
  function modal(title,subtitle,body,footer="",size="") {
    const dialog=byId("modal"),bodyHost=byId("modalBody"),footerHost=byId("modalFooter");
    dialog.className=`modal ${size}`.trim();
    byId("modalTitle").textContent=title;
    byId("modalSubtitle").textContent=subtitle||"";
    bodyHost.innerHTML=body;
    footerHost.innerHTML=footer;
    if(/<form\b/i.test(body)&&!bodyHost.querySelector("form")){
      const error=new Error("The record form could not be created.");
      toast("Form unavailable","Reload the application and try again.","error",6500);
      throw error;
    }
    if(!dialog.open) dialog.showModal();
    return dialog;
  }
  function closeModal(force=false){
    if(state.passwordChangeRequired&&!force)return;
    const dialog=byId("modal");
    if(dialog.open) dialog.close();
    byId("modalBody").replaceChildren();
    byId("modalFooter").replaceChildren();
    byId("modalClose").classList.remove("hidden");
  }
  function confirmAction(title,message,confirmLabel="Continue",danger=false) {
    return new Promise(resolve=>{
      modal(title,"",`<p>${esc(message)}</p>`,
        `<button class="button ghost" type="button" id="confirmCancel">Cancel</button>
         <button class="button ${danger?"danger":"primary"}" type="button" id="confirmOk">${esc(confirmLabel)}</button>`,"small");
      byId("confirmCancel").onclick=()=>{closeModal();resolve(false)};
      byId("confirmOk").onclick=()=>{closeModal();resolve(true)};
    });
  }

  async function rpc(name,args={}) {
    const {data,error}=await state.client.rpc(name,args);
    if(error) throw error;
    state.lastSync=new Date();
    return data;
  }
  async function query(builder) {
    const {data,error}=await builder;
    if(error) throw error;
    state.lastSync=new Date();
    return data;
  }
  async function reportClientError(error,context={}) {
    console.error(error);
    if(!state.client || !state.session) return;
    try {
      await state.client.rpc("log_client_error",{
        message_text:error?.message||String(error),stack_text:error?.stack||"",
        context_data:context,user_agent_text:navigator.userAgent
      });
    } catch (_) {}
  }
  function friendlyError(error) {
    const msg=error?.message||String(error||"Operation failed");
    if(msg.includes("40001")||msg.includes("changed by another user")) return "Another user changed this record. The latest version has been loaded.";
    if(msg.includes("PLATFORM_ACCESS_LOCKED:")) return msg.split("PLATFORM_ACCESS_LOCKED:").slice(1).join(":").trim()||"Platform access has been restricted.";
    if(msg.includes("LICENSE_WRITE_RESTRICTED:")) return msg.split("LICENSE_WRITE_RESTRICTED:").slice(1).join(":").trim()||"The current licence permits read-only access.";
    if(msg.includes("LICENSE_CAPACITY_REACHED:")) return msg.split("LICENSE_CAPACITY_REACHED:").slice(1).join(":").trim();
    if(msg.toLowerCase().includes("platform super administrator access required")) return "Only a Platform Super Administrator can manage licensing and access controls.";
    if(msg.toLowerCase().includes("permission denied for function can_publish_report")) return "Apply the v6.8.2 continuation in 07_schema.sql, then reload the system.";
    if(msg.includes("42501")||msg.toLowerCase().includes("access denied")) return "You do not have permission to complete this operation.";
    if(msg.includes("student_reports_enrollment_id_key")||msg.includes("student_reports_enrollment_id_term_id_key")) return "The database still has a legacy report uniqueness rule. Apply the v6.6.1 database hotfix, then save the report again.";
    if(msg.includes("list_report_card_templates")||msg.includes("report_card_templates")||msg.includes("report-card-templates")) return "Apply the v6.6.3 database hotfix, then reload the system.";
    if(error?.code==="23505"&&msg.toLowerCase().includes("student_reports")) return "A current report already exists for this student and term.";
    if(msg.toLowerCase().includes("failed to fetch")||msg.toLowerCase().includes("network")) return "The server could not be reached.";
    return msg;
  }
  async function run(action,{success="",context={}}={}) {
    try {
      const result=await action();
      if(success) toast(success);
      return result;
    } catch(error) {
      await reportClientError(error,context);
      toast("Operation unsuccessful",friendlyError(error),"error",6500);
      throw error;
    }
  }

  function openLocalDb() {
    return new Promise((resolve,reject)=>{
      const request=indexedDB.open("nis-report-card",2);
      request.onupgradeneeded=()=>{
        const db=request.result;
        if(!db.objectStoreNames.contains("outbox")) db.createObjectStore("outbox",{keyPath:"id"});
        if(!db.objectStoreNames.contains("drafts")) db.createObjectStore("drafts",{keyPath:"key"});
      };
      request.onsuccess=()=>resolve(request.result);
      request.onerror=()=>reject(request.error);
    });
  }
  async function idbTransaction(store,mode,operation) {
    const db=await openLocalDb();
    return new Promise((resolve,reject)=>{
      const tx=db.transaction(store,mode), os=tx.objectStore(store);
      let request;
      try { request=operation(os); } catch(error){ reject(error);return; }
      tx.oncomplete=()=>resolve(request?.result);
      tx.onerror=()=>reject(tx.error);
    });
  }
  const outboxAll=()=>idbTransaction("outbox","readonly",os=>os.getAll());
  const outboxPut=item=>idbTransaction("outbox","readwrite",os=>os.put(item));
  const outboxDelete=id=>idbTransaction("outbox","readwrite",os=>os.delete(id));
  const draftPut=item=>idbTransaction("drafts","readwrite",os=>os.put(item));
  const draftGet=key=>idbTransaction("drafts","readonly",os=>os.get(key));
  const draftDelete=key=>idbTransaction("drafts","readwrite",os=>os.delete(key));

  async function refreshPendingCount() {
    const items=await outboxAll().catch(()=>[]);
    state.pending=items.filter(x=>x.status!=="conflict").length;
    state.conflicts=items.filter(x=>x.status==="conflict").length;
    const bar=byId("offlineBar");
    byId("outboxCount").textContent=[state.pending?`${state.pending} pending`:"",state.conflicts?`${state.conflicts} conflict${state.conflicts===1?"":"s"}`:""].filter(Boolean).join(" • ")||"0 pending";
    bar.classList.toggle("conflict",state.conflicts>0);
    bar.classList.toggle("hidden",state.online && state.pending===0 && state.conflicts===0);
    if(!state.online) setSync("offline","Offline");
    else if(state.conflicts) setSync("error",`${state.conflicts} conflict${state.conflicts===1?"":"s"}`);
    else if(state.pending) setSync("pending",`${state.pending} pending`);
  }
  async function queueReportSave(payload,expectedVersion) {
    const item={id:uuid(),type:"save_report",payload,expectedVersion,createdAt:new Date().toISOString(),status:"pending"};
    await outboxPut(item);
    await refreshPendingCount();
    toast("Saved offline","The report will synchronise automatically.","warning");
    return state.reportEditor;
  }
  async function flushOutbox() {
    if(!state.online||!state.session) return;
    const items=(await outboxAll().catch(()=>[])).sort((a,b)=>a.createdAt.localeCompare(b.createdAt));
    for(const item of items) {
      if(item.status==="conflict") continue;
      try {
        if(item.type==="save_report") await rpc("save_report_card",{payload:item.payload,expected_version:item.expectedVersion});
        await outboxDelete(item.id);
      } catch(error) {
        if(error?.code==="40001"||String(error?.message).includes("changed by another user")) {
          item.status="conflict"; item.error=error.message; await outboxPut(item);
          toast("Synchronisation conflict","A queued report needs review.","error",7000);
        } else break;
      }
    }
    await refreshPendingCount();
    if(state.online && state.pending===0) setSync("online","Synced");
  }

  async function openSyncQueue() {
    const items=(await outboxAll().catch(()=>[])).sort((a,b)=>b.createdAt.localeCompare(a.createdAt));
    modal("Synchronisation Queue",`${items.length} record${items.length===1?"":"s"}`,items.length?`
      <div class="stack-list">${items.map(item=>`<article class="list-card">
        <div><strong>${item.status==="conflict"?"Conflict":"Pending report"}</strong><small>${isoDateTime(item.createdAt)}</small>${item.error?`<span class="form-message">${esc(item.error)}</span>`:""}</div>
        <div class="button-row">
          ${item.status==="conflict"?`<button class="button primary small" type="button" data-sync-retry="${attr(item.id)}">Retry</button><button class="button outline small" type="button" data-sync-server="${attr(item.id)}">Use server record</button>`:""}
          <button class="button ghost small" type="button" data-sync-remove="${attr(item.id)}">Remove</button>
        </div>
      </article>`).join("")}</div>`:`<div class="empty"><strong>Queue clear</strong></div>`,
      `<button class="button ghost" id="syncQueueClose" type="button">Close</button>`,"wide");
    byId("syncQueueClose").onclick=closeModal;
    $$('[data-sync-remove]').forEach(button=>button.onclick=async()=>{await outboxDelete(button.dataset.syncRemove);await refreshPendingCount();openSyncQueue()});
    $$('[data-sync-server]').forEach(button=>button.onclick=async()=>{
      const item=items.find(x=>x.id===button.dataset.syncServer);await outboxDelete(item.id);await refreshPendingCount();
      if(item?.payload?.report_id){state.reportEditor=await rpc("get_report_editor",{target_report_id:item.payload.report_id,target_enrollment_id:null,target_term_id:null});}
      closeModal();if(state.view==="reports"&&state.reportEditor)renderReportEditor();
    });
    $$('[data-sync-retry]').forEach(button=>button.onclick=async()=>{
      const item=items.find(x=>x.id===button.dataset.syncRetry);if(!item)return;
      if(item.payload?.report_id){const current=await rpc("get_report_editor",{target_report_id:item.payload.report_id,target_enrollment_id:null,target_term_id:null});item.expectedVersion=Number(current.report.version);}
      item.status="pending";item.error="";await outboxPut(item);closeModal();await refreshPendingCount();await flushOutbox();
    });
  }

  async function signedUrl(bucket,path,seconds=900) {
    if(!path) return "";
    if(/^https?:\/\//i.test(path)||path.startsWith("data:")||path.startsWith("assets/")) return path;
    const cache=bucket===CONFIG.photoBucket?state.photoUrls:
      bucket===CONFIG.signatureBucket?state.signatureUrls:
      bucket===CONFIG.templateBucket?state.templateUrls:state.pdfUrls;
    const cached=cache.get(path);
    if(cached&&cached.expires>Date.now()) return cached.url;
    const {data,error}=await state.client.storage.from(bucket).createSignedUrl(path,seconds);
    if(error) throw error;
    cache.set(path,{url:data.signedUrl,expires:Date.now()+(seconds-30)*1000});
    return data.signedUrl;
  }

  async function init() {
    renderStaticBrand();
    byId("togglePassword").onclick=()=>{
      const input=byId("loginPassword");
      input.type=input.type==="password"?"text":"password";
    };
    byId("modalClose").onclick=()=>closeModal();
    byId("modal").addEventListener("cancel",event=>{event.preventDefault();closeModal()});
    byId("loginForm").addEventListener("submit",login);
    byId("mfaForm").addEventListener("submit",verifyMfa);
    byId("mfaSignOut").onclick=logout;
    byId("logoutButton").onclick=logout;
    byId("menuButton").onclick=()=>byId("sidebar").classList.toggle("open");
    byId("refreshButton").onclick=()=>navigate(state.view,true);
    byId("notificationButton").onclick=()=>navigate("notifications");
    byId("offlineBar").onclick=openSyncQueue;
    byId("offlineBar").onkeydown=event=>{if(event.key==="Enter"||event.key===" "){event.preventDefault();openSyncQueue()}};
    window.addEventListener("online",async()=>{state.online=true;await refreshPendingCount();await flushOutbox();await reconnectRealtime()});
    window.addEventListener("offline",async()=>{state.online=false;await refreshPendingCount()});
    window.addEventListener("beforeunload",event=>{if(state.pending||state.conflicts){event.preventDefault();event.returnValue=""}});
    window.addEventListener("error",event=>reportClientError(event.error||new Error(event.message),{source:"window"}));
    window.addEventListener("unhandledrejection",event=>reportClientError(event.reason,{source:"promise"}));
    if("serviceWorker" in navigator) {
      navigator.serviceWorker.register("service-worker.js").catch(()=>{});
      navigator.serviceWorker.addEventListener("message",event=>{if(event.data?.type==="FLUSH_OUTBOX")flushOutbox()});
    }
    await refreshPendingCount();

    const verifyToken=new URLSearchParams(location.search).get("verify");
    if(verifyToken) {
      await showVerification(verifyToken);
      setLoading(false);
      return;
    }
    if(!isConfigured()||!window.supabase?.createClient) {
      showOnly("authView");
      setAuthMessage("Service unavailable.");
      setLoading(false);
      return;
    }
    state.client=window.supabase.createClient(CONFIG.supabaseUrl,CONFIG.supabaseAnonKey,{
      auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:true},
      realtime:{params:{eventsPerSecond:20}}
    });
    const {data:{session}}=await state.client.auth.getSession();
    state.session=session;
    state.client.auth.onAuthStateChange(async(event,newSession)=>{
      state.session=newSession;
      if(event==="SIGNED_OUT"){state.initialized=false;disconnectRealtime();showOnly("authView");}
      if(event==="TOKEN_REFRESHED"&&newSession) await state.client.realtime.setAuth(newSession.access_token).catch(()=>{});
    });
    if(session) await startAuthenticated();
    else {showOnly("authView");setLoading(false);}
  }

  async function login(event) {
    event.preventDefault(); setAuthMessage("");
    const email=byId("loginEmail").value.trim(),password=byId("loginPassword").value;
    const button=$("#loginForm button[type=submit]");button.disabled=true;
    try {
      const {data,error}=await state.client.auth.signInWithPassword({email,password});
      if(error) throw error;
      state.session=data.session;
      await startAuthenticated();
    } catch(error){setAuthMessage(friendlyError(error));}
    finally{button.disabled=false;}
  }
  async function logout() {
    disconnectRealtime();
    await state.client?.auth.signOut();
    state.boot=null;state.session=null;state.initialized=false;state.reportTemplates=null;state.reportTemplatesLoadedAt=0;
    state.templateUrls.clear();state.templateCanvases.clear();
    showOnly("authView");setLoading(false);
  }

  async function startAuthenticated() {
    setLoading(true);
    try {
      await rpc("ensure_current_user_profile");
      state.boot=await rpc("get_bootstrap_data");
      if(!state.boot?.profile?.active) throw new Error("Account inactive");
      const verified=await ensureMfa();
      if(!verified){setLoading(false);return;}
      await continueAuthenticatedSession();
    } catch(error) {
      await reportClientError(error,{source:"bootstrap"});
      await state.client.auth.signOut().catch(()=>{});
      showOnly("authView");setAuthMessage(friendlyError(error));setLoading(false);
    }
  }
  async function ensureMfa() {
    if(!state.boot.profile.mfa_required) return true;
    const {data:aal,error}=await state.client.auth.mfa.getAuthenticatorAssuranceLevel();
    if(error) throw error;
    if(aal.currentLevel==="aal2") return true;
    const {data:factors,error:factorError}=await state.client.auth.mfa.listFactors();
    if(factorError) throw factorError;
    const verified=(factors.totp||[]).find(f=>f.status==="verified");
    if(verified) {
      state.mfaFactorId=verified.id;state.mfaEnrollment=null;
      byId("mfaQr").classList.add("hidden");showOnly("mfaView");byId("mfaCode").focus();return false;
    }
    const {data:enrollment,error:enrollError}=await state.client.auth.mfa.enroll({
      factorType:"totp",friendlyName:schoolDisplayName()
    });
    if(enrollError) throw enrollError;
    state.mfaFactorId=enrollment.id;state.mfaEnrollment=enrollment;
    const qr=byId("mfaQr");qr.innerHTML=`<img src="${attr(enrollment.totp.qr_code)}" alt="Authentication QR code">`;qr.classList.remove("hidden");
    showOnly("mfaView");byId("mfaCode").focus();return false;
  }
  async function verifyMfa(event) {
    event.preventDefault();setMfaMessage("");
    const code=byId("mfaCode").value.trim();
    const button=$("#mfaForm button[type=submit]");button.disabled=true;
    try {
      const {error}=await state.client.auth.mfa.challengeAndVerify({factorId:state.mfaFactorId,code});
      if(error) throw error;
      byId("mfaCode").value="";state.mfaEnrollment=null;
      state.boot=await rpc("get_bootstrap_data");
      await continueAuthenticatedSession();
    } catch(error){setMfaMessage(friendlyError(error));}
    finally{button.disabled=false;}
  }


  async function continueAuthenticatedSession() {
    if(state.boot?.profile?.must_change_password){
      openRequiredPasswordChange();
      return;
    }
    await initializeApp();
  }

  function openRequiredPasswordChange() {
    state.passwordChangeRequired=true;
    renderBrand();
    showOnly("appShell");
    byId("mainNav").innerHTML="";
    byId("pageTitle").textContent="Password Change Required";
    byId("pageSubtitle").textContent="Set a private password before continuing";
    byId("content").innerHTML='<div class="empty"><strong>Your account is secured. Complete the required password change to continue.</strong></div>';
    setLoading(false);
    modal("Change Password Required","The System Administrator requires you to replace the temporary password.",`<form id="requiredPasswordForm" class="form-stack">
      <label class="field"><span>New password</span><input name="password" type="password" minlength="8" autocomplete="new-password" required></label>
      <label class="field"><span>Confirm new password</span><input name="confirm_password" type="password" minlength="8" autocomplete="new-password" required></label>
      <p class="help-text">Use at least eight characters. Do not reuse the temporary password.</p>
    </form>`,`<button class="button ghost" id="requiredPasswordSignOut" type="button">Sign out</button><button class="button primary" id="requiredPasswordSave" type="button">Change password</button>`,"small");
    byId("modalClose").classList.add("hidden");
    byId("requiredPasswordSignOut").onclick=async()=>{
      state.passwordChangeRequired=false;
      closeModal(true);
      await logout();
    };
    byId("requiredPasswordSave").onclick=async()=>{
      const form=byId("requiredPasswordForm"),button=byId("requiredPasswordSave");
      if(!form?.reportValidity())return;
      const password=form.elements.password.value;
      if(password!==form.elements.confirm_password.value){toast("Passwords do not match","","error");return}
      button.disabled=true;button.textContent="Changing";
      try{
        const {error}=await state.client.auth.updateUser({password});
        if(error)throw error;
        await rpc("complete_required_password_change");
        state.boot=await rpc("get_bootstrap_data");
        state.passwordChangeRequired=false;
        closeModal(true);
        toast("Password changed","Your private password is now active.");
        await initializeApp();
      }catch(error){
        toast("Password not changed",friendlyError(error),"error",6500);
      }finally{
        button.disabled=false;button.textContent="Change password";
      }
    };
  }

  async function initializeApp() {
    state.initialized=true;
    renderBrand();renderNav();showOnly("appShell");
    await state.client.realtime.setAuth(state.session.access_token).catch(()=>{});
    await connectRealtime();
    await loadNotificationCount();
    await flushOutbox();
    await navigate("dashboard",true);
    setLoading(false);
  }
  function renderBrand() {
    const school=state.boot.school||{};
    byId("brandLogo").src=schoolDisplayLogo(school);
    byId("brandName").textContent=schoolDisplayName(school);
    byId("userName").textContent=state.boot.profile.full_name||state.session.user.email;
    byId("userRole").textContent=ROLE_LABELS[role()]||role();
    byId("userAvatar").textContent=(state.boot.profile.full_name||"N").trim().charAt(0).toUpperCase();
    document.documentElement.style.setProperty("--navy",school.primary_colour||"#082d70");
    document.documentElement.style.setProperty("--gold",school.accent_colour||"#f0b51d");
    document.body.dataset.accessMode=licenseState().access_mode||"full";
  }
  function availableNavItems() {
    const ordered=ROLE_NAV_IDS[role()]||["dashboard"];
    return ordered.map(id=>NAV.find(item=>item.id===id)).filter(item=>{
      if(!item)return false;
      if(item.permission&&!can(item.permission))return false;
      if(item.roles&&!item.roles.includes(role()))return false;
      if(item.hideFor?.includes(role()))return false;
      return true;
    });
  }
  function renderNav() {
    byId("mainNav").innerHTML=availableNavItems().map(item=>`<button class="nav-item ${item.id===state.view?"active":""}" data-view="${item.id}">
      <span class="nav-icon">${item.icon}</span><span>${esc(item.label)}</span></button>`).join("");
    $$(".nav-item",byId("mainNav")).forEach(button=>button.onclick=()=>navigate(button.dataset.view));
  }
  async function navigate(view,force=false) {
    const allowed=availableNavItems();
    let item=allowed.find(x=>x.id===view);
    if(!item){item=allowed.find(x=>x.id==="dashboard")||allowed[0];if(!item)return;view=item.id;}
    state.view=view;state.viewToken++;
    renderNav();byId("pageTitle").textContent=item.label;byId("pageSubtitle").textContent=item.subtitle;
    byId("sidebar").classList.remove("open");byId("content").innerHTML=`<div class="panel pad"><div class="skeleton"></div></div>`;
    const token=state.viewToken;
    try {
      const renderer={
        dashboard:renderDashboard,licensing:renderLicensing,my_class:renderMyClass,attendance:renderAttendance,my_subjects:renderMySubjects,students:renderStudents,teachers:renderTeachers,headteachers:renderPrincipals,academics:renderAcademics,reports:renderReports,
        children:renderChildren,users:renderUsers,notifications:renderNotifications,audit:renderAudit,settings:renderSettings,github:renderGithubNavigator
      }[view];
      await renderer?.(token,force);
      if(token===state.viewToken&&role()!=="platform_super_admin") {const banner=licenseBannerHtml();if(banner)byId("content")?.insertAdjacentHTML("afterbegin",banner);}
      if(token===state.viewToken) {setSync(state.online?"online":"offline",state.online?"Synced":"Offline");byId("content").focus();}
    } catch(error) {
      if(token!==state.viewToken)return;
      await reportClientError(error,{view});
      byId("content").innerHTML=`<div class="panel pad empty"><strong>Unable to load</strong><span>${esc(friendlyError(error))}</span></div>`;
      setSync(state.online?"pending":"offline",state.online?"Retry required":"Offline");
    }
  }

  async function disconnectRealtime() {
    for(const channel of state.channels) await state.client?.removeChannel(channel).catch(()=>{});
    state.channels=[];state.realtimeConnected=0;
  }
  async function reconnectRealtime(){if(state.session){await disconnectRealtime();await connectRealtime()}}
  async function connectRealtime() {
    await disconnectRealtime();
    const topics=state.boot?.topics||[];
    if(!topics.length){setSync("online","Connected");return;}
    setSync("pending","Connecting");
    for(const topic of topics.slice(0,120)) {
      const channel=state.client.channel(topic,{config:{private:true,broadcast:{self:false},presence:{key:state.session.user.id}}});
      ["INSERT","UPDATE","DELETE"].forEach(event=>channel.on("broadcast",{event},payload=>handleRealtime(topic,payload)));
      channel.on("presence",{event:"sync"},()=>{});
      channel.subscribe(async status=>{
        if(status==="SUBSCRIBED"){
          state.realtimeConnected++;
          await channel.track({user_id:state.session.user.id,at:new Date().toISOString(),view:state.view}).catch(()=>{});
          if(state.realtimeConnected===state.channels.length)setSync("online","Live");
        } else if(["CHANNEL_ERROR","TIMED_OUT","CLOSED"].includes(status)) setSync("pending","Reconnecting");
      });
      state.channels.push(channel);
    }
  }
  function handleRealtime(topic,payload) {
    state.lastSync=new Date();setSync("online","Live");
    const table=payload?.payload?.table||payload?.table||"";
    if(["profiles","user_class_access","teachers","headteachers","classes","subjects","class_subjects","students","enrollments","student_reports","subject_results","class_attendance_registers","student_attendance_entries"].includes(table))state.workspace=null;
    if(table==="report_card_templates"){state.reportTemplates=null;state.reportTemplatesLoadedAt=0;state.templateUrls.clear();state.templateCanvases.clear()}
    if(topic.startsWith("user:")||table==="notifications") loadNotificationCount();
    clearTimeout(handleRealtime.timer);
    handleRealtime.timer=setTimeout(()=>{
      if(state.view==="dashboard") renderDashboard(state.viewToken,true);
      else if(state.view==="students"&&(table==="students"||table==="enrollments"||topic.startsWith("student:"))) renderStudents(state.viewToken,true);
      else if(state.view==="attendance"&&(table==="class_attendance_registers"||table==="student_attendance_entries"||table==="students"||table==="enrollments")) loadAttendanceRegister(state.viewToken);
      else if(state.view==="teachers"&&(table==="teachers"||table==="profiles"||table==="classes"||table==="class_subjects"||topic==="school:global")) renderTeachers(state.viewToken,true);
      else if(state.view==="headteachers"&&(table==="headteachers"||table==="profiles"||topic==="school:global")) renderPrincipals(state.viewToken,true);
      else if(state.view==="users"&&(table==="profiles"||table==="user_class_access"||table==="teachers"||table==="headteachers"||topic==="school:global")) renderUsers(state.viewToken,true);
      else if(state.view==="reports"||state.view==="children") {
        if(state.reportEditor&&topic===`report:${state.reportEditor.report?.id}`) refreshOpenReport();
        else navigate(state.view,true);
      } else if(state.view==="academics"&&topic==="school:global") renderAcademics(state.viewToken,true);
      else if(state.view==="my_class") renderMyClass(state.viewToken,true);
      else if(state.view==="my_subjects") renderMySubjects(state.viewToken,true);
      else if(state.view==="notifications") renderNotifications(state.viewToken,true);
      else if(state.view==="settings"&&table==="report_card_templates") renderSettings(state.viewToken,true);
    },220);
  }

  async function loadNotificationCount() {
    if(!state.session)return;
    try {
      const data=await rpc("list_notifications",{page_number:1,page_size:5});
      state.notifications=data.rows||[];
      const badge=byId("notificationBadge"),count=Number(data.unread||0);
      badge.textContent=count>99?"99+":String(count);badge.classList.toggle("hidden",count===0);
    } catch(_){}
  }

  init().catch(error=>{console.error(error);showOnly("authView");setAuthMessage("Service unavailable.");setLoading(false)});
  if(window.__NIS_TEMPLATE_TEST_MODE__){
    window.NIS_TEMPLATE_TEST_HOOKS=Object.freeze({
      reportTemplateRangeForClass,validateReportTemplateFile,normaliseTemplateCanvas,drawAssignedTemplateOverlay,drawPreferredTerminalReport,builtInReportTemplateCanvas,
      ordinalReportPosition,reportBodyFontName,reportBodyFontSize,reportBodyFontScale,reportSubjectPositionMap,
      setBoot:value=>{state.boot=value},getState:()=>state
    });
  }


  async function renderDashboard(token) {
    const term=activeTerm();
    const metrics=await rpc("get_role_dashboard",{target_term_id:term?.id||null});
    if(token!==state.viewToken)return;
    const currentRole=role(),statuses=metrics.by_status||{},reports=Number(metrics.reports||0),published=Number(metrics.published||0);
    const signatureRecord=currentRole==="principal"?await rpc("get_my_headteacher_signature").catch(error=>({linked:false,error:friendlyError(error)})):null;
    if(token!==state.viewToken)return;
    const completion=reports?Math.round(published/reports*100):0;
    const configs={
      system_admin:{title:"System Administration Dashboard",subtitle:"Users, records, security, and report operations",cards:[["blue","♟","Active Users",metrics.active_users],["gold","♜","Active Teachers",metrics.active_teachers],["green","◉","Active Students",metrics.active_students],["purple","▤","Report Cards",reports]]},
      principal:{title:"Principal Dashboard",subtitle:"School performance, approvals, and publication",cards:[["blue","◉","Active Students",metrics.active_students],["gold","⌛","Awaiting Action",metrics.pending_review],["green","✓","Published Reports",published],["purple","%","Published Average",number(metrics.average,1)+"%"]]},
      class_teacher:{title:"Class and Subject Teacher Dashboard",subtitle:"Home-class responsibilities and subject teaching assignments",cards:[["blue","▣","Assigned Classes",metrics.assigned_classes],["gold","⌘","Assigned Subjects",metrics.assigned_subjects],["green","◉","Visible Students",metrics.active_students],["purple","✎","Draft or Returned",metrics.draft_returned]]},
      subject_teacher:{title:"Subject Teacher Dashboard",subtitle:"Assigned subjects and assessment workload",cards:[["blue","⌘","Assigned Subjects",metrics.assigned_subjects],["gold","▣","Assigned Classes",metrics.assigned_classes],["green","✎","Open Reports",metrics.draft_returned],["purple","%","Published Average",number(metrics.average,1)+"%"]]},
      parent_guardian:{title:"Parent and Guardian Dashboard",subtitle:"Linked children and published academic records",cards:[["blue","♥","My Children",metrics.children],["gold","✓","Published Reports",published],["green","◆","Unread Notifications",metrics.unread_notifications],["purple","%","Average",number(metrics.average,1)+"%"]]}
    };
    const cfg=configs[currentRole]||configs.parent_guardian;
    byId("content").innerHTML=`
      <div class="page-head"><div><h3>${esc(cfg.title)}</h3><p>${esc(cfg.subtitle)}</p></div><div class="page-actions">${dashboardQuickActions(currentRole)}</div></div>
      <div class="stat-grid">${cfg.cards.map(card=>statCard(...card)).join("")}</div>
      ${currentRole==="principal"?headteacherSignaturePanel(signatureRecord):""}
      <div class="grid two">
        <section class="panel"><div class="panel-header"><div><h3>Current Academic Period</h3><p>${esc(activeYear()?.name||"No active academic year")} • ${esc(term?.name||"No active term")}</p></div></div>
          <div class="panel-body"><div class="metric-row"><div class="metric"><span>Draft</span><strong>${number(statuses.draft)}</strong></div><div class="metric"><span>Submitted</span><strong>${number(statuses.submitted)}</strong></div><div class="metric"><span>Approved</span><strong>${number(statuses.approved)}</strong></div><div class="metric"><span>Completion</span><strong>${completion}%</strong></div></div><div class="progress"><span style="width:${completion}%"></span></div></div>
        </section>
        <section class="panel"><div class="panel-header"><div><h3>Class Performance</h3><p>Published report averages</p></div></div><div class="panel-body"><div class="bar-list">
          ${(metrics.class_performance||[]).length?(metrics.class_performance||[]).map(row=>`<div class="bar-item"><label>${esc(row.class_name)}</label><div class="bar-track"><span style="width:${Math.min(100,Number(row.average||0))}%"></span></div><b>${number(row.average,1)}</b></div>`).join(""):`<div class="empty"><strong>No published results</strong></div>`}
        </div></div></section>
      </div>
      <section class="panel" style="margin-top:18px"><div class="panel-header"><div><h3>Recent Report Cards</h3><p>Latest authorised activity</p></div>${currentRole!=="parent_guardian"?`<button class="button secondary small" data-open-reports>View reports</button>`:`<button class="button secondary small" data-open-children>View children</button>`}</div>${reportTable(metrics.recent||[],true)}</section>`;
    $(`[data-open-reports]`)?.addEventListener("click",()=>navigate("reports"));
    $(`[data-open-children]`)?.addEventListener("click",()=>navigate("children"));
    $$(`[data-dashboard-view]`).forEach(button=>button.onclick=()=>navigate(button.dataset.dashboardView));
    if(currentRole==="principal")await bindPrincipalSignaturePanel(signatureRecord);
  }
  function headteacherSignaturePanel(record) {
    if(!record?.linked)return `<section class="panel signature-panel"><div class="panel-header"><div><h3>Digital Signature</h3><p>Principal report signing</p></div></div><div class="panel-body"><div class="empty"><strong>No linked principal record</strong><span>${esc(record?.error||"Ask the System Administrator to link this account to a principal record in Users and Access.")}</span></div></div></section>`;
    return `<section class="panel signature-panel"><div class="panel-header"><div><h3>Digital Signature</h3><p>The current signature replaces any signature embedded in report templates</p></div><span class="status ${record.signature_path?"published":"draft"}">${record.signature_path?"Signature ready":"Not uploaded"}</span></div>
      <div class="panel-body signature-layout"><div class="signature-preview-wrap">${record.signature_path?`<img id="headteacherSignaturePreview" alt="Principal signature">`:`<div class="signature-empty">No signature uploaded</div>`}</div>
      <div class="form-stack"><div><strong>${esc(record.full_name||"Principal")}</strong><p class="muted">Use a clear PNG, JPEG or WebP signature. A transparent PNG gives the best result.</p></div>
      <label class="field"><span>Signature image</span><input id="headteacherSignatureFile" type="file" accept="image/png,image/jpeg,image/webp"></label>
      <div class="button-row"><button class="button primary" id="headteacherSignatureUpload" type="button">Upload signature</button>${record.signature_path?`<button class="button danger" id="headteacherSignatureRemove" type="button">Remove signature</button>`:""}</div></div></div></section>`;
  }
  async function bindPrincipalSignaturePanel(record) {
    if(!record?.linked)return;
    if(record.signature_path&&byId("headteacherSignaturePreview")){
      try{byId("headteacherSignaturePreview").src=await signedUrl(CONFIG.signatureBucket,record.signature_path,900)}catch(_){byId("headteacherSignaturePreview").replaceWith(Object.assign(document.createElement("div"),{className:"signature-empty",textContent:"Signature preview unavailable"}))}
    }
    byId("headteacherSignatureUpload")?.addEventListener("click",async()=>{
      const file=byId("headteacherSignatureFile")?.files?.[0],button=byId("headteacherSignatureUpload");
      if(!file){toast("Signature not uploaded","Select a signature image first.","error");return}
      if(file.size>5*1024*1024){toast("Signature not uploaded","The image must be 5 MB or smaller.","error");return}
      button.disabled=true;button.textContent="Uploading";let uploadedPath="";
      try{
        const blob=await prepareSignatureImage(file),path=`${state.boot.profile.id}/${Date.now()}.webp`;uploadedPath=path;
        const {error}=await state.client.storage.from(CONFIG.signatureBucket).upload(path,blob,{contentType:"image/webp",upsert:false});if(error)throw error;
        await rpc("set_my_headteacher_signature",{target_signature_path:path,expected_updated_at:record.updated_at||null});
        if(record.signature_path&&record.signature_path!==path)await state.client.storage.from(CONFIG.signatureBucket).remove([record.signature_path]).catch(()=>{});
        state.signatureUrls.clear();toast("Digital signature uploaded","New and regenerated official report cards will use this signature.");await renderDashboard(state.viewToken);
      }catch(error){if(uploadedPath)await state.client.storage.from(CONFIG.signatureBucket).remove([uploadedPath]).catch(()=>{});toast("Signature not uploaded",friendlyError(error),"error",6500)}
      finally{button.disabled=false;button.textContent="Upload signature"}
    });
    byId("headteacherSignatureRemove")?.addEventListener("click",async()=>{
      if(!await confirmAction("Remove Digital Signature","Published PDF files already generated remain unchanged. New and regenerated report cards will not show this signature.","Remove",true))return;
      try{await rpc("set_my_headteacher_signature",{target_signature_path:"",expected_updated_at:record.updated_at||null});if(record.signature_path)await state.client.storage.from(CONFIG.signatureBucket).remove([record.signature_path]).catch(()=>{});state.signatureUrls.clear();toast("Digital signature removed");await renderDashboard(state.viewToken)}
      catch(error){toast("Signature not removed",friendlyError(error),"error",6500)}
    });
  }
  async function prepareSignatureImage(file,maxWidth=1200,maxHeight=420) {
    const bitmap=await createImageBitmap(file),scale=Math.min(1,maxWidth/bitmap.width,maxHeight/bitmap.height);
    const canvas=document.createElement("canvas");canvas.width=Math.max(1,Math.round(bitmap.width*scale));canvas.height=Math.max(1,Math.round(bitmap.height*scale));
    const ctx=canvas.getContext("2d",{willReadFrequently:true});ctx.drawImage(bitmap,0,0,canvas.width,canvas.height);bitmap.close();
    const image=ctx.getImageData(0,0,canvas.width,canvas.height),data=image.data;let minX=canvas.width,minY=canvas.height,maxX=-1,maxY=-1;
    for(let y=0;y<canvas.height;y++)for(let x=0;x<canvas.width;x++){const i=(y*canvas.width+x)*4,r=data[i],g=data[i+1],b=data[i+2],brightness=(r+g+b)/3;if(brightness>248)data[i+3]=0;else if(brightness>225)data[i+3]=Math.round(data[i+3]*(248-brightness)/23);if(data[i+3]>18){minX=Math.min(minX,x);minY=Math.min(minY,y);maxX=Math.max(maxX,x);maxY=Math.max(maxY,y)}}
    ctx.putImageData(image,0,0);if(maxX<minX||maxY<minY)throw new Error("The selected image does not contain a visible signature");
    const pad=18,x=Math.max(0,minX-pad),y=Math.max(0,minY-pad),w=Math.min(canvas.width-x,maxX-minX+1+pad*2),h=Math.min(canvas.height-y,maxY-minY+1+pad*2);
    const cropped=document.createElement("canvas");cropped.width=w;cropped.height=h;cropped.getContext("2d").drawImage(canvas,x,y,w,h,0,0,w,h);
    return new Promise((resolve,reject)=>cropped.toBlob(blob=>blob?resolve(blob):reject(new Error("Signature conversion failed")),"image/webp",.92));
  }
  function dashboardQuickActions(currentRole) {
    const actions=[];
    if(currentRole==="class_teacher"){
      actions.push(`<button class="button secondary" data-dashboard-view="my_class">My Class</button>`);
      actions.push(`<button class="button secondary" data-dashboard-view="attendance">Attendance</button>`);
      actions.push(`<button class="button secondary" data-dashboard-view="my_subjects">My Subjects</button>`);
    }
    if(currentRole==="subject_teacher")actions.push(`<button class="button secondary" data-dashboard-view="my_subjects">My Subjects</button>`);
    if(can("manage_students"))actions.push(`<button class="button secondary" data-dashboard-view="students">Students</button>`);
    if(can("manage_teachers"))actions.push(`<button class="button secondary" data-dashboard-view="teachers">Teachers</button>`);
    if(can("manage_headteachers"))actions.push(`<button class="button secondary" data-dashboard-view="headteachers">Principals</button>`);
    if(can("create_reports"))actions.push(`<button class="button primary" data-dashboard-view="reports">Report Cards</button>`);
    if(currentRole==="parent_guardian")actions.push(`<button class="button primary" data-dashboard-view="children">My Children</button>`);
    return actions.join("");
  }
  async function loadRoleWorkspace(force=false) {
    if(force||!state.workspace)state.workspace=await rpc("get_role_workspace");
    return state.workspace||{classes:[],subjects:[]};
  }
  function assignedClassRowsFromWorkspace(workspace=state.workspace) {
    const all=state.boot?.classes||[];
    if(!["class_teacher","subject_teacher"].includes(role()))return all;
    const ids=new Set([...(workspace?.classes||[]).map(item=>item.class_id),...(workspace?.subjects||[]).map(item=>item.class_id)]);
    return all.filter(item=>ids.has(item.id));
  }
  async function visibleClassesForCurrentRole() {
    if(!["class_teacher","subject_teacher"].includes(role()))return state.boot?.classes||[];
    const workspace=await loadRoleWorkspace();
    return assignedClassRowsFromWorkspace(workspace);
  }
  function workspaceProgress(done,total) {
    const safeTotal=Number(total||0),safeDone=Number(done||0);
    return safeTotal?Math.max(0,Math.min(100,Math.round(safeDone/safeTotal*100))):0;
  }
  async function renderMyClass(token,force=false) {
    const data=await loadRoleWorkspace(force);if(token!==state.viewToken)return;
    const classes=data.classes||[];
    byId("content").innerHTML=`<div class="page-head"><div><h3>My Class</h3><p>Assigned learners, subjects, and report completion</p></div></div>
      ${classes.length?`<div class="grid two">${classes.map(item=>{const completion=workspaceProgress(item.completed_reports,item.expected_reports);return `<section class="panel pad">
        <div class="panel-header"><div><h3>${esc(item.class_name)}</h3><p>${number(item.student_count)} learners • ${number(item.subject_count)} subjects</p></div><span class="status ${completion===100?"published":"draft"}">${completion}% complete</span></div>
        <div class="metric-row"><div class="metric"><span>Draft or returned</span><strong>${number(item.open_reports)}</strong></div><div class="metric"><span>In review</span><strong>${number(item.review_reports)}</strong></div><div class="metric"><span>Published</span><strong>${number(item.published_reports)}</strong></div></div>
        <div class="progress"><span style="width:${completion}%"></span></div><div class="button-row" style="margin-top:15px"><button class="button secondary small" data-workspace-students="${attr(item.class_id)}">Students</button><button class="button primary small" data-workspace-reports="${attr(item.class_id)}">Report Cards</button></div></section>`}).join("")}</div>`:`<section class="panel pad"><div class="empty"><strong>No assigned class</strong></div></section>`}`;
    $$('[data-workspace-students]').forEach(button=>button.onclick=()=>{state.studentClassFilter=button.dataset.workspaceStudents;navigate("students")});
    $$('[data-workspace-reports]').forEach(button=>button.onclick=()=>{state.reportClassFilter=button.dataset.workspaceReports;navigate("reports")});
  }
  function localDateValue(date=new Date()) {
    const offset=date.getTimezoneOffset()*60000;
    return new Date(date.getTime()-offset).toISOString().slice(0,10);
  }
  function attendanceDateForTerm(term) {
    const today=localDateValue();
    if(term?.start_date&&today<term.start_date)return term.start_date;
    if(term?.end_date&&today>term.end_date)return term.end_date;
    return today;
  }
  function attendanceStatusOptions(selected="present") {
    return [["present","Present"],["absent","Absent"],["late","Late"],["excused","Excused"]]
      .map(([value,label])=>`<option value="${value}" ${selected===value?"selected":""}>${label}</option>`).join("");
  }
  async function renderAttendance(token) {
    if(role()!=="class_teacher")throw new Error("Attendance is available only to assigned class teachers");
    const terms=state.boot.terms||[];
    const termId=state.attendanceTermId||activeTerm()?.id||terms[0]?.id||"";
    const term=terms.find(item=>item.id===termId)||terms[0]||null;
    state.attendanceTermId=term?.id||"";
    const classes=term?await rpc("list_my_attendance_classes",{target_term_id:term.id}):[];
    if(token!==state.viewToken)return;
    if(!classes.some(item=>item.id===state.attendanceClassId))state.attendanceClassId=classes[0]?.id||"";
    const today=localDateValue();
    const attendanceMaxDate=term?.end_date&&term.end_date<today?term.end_date:today;
    if(!state.attendanceDate)state.attendanceDate=attendanceDateForTerm(term);
    if(term?.start_date&&state.attendanceDate<term.start_date)state.attendanceDate=term.start_date;
    if(state.attendanceDate>attendanceMaxDate)state.attendanceDate=attendanceMaxDate;
    byId("content").innerHTML=`
      <div class="page-head"><div><h3>Class Attendance</h3><p>Mark daily attendance for your assigned class. Term totals update report cards automatically.</p></div></div>
      <section class="panel pad">
        <div class="form-grid three attendance-controls">
          <label class="field"><span>Academic term</span><select id="attendanceTerm">${optionList(terms,"id","name",state.attendanceTermId)}</select></label>
          <label class="field"><span>Assigned class</span><select id="attendanceClass">${optionList(classes,"id","name",state.attendanceClassId,classes.length?null:"No assigned class")}</select></label>
          <label class="field"><span>School date</span><input id="attendanceDate" type="date" value="${attr(state.attendanceDate)}" ${term?.start_date?`min="${attr(term.start_date)}"`:""} max="${attr(attendanceMaxDate)}"></label>
        </div>
      </section>
      <section class="panel" id="attendanceResults"><div class="empty">Loading attendance register</div></section>`;
    byId("attendanceTerm").onchange=()=>{state.attendanceTermId=byId("attendanceTerm").value;state.attendanceClassId="";state.attendanceDate="";renderAttendance(token)};
    byId("attendanceClass").onchange=()=>{
      state.attendanceClassId=byId("attendanceClass").value;
      if(state.attendanceClassId)loadAttendanceRegister(token);
      else byId("attendanceResults").innerHTML=`<div class="empty"><strong>Select an assigned class</strong></div>`;
    };
    byId("attendanceDate").onchange=()=>{state.attendanceDate=byId("attendanceDate").value;loadAttendanceRegister(token)};
    if(state.attendanceClassId)await loadAttendanceRegister(token);
    else byId("attendanceResults").innerHTML=`<div class="empty"><strong>No class-teacher assignment</strong><span>Ask the System Administrator to assign you as a class teacher.</span></div>`;
  }
  async function loadAttendanceRegister(token=state.viewToken) {
    const root=byId("attendanceResults");if(!root||!state.attendanceClassId||!state.attendanceTermId||!state.attendanceDate)return;
    root.innerHTML=`<div class="empty">Loading attendance register</div>`;
    const data=await rpc("get_class_attendance_register",{target_term_id:state.attendanceTermId,target_class_id:state.attendanceClassId,target_date:state.attendanceDate});
    if(token!==state.viewToken||!byId("attendanceResults"))return;
    state.attendanceData=data;
    const rows=data.students||[],opened=Number(data.days_school_opened||0),marked=Boolean(data.register?.id);
    root.innerHTML=`
      <div class="panel-header"><div><h3>${esc(data.class?.name||"Assigned Class")}</h3><p>${isoDate(state.attendanceDate)} • ${marked?"Attendance already recorded":"New attendance register"}</p></div>
        <div class="button-row"><button class="button outline small" id="attendanceAllPresent" type="button" ${rows.length&&licenseCanWrite()?"":"disabled"}>Mark all present</button><button class="button primary" id="attendanceSave" type="button" ${rows.length&&licenseCanWrite()?"":"disabled"}>Save attendance</button></div></div>
      <div class="panel-body">
        <div class="metric-row attendance-summary"><div class="metric"><span>Students</span><strong>${number(rows.length)}</strong></div><div class="metric"><span>School days recorded</span><strong>${number(opened)}</strong></div><div class="metric"><span>Selected date</span><strong>${esc(marked?"Recorded":"Not recorded")}</strong></div></div>
        ${rows.length?`<div class="table-wrap"><table><thead><tr><th>Student</th><th>Admission No.</th><th>Daily status</th><th>Term attendance</th></tr></thead><tbody>
          ${rows.map(row=>`<tr><td><div class="cell-copy"><strong>${esc(row.full_name)}</strong><small>${row.roll_number?`Roll ${esc(row.roll_number)}`:""}</small></div></td><td>${esc(row.admission_no)}</td>
            <td><select class="attendance-status-select" data-attendance-enrollment="${attr(row.enrollment_id)}">${attendanceStatusOptions(row.attendance_status)}</select></td>
            <td><strong>${number(row.days_present)} / ${number(row.days_school_opened)}</strong><small class="attendance-term-label"> days present</small></td></tr>`).join("")}
        </tbody></table></div><label class="field attendance-notes"><span>Attendance note (optional)</span><textarea id="attendanceNotes">${esc(data.register?.notes||"")}</textarea></label>`:
        `<div class="empty"><strong>No students found</strong><span>No active student records are enrolled in this class for the selected term.</span></div>`}
      </div>`;
    byId("attendanceAllPresent")?.addEventListener("click",()=>$$('[data-attendance-enrollment]',root).forEach(select=>{select.value="present"}));
    byId("attendanceSave")?.addEventListener("click",saveClassAttendance);
  }
  async function saveClassAttendance() {
    const button=byId("attendanceSave"),entries=$$('[data-attendance-enrollment]',byId("attendanceResults")).map(select=>({enrollment_id:select.dataset.attendanceEnrollment,attendance_status:select.value}));
    if(!entries.length)return;
    button.disabled=true;button.textContent="Saving";
    try{
      const data=await rpc("save_class_attendance",{target_term_id:state.attendanceTermId,target_class_id:state.attendanceClassId,target_date:state.attendanceDate,entries,notes_text:byId("attendanceNotes")?.value.trim()||""});
      state.attendanceData=data;state.workspace=null;toast("Attendance saved",`${number(data.days_school_opened||0)} school day${Number(data.days_school_opened||0)===1?"":"s"} recorded for this term.`);await loadAttendanceRegister();
    }catch(error){toast("Attendance not saved",friendlyError(error),"error",6500)}
    finally{if(button){button.disabled=false;button.textContent="Save attendance"}}
  }

  async function renderMySubjects(token,force=false) {
    const data=await loadRoleWorkspace(force);if(token!==state.viewToken)return;
    const subjects=data.subjects||[];
    byId("content").innerHTML=`<div class="page-head"><div><h3>My Subjects</h3><p>Assigned classes and assessment workload</p></div></div><section class="panel"><div class="table-wrap"><table><thead><tr><th>Class</th><th>Subject</th><th>Learners</th><th>Open reports</th><th>Scored</th><th>Progress</th><th></th></tr></thead><tbody>
      ${subjects.length?subjects.map(item=>{const completion=workspaceProgress(item.scored_reports,item.expected_reports);return `<tr><td><strong>${esc(item.class_name)}</strong></td><td><div class="cell-copy"><strong>${esc(item.subject_name)}</strong><small>${esc(item.subject_code||"")}</small></div></td><td>${number(item.student_count)}</td><td>${number(item.open_reports)}</td><td>${number(item.scored_reports)} / ${number(item.expected_reports)}</td><td><div class="bar-track"><span style="width:${completion}%"></span></div><small>${completion}%</small></td><td><button class="button primary small" data-subject-reports="${attr(item.class_id)}">Report Cards</button></td></tr>`}).join(""):`<tr><td colspan="7"><div class="empty"><strong>No assigned subjects</strong></div></td></tr>`}
      </tbody></table></div></section>`;
    $$('[data-subject-reports]').forEach(button=>button.onclick=()=>{state.reportClassFilter=button.dataset.subjectReports;navigate("reports")});
  }
  function statCard(colour,icon,label,value) {
    const display=typeof value==="string"?value:number(value);
    return `<article class="stat-card"><div class="stat-icon ${colour}">${icon}</div><div><span>${esc(label)}</span><strong>${esc(display)}</strong></div></article>`;
  }
  function canRemoveReportRow(row) {
    if(!can("remove_reports")||row?.archived)return false;
    return ["system_admin","class_teacher","subject_teacher"].includes(role());
  }
  function reportTable(rows,compact=false,manage=false) {
    if(!rows.length)return `<div class="empty"><strong>No report cards</strong><span>Records will appear here when available.</span></div>`;
    return `<div class="table-wrap"><table><thead><tr>
      <th>Student</th><th>Class</th><th>Term</th><th>Average</th><th>Status</th><th>Updated</th>${compact?"":"<th></th>"}
      </tr></thead><tbody>${rows.map(row=>`<tr>
      <td><div class="cell-copy"><strong>${esc(row.student_name)}</strong><small>${esc(row.report_number||row.admission_no||"")}</small></div></td>
      <td>${esc(row.class_name)}</td><td>${esc(row.term_name||"")}</td><td><strong>${number(row.average,1)}%</strong></td>
      <td>${statusBadge(row.archived?"archived":row.status)}</td><td>${isoDateTime(row.updated_at)}</td>
      ${compact?"":`<td><div class="table-actions">
        ${!row.archived?`<button class="button secondary small" data-report-id="${attr(row.id)}">Open</button>`:""}
        ${manage&&canRemoveReportRow(row)?`<button class="button danger small" data-report-archive="${attr(row.id)}">Delete permanently</button>`:""}
      </div></td>`}
      </tr>`).join("")}</tbody></table></div>`;
  }

  async function renderStudents(token) {
    const visibleClasses=await visibleClassesForCurrentRole();
    if(token!==state.viewToken)return;
    if(state.studentClassFilter&&!visibleClasses.some(item=>item.id===state.studentClassFilter))state.studentClassFilter="";
    const content=byId("content");
    content.innerHTML=`
      <div class="page-head"><div><h3>Student Directory</h3><p>Secure student, guardian, and enrolment records</p></div>
        <div class="page-actions">
          ${can("manage_students")?`<button class="button outline" id="studentImport">Import CSV</button><button class="button outline" id="studentExport">Export CSV</button><button class="button primary" id="studentAdd">Add student</button>`:""}
        </div></div>
      <section class="panel">
        <div class="toolbar">
          <label class="search"><input id="studentSearch" type="search" placeholder="Search name or admission number"></label>
          <select id="studentClass">${optionList(visibleClasses,"id","name",state.studentClassFilter||"",["class_teacher","subject_teacher"].includes(role())?"All assigned classes":"All classes")}</select>
          <select id="studentStatus"><option value="">All statuses</option><option value="active">Active</option><option value="graduated">Graduated</option><option value="withdrawn">Withdrawn</option><option value="suspended">Suspended</option></select>
          ${can("remove_students")?`<select id="studentArchive"><option value="active">Current records</option><option value="archived">Archived records</option><option value="all">All records</option></select>`:""}
        </div>
        <div id="studentResults"><div class="empty">Loading students</div></div>
      </section>`;
    byId("studentAdd")?.addEventListener("click",()=>openStudentEditor());
    byId("studentImport")?.addEventListener("click",openStudentImport);
    byId("studentExport")?.addEventListener("click",exportStudentsCsv);
    let timer;
    byId("studentSearch").addEventListener("input",()=>{clearTimeout(timer);timer=setTimeout(()=>{state.studentPage=1;loadStudentPage(token)},250)});
    byId("studentClass").addEventListener("change",()=>{state.studentPage=1;loadStudentPage(token)});
    byId("studentStatus").addEventListener("change",()=>{state.studentPage=1;loadStudentPage(token)});
    byId("studentArchive")?.addEventListener("change",()=>{state.studentPage=1;loadStudentPage(token)});
    await loadStudentPage(token);
  }
  async function loadStudentPage(token=state.viewToken) {
    const container=byId("studentResults");if(!container)return;
    container.innerHTML=`<div class="empty">Loading students</div>`;
    const data=await rpc("search_students_v5",{
      search_text:byId("studentSearch")?.value.trim()||"",
      target_class_id:byId("studentClass")?.value||null,
      target_status:byId("studentStatus")?.value||null,
      archive_filter:byId("studentArchive")?.value||"active",
      page_number:state.studentPage,page_size:CONFIG.pageSize
    });
    if(token!==state.viewToken||!byId("studentResults"))return;
    const rows=data.rows||[];
    container.innerHTML=rows.length?`
      <div class="table-wrap"><table><thead><tr><th>Student</th><th>Admission No.</th><th>Class</th><th>Academic Year</th><th>Status</th><th></th></tr></thead>
      <tbody>${rows.map(row=>`<tr>
        <td><div class="cell-main"><img class="thumb signed-photo" data-photo="${attr(row.photo_url||"")}" src="${CONFIG.logoPath}" alt="">
          <div class="cell-copy"><strong>${esc(fullName(row))}</strong><small>${esc(row.gender||"")} ${row.roll_number?`• Roll ${esc(row.roll_number)}`:""}</small></div></div></td>
        <td>${esc(row.admission_no)}</td><td>${esc(row.class_name||"—")}</td><td>${esc(row.academic_year_name||"—")}</td>
        <td>${statusBadge(row.archived?"archived":row.status)}</td><td><div class="table-actions">
          <button class="button secondary small" data-student-view="${attr(row.id)}">View</button>
          ${can("manage_students")&&!row.archived?`<button class="button ghost small" data-student-edit="${attr(row.id)}">Edit</button>`:""}
          ${row.enrollment_id&&!row.archived&&["class_teacher","subject_teacher"].includes(role())?`<button class="button outline small" data-student-report="${attr(row.enrollment_id)}">Report</button>`:""}
          ${can("remove_students")&&!row.archived?`<button class="button danger small" data-student-archive="${attr(row.id)}">Remove</button>`:""}
          ${can("remove_students")&&row.archived?`<button class="button success small" data-student-restore="${attr(row.id)}">Restore</button>`:""}
        </div></td></tr>`).join("")}</tbody></table></div>
      ${pagination(data.total,data.page,data.page_size,"student")}`:`<div class="empty"><strong>No students found</strong><span>The current filters returned no records.</span></div>`;
    resolveSignedPhotos(container);
    $$("[data-student-view]",container).forEach(btn=>btn.onclick=()=>openStudentRecord(btn.dataset.studentView));
    $$("[data-student-edit]",container).forEach(btn=>btn.onclick=()=>openStudentEditor(btn.dataset.studentEdit));
    $$("[data-student-report]",container).forEach(btn=>btn.onclick=()=>chooseTermForReport(btn.dataset.studentReport));
    $$("[data-student-archive]",container).forEach(btn=>btn.onclick=()=>archiveStudent(btn.dataset.studentArchive));
    $$("[data-student-restore]",container).forEach(btn=>btn.onclick=()=>restoreStudent(btn.dataset.studentRestore));
    bindPagination("student",data);
  }
  function pagination(total,page,pageSize,key) {
    const pages=Math.max(1,Math.ceil(Number(total||0)/Number(pageSize||CONFIG.pageSize)));
    const start=total?((page-1)*pageSize+1):0,end=Math.min(page*pageSize,total);
    return `<div class="pagination"><small>${number(start)}–${number(end)} of ${number(total)}</small><div class="pager">
      <button class="button ghost small" data-page-key="${key}" data-page="${page-1}" ${page<=1?"disabled":""}>Previous</button>
      <button class="button ghost small" data-page-key="${key}" data-page="${page+1}" ${page>=pages?"disabled":""}>Next</button>
    </div></div>`;
  }
  function bindPagination(key,data) {
    $$(`[data-page-key="${key}"]`).forEach(button=>button.onclick=()=>{
      const page=Number(button.dataset.page);if(page<1)return;
      if(key==="student"){state.studentPage=page;loadStudentPage()}
      if(key==="teacher"){state.teacherPage=page;loadTeacherPage()}
      if(key==="principal"){state.headteacherPage=page;loadPrincipalPage()}
      if(key==="report"){state.reportPage=page;loadReportPage()}
    });
  }
  async function resolveSignedPhotos(root=document) {
    await Promise.all($$(".signed-photo",root).map(async image=>{
      const path=image.dataset.photo;if(!path)return;
      try{image.src=await signedUrl(CONFIG.photoBucket,path)}catch(_){image.src=CONFIG.logoPath}
    }));
  }

  async function openStudentRecord(id) {
    const data=await run(()=>rpc("get_student_record_v5",{target_student_id:id}),{context:{student_id:id}});
    state.currentStudent=data;
    const student=data.student||{},enrolments=data.enrollments||[],guardians=data.guardians||[],reports=data.reports||[];
    modal(fullName(student),student.admission_no,`
      <div class="grid two">
        <div class="panel pad">
          <div class="cell-main"><img id="recordPhoto" class="preview-photo" src="${CONFIG.logoPath}" alt=""><div class="cell-copy">
            <strong>${esc(fullName(student))}</strong><small>${esc(student.gender)} • ${isoDate(student.date_of_birth)}</small>
            <small>${statusBadge(student.archived?"archived":student.status)}</small></div></div>
          <div class="hr"></div><div class="section-title"><h4>Guardians</h4></div>
          ${guardians.length?guardians.map(g=>`<div class="metric"><strong>${esc(g.full_name)}</strong><span>${esc(g.relationship)} • ${esc(g.phone||"No phone")} • ${esc(g.email||"No email")}</span></div>`).join(""):`<p class="help-text">No guardian record</p>`}
        </div>
        <div class="panel pad"><div class="section-title"><h4>Enrolment History</h4></div>
          ${enrolments.length?enrolments.map(e=>`<div class="diff-row"><span>${esc(e.academic_year_name)} • ${esc(e.class_name)}</span><b>${e.active?"Active":"Closed"}</b></div>`).join(""):`<p class="help-text">No enrolment record</p>`}
        </div>
      </div>
      <div class="section-title" style="margin-top:18px"><h4>Report Cards</h4></div>
      ${reportTable(reports)}
    `,can("manage_students")?`<div class="button-row">
      ${!student.archived?`<button class="button primary" id="recordEdit">Edit student</button>`:""}
      ${can("remove_students")&&!student.archived?`<button class="button danger" id="recordArchive">Remove student</button>`:""}
      ${can("remove_students")&&student.archived?`<button class="button success" id="recordRestore">Restore student</button>`:""}
    </div>`:"","wide");
    if(student.photo_url) signedUrl(CONFIG.photoBucket,student.photo_url).then(url=>{if(byId("recordPhoto"))byId("recordPhoto").src=url}).catch(()=>{});
    byId("recordEdit")?.addEventListener("click",()=>{closeModal();openStudentEditor(id)});
    byId("recordArchive")?.addEventListener("click",()=>{closeModal();archiveStudent(id)});
    byId("recordRestore")?.addEventListener("click",()=>{closeModal();restoreStudent(id)});
    $$("[data-report-id]",byId("modalBody")).forEach(btn=>btn.onclick=()=>{closeModal();openReportEditor(btn.dataset.reportId)});
  }

  async function archiveStudent(id) {
    const ok=await confirmAction("Remove Student","The student will be archived while historical reports remain preserved.","Remove",true);
    if(!ok)return;
    try{
      await rpc("archive_student",{target_student_id:id,reason_text:"Student removed from active records"});
      state.workspace=null;toast("Student removed");await loadStudentPage();
    }catch(error){toast("Student not removed",friendlyError(error),"error")}
  }
  async function restoreStudent(id) {
    const ok=await confirmAction("Restore Student","The student will return to the current student directory.","Restore");
    if(!ok)return;
    try{
      await rpc("restore_student",{target_student_id:id,reason_text:"Student restored to active records"});
      state.workspace=null;toast("Student restored");await loadStudentPage();
    }catch(error){toast("Student not restored",friendlyError(error),"error")}
  }

  async function openStudentEditor(id=null) {
    let record={student:{status:"active",gender:"Male"},enrollments:[],guardians:[]};
    if(id) record=await run(()=>rpc("get_student_record_v5",{target_student_id:id}));
    try{state.guardianAccounts=await rpc("list_guardian_portal_accounts",{search_text:""})}catch(_){state.guardianAccounts=[]}
    const student=record.student||{},latest=record.enrollments?.[0]||{},guardian=record.guardians?.find(g=>g.is_primary)||record.guardians?.[0]||{};
    if(!id&&!student.admission_no){try{student.admission_no=await rpc("generate_school_identifier",{identifier_kind:"student"})}catch(_){student.admission_no=""}}
    const years=state.boot.academic_years||[],classes=state.boot.classes||[];
    modal(id?"Edit Student":"Add Student",id?student.admission_no:"",`
      <form id="studentForm" class="form-stack">
        <input type="hidden" name="id" value="${attr(student.id||"")}">
        <input type="hidden" name="updated_at" value="${attr(student.updated_at||"")}">
        <div class="form-grid three">
          <label class="field"><span>Admission number</span><input name="admission_no" value="${attr(student.admission_no||"")}" readonly></label>
          <label class="field"><span>First name</span><input name="first_name" value="${attr(student.first_name||"")}" required></label>
          <label class="field"><span>Middle name</span><input name="middle_name" value="${attr(student.middle_name||"")}"></label>
          <label class="field"><span>Last name</span><input name="last_name" value="${attr(student.last_name||"")}" required></label>
          <label class="field"><span>Gender</span><select name="gender">
            ${["Male","Female","Other"].map(v=>`<option ${v===student.gender?"selected":""}>${v}</option>`).join("")}</select></label>
          <label class="field"><span>Date of birth</span><input type="date" name="date_of_birth" value="${attr(student.date_of_birth||"")}"></label>
          <label class="field"><span>Status</span><select name="status">
            ${["active","graduated","withdrawn","suspended"].map(v=>`<option value="${v}" ${v===student.status?"selected":""}>${v.replaceAll("_"," ")}</option>`).join("")}</select></label>
          <label class="field"><span>Academic year</span><select name="academic_year_id">${optionList(years,"id","name",latest.academic_year_id||activeYear()?.id,"Select academic year")}</select></label>
          <label class="field"><span>Class</span><select name="class_id">${optionList(classes,"id","name",latest.class_id,"Select class")}</select></label>
          <label class="field"><span>Roll number</span><input type="number" min="1" name="roll_number" value="${attr(latest.roll_number||"")}"></label>
          <label class="field full"><span>Student photograph</span><input id="studentPhotoFile" type="file" accept="image/jpeg,image/png,image/webp"></label>
        </div>
        <div class="section-title"><h4>Primary Guardian</h4></div>
        <div class="form-grid three">
          <input type="hidden" name="guardian_id" value="${attr(guardian.id||"")}">
          <label class="field"><span>Full name</span><input name="guardian_name" value="${attr(guardian.full_name||student.guardian_name||"")}"></label>
          <label class="field"><span>Relationship</span><input name="relationship" value="${attr(guardian.relationship||"Guardian")}"></label>
          <label class="field"><span>Telephone</span><input name="guardian_phone" value="${attr(guardian.phone||student.guardian_phone||"")}"></label>
          <label class="field"><span>Email</span><input type="email" name="guardian_email" value="${attr(guardian.email||student.guardian_email||"")}"></label>
          <label class="field"><span>Portal account</span><select name="guardian_auth_user_id">${optionList((state.guardianAccounts||[]).map(item=>({...item,label:`${item.full_name}${item.email?` • ${item.email}`:""}`})),"id","label",guardian.auth_user_id,"No linked account")}</select></label>
          <label class="field"><span>Address</span><input name="guardian_address" value="${attr(guardian.address||"")}"></label>
          <label class="check-field"><input type="checkbox" name="guardian_notify" ${guardian.can_receive_notifications!==false?"checked":""}><span>Receive notifications</span></label>
        </div>
      </form>`,
      `<button class="button ghost" type="button" id="studentCancel">Cancel</button><button class="button primary" type="submit" form="studentForm" id="studentSave">Save student</button>`,"wide");
    byId("studentCancel").onclick=closeModal;
    byId("studentForm").addEventListener("submit",event=>{event.preventDefault();saveStudentForm(record)});
  }

  function formObject(form) {return Object.fromEntries(new FormData(form).entries())}
  async function saveStudentForm(record) {
    const form=byId("studentForm"),button=byId("studentSave");
    if(!form?.reportValidity()){toast("Student not saved","Complete the required student fields.","error");return}
    const values=formObject(form);if(Boolean(values.academic_year_id)!==Boolean(values.class_id)){toast("Student not saved","Academic year and class must be selected together.","error");return}
    button.disabled=true;button.textContent="Saving";
    const payload={
      student:{id:values.id,updated_at:values.updated_at,admission_no:values.admission_no.trim(),first_name:values.first_name.trim(),
        middle_name:(values.middle_name||"").trim(),last_name:values.last_name.trim(),gender:values.gender,
        date_of_birth:values.date_of_birth||"",status:values.status,photo_url:record.student?.photo_url||""},
      enrollment:values.academic_year_id&&values.class_id?{academic_year_id:values.academic_year_id,class_id:values.class_id,roll_number:values.roll_number||"",active:true}:{},
      guardian:{id:values.guardian_id,full_name:(values.guardian_name||"").trim(),relationship:(values.relationship||"Guardian").trim(),
        phone:(values.guardian_phone||"").trim(),email:(values.guardian_email||"").trim(),address:(values.guardian_address||"").trim(),
        auth_user_id:values.guardian_auth_user_id||"",is_primary:true,can_view_reports:true,
        can_receive_notifications:form.elements.guardian_notify.checked},
      reason:values.id?"Student record updated":"Student registered"
    };
    let saved;
    try {
      saved=await rpc("save_student",{payload});
    } catch(error) {
      await reportClientError(error,{source:"student_save",stage:"record"});
      toast("Student not saved",friendlyError(error),"error",6500);
      button.disabled=false;button.textContent="Save student";return;
    }

    let photoWarning="",photoReportSummary="";
    const file=byId("studentPhotoFile")?.files?.[0];
    if(file) {
      let uploadedPhotoPath="",photoSaved=false;
      try {
        uploadedPhotoPath=await uploadStudentPhoto(saved.student.id,file);
        saved=await rpc("set_student_photo",{target_student_id:saved.student.id,target_photo_url:uploadedPhotoPath,expected_updated_at:saved.student.updated_at||null});
        uploadedPhotoPath="";photoSaved=true;
      } catch(error) {
        if(uploadedPhotoPath)await state.client.storage.from(CONFIG.photoBucket).remove([uploadedPhotoPath]).catch(()=>{});
        await reportClientError(error,{source:"student_save",stage:"photo",student_id:saved.student.id});
        photoWarning="The student record was saved, but the photograph was not updated.";
      }
      if(photoSaved){
        button.textContent="Updating report PDFs";
        const refreshed=await refreshPublishedStudentReportPdfs(saved.student);
        if(refreshed.updated)photoReportSummary=`${refreshed.updated} published report PDF${refreshed.updated===1?"":"s"} updated with the photograph.`;
        if(refreshed.failed)photoWarning=`The photograph was saved, but ${refreshed.failed} published report PDF${refreshed.failed===1?"":"s"} could not be refreshed automatically.`;
      }
    }

    state.workspace=null;closeModal();
    const saveDetail=[photoReportSummary,photoWarning].filter(Boolean).join(" ");
    toast("Student record saved",saveDetail,photoWarning?"warning":"success",7500);
    try {
      state.boot=await rpc("get_bootstrap_data");
      await loadStudentPage();
    } catch(error) {
      await reportClientError(error,{source:"student_save",stage:"refresh",student_id:saved.student.id});
      toast("Student saved","Reload the page to display the latest record.","warning",6500);
    } finally {button.disabled=false;button.textContent="Save student"}
  }
  async function compressImage(file,maxSize=1000,quality=.84) {
    const bitmap=await createImageBitmap(file),scale=Math.min(1,maxSize/Math.max(bitmap.width,bitmap.height));
    const canvas=document.createElement("canvas");canvas.width=Math.round(bitmap.width*scale);canvas.height=Math.round(bitmap.height*scale);
    canvas.getContext("2d").drawImage(bitmap,0,0,canvas.width,canvas.height);bitmap.close();
    return new Promise((resolve,reject)=>canvas.toBlob(blob=>blob?resolve(blob):reject(new Error("Image conversion failed")),"image/webp",quality));
  }
  async function uploadStudentPhoto(studentId,file) {
    const blob=await compressImage(file),path=`${studentId}/${Date.now()}.webp`;
    const {error}=await state.client.storage.from(CONFIG.photoBucket).upload(path,blob,{contentType:"image/webp",upsert:false});
    if(error)throw error;
    return path;
  }
  function parseCsv(text) {
    const rows=[];let row=[],cell="",quoted=false;
    for(let i=0;i<text.length;i++){
      const ch=text[i],next=text[i+1];
      if(ch==='"'&&quoted&&next==='"'){cell+='"';i++}
      else if(ch==='"'){quoted=!quoted}
      else if(ch===","&&!quoted){row.push(cell);cell=""}
      else if((ch==="\n"||ch==="\r")&&!quoted){if(ch==="\r"&&next==="\n")i++;row.push(cell);cell="";if(row.some(v=>v.trim()))rows.push(row);row=[]}
      else cell+=ch;
    }
    row.push(cell);if(row.some(v=>v.trim()))rows.push(row);
    if(rows.length<2)return[];
    const headers=rows[0].map(h=>h.trim().toLowerCase().replace(/\s+/g,"_"));
    return rows.slice(1).map(values=>Object.fromEntries(headers.map((h,i)=>[h,(values[i]||"").trim()])));
  }
  function openStudentImport() {
    modal("Import Students","CSV student registration",`
      <form id="studentImportForm" class="form-stack">
        <div class="form-grid">
          <label class="field"><span>Academic year</span><select name="academic_year_id" required>${optionList(state.boot.academic_years||[],"id","name",activeYear()?.id)}</select></label>
          <label class="field"><span>Class</span><select name="class_id" required>${optionList(state.boot.classes||[],"id","name")}</select></label>
        </div>
        <label class="file-drop"><strong>CSV file</strong><input name="file" type="file" accept=".csv,text/csv" required></label>
      </form>`,
      `<button class="button ghost" id="importCancel" type="button">Cancel</button><button class="button primary" id="importRun" type="button">Import</button>`,"small");
    byId("importCancel").onclick=closeModal;
    byId("importRun").onclick=async()=>{
      const form=byId("studentImportForm"),file=form.elements.file.files[0];if(!file)return;
      const values=formObject(form),rows=parseCsv(await file.text()).map(row=>({...row,academic_year_id:values.academic_year_id,class_id:values.class_id}));
      const button=byId("importRun");button.disabled=true;
      try {
        const result=await rpc("bulk_import_students",{rows,filename:file.name});
        closeModal();toast("Import completed",`${result.successful} saved, ${result.failed} failed`,result.failed?"warning":"success",7000);
        await loadStudentPage();
      } catch(error){toast("Import unsuccessful",friendlyError(error),"error")}
      finally{button.disabled=false}
    };
  }
  async function exportStudentsCsv() {
    const data=await rpc("search_students_v5",{search_text:byId("studentSearch")?.value||"",target_class_id:byId("studentClass")?.value||null,
      target_status:byId("studentStatus")?.value||null,archive_filter:byId("studentArchive")?.value||"active",page_number:1,page_size:100});
    const headers=["admission_no","first_name","middle_name","last_name","gender","date_of_birth","status","class_name","academic_year_name","roll_number"];
    downloadText("students.csv",[headers.join(","),...(data.rows||[]).map(row=>headers.map(h=>csvCell(row[h])).join(","))].join("\n"),"text/csv");
  }
  const csvCell=value=>`"${String(value??"").replaceAll('"','""')}"`;
  function downloadText(filename,text,type="text/plain") {
    const url=URL.createObjectURL(new Blob([text],{type})),a=document.createElement("a");a.href=url;a.download=filename;a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);
  }
  function chooseTermForReport(enrollmentId) {
    const enrollmentYear=(state.currentStudent?.enrollments||[]).find(e=>e.id===enrollmentId)?.academic_year_id;
    const terms=(state.boot.terms||[]).filter(t=>!enrollmentYear||t.academic_year_id===enrollmentYear);
    modal("Select Term","Create or open a report card",`<label class="field"><span>Term</span><select id="reportTermChoice">${optionList(terms,"id","name",activeTerm()?.id)}</select></label>`,
      `<button class="button ghost" id="termCancel" type="button">Cancel</button><button class="button primary" id="termOpen" type="button">Open report</button>`,"small");
    byId("termCancel").onclick=closeModal;
    byId("termOpen").onclick=()=>{const termId=byId("reportTermChoice").value;if(termId){closeModal();openReportEditor(null,enrollmentId,termId)}};
  }


  async function renderAcademics(token) {
    const data=await rpc("get_academic_configuration");
    if(token!==state.viewToken)return;
    state.academic=data;
    byId("content").innerHTML=`
      <div class="page-head"><div><h3>Academic Configuration</h3><p>Periods, classes, subjects, assessment, and promotion</p></div></div>
      <div class="tabs">
        ${[["periods","Academic Periods"],["classes","Classes and Subjects"],["assessment","Assessment Schemes"],["grading","Grading Scales"],["promotion","Class Promotion"]].map(([id,label])=>
          `<button class="tab ${state.academicTab===id?"active":""}" data-academic-tab="${id}">${label}</button>`).join("")}
      </div>
      <div id="academicPanel"></div>`;
    $$("[data-academic-tab]").forEach(button=>button.onclick=()=>{state.academicTab=button.dataset.academicTab;renderAcademicTab()});
    renderAcademicTab();
  }
  function renderAcademicTab() {
    const target=byId("academicPanel");if(!target)return;
    const renderers={periods:renderPeriodsTab,classes:renderClassesTab,assessment:renderAssessmentTab,grading:renderGradingTab,promotion:renderPromotionTab};
    target.innerHTML=renderers[state.academicTab]();
    bindAcademicTabEvents();
  }
  function renderPeriodsTab() {
    const y=state.academic.academic_years||[],terms=state.academic.terms||[];
    return `<div class="grid two">
      <section class="panel"><div class="panel-header"><div><h3>Academic Years</h3><p>${y.length} configured</p></div><button class="button primary small" id="addYear">Add year</button></div>
        <div class="table-wrap"><table><thead><tr><th>Name</th><th>Dates</th><th>Status</th><th></th></tr></thead><tbody>
          ${y.map(row=>`<tr><td><strong>${esc(row.name)}</strong></td><td>${isoDate(row.start_date)} – ${isoDate(row.end_date)}</td>
            <td>${row.is_active?`<span class="status published">Active</span>`:`<span class="status draft">Inactive</span>`}</td>
            <td><div class="table-actions"><button class="button ghost small" data-edit-year="${row.id}">Edit</button>${!row.is_active?`<button class="button danger small" data-remove-year="${row.id}">Remove</button>`:""}</div></td></tr>`).join("")}
        </tbody></table></div></section>
      <section class="panel"><div class="panel-header"><div><h3>Terms</h3><p>${terms.length} configured</p></div><button class="button primary small" id="addTerm">Add term</button></div>
        <div class="table-wrap"><table><thead><tr><th>Term</th><th>Academic Year</th><th>Status</th><th></th></tr></thead><tbody>
          ${terms.map(row=>`<tr><td><div class="cell-copy"><strong>${esc(row.name)}</strong><small>${isoDate(row.start_date)} – ${isoDate(row.end_date)}</small></div></td>
            <td>${esc(y.find(x=>x.id===row.academic_year_id)?.name||"")}</td>
            <td>${row.is_active?`<span class="status published">Active</span>`:`<span class="status draft">Inactive</span>`}</td>
            <td><div class="table-actions"><button class="button ghost small" data-edit-term="${row.id}">Edit</button>
            ${!row.is_active?`<button class="button success small" data-set-active="${row.academic_year_id}|${row.id}">Activate</button><button class="button danger small" data-remove-term="${row.id}">Remove</button>`:""}</div></td></tr>`).join("")}
        </tbody></table></div></section>
    </div>`;
  }
  function classSubjectAssignmentGroups(assignments=[]) {
    const groups=new Map();
    assignments.forEach(row=>{
      const key=row.teacher_id||"__unassigned__";
      if(!groups.has(key)){
        groups.set(key,{
          key,
          teacher_id:row.teacher_id||null,
          teacher_name:row.teacher_name||"Unassigned",
          rows:[],
          classes:new Map(),
          subjects:new Map(),
          active_count:0,
          inactive_count:0
        });
      }
      const group=groups.get(key);
      group.rows.push(row);
      if(row.class_id||row.class_name)group.classes.set(row.class_id||row.class_name,row.class_name||"Class");
      if(row.subject_id||row.subject_name)group.subjects.set(row.subject_id||row.subject_name,row.subject_name||"Subject");
      if(row.active)group.active_count+=1;else group.inactive_count+=1;
    });
    return [...groups.values()].sort((a,b)=>
      String(a.teacher_name).localeCompare(String(b.teacher_name),undefined,{sensitivity:"base"})
    );
  }

  function assignmentCountText(count,singular,plural=`${singular}s`) {
    return `${count} ${count===1?singular:plural}`;
  }

  function assignmentNamesPreview(values,limit=3) {
    const names=[...values.values()];
    if(!names.length)return "—";
    if(names.length<=limit)return names.join(", ");
    return `${names.slice(0,limit).join(", ")} +${names.length-limit}`;
  }

  function openAssignmentGroupManager(groupKey) {
    const group=classSubjectAssignmentGroups(state.academic?.class_subjects||[])
      .find(item=>item.key===groupKey);
    if(!group)return;
    const rows=[...group.rows].sort((a,b)=>
      String(a.class_name||"").localeCompare(String(b.class_name||""),undefined,{numeric:true,sensitivity:"base"})||
      String(a.subject_name||"").localeCompare(String(b.subject_name||""),undefined,{sensitivity:"base"})
    );
    modal("Manage Teacher Assignments",group.teacher_name,`
      <div class="assignment-group-summary">
        <div><span>Teacher</span><strong>${esc(group.teacher_name)}</strong></div>
        <div><span>Classes</span><strong>${assignmentCountText(group.classes.size,"class","classes")}</strong></div>
        <div><span>Subjects</span><strong>${assignmentCountText(group.subjects.size,"subject")}</strong></div>
        <div><span>Assignments</span><strong>${assignmentCountText(group.rows.length,"assignment")}</strong></div>
      </div>
      <div class="assignment-detail-meta">
        <div><span>Classes:</span> ${esc([...group.classes.values()].join(", ")||"—")}</div>
        <div><span>Subjects:</span> ${esc([...group.subjects.values()].join(", ")||"—")}</div>
      </div>
      <div class="table-wrap assignment-detail-table"><table>
        <thead><tr><th>Class</th><th>Subject</th><th>Status</th><th></th></tr></thead>
        <tbody>${rows.map(row=>`<tr>
          <td>${esc(row.class_name||"—")}</td>
          <td>${esc(row.subject_name||"—")}</td>
          <td>${row.active?`<span class="status published">Active</span>`:`<span class="status withdrawn">Inactive</span>`}</td>
          <td><div class="table-actions">
            <button class="button ghost small" data-group-edit-assignment="${attr(row.id)}">Edit</button>
            ${row.active
              ?`<button class="button danger small" data-group-remove-assignment="${attr(row.id)}">Remove</button>`
              :`<button class="button danger small" data-group-delete-assignment="${attr(row.id)}">Delete</button>`}
          </div></td>
        </tr>`).join("")}</tbody>
      </table></div>
    `,`<button class="button ghost" id="assignmentGroupClose" type="button">Close</button>
       ${group.teacher_id?`<button class="button primary" id="assignmentGroupAdd" type="button">Assign more</button>`:""}`,"wide");
    byId("assignmentGroupClose").onclick=closeModal;
    if(byId("assignmentGroupAdd"))byId("assignmentGroupAdd").onclick=()=>{
      const teacherId=group.teacher_id;
      closeModal();
      openAssignmentEditor(null,teacherId);
    };
    $$("[data-group-edit-assignment]").forEach(button=>button.onclick=()=>{
      const id=button.dataset.groupEditAssignment;
      closeModal();
      openAssignmentEditor(id);
    });
    $$("[data-group-remove-assignment]").forEach(button=>button.onclick=()=>{
      const id=button.dataset.groupRemoveAssignment;
      closeModal();
      removeAcademicEntity("assignment",id);
    });
    $$("[data-group-delete-assignment]").forEach(button=>button.onclick=()=>{
      const id=button.dataset.groupDeleteAssignment;
      closeModal();
      deleteClassSubjectAssignment(id);
    });
  }

  function renderClassesTab() {
    const classes=state.academic.classes||[],subjects=state.academic.subjects||[],assignments=state.academic.class_subjects||[];
    const assignmentGroups=classSubjectAssignmentGroups(assignments);
    const activeAssignments=assignments.filter(item=>item.active).length;
    const activeTeachers=assignmentGroups.filter(group=>group.active_count>0).length;
    return `<div class="grid two">
      <section class="panel"><div class="panel-header"><div><h3>Classes</h3><p>${classes.length} configured</p></div><button class="button primary small" id="addClass">Add class</button></div>
        <div class="table-wrap academic-list-scroll"><table><thead><tr><th>Class</th><th>Level</th><th>Class Teacher</th><th></th></tr></thead><tbody>
          ${classes.map(row=>`<tr><td><strong>${esc(row.name)}</strong></td><td>${number(row.level_order)}</td>
            <td>${esc(
              (state.academic.teacher_records||[]).find(t=>t.id===row.class_teacher_record_id)?.full_name
              ||(state.academic.profiles||[]).find(p=>p.id===row.class_teacher_id)?.full_name
              ||"—"
            )}</td>
            <td><div class="table-actions"><button class="button ghost small" data-edit-class="${row.id}">Edit</button><button class="button danger small" data-remove-class="${row.id}">Remove</button></div></td></tr>`).join("")}
        </tbody></table></div></section>
      <section class="panel"><div class="panel-header"><div><h3>Subjects</h3><p>${subjects.length} configured</p></div><button class="button primary small" id="addSubject">Add subject</button></div>
        <div class="table-wrap academic-list-scroll"><table><thead><tr><th>Code</th><th>Subject</th><th>Order</th><th></th></tr></thead><tbody>
          ${subjects.map(row=>`<tr><td><strong>${esc(row.code)}</strong></td><td>${esc(row.name)}</td><td>${number(row.display_order)}</td>
            <td><div class="table-actions"><button class="button ghost small" data-edit-subject="${row.id}">Edit</button><button class="button danger small" data-remove-subject="${row.id}">Remove</button></div></td></tr>`).join("")}
        </tbody></table></div></section>
      <section class="panel" style="grid-column:1/-1"><div class="panel-header"><div><h3>Class Subject Assignments</h3><p>${activeAssignments} active assignments across ${assignmentCountText(activeTeachers,"teacher")}</p></div>
        <button class="button primary small" id="addAssignment">Assign subject</button></div>
        <div class="table-wrap"><table class="compact-assignment-table"><thead><tr><th>Teacher</th><th>Classes</th><th>Subjects</th><th>Assignments</th><th>Status</th><th></th></tr></thead><tbody>
          ${assignmentGroups.length?assignmentGroups.map(group=>`<tr>
            <td><div class="cell-copy"><strong>${esc(group.teacher_name)}</strong><small>${group.teacher_id?"Assigned teacher":"No teacher selected"}</small></div></td>
            <td><div class="assignment-count"><strong>${assignmentCountText(group.classes.size,"class","classes")}</strong><small title="${attr([...group.classes.values()].join(", "))}">${esc(assignmentNamesPreview(group.classes))}</small></div></td>
            <td><div class="assignment-count"><strong>${assignmentCountText(group.subjects.size,"subject")}</strong><small title="${attr([...group.subjects.values()].join(", "))}">${esc(assignmentNamesPreview(group.subjects))}</small></div></td>
            <td><strong>${group.rows.length}</strong></td>
            <td><div class="assignment-status-stack">
              ${group.active_count?`<span class="status published">${group.active_count} active</span>`:""}
              ${group.inactive_count?`<span class="status withdrawn">${group.inactive_count} inactive</span>`:""}
            </div></td>
            <td><button class="button ghost small" data-manage-assignment-group="${attr(group.key)}">Manage</button></td>
          </tr>`).join(""):`<tr><td colspan="6"><div class="empty">No class-subject assignments configured</div></td></tr>`}
        </tbody></table></div></section>
    </div>`;
  }
  function renderAssessmentTab() {
    const schemes=state.academic.assessment_schemes||[];
    return `<section class="panel"><div class="panel-header"><div><h3>Assessment Schemes</h3><p>Weighted components by academic scope</p></div>
      <button class="button primary small" id="addScheme">Add scheme</button></div>
      <div class="table-wrap"><table><thead><tr><th>Scheme</th><th>Scope</th><th>Components</th><th>Weight</th><th>Status</th><th></th></tr></thead><tbody>
        ${schemes.map(row=>`<tr><td><strong>${esc(row.name)}</strong></td><td>${esc(schemeScope(row))}</td>
          <td>${(row.components||[]).map(c=>`<span class="chip">${esc(c.code)} ${number(c.weight,1)}%</span>`).join(" ")}</td>
          <td><strong>${number(row.total_weight,1)}%</strong></td><td>${row.active?`<span class="status published">Active</span>`:`<span class="status draft">Inactive</span>`}</td>
          <td><button class="button ghost small" data-edit-scheme="${row.id}">Edit</button></td></tr>`).join("")}
      </tbody></table></div></section>`;
  }
  function schemeScope(row) {
    const names=[];
    if(row.academic_year_id)names.push((state.academic.academic_years||[]).find(x=>x.id===row.academic_year_id)?.name);
    if(row.term_id)names.push((state.academic.terms||[]).find(x=>x.id===row.term_id)?.name);
    if(row.class_id)names.push((state.academic.classes||[]).find(x=>x.id===row.class_id)?.name);
    if(row.subject_id)names.push((state.academic.subjects||[]).find(x=>x.id===row.subject_id)?.name);
    return names.filter(Boolean).join(" • ")||"School-wide";
  }
  function renderGradingTab() {
    const scales=state.academic.grading_scales||[];
    return `<section class="panel"><div class="panel-header"><div><h3>Grading Scales</h3><p>Scope-aware grade ranges and points</p></div>
      <button class="button primary small" id="addGrade">Add grade</button></div>
      <div class="table-wrap"><table><thead><tr><th>Grade</th><th>Range</th><th>Remark</th><th>Point</th><th>Scope</th><th></th></tr></thead><tbody>
        ${scales.map(row=>`<tr><td><strong>${esc(row.grade)}</strong></td><td>${number(row.min_mark,2)}–${number(row.max_mark,2)}</td>
          <td>${esc(row.remark)}</td><td>${number(row.grade_point,2)}</td><td>${esc(gradeScope(row))}</td>
          <td><div class="table-actions"><button class="button ghost small" data-edit-grade="${row.id}">Edit</button>
            <button class="button danger small" data-delete-grade="${row.id}">Remove</button></div></td></tr>`).join("")}
      </tbody></table></div></section>`;
  }
  function gradeScope(row) {
    return [
      (state.academic.academic_years||[]).find(x=>x.id===row.academic_year_id)?.name,
      (state.academic.classes||[]).find(x=>x.id===row.class_id)?.name,
      (state.academic.subjects||[]).find(x=>x.id===row.subject_id)?.name
    ].filter(Boolean).join(" • ")||"School-wide";
  }
  const PROMOTION_ALL_CLASSES="__all_eligible_classes__";
  function promotionCutoffOptions(selected=50) {
    return Array.from({length:21},(_,index)=>40+index).map(score=>`<option value="${score}" ${Number(selected)===score?"selected":""}>${score}%</option>`).join("");
  }
  function orderedActiveClasses() {
    return [...(state.academic?.classes||state.boot?.classes||[])].filter(row=>row.active!==false&&!row.deleted_at)
      .sort((a,b)=>Number(a.level_order||0)-Number(b.level_order||0)||String(a.name||"").localeCompare(String(b.name||""),undefined,{numeric:true}));
  }
  function configuredNextClass(sourceClassId) {
    const classes=orderedActiveClasses(),source=classes.find(row=>row.id===sourceClassId);if(!source)return null;
    return classes.find(row=>Number(row.level_order||0)>Number(source.level_order||0))||null;
  }
  function configuredPromotionMappings() {
    const classes=orderedActiveClasses();
    return classes.map(source=>({source,target:classes.find(row=>Number(row.level_order||0)>Number(source.level_order||0))||null}))
      .filter(mapping=>mapping.target);
  }
  function promotionAcademicYearOrderValue(row) {
    const start=Date.parse(row?.start_date||"");if(Number.isFinite(start))return start;
    const year=String(row?.name||"").match(/(?:19|20)\d{2}/)?.[0];if(year)return Date.UTC(Number(year),0,1);
    const created=Date.parse(row?.created_at||"");return Number.isFinite(created)?created:0;
  }
  function orderedPromotionAcademicYears() {
    return [...(state.academic?.academic_years||[])].filter(row=>!row.deleted_at)
      .sort((a,b)=>promotionAcademicYearOrderValue(a)-promotionAcademicYearOrderValue(b)||String(a.name||"").localeCompare(String(b.name||""),undefined,{numeric:true}));
  }
  function configuredNextAcademicYear(sourceYearId) {
    const years=orderedPromotionAcademicYears(),index=years.findIndex(row=>row.id===sourceYearId);
    return index>=0?years[index+1]||null:null;
  }
  function isTermThreeRecord(record={}) {
    if(Number(record?.term_sequence||0)===3)return true;
    const normalized=String(record?.term_name||record?.name||"").toLowerCase().replace(/[^a-z0-9]+/g,"");
    return ["term3","termthree","thirdterm","3rdterm"].includes(normalized);
  }
  function promotionTargetYearOptions(sourceYearId) {
    const target=configuredNextAcademicYear(sourceYearId);
    return target?`<option value="${attr(target.id)}" selected>${esc(target.name)}</option>`:`<option value="">Create the next academic year first</option>`;
  }
  function promotionSourceClassOptions() {
    const rows=orderedActiveClasses();
    return `<option value="">Select</option><option value="${PROMOTION_ALL_CLASSES}">All eligible classes</option>`+
      rows.map(row=>`<option value="${attr(row.id)}">${esc(row.name)}</option>`).join("");
  }
  function renderPromotionTab() {
    const cutoff=Number(state.boot?.school?.promotion_cutoff_score||50);
    const years=orderedPromotionAcademicYears();
    const sourceYearId=activeYear()?.id||years[0]?.id||"";
    return `<div class="form-stack">
      <section class="panel pad"><div class="page-head"><div><h3>Automatic Promotion Rule</h3><p>Term 3 promotion is determined from each student's overall average across all assigned subjects.</p></div></div>
        <div class="promotion-rule-layout">
          <form id="promotionCutoffForm" class="form-grid promotion-cutoff-form">
            <label class="field"><span>Promotion cutoff score</span><select name="promotion_cutoff_score" required>${promotionCutoffOptions(cutoff)}</select>
              <small>Students with a complete Term 3 average at or above this score pass. The allowed range is 40% through 60%.</small></label>
            <div class="field promotion-setting-action"><span>Academic rule</span><button class="button primary" id="savePromotionCutoff" type="button">Save cutoff score</button></div>
          </form>
          <div class="promotion-rule-card"><strong>Current rule: ${number(cutoff,0)}% pass mark</strong>
            <span>Term 1 and Term 2 do not promote students. In Term 3, the system calculates the arithmetic mean of all subject totals. A student below ${number(cutoff,0)}% is not promoted.</span></div>
        </div>
      </section>
      <section class="panel pad"><div class="page-head"><div><h3>Term 3 Promotion Processing</h3><p>The source year contains the Term 3 assessment. The immediate next academic year is selected automatically. Passing reports become eligible immediately, but the next-year enrolment is created only after Principal approval or publication.</p></div></div>
        <form id="promotionForm" class="form-grid">
          <label class="field"><span>Source academic year</span><select name="source_year" required>${optionList(years,"id","name",sourceYearId)}</select></label>
          <label class="field"><span>Source class</span><select name="source_class" required>${promotionSourceClassOptions()}</select>
            <small>Select one class, or process every class that has a configured next class.</small></label>
          <label class="field"><span>Automatic target academic year</span><select name="target_year" required>${promotionTargetYearOptions(sourceYearId)}</select>
            <small>The immediate next configured academic year is selected automatically.</small></label>
          <label class="field"><span>Automatic target class</span><input id="promotionTargetClassLabel" value="Select a source class" readonly><input type="hidden" name="target_class"></label>
          <div class="full promotion-processing-note" id="promotionProcessingNote">All complete Term 3 records are evaluated. Draft, submitted, and class-reviewed reports remain eligible pending approval; only approved or published reports create next-year enrolments. Returned and withdrawn reports are skipped.</div>
          <div class="full"><button class="button primary" id="runPromotion" type="button">Run automatic promotion</button></div>
        </form>
      </section>
    </div>`;
  }
  function syncPromotionTargetYear() {
    const form=byId("promotionForm");if(!form)return;
    const sourceYearId=form.elements.source_year?.value||"",target=configuredNextAcademicYear(sourceYearId),targetSelect=form.elements.target_year;
    if(targetSelect){
      targetSelect.innerHTML=promotionTargetYearOptions(sourceYearId);
      targetSelect.value=target?.id||"";
      targetSelect.disabled=!target;
    }
    syncPromotionTargetClass();
  }
  function syncPromotionTargetClass() {
    const form=byId("promotionForm");if(!form)return;
    const sourceYearId=form.elements.source_year?.value||"",targetYear=configuredNextAcademicYear(sourceYearId);
    const sourceValue=form.elements.source_class?.value||"",allClasses=sourceValue===PROMOTION_ALL_CLASSES;
    const mappings=allClasses?configuredPromotionMappings():[],target=allClasses?null:configuredNextClass(sourceValue);
    form.elements.target_class.value=target?.id||"";
    const label=byId("promotionTargetClassLabel"),button=byId("runPromotion"),note=byId("promotionProcessingNote");
    const validYear=Boolean(targetYear&&form.elements.target_year?.value===targetYear.id);
    if(!validYear){
      if(label)label.value="Next academic year required";
      if(button){button.disabled=true;button.textContent=allClasses?"Run all-class promotion":"Run automatic promotion"}
      if(note)note.textContent="Create the immediate next academic year before running Term 3 promotion.";
      return;
    }
    if(allClasses){
      if(label)label.value=mappings.length?`Each eligible class → its next class (${mappings.length} mappings)`:"No eligible class mappings";
      if(button){button.disabled=!mappings.length;button.textContent="Run all-class promotion"}
      if(note)note.textContent=mappings.length
        ?`Source-year Term 3 results will be evaluated for ${targetYear.name}. Approved or published passing reports create next-year enrolments; earlier workflow states remain eligible pending approval. One operation will process ${mappings.length} class mappings. The final class, and any class without a higher configured class, will be skipped.`
        :"No active class currently has a higher configured class.";
      return;
    }
    if(label)label.value=target?.name||(sourceValue?"No next class configured":"Select a source class");
    if(button){button.disabled=!target;button.textContent="Run automatic promotion"}
    if(note)note.textContent=target
      ?`Passing students are eligible for ${target.name}. The ${targetYear.name} enrolment is created only after Principal approval or publication; students below the cutoff remain unpromoted.`
      :(sourceValue?"The selected class is the final configured class or has no higher class level.":"Complete Term 3 records are evaluated under the approval-gated promotion rule. Returned and withdrawn reports are skipped.");
  }
  function bindAcademicTabEvents() {
    byId("addYear")?.addEventListener("click",()=>openYearEditor());
    $$("[data-edit-year]").forEach(b=>b.onclick=()=>openYearEditor(b.dataset.editYear));
    $$("[data-remove-year]").forEach(b=>b.onclick=()=>removeAcademicEntity("academic_year",b.dataset.removeYear));
    byId("addTerm")?.addEventListener("click",()=>openTermEditor());
    $$("[data-edit-term]").forEach(b=>b.onclick=()=>openTermEditor(b.dataset.editTerm));
    $$("[data-remove-term]").forEach(b=>b.onclick=()=>removeAcademicEntity("term",b.dataset.removeTerm));
    $$("[data-set-active]").forEach(b=>b.onclick=async()=>{
      const [yearId,termId]=b.dataset.setActive.split("|");
      if(await confirmAction("Activate Academic Period","This term will become the current reporting period.","Activate")){
        await run(()=>rpc("set_active_period",{target_academic_year_id:yearId,target_term_id:termId}),{success:"Academic period activated"});
        state.boot=await rpc("get_bootstrap_data");await renderAcademics(state.viewToken,true);
      }
    });
    byId("addClass")?.addEventListener("click",()=>openClassEditor());
    $$("[data-edit-class]").forEach(b=>b.onclick=()=>openClassEditor(b.dataset.editClass));
    $$("[data-remove-class]").forEach(b=>b.onclick=()=>removeAcademicEntity("class",b.dataset.removeClass));
    byId("addSubject")?.addEventListener("click",()=>openSubjectEditor());
    $$("[data-edit-subject]").forEach(b=>b.onclick=()=>openSubjectEditor(b.dataset.editSubject));
    $$("[data-remove-subject]").forEach(b=>b.onclick=()=>removeAcademicEntity("subject",b.dataset.removeSubject));
    byId("addAssignment")?.addEventListener("click",()=>openAssignmentEditor());
    $$("[data-manage-assignment-group]").forEach(button=>button.onclick=()=>openAssignmentGroupManager(button.dataset.manageAssignmentGroup));
    byId("addScheme")?.addEventListener("click",()=>openSchemeEditor());
    $$("[data-edit-scheme]").forEach(b=>b.onclick=()=>openSchemeEditor(b.dataset.editScheme));
    byId("addGrade")?.addEventListener("click",()=>openGradeEditor());
    $$("[data-edit-grade]").forEach(b=>b.onclick=()=>openGradeEditor(b.dataset.editGrade));
    $$("[data-delete-grade]").forEach(b=>b.onclick=()=>removeGrade(b.dataset.deleteGrade));
    byId("savePromotionCutoff")?.addEventListener("click",savePromotionCutoff);
    byId("promotionForm")?.elements.source_year?.addEventListener("change",syncPromotionTargetYear);
    byId("promotionForm")?.elements.source_class?.addEventListener("change",syncPromotionTargetClass);
    byId("runPromotion")?.addEventListener("click",runPromotion);
    syncPromotionTargetYear();
  }
  async function removeAcademicEntity(type,id) {
    const labels={academic_year:"Academic year",term:"Term",class:"Class",subject:"Subject",assignment:"Subject assignment"};
    const messages={academic_year:"The academic year and its terms will be removed from current configuration. Published historical reports remain preserved.",term:"The term will be removed from current configuration. Published historical reports remain preserved."};
    const ok=await confirmAction(`Remove ${labels[type]||"Record"}`,messages[type]||"The record will be archived while historical academic results remain preserved.","Remove",true);
    if(!ok)return;
    try{
      await rpc("archive_academic_entity",{entity_type:type,target_id:id,reason_text:`${labels[type]||"Academic record"} removed`});
      toast(`${labels[type]||"Academic record"} removed`);await refreshAcademic();
    }catch(error){toast("Record not removed",friendlyError(error),"error",6500)}
  }

  async function deleteClassSubjectAssignment(id) {
    const row=(state.academic?.class_subjects||[]).find(item=>item.id===id);if(!row)return;
    const label=[row.class_name,row.subject_name].filter(Boolean).join(" • ")||"this assignment";
    const ok=await confirmAction("Delete Subject Assignment",`Permanently delete ${label}? This cannot be undone.`,"Delete",true);
    if(!ok)return;
    try{
      await rpc("delete_class_subject_assignment",{target_id:id,reason_text:"Class subject assignment permanently deleted"});
      toast("Subject assignment deleted");await refreshAcademic();
    }catch(error){toast("Assignment not deleted",friendlyError(error),"error",6500)}
  }

  async function refreshAcademic() {
    state.workspace=null;state.academic=await rpc("get_academic_configuration");
    state.boot=await rpc("get_bootstrap_data");
    renderAcademicTab();
  }
  function openYearEditor(id=null) {
    const row=(state.academic.academic_years||[]).find(x=>x.id===id)||{};
    modal(id?"Edit Academic Year":"Add Academic Year","",`<form id="entityForm" class="form-grid">
      <label class="field full"><span>Name</span><input name="name" value="${attr(row.name||"")}" required></label>
      <label class="field"><span>Start date</span><input type="date" name="start_date" value="${attr(row.start_date||"")}"></label>
      <label class="field"><span>End date</span><input type="date" name="end_date" value="${attr(row.end_date||"")}"></label>
    </form>`,`<button class="button ghost" id="entityCancel" type="button">Cancel</button><button class="button primary" id="entitySave" type="button">Save</button>`,"small");
    byId("entityCancel").onclick=closeModal;
    byId("entitySave").onclick=()=>saveEntity("academic_years",id);
  }
  function openTermEditor(id=null) {
    const row=(state.academic.terms||[]).find(x=>x.id===id)||{};
    modal(id?"Edit Term":"Add Term","",`<form id="entityForm" class="form-grid">
      <label class="field full"><span>Academic year</span><select name="academic_year_id" required>${optionList(state.academic.academic_years||[],"id","name",row.academic_year_id||activeYear()?.id)}</select></label>
      <label class="field"><span>Name</span><input name="name" value="${attr(row.name||"")}" required></label>
      <label class="field"><span>Sequence</span><input type="number" min="1" max="6" name="sequence" value="${attr(row.sequence||1)}" required></label>
      <label class="field"><span>Start date</span><input type="date" name="start_date" value="${attr(row.start_date||"")}"></label>
      <label class="field"><span>End date</span><input type="date" name="end_date" value="${attr(row.end_date||"")}"></label>
      <label class="field full"><span>Next term begins</span><input type="date" name="next_term_begins" value="${attr(row.next_term_begins||"")}"></label>
    </form>`,`<button class="button ghost" id="entityCancel" type="button">Cancel</button><button class="button primary" id="entitySave" type="button">Save</button>`,"small");
    byId("entityCancel").onclick=closeModal;byId("entitySave").onclick=()=>saveEntity("terms",id);
  }
  function openClassEditor(id=null) {
    const row=(state.academic.classes||[]).find(x=>x.id===id)||{};
    const teacherRecords=(state.academic.teacher_records||[]).filter(teacher=>teacher.active!==false);
    const selectedTeacherRecordId=row.class_teacher_record_id
      ||teacherRecords.find(teacher=>teacher.profile_id&&teacher.profile_id===row.class_teacher_id)?.id
      ||"";
    modal(id?"Edit Class":"Add Class","",`<form id="entityForm" class="form-grid">
      <label class="field"><span>Name</span><input name="name" value="${attr(row.name||"")}" required></label>
      <label class="field"><span>Level order</span><input type="number" name="level_order" value="${attr(row.level_order||0)}"></label>
      <label class="field full"><span>Class teacher</span><select name="class_teacher_record_id">${optionList(teacherRecords,"id","label",selectedTeacherRecordId,"Unassigned")}</select>
        <small class="help-text">All active teacher records are listed. A teacher without a linked account can be assigned now; portal access begins after the account is linked.</small>
      </label>
      <label class="check-field full"><input type="checkbox" name="active" ${row.active!==false?"checked":""}><span>Active class</span></label>
    </form>`,`<button class="button ghost" id="entityCancel" type="button">Cancel</button><button class="button primary" id="entitySave" type="button">Save</button>`,"small");
    byId("entityCancel").onclick=closeModal;byId("entitySave").onclick=()=>saveEntity("classes",id);
  }
  function openSubjectEditor(id=null) {
    const row=(state.academic.subjects||[]).find(x=>x.id===id)||{};
    modal(id?"Edit Subject":"Add Subject",id?"The unique subject code remains permanent.":"The code is generated automatically from the subject name.",`<form id="entityForm" class="form-grid">
      <label class="field"><span>Subject name</span><input name="name" value="${attr(row.name||"")}" required></label>
      <label class="field"><span>Unique code</span><input name="code" value="${attr(row.code||"")}" placeholder="Generated automatically" readonly></label>
      <label class="field"><span>Display order</span><input type="number" name="display_order" value="${attr(row.display_order||0)}"></label>
      <label class="check-field"><input type="checkbox" name="active" ${row.active!==false?"checked":""}><span>Active subject</span></label>
    </form>`,`<button class="button ghost" id="entityCancel" type="button">Cancel</button><button class="button primary" id="entitySave" type="button">Save</button>`,"small");
    const form=byId("entityForm"),nameInput=form.elements.name,codeInput=form.elements.code;
    if(!id){
      let timer;const generate=async()=>{const name=nameInput.value.trim();if(!name){codeInput.value="";return}try{codeInput.value=await rpc("generate_subject_code",{subject_name:name,exclude_subject_id:null})}catch(_){codeInput.value=""}};
      nameInput.addEventListener("input",()=>{clearTimeout(timer);codeInput.value="";codeInput.placeholder=`${subjectCodePrefix(nameInput.value)}####`;timer=setTimeout(generate,550)});
      nameInput.addEventListener("blur",generate);
    }
    byId("entityCancel").onclick=closeModal;byId("entitySave").onclick=()=>saveEntity("subjects",id);
  }
  function subjectCodePrefix(name) {
    const words=String(name||"").toUpperCase().replace(/[^A-Z0-9 ]/g," ").trim().split(/\s+/).filter(Boolean);
    const meaningful=words.filter(word=>!["AND","OF","THE","FOR","IN","TO"].includes(word)),source=meaningful.length?meaningful:words;
    if(!source.length)return "SUB";return source.length===1?source[0].slice(0,3):source.slice(0,4).map(word=>word[0]).join("");
  }
  async function saveEntity(table,id) {
    const form=byId("entityForm"),values=formObject(form),button=byId("entitySave");if(!form?.reportValidity())return;button.disabled=true;let saved=false;
    try {
      const numeric=["sequence","level_order","display_order"];
      numeric.forEach(key=>{if(key in values)values[key]=Number(values[key]||0)});
      ["start_date","end_date","next_term_begins","class_teacher_id","class_teacher_record_id"].forEach(key=>{if(key in values&&!values[key])values[key]=null});
      if("active" in form.elements)values.active=form.elements.active.checked;
      await rpc("save_academic_entity",{entity_type:table,payload:{...values,id:id||null,reason:id?"Academic record updated":"Academic record created"}});
      saved=true;state.workspace=null;closeModal();toast("Academic record saved");
      try{await refreshAcademic()}catch(refreshError){await reportClientError(refreshError,{source:"academic_save",entity_type:table,stage:"refresh"});toast("Record saved","Reload the page to display the latest record.","warning",6500)}
    } catch(error){await reportClientError(error,{source:"academic_save",entity_type:table,stage:saved?"refresh":"record"});toast(saved?"Record saved":"Record not saved",saved?"Reload the page to display the latest record.":friendlyError(error),saved?"warning":"error",6500)}
    finally{button.disabled=false}
  }
  function multiSelectSummary(items,selected,emptyLabel) {
    const chosen=items.filter(item=>selected.has(item.id));
    if(!chosen.length)return emptyLabel;
    if(chosen.length===1)return chosen[0].name;
    if(chosen.length===2)return `${chosen[0].name}, ${chosen[1].name}`;
    return `${chosen.length} selected`;
  }

  function renderVerticalChecklistDropdown({
    rootId,label,items,selected,emptyLabel="Select",allLabel="",showCode=false,onChange
  }) {
    const root=byId(rootId);if(!root)return;
    const allSelected=items.length>0&&items.every(item=>selected.has(item.id));
    root.innerHTML=`<details class="vertical-check-dropdown">
      <summary><span class="vertical-check-title">${esc(label)}</span><span class="vertical-check-value">${esc(multiSelectSummary(items,selected,emptyLabel))}</span></summary>
      <div class="vertical-check-panel">
        ${allLabel?`<label class="vertical-check-option all-option"><span>${esc(allLabel)}</span><input type="checkbox" data-check-all ${allSelected?"checked":""}></label>`:""}
        ${items.map(item=>`<label class="vertical-check-option">
          <span><strong>${esc(item.name)}</strong>${showCode&&item.code?`<small>${esc(item.code)}</small>`:""}</span>
          <input type="checkbox" data-check-id="${attr(item.id)}" ${selected.has(item.id)?"checked":""}>
        </label>`).join("")||`<div class="vertical-check-empty">No records available</div>`}
      </div>
    </details>`;
    $$("[data-check-id]",root).forEach(input=>input.onchange=()=>{
      if(input.checked)selected.add(input.dataset.checkId);else selected.delete(input.dataset.checkId);
      onChange?.();
    });
    const allInput=root.querySelector("[data-check-all]");
    if(allInput)allInput.onchange=()=>{
      if(allInput.checked)items.forEach(item=>selected.add(item.id));
      else selected.clear();
      onChange?.();
    };
  }

  function classSubjectPairKey(classId,subjectId){return `${classId}|${subjectId}`}

  function renderAssignmentVerticalSelectors() {
    const classes=(state.academic.classes||[]).filter(item=>item.active!==false);
    const subjects=(state.academic.subjects||[]).filter(item=>item.active!==false);
    renderVerticalChecklistDropdown({
      rootId:"assignmentClassDropdown",
      label:"Class",
      items:classes,
      selected:state.assignmentClassSelections,
      emptyLabel:"Select class",
      onChange:renderAssignmentVerticalSelectors
    });
    renderVerticalChecklistDropdown({
      rootId:"assignmentSubjectDropdown",
      label:"Subject",
      items:subjects,
      selected:state.assignmentSubjectSelections,
      emptyLabel:"Select subject",
      allLabel:"All subjects",
      showCode:true,
      onChange:renderAssignmentVerticalSelectors
    });
    const count=state.assignmentClassSelections.size*state.assignmentSubjectSelections.size;
    const summary=byId("assignmentCombinationSummary");
    if(summary)summary.textContent=count
      ?`${count} class-subject assignment${count===1?"":"s"} will be saved.`
      :"Select one or more classes and one or more subjects.";
  }

  function openAssignmentEditor(id=null,teacherId="") {
    const row=(state.academic.class_subjects||[]).find(x=>x.id===id)||{};
    const teacherProfiles=(state.academic.profiles||[]).filter(profile=>["class_teacher","subject_teacher"].includes(profile.role));
    state.assignmentClassSelections=new Set(row.class_id?[row.class_id]:[]);
    state.assignmentSubjectSelections=new Set(row.subject_id?[row.subject_id]:[]);
    modal(id?"Edit Subject Assignment":"Assign Subjects","Select one or more classes and subjects for the selected teacher.",`<form id="entityForm" class="form-stack">
      <label class="field"><span>Teacher</span><select name="teacher_id" required>${optionList(teacherProfiles,"id","full_name",row.teacher_id||teacherId,"Select teacher")}</select></label>
      <div class="independent-check-grid">
        <div id="assignmentClassDropdown"></div>
        <div id="assignmentSubjectDropdown"></div>
      </div>
      <p class="help-text" id="assignmentCombinationSummary"></p>
      <p class="help-text">For different subject groups, save one group first, then use Assign more for the next class range.</p>
      <label class="check-field"><input type="checkbox" name="active" ${row.active!==false?"checked":""}><span>Active assignments</span></label>
    </form>`,`<button class="button ghost" id="entityCancel" type="button">Cancel</button><button class="button primary" id="entitySave" type="button">Save assignments</button>`,"wide");
    renderAssignmentVerticalSelectors();
    byId("entityCancel").onclick=closeModal;
    byId("entitySave").onclick=async()=>{
      const form=byId("entityForm"),v=formObject(form),button=byId("entitySave");if(!form?.reportValidity())return;
      const classIds=[...state.assignmentClassSelections];
      const subjectIds=[...state.assignmentSubjectSelections];
      if(!classIds.length){toast("Select at least one class","","error");return}
      if(!subjectIds.length){toast("Select at least one subject","","error");return}
      const selections=classIds.flatMap(class_id=>subjectIds.map(subject_id=>({class_id,subject_id})));
      button.disabled=true;button.textContent="Saving";let saved=false;
      try{
        await rpc("save_class_subject_assignments_batch",{payload:{id:id||null,teacher_id:v.teacher_id||null,active:form.elements.active.checked,selections,
          reason:id?"Class-subject assignments updated":"Class-subject assignments created"}});
        saved=true;state.workspace=null;closeModal();toast(`${selections.length} assignment${selections.length===1?"":"s"} saved`);
        try{await refreshAcademic()}catch(refreshError){await reportClientError(refreshError,{source:"assignment_batch_save",stage:"refresh"});toast("Assignments saved","Reload to display the latest assignments.","warning",6500)}
      }catch(error){await reportClientError(error,{source:"assignment_batch_save",stage:saved?"refresh":"record"});toast(saved?"Assignments saved":"Assignments not saved",saved?"Reload to display the latest assignments.":friendlyError(error),saved?"warning":"error",6500)}
      finally{button.disabled=false;button.textContent="Save assignments"}
    };
  }
  function openSchemeEditor(id=null) {
    const row=(state.academic.assessment_schemes||[]).find(x=>x.id===id)||{components:[
      {name:"Continuous Assessment",code:"CA",maximum_score:30,weight:30,display_order:1,required:true},
      {name:"End of Term Examination",code:"EXAM",maximum_score:70,weight:70,display_order:2,required:true}
    ]};
    modal(id?"Edit Assessment Scheme":"Add Assessment Scheme",schemeScope(row),`<form id="schemeForm" class="form-stack">
      <div class="form-grid three">
        <input type="hidden" name="id" value="${attr(row.id||"")}">
        <label class="field"><span>Name</span><input name="name" value="${attr(row.name||"")}" required></label>
        <label class="field"><span>Academic year</span><select name="academic_year_id">${optionList(state.academic.academic_years||[],"id","name",row.academic_year_id,"All years")}</select></label>
        <label class="field"><span>Term</span><select name="term_id">${optionList(state.academic.terms||[],"id","name",row.term_id,"All terms")}</select></label>
        <label class="field"><span>Class</span><select name="class_id">${optionList(state.academic.classes||[],"id","name",row.class_id,"All classes")}</select></label>
        <label class="field"><span>Subject</span><select name="subject_id">${optionList(state.academic.subjects||[],"id","name",row.subject_id,"All subjects")}</select></label>
        <label class="check-field"><input type="checkbox" name="active" ${row.active!==false?"checked":""}><span>Active scheme</span></label>
      </div>
      <div class="section-title"><h4>Components</h4><button class="button secondary small" id="addComponent" type="button">Add component</button></div>
      <div id="componentRows"></div>
    </form>`,`<button class="button ghost" id="schemeCancel" type="button">Cancel</button><button class="button primary" id="schemeSave" type="button">Save scheme</button>`,"wide");
    state.schemeComponents=(row.components||[]).map(x=>({...x}));
    renderComponentRows();
    byId("addComponent").onclick=()=>{state.schemeComponents.push({name:"",code:"",maximum_score:100,weight:0,display_order:state.schemeComponents.length+1,required:true});renderComponentRows()};
    byId("schemeCancel").onclick=closeModal;byId("schemeSave").onclick=saveScheme;
  }
  function renderComponentRows() {
    const root=byId("componentRows");if(!root)return;
    root.innerHTML=state.schemeComponents.map((c,i)=>`<div class="form-grid three component-row" data-index="${i}" style="margin-bottom:12px">
      <label class="field"><span>Component name</span><input data-key="name" value="${attr(c.name||"")}" required></label>
      <label class="field"><span>Code</span><input data-key="code" value="${attr(c.code||"")}" required></label>
      <label class="field"><span>Maximum score</span><input data-key="maximum_score" type="number" min=".01" step=".01" value="${attr(c.maximum_score||0)}" required></label>
      <label class="field"><span>Weight (%)</span><input data-key="weight" type="number" min=".001" max="100" step=".001" value="${attr(c.weight||0)}" required></label>
      <label class="field"><span>Display order</span><input data-key="display_order" type="number" value="${attr(c.display_order||i+1)}"></label>
      <div class="button-row"><label class="check-field"><input data-key="required" type="checkbox" ${c.required!==false?"checked":""}><span>Required</span></label>
        <button class="button danger small" type="button" data-remove-component="${i}">Remove</button></div>
    </div>`).join("");
    $$(".component-row",root).forEach(row=>$$("[data-key]",row).forEach(input=>input.oninput=()=>{
      const item=state.schemeComponents[Number(row.dataset.index)],key=input.dataset.key;
      item[key]=input.type==="checkbox"?input.checked:input.type==="number"?Number(input.value):input.value;
    }));
    $$("[data-remove-component]",root).forEach(button=>button.onclick=()=>{state.schemeComponents.splice(Number(button.dataset.removeComponent),1);renderComponentRows()});
  }
  async function saveScheme() {
    const form=byId("schemeForm"),v=formObject(form),button=byId("schemeSave");if(!form?.reportValidity())return;button.disabled=true;let saved=false;
    try{
      const payload={id:v.id,name:v.name,academic_year_id:v.academic_year_id,term_id:v.term_id,class_id:v.class_id,subject_id:v.subject_id,
        active:form.elements.active.checked,components:state.schemeComponents,reason:v.id?"Assessment scheme updated":"Assessment scheme created"};
      await rpc("save_assessment_scheme",{payload});saved=true;closeModal();toast("Assessment scheme saved");
      try{await refreshAcademic()}catch(refreshError){await reportClientError(refreshError,{source:"assessment_scheme_save",stage:"refresh"});toast("Scheme saved","Reload the page to display the latest scheme.","warning",6500)}
    }catch(error){await reportClientError(error,{source:"assessment_scheme_save",stage:saved?"refresh":"record"});toast(saved?"Scheme saved":"Scheme not saved",saved?"Reload the page to display the latest scheme.":friendlyError(error),saved?"warning":"error",6500)}finally{button.disabled=false}
  }
  function openGradeEditor(id=null) {
    const row=(state.academic.grading_scales||[]).find(x=>x.id===id)||{};
    modal(id?"Edit Grade":"Add Grade","",`<form id="gradeForm" class="form-grid three">
      <label class="field"><span>Grade</span><input name="grade" value="${attr(row.grade||"")}" required></label>
      <label class="field"><span>Minimum mark</span><input type="number" min="0" max="100" step=".01" name="min_mark" value="${attr(row.min_mark??"")}" required></label>
      <label class="field"><span>Maximum mark</span><input type="number" min="0" max="100" step=".01" name="max_mark" value="${attr(row.max_mark??"")}" required></label>
      <label class="field"><span>Remark</span><input name="remark" value="${attr(row.remark||"")}" required></label>
      <label class="field"><span>Grade point</span><input type="number" step=".01" name="grade_point" value="${attr(row.grade_point||0)}"></label>
      <label class="field"><span>Display order</span><input type="number" name="display_order" value="${attr(row.display_order||0)}"></label>
      <label class="field"><span>Academic year</span><select name="academic_year_id">${optionList(state.academic.academic_years||[],"id","name",row.academic_year_id,"All years")}</select></label>
      <label class="field"><span>Class</span><select name="class_id">${optionList(state.academic.classes||[],"id","name",row.class_id,"All classes")}</select></label>
      <label class="field"><span>Subject</span><select name="subject_id">${optionList(state.academic.subjects||[],"id","name",row.subject_id,"All subjects")}</select></label>
    </form>`,`<button class="button ghost" id="gradeCancel" type="button">Cancel</button><button class="button primary" id="gradeSave" type="button">Save</button>`,"wide");
    byId("gradeCancel").onclick=closeModal;
    byId("gradeSave").onclick=async()=>{
      const form=byId("gradeForm");if(!form?.reportValidity())return;
      const v=formObject(form),record={id:id||null,grade:v.grade,remark:v.remark,min_mark:Number(v.min_mark),max_mark:Number(v.max_mark),
        grade_point:Number(v.grade_point||0),display_order:Number(v.display_order||0),academic_year_id:v.academic_year_id||null,class_id:v.class_id||null,subject_id:v.subject_id||null,reason:id?"Grading scale updated":"Grading scale created"};
      const button=byId("gradeSave");button.disabled=true;
      let saved=false;
      try{await rpc("save_grading_scale",{payload:record});saved=true;closeModal();toast("Grading scale saved");
        try{await refreshAcademic()}catch(refreshError){await reportClientError(refreshError,{source:"grading_scale_save",stage:"refresh"});toast("Grade saved","Reload the page to display the latest grading scale.","warning",6500)}}
      catch(error){await reportClientError(error,{source:"grading_scale_save",stage:saved?"refresh":"record"});toast(saved?"Grade saved":"Grade not saved",saved?"Reload the page to display the latest grading scale.":friendlyError(error),saved?"warning":"error",6500)}finally{button.disabled=false}
    };
  }
  async function removeGrade(id) {
    if(!await confirmAction("Remove Grade","The grade will no longer be used for future calculations.","Remove",true))return;
    await run(()=>rpc("archive_grading_scale",{target_grade_id:id,reason_text:"Grading scale removed"}),{success:"Grade removed"});
    await refreshAcademic();
  }
  async function savePromotionCutoff() {
    const form=byId("promotionCutoffForm"),score=Number(form?.elements.promotion_cutoff_score?.value||0),button=byId("savePromotionCutoff");
    if(!Number.isInteger(score)||score<40||score>60){toast("Cutoff not saved","Choose a whole-number score from 40 through 60.","error");return}
    if(button)button.disabled=true;
    try{
      const result=await rpc("save_promotion_cutoff",{target_score:score});
      state.boot.school={...(state.boot.school||{}),promotion_cutoff_score:Number(result.promotion_cutoff_score||score)};
      toast("Promotion cutoff saved",`${score}% will be used for Term 3 automatic promotion. ${number(result.reports_recalculated||0)} existing Term 3 reports were recalculated.`);
      renderAcademicTab();
    }catch(error){toast("Cutoff not saved",friendlyError(error),"error",6500)}finally{if(button)button.disabled=false}
  }
  async function runPromotion() {
    const form=byId("promotionForm"),v=formObject(form),allClasses=v.source_class===PROMOTION_ALL_CLASSES;
    if(!v.source_year||!v.source_class)return;
    const expectedTargetYear=configuredNextAcademicYear(v.source_year);
    if(!expectedTargetYear){toast("Promotion not started","Create the immediate next academic year first.","error",6500);syncPromotionTargetYear();return}
    if(v.target_year!==expectedTargetYear.id){
      form.elements.target_year.value=expectedTargetYear.id;
      toast("Target year corrected",`${expectedTargetYear.name} is the automatic next academic year.`,"warning",5000);
      v.target_year=expectedTargetYear.id;
    }
    const cutoff=Number(state.boot?.school?.promotion_cutoff_score||50),button=byId("runPromotion");
    if(allClasses){
      const mappings=configuredPromotionMappings();if(!mappings.length)return;
      if(!await confirmAction("Run All-Class Automatic Promotion",`This single operation will process ${mappings.length} eligible class mappings into ${expectedTargetYear.name}. Complete Term 3 reports with an average of ${cutoff}% or higher will be evaluated. Next-year enrolments are created only for approved or published reports; earlier workflow states remain eligible pending approval.`,"Run all classes"))return;
      if(button)button.disabled=true;
      try{
        const result=await run(()=>rpc("bulk_promote_all_classes",{source_academic_year_id:v.source_year,target_academic_year_id:v.target_year}),{success:"All-class automatic promotion completed"});
        const targetName=result.target_academic_year_name||expectedTargetYear.name;
        toast("All-class promotion result",`${number(result.classes_processed||0)} class mappings processed into ${targetName} • ${number(result.promoted||0)} promoted • ${number(result.eligible_pending_approval||0)} eligible pending approval • ${number(result.not_promoted||0)} not promoted • ${number(result.incomplete||0)} incomplete${number(result.skipped_status||0)?` • ${number(result.skipped_status||0)} returned/withdrawn skipped`:""}`);
      }finally{syncPromotionTargetYear()}
      return;
    }
    const target=configuredNextClass(v.source_class);
    if(!v.target_class||!target)return;
    if(!await confirmAction("Run Automatic Promotion",`Complete Term 3 reports with an average of ${cutoff}% or higher will be evaluated for ${target.name}. The next-year enrolment is created only after Principal approval or publication.`,"Run promotion"))return;
    if(button)button.disabled=true;
    try{
      const result=await run(()=>rpc("bulk_promote_class",{source_academic_year_id:v.source_year,source_class_id:v.source_class,
        target_academic_year_id:v.target_year,target_class_id:v.target_class}),{success:"Automatic promotion completed"});
      const targetName=result.target_academic_year_name||expectedTargetYear.name;
      toast("Promotion result",`${number(result.promoted||0)} promoted into ${targetName} • ${number(result.eligible_pending_approval||0)} eligible pending approval • ${number(result.not_promoted||0)} not promoted • ${number(result.incomplete||0)} incomplete${number(result.skipped_status||0)?` • ${number(result.skipped_status||0)} returned/withdrawn skipped`:""}`);
    }finally{syncPromotionTargetYear()}
  }


  async function renderReports(token) {
    state.reportEditor=null;
    const visibleClasses=await visibleClassesForCurrentRole();
    if(token!==state.viewToken)return;
    if(state.reportClassFilter&&!visibleClasses.some(item=>item.id===state.reportClassFilter))state.reportClassFilter="";
    byId("content").innerHTML=`
      <div class="page-head"><div><h3>Report Cards</h3><p>Transactional assessment, review, approval, and publication</p></div>
        <div class="page-actions">
          ${can("import_scores")?`<button class="button outline" id="scoreImport">Import scores</button>`:""}
          <button class="button outline" id="manualReportTemplate">Manual template</button>
          <button class="button outline" id="reportExport">Export list</button>
          ${canBulkDownloadPublishedReports()?`<button class="button secondary" id="reportBulkDownload">Bulk class PDFs</button>`:""}
          ${can("bulk_submit_reports")?`<button class="button secondary" id="reportBulkSubmit">Submit class reports</button>`:""}
          ${can("bulk_approve_reports")?`<button class="button success" id="reportBulkApprove">Approve class reports</button>`:""}
          ${can("bulk_publish_reports")?`<button class="button success" id="reportBulkPublish">Publish class reports</button>`:""}
          ${can("create_reports")?`<button class="button primary" id="reportNew">New report</button>`:""}
        </div></div>
      <section class="panel">
        <div class="toolbar">
          <label class="search"><input id="reportSearch" type="search" placeholder="Search student or report number"></label>
          <select id="reportTerm">${optionList(state.boot.terms||[],"id","name",activeTerm()?.id,"All terms")}</select>
          <select id="reportClass">${optionList(visibleClasses,"id","name",state.reportClassFilter||"",["class_teacher","subject_teacher"].includes(role())?"All assigned classes":"All classes")}</select>
          <select id="reportStatus"><option value="">All statuses</option>
            ${["draft","submitted","class_reviewed","approved","published","returned","withdrawn"].map(v=>`<option value="${v}">${v.replaceAll("_"," ")}</option>`).join("")}</select>
        </div>
        <div id="reportResults"><div class="empty">Loading report cards</div></div>
      </section>`;
    byId("reportNew")?.addEventListener("click",openNewReportPicker);
    byId("scoreImport")?.addEventListener("click",openScoreImport);
    byId("manualReportTemplate")?.addEventListener("click",openManualReportTemplate);
    byId("reportExport")?.addEventListener("click",exportReportList);
    byId("reportBulkDownload")?.addEventListener("click",openBulkPublishedReportPackage);
    byId("reportBulkSubmit")?.addEventListener("click",()=>requestBulkReportTransition("submitted"));
    byId("reportBulkApprove")?.addEventListener("click",()=>requestBulkReportTransition("approved"));
    byId("reportBulkPublish")?.addEventListener("click",()=>requestBulkReportTransition("published"));
    let timer;
    byId("reportSearch").oninput=()=>{clearTimeout(timer);timer=setTimeout(()=>{state.reportPage=1;loadReportPage(token)},250)};
    ["reportTerm","reportClass","reportStatus"].forEach(id=>{if(byId(id))byId(id).onchange=()=>{state.reportPage=1;loadReportPage(token)}});
    await loadReportPage(token);
  }
  async function loadReportPage(token=state.viewToken) {
    const root=byId("reportResults");if(!root)return;
    root.innerHTML=`<div class="empty">Loading report cards</div>`;
    const data=await rpc("list_report_cards_v6",{
      target_term_id:byId("reportTerm")?.value||null,target_class_id:byId("reportClass")?.value||null,
      target_status:byId("reportStatus")?.value||null,search_text:byId("reportSearch")?.value.trim()||"",
      archive_filter:"active",page_number:state.reportPage,page_size:CONFIG.pageSize
    });
    if(token!==state.viewToken||!byId("reportResults"))return;
    root.innerHTML=reportTable(data.rows||[],false,true)+pagination(data.total,data.page,data.page_size,"report");
    $$("[data-report-id]",root).forEach(btn=>btn.onclick=()=>openReportEditor(btn.dataset.reportId));
    $$("[data-report-archive]",root).forEach(btn=>btn.onclick=()=>archiveReportCard(btn.dataset.reportArchive));
    bindPagination("report",data);
  }
  function bulkReportWorkflowDefinition(targetStatus) {
    return {
      submitted:{title:"Submit Class Reports",verb:"submit",past:"submitted",button:"Submit all eligible reports",permission:"bulk_submit_reports",source:"draft or returned"},
      approved:{title:"Approve Class Reports",verb:"approve",past:"approved",button:"Approve all eligible reports",permission:"bulk_approve_reports",source:"submitted"},
      published:{title:"Publish Class Reports",verb:"publish",past:"published",button:"Publish all approved reports",permission:"bulk_publish_reports",source:"approved"}
    }[targetStatus]||null;
  }
  async function storeBulkPublishedReportPdfs(reportIds=[]) {
    const ids=[...new Set((reportIds||[]).filter(Boolean))];
    if(!ids.length)return {created:0,failed:0};
    modal("Creating Official PDFs","Published report records are secure while the latest official PDF files are generated.",`
      <div class="template-information"><strong id="bulkPublishPdfHeading">Preparing official PDFs</strong><span id="bulkPublishPdfProgress">0 of ${ids.length} completed</span></div>`,
      `<button class="button ghost" type="button" disabled>Please wait</button>`,"small");
    let created=0,failed=0;
    for(let index=0;index<ids.length;index++){
      const reportId=ids[index];
      try{
        const editor=await rpc("get_report_editor",{target_report_id:reportId,target_enrollment_id:null,target_term_id:null});
        const publication=(editor.publications||[]).find(item=>!item.revoked_at);
        if(!publication)throw new Error("Active publication record not found");
        await createAndStoreOfficialPdf(editor,publication);created+=1;
      }catch(error){
        failed+=1;await reportClientError(error,{source:"bulk_publish_pdf",report_id:reportId});
      }
      const progress=byId("bulkPublishPdfProgress");
      if(progress)progress.textContent=`${index+1} of ${ids.length} completed • ${created} stored${failed?` • ${failed} failed`:""}`;
    }
    closeModal();
    return {created,failed};
  }
  async function requestBulkReportTransition(targetStatus) {
    const definition=bulkReportWorkflowDefinition(targetStatus);
    if(!definition||!can(definition.permission)){toast("Bulk action unavailable","Your account is not permitted to perform this class workflow action.","error");return}
    const termId=byId("reportTerm")?.value||"",classId=byId("reportClass")?.value||"";
    if(!termId||!classId){toast("Select a class and term","Bulk workflow actions require one specific class and one specific term.","warning",6500);return}
    const term=(state.boot.terms||[]).find(item=>item.id===termId),classRow=(state.boot.classes||[]).find(item=>item.id===classId);
    if(role()==="class_teacher"&&["submitted","published"].includes(targetStatus)){
      const workspace=await loadRoleWorkspace();
      if(!(workspace.classes||[]).some(item=>item.class_id===classId)){
        toast("Class-teacher assignment required",`You may ${definition.verb} all reports only for the class where you are the assigned class teacher.`,"error",7000);return;
      }
    }
    modal(definition.title,`${classRow?.name||"Selected class"} • ${term?.name||"Selected term"}`,`
      <div class="template-information"><strong>Class-level workflow</strong><span>All ${definition.source} reports in this class will be checked. Reports with incomplete assigned subjects or required scores will remain unchanged and will be listed as failed.</span></div>
      <label class="field" style="margin-top:15px"><span>Comment</span><textarea id="bulkWorkflowComment" placeholder="Optional workflow comment"></textarea></label>`,
      `<button class="button ghost" id="bulkWorkflowCancel" type="button">Cancel</button><button class="button primary" id="bulkWorkflowConfirm" type="button">${definition.button}</button>`,"small");
    byId("bulkWorkflowCancel").onclick=closeModal;
    byId("bulkWorkflowConfirm").onclick=async()=>{
      const button=byId("bulkWorkflowConfirm"),comment=byId("bulkWorkflowComment").value.trim();button.disabled=true;
      try{
        const result=await rpc("bulk_transition_class_reports",{target_term_id:termId,target_class_id:classId,target_status:targetStatus,comment_text:comment});
        closeModal();state.workspace=null;
        let pdfSummary="";
        if(targetStatus==="published"&&Number(result.transitioned_reports||0)>0){
          const pdf=await storeBulkPublishedReportPdfs(result.transitioned_report_ids||[]);
          pdfSummary=` • ${pdf.created} official PDF${pdf.created===1?"":"s"} stored${pdf.failed?` • ${pdf.failed} PDF failure${pdf.failed===1?"":"s"}`:""}`;
        }
        const transitioned=Number(result.transitioned_reports||0),failed=Number(result.failed_reports||0),missing=Number(result.missing_reports||0),already=Number(result.already_target_status||0);
        toast(`${definition.title} completed`,`${transitioned} report${transitioned===1?"":"s"} ${definition.past}${failed?` • ${failed} incomplete or unsuccessful`:""}${already?` • ${already} already ${definition.past}`:""}${missing?` • ${missing} student${missing===1?" has":"s have"} no report`:""}${pdfSummary}`,failed?"warning":"success",10000);
        await loadReportPage();
      }catch(error){toast(`${definition.title} unsuccessful`,friendlyError(error),"error",8000)}
      finally{if(button)button.disabled=false}
    };
  }

  async function archiveReportCard(id) {
    const ok=await confirmAction("Permanently Delete Report Card","This permanently deletes the report, scores, revisions, workflow history, publication records, stored PDFs, and related audit history. This action cannot be undone.","Delete permanently",true);if(!ok)return;
    setLoading(true);
    try{
      const paths=(await rpc("list_report_pdf_paths",{target_report_id:id})||[]).filter(Boolean);
      if(paths.length){
        const {error}=await state.client.storage.from(CONFIG.pdfBucket).remove(paths);
        if(error)throw error;
        paths.forEach(path=>state.pdfUrls.delete(path));
      }
      await rpc("delete_report_card_permanently",{target_report_id:id,reason_text:"Report card permanently deleted"});
      state.workspace=null;
      if(state.reportEditor?.report?.id===id)state.reportEditor=null;
      toast("Report card permanently deleted");
      if(byId("reportResults"))await loadReportPage();
    }catch(error){toast("Report card not deleted",friendlyError(error),"error",6500)}
    finally{setLoading(false)}
  }

  async function openNewReportPicker() {
    const visibleClasses=await visibleClassesForCurrentRole();
    modal("New Report Card","Select a student enrolment and term",`
      <div class="form-grid">
        <label class="field"><span>Class</span><select id="newReportClass">${optionList(visibleClasses,"id","name")}</select></label>
        <label class="field"><span>Term</span><select id="newReportTerm">${optionList(state.boot.terms||[],"id","name",activeTerm()?.id)}</select></label>
      </div>
      <label class="field new-report-student-field" style="margin-top:15px"><span>Student</span>
        <select id="newReportStudent" class="new-report-student-list" size="8" disabled aria-describedby="newReportStudentHelp"><option value="">Select a class first</option></select>
        <small id="newReportStudentHelp">The student list stays compact. Scroll up or down, use the mouse wheel, or use the keyboard arrow keys.</small>
      </label>`,
      `<button class="button ghost" id="newReportCancel" type="button">Cancel</button><button class="button primary" id="newReportOpen" type="button" disabled>Open report</button>`,"small");
    const classSelect=byId("newReportClass"),studentSelect=byId("newReportStudent"),openButton=byId("newReportOpen");
    const syncOpenButton=()=>{openButton.disabled=!(studentSelect.value&&byId("newReportTerm").value)};
    byId("newReportCancel").onclick=closeModal;
    studentSelect.onchange=syncOpenButton;
    byId("newReportTerm").onchange=syncOpenButton;
    classSelect.onchange=async()=>{
      const classId=classSelect.value;
      openButton.disabled=true;
      if(!classId){studentSelect.disabled=true;studentSelect.innerHTML=`<option value="">Select a class first</option>`;return}
      studentSelect.disabled=true;studentSelect.innerHTML=`<option value="">Loading students…</option>`;
      try{
        const data=await rpc("search_students",{search_text:"",target_class_id:classId,target_status:"active",page_number:1,page_size:500});
        const rows=(data.rows||[]).filter(x=>x.enrollment_id);
        studentSelect.innerHTML=rows.length?rows.map(row=>
          `<option value="${attr(row.enrollment_id)}">${esc(fullName(row))} • ${esc(row.admission_no)}</option>`).join(""):
          `<option value="">No active students found in this class</option>`;
        studentSelect.disabled=!rows.length;
        if(rows.length){studentSelect.selectedIndex=-1;studentSelect.focus();syncOpenButton()}
      }catch(error){
        studentSelect.innerHTML=`<option value="">Students could not be loaded</option>`;
        studentSelect.disabled=true;
        toast("Students not loaded",friendlyError(error),"error",6500);
      }
    };
    openButton.onclick=()=>{
      const enrollment=studentSelect.value,term=byId("newReportTerm").value;
      if(enrollment&&term){closeModal();openReportEditor(null,enrollment,term)}
    };
  }
  function localPromotionEvaluation(editor=state.reportEditor) {
    const student=editor?.student||{},subjects=editor?.subjects||[],previous=editor?.promotion||{};
    const cutoff=Number(state.boot?.school?.promotion_cutoff_score||50);
    const term3=isTermThreeRecord(student);
    const complete=subjects.length>0;
    const average=complete?subjects.reduce((sum,row)=>sum+Number(row.total_score||0),0)/subjects.length:0;
    const nextClass=configuredNextClass(student.class_id);
    const passed=term3&&complete&&average>=cutoff;
    const targetYear=previous.target_academic_year_id?{id:previous.target_academic_year_id,name:previous.target_academic_year_name||""}:configuredNextAcademicYear(student.academic_year_id);
    const reportStatus=String(editor?.report?.status||previous.report_status||"draft");
    const governanceApproved=["approved","published"].includes(reportStatus);
    const promotionApplied=Boolean(passed&&governanceApproved&&previous.promotion_applied&&previous.next_class_id===nextClass?.id);
    return {term3,complete,average,cutoff,passed,eligible:passed&&Boolean(nextClass),report_status:reportStatus,
      governance_approved:governanceApproved,approval_required:passed&&!governanceApproved,
      next_class_id:nextClass?.id||null,next_class_name:nextClass?.name||"",
      target_academic_year_id:targetYear?.id||null,target_academic_year_name:targetYear?.name||"",promotion_applied:promotionApplied,
      can_create_enrollment:passed&&governanceApproved&&Boolean(nextClass&&targetYear)};
  }
  async function enrichReportPromotion(editor) {
    if(!editor)return editor;
    if(editor.report?.id){
      try{editor.promotion=await rpc("report_promotion_evaluation",{target_report_id:editor.report.id})}
      catch(_){editor.promotion=localPromotionEvaluation(editor)}
    }else editor.promotion=localPromotionEvaluation(editor);
    return editor;
  }
  function promotionDisplay(evaluation=localPromotionEvaluation()) {
    if(!evaluation.term3)return {title:"Not applicable",detail:"This record is not recognised as Term 3. Automatic promotion uses Term 3 results only.",state:"neutral"};
    if(!evaluation.complete)return {title:"Awaiting complete results",detail:`All assigned subjects must be completed before the ${number(evaluation.cutoff||50,0)}% promotion rule is applied.`,state:"warning"};
    if(evaluation.passed&&evaluation.next_class_name&&evaluation.promotion_applied)return {title:`Promoted to ${evaluation.next_class_name}`,detail:`The approved ${evaluation.target_academic_year_name||"next academic year"} enrolment is now the student’s active class placement. The earlier enrolment remains only in protected history.`,state:"pass"};
    if(evaluation.passed&&evaluation.next_class_name&&evaluation.approval_required)return {title:`Eligible for ${evaluation.next_class_name}`,detail:`Term 3 average ${number(evaluation.average,1)}% meets the ${number(evaluation.cutoff,0)}% cutoff. The next-year enrolment will be created only after Principal approval or publication.`,state:"warning"};
    if(evaluation.passed&&evaluation.next_class_name)return {title:`Eligible for ${evaluation.next_class_name}`,detail:`Term 3 average ${number(evaluation.average,1)}% meets the cutoff. Run Term 3 Promotion Processing after approval to create the ${evaluation.target_academic_year_name||"next-year"} enrolment.`,state:"pass"};
    if(evaluation.passed&&!evaluation.next_class_name)return {title:"Passed, no next class configured",detail:`Term 3 average ${number(evaluation.average,1)}% meets the ${number(evaluation.cutoff,0)}% cutoff.`,state:"pass"};
    return {title:"Not promoted",detail:`Term 3 average ${number(evaluation.average,1)}% is below the ${number(evaluation.cutoff,0)}% cutoff.`,state:"fail"};
  }
  function updatePromotionPreview() {
    if(!state.reportEditor)return;
    const evaluation=localPromotionEvaluation(state.reportEditor),display=promotionDisplay(evaluation);
    state.reportEditor.promotion=evaluation;
    const title=byId("automaticPromotionValue"),detail=byId("automaticPromotionDetail"),box=byId("automaticPromotionField");
    if(title)title.textContent=display.title;if(detail)detail.textContent=display.detail;
    if(box)box.dataset.promotionState=display.state;
  }

  async function openReportEditor(reportId=null,enrollmentId=null,termId=null) {
    setLoading(true);
    try {
      const editor=await rpc("get_report_editor",{target_report_id:reportId,target_enrollment_id:enrollmentId,target_term_id:termId});
      await enrichReportPromotion(editor);
      state.reportEditor=editor;
      state.view="reports";renderNav();
      renderReportEditor();
      const key=`report:${editor.report?.id||`${editor.report?.enrollment_id}:${editor.report?.term_id}`}`;
      const local=await draftGet(key).catch(()=>null);
      if(local&&Number(local.version)===Number(editor.report?.version||0)&&editor.can_edit) {
        applyLocalReportDraft(local.payload);
        toast("Draft restored","Unsaved local changes were recovered.","warning");
      }
    } catch(error){toast("Report unavailable",friendlyError(error),"error");await navigate("reports",true)}
    finally{setLoading(false)}
  }
  async function refreshOpenReport() {
    if(!state.reportEditor?.report?.id)return;
    try{
      const latest=await rpc("get_report_editor",{target_report_id:state.reportEditor.report.id,target_enrollment_id:null,target_term_id:null});
      await enrichReportPromotion(latest);
      if(state.reportEditor&&Number(latest.report.version)>Number(state.reportEditor.report.version)) {
        state.reportEditor=latest;renderReportEditor();toast("Report refreshed","A newer version was received.","warning");
      }
    }catch(_){}
  }
  function renderReportEditor() {
    const editor=state.reportEditor,report=editor.report||{},student=editor.student||{},subjects=editor.subjects||[];
    const average=subjects.length?subjects.reduce((sum,s)=>sum+Number(s.total_score||0),0)/subjects.length:0;
    const publication=(editor.publications||[]).find(p=>!p.revoked_at);
    const locked=!editor.can_edit;
    const fieldsLocked=!editor.can_edit_fields;
    const canHeadComment=can("approve_reports")&&!['published','withdrawn'].includes(report.status);
    byId("pageTitle").textContent=student.full_name||"Report Card";
    byId("pageSubtitle").textContent=`${student.class_name||""} • ${student.term_name||""} • ${report.report_number||"New report"}`;
    byId("content").innerHTML=`
      <div class="page-head"><div><h3>${esc(student.full_name)}</h3><p>${esc(student.admission_no)} • ${esc(student.class_name)} • ${esc(student.academic_year_name)} • ${esc(student.term_name)}</p></div>
        <div class="page-actions"><button class="button ghost" id="reportBack">Back to reports</button>
          ${report.id?`<button class="button outline" id="reportHistory">Revisions</button>`:""}
          ${publication?`<button class="button outline" id="reportDownload">Download latest PDF</button>`:""}
          ${report.id&&canRemoveReportRow(report)?`<button class="button danger" id="reportRemove">Delete permanently</button>`:""}
        </div></div>
      <div class="report-layout">
        <section class="panel">
          <div class="panel-header"><div><h3>Assessment Record</h3><p>${statusBadge(report.status)}</p></div>
            <div class="button-row">${locked?`<span class="chip">Read only</span>`:`<span class="chip">Version ${number(report.version||0)}</span>`}</div></div>
          <div class="panel-body">
            <form id="reportForm" class="form-stack">
              <div class="form-grid three">
                <label class="field"><span>Days school opened (automatic)</span><input name="days_school_opened" type="number" min="0" value="${attr(report.days_school_opened||0)}" readonly></label>
                <label class="field"><span>Days present (automatic)</span><input name="days_present" type="number" min="0" value="${attr(report.days_present||0)}" readonly></label>
                ${(()=>{const display=promotionDisplay(editor.promotion||localPromotionEvaluation(editor));return `<div class="field automatic-promotion-field" id="automaticPromotionField" data-promotion-state="${display.state}"><span>Automatic promotion</span><strong id="automaticPromotionValue">${esc(display.title)}</strong><small id="automaticPromotionDetail">${esc(display.detail)}</small></div>`})()}
                <label class="field"><span>Attitude</span><input name="attitude" value="${attr(report.attitude||"")}" ${fieldsLocked?"disabled":""}></label>
                <label class="field"><span>Conduct</span><input name="conduct" value="${attr(report.conduct||"")}" ${fieldsLocked?"disabled":""}></label>
                <label class="field"><span>Interest or talent</span><input name="interest" value="${attr(report.interest||"")}" ${fieldsLocked?"disabled":""}></label>
                <div class="full comment-actions">${editor.can_edit_fields||canHeadComment?`<button class="button secondary small" id="reportGenerateComments" type="button">Generate comments</button>`:""}
                  ${locked&&canHeadComment?`<button class="button primary small" id="reportSaveComments" type="button">Save comments</button>`:""}</div>
                <label class="field full"><span>Class teacher's comment</span><textarea name="teacher_comment" ${fieldsLocked?"disabled":""}>${esc(report.teacher_comment||"")}</textarea></label>
                <label class="field full"><span>Principal's comment</span><textarea name="head_comment" ${canHeadComment?"":"disabled"}>${esc(report.head_comment||"")}</textarea></label>
              </div>
              <div class="section-title"><h4>Subject Results</h4><span class="chip">${subjects.length} subjects</span></div>
              <div class="score-grid"><table><thead><tr><th>Subject</th><th>Assessment Components</th><th>Total</th><th>Grade</th><th>Remark</th><th>Initials</th></tr></thead>
                <tbody>${subjects.map((subject,index)=>reportSubjectRow(subject,index,!subject.can_score)).join("")}</tbody></table></div>
            </form>
          </div>
        </section>
        <aside class="report-sidebar">
          <div class="report-summary"><p>Current average</p><div class="summary-number" id="reportAverage">${number(average,1)}%</div>
            <p>${esc(report.report_number||"Unpublished record")}</p></div>
          <section class="panel pad"><div class="section-title"><h4>Workflow</h4></div>
            <div class="workflow">${workflowButtons(report,publication)}</div></section>
          <section class="panel pad"><div class="section-title"><h4>Activity</h4></div>
            <div class="timeline">${(editor.workflow||[]).length?(editor.workflow||[]).slice(0,8).map(item=>`
              <div class="timeline-item"><span class="timeline-dot"></span><div class="timeline-copy"><strong>${esc(item.to_status.replaceAll("_"," "))}</strong>
              <small>${isoDateTime(item.created_at)}${item.comment?` • ${esc(item.comment)}`:""}</small></div></div>`).join(""):`<p class="help-text">No workflow activity</p>`}</div></section>
        </aside>
      </div>`;
    byId("reportBack").onclick=()=>navigate("reports",true);
    byId("reportHistory")?.addEventListener("click",openRevisionHistory);
    byId("reportDownload")?.addEventListener("click",()=>downloadLatestOfficialPdf(report.id));
    byId("reportRemove")?.addEventListener("click",async()=>{const id=report.id;await archiveReportCard(id);if(state.view==="reports")await navigate("reports",true)});
    byId("reportSave")?.addEventListener("click",saveOpenReport);
    byId("reportGenerateComments")?.addEventListener("click",()=>applyAutomaticComments(true));
    byId("reportSaveComments")?.addEventListener("click",saveLockedReportComments);
    $$("[data-transition]").forEach(button=>button.onclick=()=>requestTransition(button.dataset.transition));
    byId("reportGeneratePdf")?.addEventListener("click",()=>generateAndUploadOfficialPdf());
    byId("reportCorrection")?.addEventListener("click",openCorrection);
    $$("[data-component-input]").forEach(input=>input.addEventListener("input",()=>{
      recalculateSubject(Number(input.dataset.subjectIndex));
      scheduleLocalDraft();
    }));
    $$("[data-teacher-initials]").forEach(input=>input.addEventListener("input",scheduleLocalDraft));
    $$("#reportForm input,#reportForm textarea,#reportForm select").forEach(input=>input.addEventListener("change",scheduleLocalDraft));
    updatePromotionPreview();
    setTimeout(()=>applyAutomaticComments(false),0);
  }
  function reportSubjectRow(subject,index,locked) {
    return `<tr data-subject-row="${index}">
      <td><div class="cell-copy"><strong>${esc(subject.subject_name)}</strong><small>${esc(subject.subject_code)} • ${esc(subject.scheme_name||"")}</small></div></td>
      <td><div class="chip-list">${(subject.components||[]).map(component=>`<label class="chip">
        <span>${esc(component.code)} / ${number(component.maximum_score,0)}</span>
        <input class="score-input" data-component-input data-subject-index="${index}" data-component-id="${attr(component.component_id)}"
          data-max="${attr(component.maximum_score)}" data-weight="${attr(component.weight)}" type="number" min="0" max="${attr(component.maximum_score)}"
          step=".01" value="${attr(component.raw_score||0)}" ${locked?"disabled":""}>
      </label>`).join("")}</div></td>
      <td class="score-total" data-subject-total="${index}">${number(subject.total_score,1)}</td>
      <td data-subject-grade="${index}">${esc(subject.grade||"—")}</td><td>${esc(subject.remark||"")}</td>
      <td><input class="score-input" data-teacher-initials="${index}" value="${attr(subject.teacher_initials||"")}" ${locked?"disabled":""}></td>
    </tr>`;
  }
  function recalculateSubject(index) {
    const subject=state.reportEditor.subjects[index];
    let total=0;
    $$(`[data-subject-index="${index}"]`).forEach(input=>{
      const raw=Math.max(0,Math.min(Number(input.value||0),Number(input.dataset.max||0)));
      total+=(raw/Number(input.dataset.max||1))*Number(input.dataset.weight||0);
    });
    subject.total_score=Math.round(total*100)/100;
    $(`[data-subject-total="${index}"]`).textContent=number(subject.total_score,1);
    const totals=state.reportEditor.subjects.map(s=>Number(s.total_score||0));
    byId("reportAverage").textContent=`${number(totals.reduce((a,b)=>a+b,0)/(totals.length||1),1)}%`;
    updatePromotionPreview();
    if(byId("reportForm")?.elements.teacher_comment?.dataset.autoGenerated==="true"||byId("reportForm")?.elements.head_comment?.dataset.autoGenerated==="true")applyAutomaticComments(false);
  }
  function automaticCommentText() {
    const editor=state.reportEditor,student=editor?.student||{},subjects=editor?.subjects||[];
    const scores=subjects.map(subject=>({name:subject.subject_name||"the assessed subjects",score:Number(subject.total_score||0)}));
    const average=scores.length?scores.reduce((sum,item)=>sum+item.score,0)/scores.length:0;
    const strongest=[...scores].sort((a,b)=>b.score-a.score)[0]?.name||"the assessed subjects";
    const weakest=[...scores].sort((a,b)=>a.score-b.score)[0]?.name||"the weaker subjects";
    const firstName=student.first_name||student.full_name?.split(" ")[0]||"The student";
    const pronoun=student.gender==="Male"?"He":student.gender==="Female"?"She":"They";
    const form=byId("reportForm"),opened=Number(form?.elements.days_school_opened?.value||0),present=Number(form?.elements.days_present?.value||0);
    const attendance=opened>0?present/opened*100:0;
    const mark=number(average,1);
    let teacherComment,headComment;
    if(!scores.length){teacherComment=`${firstName}'s assessment record is incomplete and requires all subject results.`;headComment="Complete the outstanding assessment records before final approval."}
    else if(average>=85){teacherComment=`${firstName} has demonstrated outstanding academic performance with an average of ${mark}%. ${pronoun} showed exceptional strength in ${strongest}. Maintain this excellent standard.`;headComment="Excellent performance. Continue to pursue excellence and remain a positive example to others."}
    else if(average>=75){teacherComment=`${firstName} has achieved a very good academic performance with an average of ${mark}%. ${pronoun} performed especially well in ${strongest} and should continue working consistently.`;headComment="Very good performance. Keep working diligently and aim for an even higher standard next term."}
    else if(average>=65){teacherComment=`${firstName} has made good academic progress with an average of ${mark}%. ${pronoun} showed strength in ${strongest} and should give additional attention to ${weakest}.`;headComment="Good progress. Maintain steady effort and improve the areas that require greater attention."}
    else if(average>=50){teacherComment=`${firstName} has produced a satisfactory performance with an average of ${mark}%. More regular revision, active class participation, and focused practice in ${weakest} will improve future results.`;headComment="Satisfactory performance. Greater consistency and focused study are required for stronger achievement."}
    else if(average>=40){teacherComment=`${firstName} has shown a fair performance with an average of ${mark}%. ${pronoun} needs sustained support, regular practice, and closer attention to ${weakest}.`;headComment="There is potential for improvement. Work closely with teachers and maintain a disciplined study routine."}
    else {teacherComment=`${firstName} needs substantial academic improvement. The current average is ${mark}%, and immediate support is required, particularly in ${weakest}.`;headComment="Considerable improvement is required. Consistent effort, supervision, and remedial support should begin immediately."}
    if(opened>0&&attendance<85)teacherComment+=` Attendance also requires improvement (${present} of ${opened} days present).`;
    else if(opened>0&&attendance>=95)teacherComment+=` ${pronoun} maintained excellent attendance.`;
    const promotion=localPromotionEvaluation(editor);
    if(promotion.term3&&promotion.complete){
      if(promotion.passed&&promotion.next_class_name&&promotion.promotion_applied)headComment+=` Promotion: Promoted to ${promotion.next_class_name}.`;
      else if(promotion.passed&&promotion.next_class_name)headComment+=` Promotion: Eligible for ${promotion.next_class_name}, subject to Principal approval or publication.`;
      else if(!promotion.passed)headComment+=` Promotion: Not promoted because the Term 3 average is below the ${number(promotion.cutoff,0)}% cutoff.`;
    }
    return {teacherComment,headComment,average};
  }
  function applyAutomaticComments(force=false) {
    if(!state.reportEditor||!byId("reportForm"))return;
    const generated=automaticCommentText(),form=byId("reportForm");
    const teacher=form.elements.teacher_comment,head=form.elements.head_comment;
    if(teacher&&!teacher.disabled&&(force||!teacher.value.trim()||teacher.dataset.autoGenerated==="true")){
      teacher.value=generated.teacherComment;teacher.dataset.autoGenerated="true";
    }
    if(head&&!head.disabled&&(force||!head.value.trim()||head.dataset.autoGenerated==="true")){
      head.value=generated.headComment;head.dataset.autoGenerated="true";
    }
    state.autoComments=generated;scheduleLocalDraft();
  }
  async function saveLockedReportComments() {
    const report=state.reportEditor?.report,form=byId("reportForm"),button=byId("reportSaveComments");
    if(!report?.id||!form)return;if(button)button.disabled=true;
    try{
      state.reportEditor=await rpc("save_report_comments",{
        target_report_id:report.id,teacher_comment_text:null,
        head_comment_text:form.elements.head_comment?.value||"",expected_version:report.version
      });
      state.workspace=null;renderReportEditor();toast("Comments saved");
    }catch(error){if(error?.code==="40001")await refreshOpenReport();toast("Comments not saved",friendlyError(error),"error")}
    finally{if(button)button.disabled=false}
  }

  function workflowButtons(report,publication) {
    const buttons=[],allowed=new Set(state.reportEditor.allowed_transitions||[]);
    if(state.reportEditor.can_edit)buttons.push(`<button class="button primary full" id="reportSave">Save report</button>`);
    if(allowed.has("submitted"))buttons.push(`<button class="button secondary full" data-transition="submitted">Submit for Principal approval</button>`);
    if(allowed.has("class_reviewed"))buttons.push(`<button class="button success full" data-transition="class_reviewed">Complete class review</button>`);
    if(allowed.has("approved"))buttons.push(`<button class="button success full" data-transition="approved">Approve report</button>`);
    if(allowed.has("published"))buttons.push(`<button class="button success full" data-transition="published">${report.status==="withdrawn"?"Republish report":"Publish report"}</button>`);
    if(allowed.has("returned"))buttons.push(`<button class="button warning full" data-transition="returned">Return for correction</button>`);
    if(report.status==="published"&&!publication?.storage_path&&can("publish_reports"))buttons.push(`<button class="button primary full" id="reportGeneratePdf">Create official PDF</button>`);
    if(["published","approved"].includes(report.status)&&can("approve_reports"))buttons.push(`<button class="button warning full" id="reportCorrection">Open correction</button>`);
    if(allowed.has("withdrawn"))buttons.push(`<button class="button danger full" data-transition="withdrawn">Withdraw publication</button>`);
    return buttons.join("")||`<span class="help-text">No workflow action available</span>`;
  }
  function collectReportPayload() {
    const form=byId("reportForm"),values=formObject(form),editor=state.reportEditor;
    const subjects=editor.subjects.map((subject,index)=>({subject,index})).filter(item=>item.subject.can_score).map(({subject,index})=>({
      subject_id:subject.subject_id,scheme_id:subject.scheme_id,
      teacher_initials:$(`[data-teacher-initials="${index}"]`)?.value.trim()||"",
      components:(subject.components||[]).map(component=>({component_id:component.component_id,raw_score:Number($(`[data-subject-index="${index}"][data-component-id="${component.component_id}"]`)?.value||0)}))
    }));
    const fields=editor.can_edit_fields?{days_school_opened:Number(values.days_school_opened||0),days_present:Number(values.days_present||0),
      attitude:values.attitude||"",conduct:values.conduct||"",interest:values.interest||"",
      teacher_comment:values.teacher_comment||"",head_comment:values.head_comment??editor.report.head_comment??"",
      promoted_to_class_id:editor.report.promoted_to_class_id||null}:{};
    return {report_id:editor.report.id||null,enrollment_id:editor.report.enrollment_id,term_id:editor.report.term_id,fields,subjects,reason:"Report assessment updated"};
  }
  function scheduleLocalDraft() {
    clearTimeout(scheduleLocalDraft.timer);
    scheduleLocalDraft.timer=setTimeout(async()=>{
      if(!state.reportEditor?.can_edit||!byId("reportForm"))return;
      const payload=collectReportPayload(),key=`report:${state.reportEditor.report.id||`${payload.enrollment_id}:${payload.term_id}`}`;
      await draftPut({key,payload,version:state.reportEditor.report.version||0,savedAt:new Date().toISOString()}).catch(()=>{});
    },450);
  }
  function applyLocalReportDraft(payload) {
    if(!payload||!byId("reportForm"))return;
    const f=payload.fields||{},form=byId("reportForm");
    Object.entries(f).forEach(([key,value])=>{if(form.elements[key]&&!form.elements[key].disabled)form.elements[key].value=value??""});
    (payload.subjects||[]).forEach(subject=>{
      const index=(state.reportEditor.subjects||[]).findIndex(item=>item.subject_id===subject.subject_id);if(index<0||!state.reportEditor.subjects[index].can_score)return;
      (subject.components||[]).forEach(component=>{const input=$(`[data-subject-index="${index}"][data-component-id="${component.component_id}"]`);if(input&&!input.disabled)input.value=component.raw_score});
      const initials=$(`[data-teacher-initials="${index}"]`);if(initials&&!initials.disabled)initials.value=subject.teacher_initials||"";recalculateSubject(index);
    });
  }
  async function saveOpenReport() {
    const form=byId("reportForm");if(form&&!form.reportValidity())return;
    const button=byId("reportSave");if(button)button.disabled=true;
    const payload=collectReportPayload(),expected=state.reportEditor.report.version||null;let persisted=false;
    try {
      let saved;
      if(!state.online) saved=await queueReportSave(payload,expected);
      else {
        try{saved=await rpc("save_report_card",{payload,expected_version:expected});persisted=true}
        catch(error){
          if(error?.message?.toLowerCase().includes("fetch")||error?.name==="TypeError"){saved=await queueReportSave(payload,expected)}
          else throw error;
        }
      }
      if(saved?.report){await enrichReportPromotion(saved);state.workspace=null;state.reportEditor=saved;renderReportEditor()}
      const key=`report:${payload.report_id||`${payload.enrollment_id}:${payload.term_id}`}`;await draftDelete(key).catch(()=>{});
      if(persisted)toast("Report saved");
    } catch(error){
      if(persisted){await reportClientError(error,{source:"report_save",stage:"refresh"});toast("Report saved","Reload the page to display the latest report.","warning",6500);return}
      if(error?.code==="40001"||String(error?.message).includes("changed by another user"))await refreshOpenReport();
      toast("Report not saved",friendlyError(error),"error");
    } finally{if(button)button.disabled=false}
  }
  async function requestTransition(targetStatus) {
    const labels={submitted:"Submit report",class_reviewed:"Complete review",approved:"Approve report",published:state.reportEditor?.report?.status==="withdrawn"?"Republish report":"Publish report",returned:"Return report",withdrawn:"Withdraw publication"};
    modal(labels[targetStatus]||"Update report status","",`<label class="field"><span>Comment</span><textarea id="workflowComment"></textarea></label>`,
      `<button class="button ghost" id="workflowCancel" type="button">Cancel</button><button class="button ${targetStatus==="withdrawn"?"danger":"primary"}" id="workflowConfirm" type="button">${esc(labels[targetStatus]||"Continue")}</button>`,"small");
    byId("workflowCancel").onclick=closeModal;
    byId("workflowConfirm").onclick=async()=>{
      const comment=byId("workflowComment").value.trim(),button=byId("workflowConfirm");button.disabled=true;
      try{
        if(state.reportEditor.can_edit&&(targetStatus==="submitted"||(targetStatus==="published"&&state.reportEditor.report.status==="withdrawn")))await saveOpenReport();
        const updated=await rpc("transition_report_status",{target_report_id:state.reportEditor.report.id,target_status:targetStatus,
          comment_text:comment,expected_version:state.reportEditor.report.version});
        await enrichReportPromotion(updated);
        state.workspace=null;state.reportEditor=updated;closeModal();toast("Report status updated");
        renderReportEditor();
        if(targetStatus==="published")await generateAndUploadOfficialPdf();
      }catch(error){toast("Workflow action unsuccessful",friendlyError(error),"error");if(error?.code==="40001")await refreshOpenReport()}
      finally{button.disabled=false}
    };
  }
  async function openCorrection() {
    modal("Open Report Correction","Published records remain preserved in revision history",`<label class="field"><span>Correction reason</span><textarea id="correctionReason" required></textarea></label>`,
      `<button class="button ghost" id="correctionCancel" type="button">Cancel</button><button class="button warning" id="correctionOpen" type="button">Open correction</button>`,"small");
    byId("correctionCancel").onclick=closeModal;
    byId("correctionOpen").onclick=async()=>{
      const reason=byId("correctionReason").value.trim();if(!reason)return;
      try{state.reportEditor=await rpc("begin_report_correction",{target_report_id:state.reportEditor.report.id,reason_text:reason});await enrichReportPromotion(state.reportEditor);closeModal();renderReportEditor();toast("Correction opened")}
      catch(error){toast("Correction not opened",friendlyError(error),"error")}
    };
  }
  async function openRevisionHistory() {
    const revisions=await rpc("get_report_revisions",{target_report_id:state.reportEditor.report.id});
    modal("Report Revisions",state.reportEditor.report.report_number||"",`
      <div class="form-grid">
        <label class="field"><span>Earlier revision</span><select id="revisionA">${(revisions||[]).map((r,i)=>`<option value="${i}" ${i===Math.min(1,revisions.length-1)?"selected":""}>Version ${r.version} • ${isoDateTime(r.created_at)}</option>`).join("")}</select></label>
        <label class="field"><span>Later revision</span><select id="revisionB">${(revisions||[]).map((r,i)=>`<option value="${i}" ${i===0?"selected":""}>Version ${r.version} • ${isoDateTime(r.created_at)}</option>`).join("")}</select></label>
      </div>
      <div id="revisionDiff" style="margin-top:18px"></div>`,
      `<button class="button ghost" id="revisionClose" type="button">Close</button>`,"wide");
    const render=()=>renderRevisionDiff(revisions[Number(byId("revisionA").value)],revisions[Number(byId("revisionB").value)]);
    byId("revisionA").onchange=render;byId("revisionB").onchange=render;byId("revisionClose").onclick=closeModal;render();
  }
  function renderRevisionDiff(a,b) {
    const root=byId("revisionDiff");if(!root||!a||!b)return;
    const fields=["status","days_school_opened","days_present","attitude","conduct","interest","teacher_comment","head_comment","promoted_to_class_id"];
    const ar=a.snapshot?.report||{},br=b.snapshot?.report||{};
    const scoreMap=snapshot=>Object.fromEntries((snapshot?.results||[]).map(x=>[x.subject_name,x.total_score]));
    const as=scoreMap(a.snapshot),bs=scoreMap(b.snapshot),subjects=[...new Set([...Object.keys(as),...Object.keys(bs)])];
    root.innerHTML=`<div class="revision-compare">
      <div class="diff-card"><h4>Version ${a.version}</h4>${fields.map(key=>`<div class="diff-row ${String(ar[key]??"")!==String(br[key]??"")?"changed":""}"><span>${esc(key.replaceAll("_"," "))}</span><b>${esc(ar[key]??"—")}</b></div>`).join("")}</div>
      <div class="diff-card"><h4>Version ${b.version}</h4>${fields.map(key=>`<div class="diff-row ${String(ar[key]??"")!==String(br[key]??"")?"changed":""}"><span>${esc(key.replaceAll("_"," "))}</span><b>${esc(br[key]??"—")}</b></div>`).join("")}</div>
    </div>
    <div class="section-title" style="margin-top:18px"><h4>Score changes</h4></div>
    <div class="table-wrap"><table><thead><tr><th>Subject</th><th>Version ${a.version}</th><th>Version ${b.version}</th><th>Change</th></tr></thead><tbody>
      ${subjects.map(name=>`<tr><td>${esc(name)}</td><td>${number(as[name],1)}</td><td>${number(bs[name],1)}</td><td>${number(Number(bs[name]||0)-Number(as[name]||0),1)}</td></tr>`).join("")}
    </tbody></table></div>`;
  }
  async function openScoreImport() {
    const visibleClasses=await visibleClassesForCurrentRole();
    modal("Import Scores","CSV assessment score entries",`<form id="scoreImportForm" class="form-stack">
      <div class="form-grid"><label class="field"><span>Term</span><select name="term_id" required>${optionList(state.boot.terms||[],"id","name",activeTerm()?.id)}</select></label>
      <label class="field"><span>Class</span><select name="class_id" required>${optionList(visibleClasses,"id","name")}</select></label></div>
      <label class="file-drop"><strong>CSV file</strong><input name="file" type="file" accept=".csv,text/csv" required></label>
    </form>`,`<button class="button ghost" id="scoreImportCancel" type="button">Cancel</button><button class="button primary" id="scoreImportRun" type="button">Import</button>`,"small");
    byId("scoreImportCancel").onclick=closeModal;
    byId("scoreImportRun").onclick=async()=>{
      const form=byId("scoreImportForm"),v=formObject(form),file=form.elements.file.files[0];if(!file)return;
      const rows=parseCsv(await file.text()),button=byId("scoreImportRun");button.disabled=true;
      try{const result=await rpc("bulk_import_scores",{target_term_id:v.term_id,target_class_id:v.class_id,rows,filename:file.name});
        closeModal();toast("Score import completed",`${result.successful} saved, ${result.failed} failed`,result.failed?"warning":"success",7000);await loadReportPage()}
      catch(error){toast("Score import unsuccessful",friendlyError(error),"error")}finally{button.disabled=false}
    };
  }

  function openManualReportTemplate() {
    const years=(state.boot.academic_years||[]).filter(item=>!item.deleted_at);
    const classes=(state.boot.classes||[]).filter(item=>item.active!==false&&!item.deleted_at);
    const activeSubjects=(state.boot.subjects||[]).filter(item=>item.active!==false&&!item.deleted_at);
    modal("Manual Report Card Template","Download a professionally formatted blank report card containing every active subject.",`
      <form id="manualTemplateForm" class="form-stack">
        <div class="form-grid">
          <label class="field"><span>Academic year</span><select name="academic_year_id">${optionList(years,"id","name",activeYear()?.id,"Leave blank")}</select></label>
          <label class="field"><span>Term</span><select name="term_id" id="manualTemplateTerm"></select></label>
          <label class="field full"><span>Class</span><select name="class_id">${optionList(classes,"id","name","","Leave blank")}</select></label>
        </div>
        <div class="template-information">
          <strong>${activeSubjects.length} active subject${activeSubjects.length===1?"":"s"} will be included.</strong>
          <span id="manualTemplateAssignment">Choose a class to apply its assigned class-range template. Student details, scores, grades, positions, comments, attendance and conduct fields remain blank for manual completion.</span>
        </div>
      </form>`,
      `<button class="button ghost" id="manualTemplateCancel" type="button">Cancel</button><button class="button primary" id="manualTemplateDownload" type="button">Download PDF template</button>`,"small");
    const form=byId("manualTemplateForm");
    const renderTerms=()=>{
      const yearId=form.elements.academic_year_id.value;
      const terms=(state.boot.terms||[]).filter(item=>!item.deleted_at&&(!yearId||item.academic_year_id===yearId));
      byId("manualTemplateTerm").innerHTML=optionList(terms,"id","name",activeTerm()?.id,"Leave blank");
    };
    const renderTemplateAssignment=async()=>{
      const classRow=classes.find(item=>item.id===form.elements.class_id.value),status=byId("manualTemplateAssignment");if(!status)return;
      if(!classRow){status.textContent="Choose a class to apply its assigned class-range template. Without a class, the built-in design is used.";return}
      try{const template=await currentReportTemplateForClass(classRow.name,true);status.textContent=template?`${classRow.name} will use the uploaded ${reportTemplateGroup(template.range_key)?.shortLabel||"class-range"} template: ${template.original_name}.`:`${classRow.name} has no uploaded class-range template and will use the approved built-in design.`}catch(_){status.textContent="Template assignment could not be checked. The system will validate it when generating the PDF."}
    };
    form.elements.academic_year_id.onchange=renderTerms;form.elements.class_id.onchange=renderTemplateAssignment;
    renderTerms();renderTemplateAssignment();
    byId("manualTemplateCancel").onclick=closeModal;
    byId("manualTemplateDownload").onclick=async()=>{
      if(!activeSubjects.length){toast("Template unavailable","Add at least one active subject first.","error");return}
      const values=formObject(form),button=byId("manualTemplateDownload");
      const year=years.find(item=>item.id===values.academic_year_id);
      const term=(state.boot.terms||[]).find(item=>item.id===values.term_id);
      const classRow=classes.find(item=>item.id===values.class_id);
      button.disabled=true;button.textContent="Preparing";
      setLoading(true);
      try{
        const pdf=await createManualReportTemplatePdf({
          academicYearName:year?.name||"",
          termName:term?.name||"",
          className:classRow?.name||"",
          subjects:activeSubjects
        });
        const safeClass=(classRow?.name||"All_Classes").replace(/[^A-Za-z0-9_-]+/g,"_");
        downloadBlob(`NIS_Manual_Report_Card_Template_${safeClass}.pdf`,pdf);
        closeModal();
        toast("Manual template downloaded",`${activeSubjects.length} subjects included.`);
      }catch(error){
        toast("Template not created",friendlyError(error),"error",6500);
        await reportClientError(error,{source:"manual_report_template"});
      }finally{
        setLoading(false);
        button.disabled=false;button.textContent="Download PDF template";
      }
    };
  }

  async function exportReportList() {
    const data=await rpc("list_report_cards_v6",{target_term_id:byId("reportTerm")?.value||null,target_class_id:byId("reportClass")?.value||null,
      target_status:byId("reportStatus")?.value||null,search_text:byId("reportSearch")?.value||"",archive_filter:"active",page_number:1,page_size:100});
    const headers=["report_number","student_name","admission_no","class_name","academic_year_name","term_name","average","status","updated_at"];
    downloadText("report-cards.csv",[headers.join(","),...(data.rows||[]).map(row=>headers.map(h=>csvCell(row[h])).join(","))].join("\n"),"text/csv");
  }


  function canBulkDownloadPublishedReports() {
    return ["system_admin","class_teacher","subject_teacher"].includes(role());
  }
  function safeArchiveSegment(value,fallback="report") {
    const cleaned=String(value||"").normalize("NFKD").replace(/[\u0300-\u036f]/g,"")
      .replace(/[^A-Za-z0-9._-]+/g,"_").replace(/^_+|_+$/g,"").slice(0,90);
    return cleaned||fallback;
  }
  function openBulkPublishedReportPackage() {
    if(!canBulkDownloadPublishedReports()){toast("Bulk download unavailable","Only the System Administrator and assigned teachers can download class report packages.","error");return}
    const selectedTerm=byId("reportTerm")?.value||activeTerm()?.id||"";
    const selectedClass=byId("reportClass")?.value||state.reportClassFilter||"";
    modal("Bulk Published Report Cards","Generate the latest official PDFs for one class and term, then download them in a single ZIP package.",`
      <form id="bulkPublishedReportsForm" class="form-stack">
        <div class="form-grid">
          <label class="field"><span>Term</span><select name="term_id" required>${optionList(state.boot.terms||[],"id","name",selectedTerm,"Select term")}</select></label>
          <label class="field"><span>Class</span><select name="class_id" required>${optionList(state.boot.classes||[],"id","name",selectedClass,"Select class")}</select></label>
        </div>
        <div class="template-information"><strong>Latest-format enforcement</strong><span>Every accessible published report is regenerated with the current positions, colours, typography, student photograph, class-range template, and Principal signature before it is added to the ZIP.</span></div>
        <div id="bulkPublishedReportsProgress" class="template-information hidden" aria-live="polite"><strong>Preparing package</strong><span id="bulkPublishedReportsProgressText">Waiting to start</span></div>
      </form>`,
      `<button class="button ghost" id="bulkPublishedReportsCancel" type="button">Cancel</button><button class="button primary" id="bulkPublishedReportsRun" type="button">Download class package</button>`,"small");
    byId("bulkPublishedReportsCancel").onclick=()=>{if(!state.bulkReportPackageBusy)closeModal()};
    byId("bulkPublishedReportsRun").onclick=downloadBulkPublishedReportPackage;
  }
  async function listAllPublishedReportsForClass(termId,classId) {
    const rows=[];let page=1,total=Infinity;
    while(rows.length<total){
      const data=await rpc("list_report_cards_v6",{
        target_term_id:termId,target_class_id:classId,target_status:"published",search_text:"",
        archive_filter:"active",page_number:page,page_size:100
      });
      const batch=(data.rows||[]).filter(row=>row.status==="published"&&!row.archived);
      rows.push(...batch);total=Number(data.total??rows.length);
      const pageSize=Math.max(1,Number(data.page_size||100));
      if(!batch.length||page*pageSize>=total)break;
      page+=1;
      if(page>1000)throw new Error("The published report list exceeded the safe pagination limit.");
    }
    return rows;
  }
  async function downloadBulkPublishedReportPackage() {
    if(state.bulkReportPackageBusy)return;
    if(!window.JSZip){toast("Bulk download unavailable","The packaged ZIP library did not load. Reload the system and try again.","error");return}
    const form=byId("bulkPublishedReportsForm");if(!form?.reportValidity())return;
    const values=formObject(form),term=(state.boot.terms||[]).find(item=>item.id===values.term_id),classRow=(state.boot.classes||[]).find(item=>item.id===values.class_id);
    if(!term||!classRow){toast("Package not created","Select a valid class and term.","error");return}
    const button=byId("bulkPublishedReportsRun"),cancel=byId("bulkPublishedReportsCancel"),progress=byId("bulkPublishedReportsProgress"),progressText=byId("bulkPublishedReportsProgressText");
    state.bulkReportPackageBusy=true;button.disabled=true;cancel.disabled=true;progress.classList.remove("hidden");
    try{
      progressText.textContent="Loading published reports";
      const rows=await listAllPublishedReportsForClass(term.id,classRow.id);
      if(!rows.length)throw new Error("No published report cards are available for this class and term, or your role is not assigned to them.");
      const zip=new window.JSZip(),folderName=safeArchiveSegment(`${classRow.name}_${term.name}`,"Published_Reports"),folder=zip.folder(folderName);
      const manifest=[];let completed=0,failed=0,storedRefreshes=0,fallbackDownloads=0;
      const canStoreOfficialPdf=can("publish_reports")&&["system_admin","class_teacher"].includes(role());
      for(const row of rows){
        completed+=1;progressText.textContent=`Preparing ${completed} of ${rows.length}: ${row.student_name||row.report_number||"report"}`;
        try{
          const editor=await rpc("get_report_editor",{target_report_id:row.id,target_enrollment_id:null,target_term_id:null});
          const publication=(editor.publications||[]).find(item=>!item.revoked_at);
          if(!publication)throw new Error("Active publication record not found");
          let pdf,storageStatus="downloaded_latest_not_stored";
          if(canStoreOfficialPdf){
            try{
              const generated=await createAndStoreOfficialPdf(editor,publication);pdf=generated.pdf;storageStatus="refreshed";storedRefreshes+=1;
            }catch(storageError){
              pdf=await createReportPdf(editor,publication);fallbackDownloads+=1;
              await reportClientError(storageError,{source:"bulk_class_pdf_storage_refresh",report_id:row.id,class_id:classRow.id,term_id:term.id});
            }
          }else{pdf=await createReportPdf(editor,publication);fallbackDownloads+=1}
          const studentName=editor.student?.full_name||row.student_name||"Student",admission=editor.student?.admission_no||row.admission_no||"";
          const reportNumber=editor.report?.report_number||row.report_number||row.id;
          const filename=`${safeArchiveSegment(reportNumber,"Report")}_${safeArchiveSegment(admission,"Admission")}_${safeArchiveSegment(studentName,"Student")}.pdf`;
          folder.file(filename,pdf);
          manifest.push({report_number:reportNumber,student_name:studentName,admission_no:admission,class_name:classRow.name,term_name:term.name,status:"included",storage_refresh:storageStatus,file_name:filename,error:""});
        }catch(error){
          failed+=1;manifest.push({report_number:row.report_number||"",student_name:row.student_name||"",admission_no:row.admission_no||"",class_name:classRow.name,term_name:term.name,status:"failed",storage_refresh:"not_attempted",file_name:"",error:friendlyError(error)});
          await reportClientError(error,{source:"bulk_class_pdf_download",report_id:row.id,class_id:classRow.id,term_id:term.id});
        }
      }
      const included=manifest.filter(item=>item.status==="included");
      if(!included.length)throw new Error("None of the published reports could be generated. Review the report and Storage configuration, then try again.");
      const headers=["report_number","student_name","admission_no","class_name","term_name","status","storage_refresh","file_name","error"];
      zip.file("BULK_DOWNLOAD_MANIFEST.csv",[headers.join(","),...manifest.map(item=>headers.map(key=>csvCell(item[key])).join(","))].join("\n"));
      zip.file("README.txt",`${schoolDisplayName()} Published Report Cards\n\nClass: ${classRow.name}\nTerm: ${term.name}\nGenerated: ${new Date().toISOString()}\nReports included: ${included.length}\nFailed: ${failed}\nStored PDFs refreshed: ${storedRefreshes}\nLatest-format fallback downloads: ${fallbackDownloads}\n\nOnly reports accessible to the signed-in System Administrator or assigned teacher are included. See BULK_DOWNLOAD_MANIFEST.csv for details.\n`);
      progressText.textContent="Compressing ZIP package";
      const blob=await zip.generateAsync({type:"blob",compression:"DEFLATE",compressionOptions:{level:6}},metadata=>{if(progressText)progressText.textContent=`Compressing ZIP package: ${Math.round(metadata.percent)}%`});
      const date=new Date().toISOString().slice(0,10),filename=`Published_Report_Cards_${safeArchiveSegment(classRow.name,"Class")}_${safeArchiveSegment(term.name,"Term")}_${date}.zip`;
      downloadBlob(filename,blob);closeModal();
      toast(failed?"Class package downloaded with warnings":"Class package downloaded",`${included.length} published report card${included.length===1?"":"s"} included${failed?` • ${failed} failed and are listed in the manifest`:""}.`,failed?"warning":"success",9000);
    }catch(error){toast("Class package not created",friendlyError(error),"error",9000);await reportClientError(error,{source:"bulk_class_pdf_package",class_id:values.class_id,term_id:values.term_id})}
    finally{state.bulkReportPackageBusy=false;if(button)button.disabled=false;if(cancel)cancel.disabled=false;if(progress)progress.classList.add("hidden")}
  }

  async function createAndStoreOfficialPdf(editor,publication) {
    if(!can("publish_reports")||!["system_admin","class_teacher"].includes(role()))throw new Error("Only the assigned class teacher or System Administrator can store an official report PDF");
    if(!editor?.report?.id||!publication||publication.revoked_at)throw new Error("Active publication record not found");
    const pdf=await createReportPdf(editor,publication);
    const checksum=await sha256(pdf),safeName=(editor.report.report_number||editor.report.id).replace(/[^A-Za-z0-9_-]/g,"_");
    const previousPath=publication.storage_path||"";
    const path=`${editor.report.id}/${safeName}-v${editor.report.version}-${Date.now()}.pdf`;
    const {error}=await state.client.storage.from(CONFIG.pdfBucket).upload(path,pdf,{contentType:"application/pdf",upsert:false,cacheControl:"31536000"});
    if(error)throw error;
    try{
      await rpc("register_report_pdf",{target_report_id:editor.report.id,target_storage_path:path,target_checksum:checksum,target_page_count:1});
    }catch(error){
      await state.client.storage.from(CONFIG.pdfBucket).remove([path]).catch(()=>{});throw error;
    }
    state.pdfUrls.delete(path);
    if(previousPath&&previousPath!==path){
      state.pdfUrls.delete(previousPath);
      await state.client.storage.from(CONFIG.pdfBucket).remove([previousPath]).catch(()=>{});
    }
    return {pdf,safeName,path};
  }

  async function refreshPublishedStudentReportPdfs(student) {
    if(!student?.id||!student?.admission_no)return {updated:0,failed:0};
    let rows=[];
    try{
      const data=await rpc("list_report_cards_v6",{
        target_term_id:null,target_class_id:null,target_status:"published",search_text:student.admission_no,
        archive_filter:"active",page_number:1,page_size:100
      });
      rows=(data.rows||[]).filter(row=>row.student_id===student.id&&!row.archived&&row.status==="published");
    }catch(error){
      await reportClientError(error,{source:"student_photo_pdf_refresh",stage:"list",student_id:student.id});
      return {updated:0,failed:1};
    }
    let updated=0,failed=0;
    for(const row of rows){
      try{
        const editor=await rpc("get_report_editor",{target_report_id:row.id,target_enrollment_id:null,target_term_id:null});
        const publication=(editor.publications||[]).find(item=>!item.revoked_at);
        if(!publication)continue;
        await createAndStoreOfficialPdf(editor,publication);updated+=1;
      }catch(error){
        failed+=1;await reportClientError(error,{source:"student_photo_pdf_refresh",stage:"generate",student_id:student.id,report_id:row.id});
      }
    }
    return {updated,failed};
  }

  async function generateAndUploadOfficialPdf() {
    const editor=state.reportEditor,publication=(editor.publications||[]).find(p=>!p.revoked_at);
    if(!publication)throw new Error("Publication record not found");
    setLoading(true);
    try{
      const {pdf,safeName}=await createAndStoreOfficialPdf(editor,publication);
      state.reportEditor=await rpc("get_report_editor",{target_report_id:editor.report.id,target_enrollment_id:null,target_term_id:null});
      renderReportEditor();downloadBlob(`${safeName}.pdf`,pdf);toast("Official PDF created");
    }catch(error){toast("PDF not created",friendlyError(error),"error");await reportClientError(error,{source:"pdf",report_id:editor.report.id})}
    finally{setLoading(false)}
  }
  async function downloadLatestOfficialPdf(reportId) {
    if(!reportId)return;
    setLoading(true);
    try{
      const editor=state.reportEditor?.report?.id===reportId
        ?state.reportEditor
        :await rpc("get_report_editor",{target_report_id:reportId,target_enrollment_id:null,target_term_id:null});
      const publication=(editor.publications||[]).find(item=>!item.revoked_at);
      if(!publication)throw new Error("Active publication record not found");
      let pdf,safeName=(editor.report.report_number||editor.report.id).replace(/[^A-Za-z0-9_-]/g,"_");
      const canRefreshStoredPdf=can("publish_reports")&&["system_admin","class_teacher"].includes(role());
      if(canRefreshStoredPdf){
        const generated=await createAndStoreOfficialPdf(editor,publication);
        pdf=generated.pdf;safeName=generated.safeName;
        if(state.reportEditor?.report?.id===reportId){
          state.reportEditor=await rpc("get_report_editor",{target_report_id:reportId,target_enrollment_id:null,target_term_id:null});
          renderReportEditor();
        }
      }else{
        pdf=await createReportPdf(editor,publication);
      }
      downloadBlob(`${safeName}.pdf`,pdf);
      toast("Latest official PDF downloaded","Current positions, colours, typography, photograph, template, and Principal signature were applied.");
    }catch(error){toast("PDF unavailable",friendlyError(error),"error",6500);await reportClientError(error,{source:"latest_pdf_download",report_id:reportId})}
    finally{setLoading(false)}
  }
  function downloadBlob(filename,blob) {
    const url=URL.createObjectURL(blob),a=document.createElement("a");a.href=url;a.download=filename;a.click();setTimeout(()=>URL.revokeObjectURL(url),1500);
  }
  async function sha256(blob) {
    const bytes=await blob.arrayBuffer(),hash=await crypto.subtle.digest("SHA-256",bytes);
    return [...new Uint8Array(hash)].map(b=>b.toString(16).padStart(2,"0")).join("");
  }
  async function loadImage(url) {
    return new Promise((resolve,reject)=>{const image=new Image();image.crossOrigin="anonymous";image.onload=()=>resolve(image);image.onerror=reject;image.src=url});
  }
  function drawImageContain(ctx,image,x,y,width,height) {
    const scale=Math.min(width/image.width,height/image.height),drawWidth=image.width*scale,drawHeight=image.height*scale;ctx.drawImage(image,x+(width-drawWidth)/2,y+(height-drawHeight)/2,drawWidth,drawHeight);
  }
  function drawImageCover(ctx,image,x,y,width,height) {
    const scale=Math.max(width/image.width,height/image.height),drawWidth=image.width*scale,drawHeight=image.height*scale;
    ctx.drawImage(image,x+(width-drawWidth)/2,y+(height-drawHeight)/2,drawWidth,drawHeight);
  }
  function drawWrapped(ctx,text,x,y,maxWidth,lineHeight,maxLines=3) {
    const words=String(text||"").split(/\s+/);let line="",lines=0;
    for(const word of words){
      const test=line?`${line} ${word}`:word;
      if(ctx.measureText(test).width>maxWidth&&line){ctx.fillText(line,x,y);y+=lineHeight;lines++;line=word;if(lines>=maxLines)return y}
      else line=test;
    }
    if(line&&lines<maxLines){ctx.fillText(line,x,y);y+=lineHeight}
    return y;
  }
  async function qrCanvas(text) {
    const box=byId("qrScratch");box.innerHTML="";
    if(!window.QRCode)return null;
    new window.QRCode(box,{text,width:190,height:190,correctLevel:window.QRCode.CorrectLevel.M});
    await sleep(80);
    const canvas=box.querySelector("canvas");if(canvas)return canvas;
    const img=box.querySelector("img");if(img)return img;
    return null;
  }
  const REPORT_FONT_OPTIONS=Object.freeze({
    "Times New Roman":'"Times New Roman", Times, "Liberation Serif", serif',
    "Arial":'Arial, Helvetica, "Liberation Sans", sans-serif',
    "Calibri":'Calibri, Carlito, Arial, sans-serif',
    "Georgia":'Georgia, "Times New Roman", serif',
    "Verdana":'Verdana, Geneva, sans-serif',
    "Tahoma":'Tahoma, Arial, sans-serif'
  });
  const REPORT_RESULT_COLOURS=Object.freeze({
    score:"#083b78",
    total:"#b00020",
    grade:"#006400",
    position:"#b00020",
    remark:"#083b78"
  });

  function reportTableLayout(ctx,subjects,columns,bodyTop,maximumTableBottom=1086) {
    const source=Array.isArray(subjects)?subjects.filter(Boolean):[];
    const displaySubjects=[...source,null]; // Always retain exactly one blank line box after the last subject.
    setReportFont(ctx,20,"normal");
    const subjectLineCounts=displaySubjects.map(subject=>subject
      ?reportTextLines(ctx,subject.subject_name||subject.name||"",columns[1]-columns[0]-16,2).length
      :1
    );
    const weights=subjectLineCounts.map(lines=>lines>1?1.34:1);
    const preferredRowUnit=56,maximumHeight=Math.max(preferredRowUnit,maximumTableBottom-bodyTop);
    const desiredHeight=Math.max(preferredRowUnit,weights.reduce((sum,value)=>sum+value,0)*preferredRowUnit);
    const availableHeight=Math.min(maximumHeight,desiredHeight);
    return {displaySubjects,subjectLineCounts,weights,availableHeight,tableBottom:bodyTop+availableHeight};
  }

  function reportBodyFontName() {
    const requested=String(state.boot?.school?.report_body_font||"Times New Roman");
    return Object.prototype.hasOwnProperty.call(REPORT_FONT_OPTIONS,requested)?requested:"Times New Roman";
  }

  function reportBodyFontFamily() {
    return REPORT_FONT_OPTIONS[reportBodyFontName()]||REPORT_FONT_OPTIONS["Times New Roman"];
  }

  function reportBodyFontSize() {
    const requested=Number(state.boot?.school?.report_body_font_size??11);
    return Number.isFinite(requested)?Math.min(16,Math.max(8,requested)):11;
  }

  function reportBodyFontScale() {
    return reportBodyFontSize()/11;
  }

  function reportFontOptionsHtml(selected="Times New Roman") {
    const current=Object.prototype.hasOwnProperty.call(REPORT_FONT_OPTIONS,selected)?selected:"Times New Roman";
    return Object.keys(REPORT_FONT_OPTIONS).map(name=>`<option value="${attr(name)}" ${name===current?"selected":""}>${esc(name)}</option>`).join("");
  }

  async function ensureReportBodyFontReady() {
    if(!document.fonts?.load)return;
    const safeName=reportBodyFontName().replace(/["\\]/g,"");
    await document.fonts.load(`${reportBodyFontSize()}pt "${safeName}"`).catch(()=>{});
  }


  function reportTemplateGroup(rangeKey) {
    return REPORT_TEMPLATE_GROUPS.find(item=>item.key===rangeKey)||null;
  }

  function normaliseClassName(value="") {
    return String(value||"").toLowerCase().normalize("NFD").replace(/[\u0300-\u036f]/g,"").replace(/[^a-z0-9]+/g," ").trim();
  }

  function reportTemplateRangeForClass(className="") {
    let name=normaliseClassName(className);
    if(!name)return "";
    if(/\b(?:kg|kindergarten|nursery)\s*(?:[12]|one|two)(?:\s*[a-z])?\b/.test(name)||/\b(creche|day care|daycare|preschool|pre school|nursery|kindergarten|kg|reception)\b/.test(name))return "early_years";
    const wordLevels={one:1,two:2,three:3,four:4,five:5,six:6,seven:7,eight:8,nine:9};
    const wordMatch=name.match(/\b(?:basic|grade|primary|class)\s*(one|two|three|four|five|six|seven|eight|nine)\b/);
    if(wordMatch)name=name.replace(wordMatch[1],String(wordLevels[wordMatch[1]]));
    const basic=name.match(/\b(?:basic|grade|primary|class)\s*([1-9])(?:\s*[a-z])?\b/);
    if(basic){const level=Number(basic[1]);return level<=6?"basic_1_6":"basic_7_9"}
    const jhsWord=name.match(/\b(?:jhs|junior high(?: school)?)\s*(one|two|three)\b/);
    if(jhsWord)return "basic_7_9";
    const jhs=name.match(/\b(?:jhs|junior high(?: school)?)\s*([1-3])(?:\s*[a-z])?\b/);
    if(jhs)return "basic_7_9";
    return "";
  }

  function templateClassesForRange(rangeKey) {
    return (state.boot?.classes||[]).filter(item=>!item.deleted_at&&item.active!==false&&reportTemplateRangeForClass(item.name)===rangeKey);
  }

  function readableBytes(value) {
    const bytes=Number(value||0);if(!bytes)return "0 B";
    const units=["B","KB","MB","GB"];const index=Math.min(units.length-1,Math.floor(Math.log(bytes)/Math.log(1024)));
    return `${number(bytes/Math.pow(1024,index),index?1:0)} ${units[index]}`;
  }

  async function loadReportCardTemplates(force=false) {
    if(!state.client)return [];
    if(!force&&Array.isArray(state.reportTemplates)&&Date.now()-state.reportTemplatesLoadedAt<60000)return state.reportTemplates;
    const rows=await rpc("list_report_card_templates");
    state.reportTemplates=Array.isArray(rows)?rows:[];
    state.reportTemplatesLoadedAt=Date.now();
    return state.reportTemplates;
  }

  async function currentReportTemplateForClass(className,force=false) {
    const rangeKey=reportTemplateRangeForClass(className);
    if(!rangeKey)return null;
    const rows=await loadReportCardTemplates(force);
    return rows.find(item=>item.range_key===rangeKey&&item.active!==false&&item.storage_path)||null;
  }

  function validateReportTemplateFile(file) {
    if(!file)throw new Error("Choose a PDF or DOCX report-card template.");
    if(file.size<=0)throw new Error("The selected template file is empty.");
    if(file.size>REPORT_TEMPLATE_MAX_BYTES)throw new Error("The template file must not exceed 20 MB.");
    const extension=String(file.name||"").split(".").pop().toLowerCase();
    const mimeType=extension==="pdf"
      ?"application/pdf"
      :extension==="docx"
        ?"application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        :"";
    if(!mimeType)throw new Error("Only PDF and DOCX files are accepted.");
    const browserMime=String(file.type||"").toLowerCase();
    if(browserMime&&browserMime!=="application/octet-stream"){
      const browserExtension=REPORT_TEMPLATE_MIME_TYPES[browserMime];
      if(!browserExtension||browserExtension!==extension)throw new Error("The selected file type does not match its PDF or DOCX filename.");
    }
    return {mimeType,extension};
  }

  function normaliseTemplateCanvas(source) {
    const canvas=document.createElement("canvas");canvas.width=1240;canvas.height=1754;
    const ctx=canvas.getContext("2d");ctx.fillStyle="#ffffff";ctx.fillRect(0,0,canvas.width,canvas.height);
    const ratio=Math.min(canvas.width/source.width,canvas.height/source.height);
    const width=source.width*ratio,height=source.height*ratio;
    ctx.drawImage(source,(canvas.width-width)/2,(canvas.height-height)/2,width,height);
    return canvas;
  }

  async function renderPdfTemplateBlob(blob) {
    if(!window.pdfjsLib?.getDocument)throw new Error("PDF template rendering service is unavailable. Reload the system and try again.");
    window.pdfjsLib.GlobalWorkerOptions.workerSrc="assets/vendor/pdfjs-3.11.174.worker.min.js";
    const documentTask=window.pdfjsLib.getDocument({data:new Uint8Array(await blob.arrayBuffer())});
    const pdf=await documentTask.promise;
    if(pdf.numPages<1)throw new Error("The PDF template has no pages.");
    const page=await pdf.getPage(1),base=page.getViewport({scale:1});
    const scale=Math.min(1240/base.width,1754/base.height)*2;
    const viewport=page.getViewport({scale});
    const source=document.createElement("canvas");source.width=Math.ceil(viewport.width);source.height=Math.ceil(viewport.height);
    await page.render({canvasContext:source.getContext("2d"),viewport}).promise;
    try{await pdf.destroy()}catch(_){}
    return normaliseTemplateCanvas(source);
  }

  async function waitForTemplateImages(root) {
    const images=[...root.querySelectorAll("img")];
    await Promise.all(images.map(image=>image.complete?Promise.resolve():new Promise(resolve=>{
      const done=()=>resolve();image.addEventListener("load",done,{once:true});image.addEventListener("error",done,{once:true});setTimeout(done,3500);
    })));
    if(document.fonts?.ready)await document.fonts.ready.catch(()=>{});
  }

  async function renderDocxTemplateBlob(blob) {
    if(!window.docx?.renderAsync||!window.html2canvas)throw new Error("DOCX template rendering service is unavailable. Reload the system and try again.");
    const host=document.createElement("div");
    host.className="docx-template-render-host";
    host.style.cssText="position:fixed;left:-100000px;top:0;width:794px;background:#fff;z-index:-1;visibility:visible;";
    document.body.append(host);
    try{
      await window.docx.renderAsync(await blob.arrayBuffer(),host,null,{
        className:"nis-docx-template",inWrapper:true,ignoreWidth:false,ignoreHeight:false,ignoreFonts:false,
        breakPages:true,ignoreLastRenderedPageBreak:false,useBase64URL:true,renderChanges:false,renderComments:false,renderAltChunks:false,experimental:false
      });
      await waitForTemplateImages(host);
      const page=host.querySelector("section.nis-docx-template")||host.querySelector(".nis-docx-template-wrapper > section")||host.firstElementChild;
      if(!page)throw new Error("The DOCX template could not be rendered.");
      const source=await window.html2canvas(page,{backgroundColor:"#ffffff",scale:2,useCORS:true,allowTaint:false,logging:false,windowWidth:Math.max(794,page.scrollWidth),windowHeight:Math.max(1123,page.scrollHeight)});
      return normaliseTemplateCanvas(source);
    }finally{host.remove()}
  }

  async function renderReportTemplateBlob(blob,mimeType) {
    if(mimeType==="application/pdf")return renderPdfTemplateBlob(blob);
    if(mimeType==="application/vnd.openxmlformats-officedocument.wordprocessingml.document")return renderDocxTemplateBlob(blob);
    throw new Error("Unsupported report-card template format.");
  }

  async function storedReportTemplateCanvas(template) {
    if(!template?.storage_path)return null;
    const cacheKey=`${template.storage_path}:${template.checksum||template.updated_at||""}`;
    if(state.templateCanvases.has(cacheKey))return state.templateCanvases.get(cacheKey);
    const {data,error}=await state.client.storage.from(CONFIG.templateBucket).download(template.storage_path);
    if(error)throw error;
    const canvas=await renderReportTemplateBlob(data,template.mime_type);
    state.templateCanvases.clear();state.templateCanvases.set(cacheKey,canvas);
    return canvas;
  }

  let builtInReportTemplatePromise=null;

  async function builtInReportTemplateCanvas() {
    if(!builtInReportTemplatePromise){
      builtInReportTemplatePromise=loadImage(CONFIG.defaultReportTemplatePath)
        .then(image=>normaliseTemplateCanvas(image))
        .catch(error=>{builtInReportTemplatePromise=null;throw error});
    }
    return builtInReportTemplatePromise;
  }

  async function resolveAssignedReportTemplate(className) {
    const template=await currentReportTemplateForClass(className);
    if(!template){
      try{return {template:null,templateBackground:await builtInReportTemplateCanvas(),templateSource:"built_in"}}
      catch(error){
        await reportClientError(error,{source:"built_in_report_template_load"});
        return {template:null,templateBackground:null,templateSource:"programmatic_fallback",templateLoadError:true};
      }
    }
    try{
      return {template,templateBackground:await storedReportTemplateCanvas(template),templateSource:"uploaded"};
    }catch(error){
      await reportClientError(error,{source:"report_template_load",range_key:template.range_key,storage_path:template.storage_path});
      try{
        return {template,templateBackground:await builtInReportTemplateCanvas(),templateSource:"built_in_fallback",templateLoadError:true};
      }catch(fallbackError){
        await reportClientError(fallbackError,{source:"built_in_report_template_load",after_uploaded_template_failure:true});
        return {template,templateBackground:null,templateSource:"programmatic_fallback",templateLoadError:true};
      }
    }
  }

  function setReportFont(ctx,size,weight="normal",style="normal") {
    const actualSize=Math.max(1,Number(size||0)*reportBodyFontScale());
    ctx.font=`${style} ${weight} ${actualSize}px ${reportBodyFontFamily()}`;
    return actualSize;
  }

  function drawCenteredReportText(ctx,text,x1,x2,y) {
    const value=String(text??"");
    ctx.fillText(value,x1+(x2-x1-ctx.measureText(value).width)/2,y);
  }

  function drawRightReportText(ctx,text,right,y) {
    const value=String(text??"");
    ctx.fillText(value,right-ctx.measureText(value).width,y);
  }

  function fitReportText(ctx,text,maxWidth,preferredSize=22,minimumSize=14,weight="normal") {
    const value=String(text??"");
    let size=preferredSize;
    while(size>minimumSize){
      setReportFont(ctx,size,weight);
      if(ctx.measureText(value).width<=maxWidth)break;
      size-=1;
    }
    return size;
  }

  function drawReportCellText(ctx,text,x1,x2,yCenter,{align="left",preferredSize=21,minimumSize=13,weight="normal",colour="#172238"}={}) {
    const value=String(text??"");
    fitReportText(ctx,value,Math.max(10,x2-x1-16),preferredSize,minimumSize,weight);
    ctx.fillStyle=colour;
    ctx.textBaseline="middle";
    const width=ctx.measureText(value).width;
    const x=align==="center"?x1+(x2-x1-width)/2:align==="right"?x2-width-8:x1+8;
    ctx.fillText(value,x,yCenter);
    ctx.textBaseline="alphabetic";
  }

  function ordinalReportPosition(value) {
    const n=Number(value||0);
    if(!n)return "";
    const mod100=n%100;
    if(mod100>=11&&mod100<=13)return `${n}th`;
    return `${n}${n%10===1?"st":n%10===2?"nd":n%10===3?"rd":"th"}`;
  }

  function subjectScoreBreakdown(subject) {
    const components=(subject.components||[]).filter(item=>item);
    const componentValue=item=>{
      const weighted=Number(item.weighted_score);
      if(Number.isFinite(weighted)&&weighted!==0)return weighted;
      const raw=Number(item.raw_score);
      return Number.isFinite(raw)?raw:0;
    };
    const examMatcher=/(exam|examination|final)/i;
    let examComponents=components.filter(item=>examMatcher.test(`${item.name||""} ${item.code||""}`));
    if(!examComponents.length&&components.length>1)examComponents=[components[components.length-1]];
    const examIds=new Set(examComponents.map(item=>item.component_id||item.id||item.code||item.name));
    let examScore=examComponents.reduce((sum,item)=>sum+componentValue(item),0);
    let classScore=components.filter(item=>!examIds.has(item.component_id||item.id||item.code||item.name))
      .reduce((sum,item)=>sum+componentValue(item),0);
    const total=Number(subject.total_score||0);
    if(!components.length){classScore=0;examScore=total}
    const computed=classScore+examScore;
    if(total&&Math.abs(computed-total)>.2){
      if(examScore<=total)classScore=Math.max(0,total-examScore);
      else{examScore=Math.max(0,total-classScore)}
    }
    return {classScore,examScore,total};
  }

  async function reportSubjectPositionMap(reportId) {
    if(!reportId)return new Map();
    try{
      const rows=await rpc("report_subject_positions",{target_report_id:reportId});
      return new Map((Array.isArray(rows)?rows:[]).map(item=>[
        item.subject_id,
        ordinalReportPosition(item.position)
      ]));
    }catch(error){
      await reportClientError(error,{source:"subject_positions",report_id:reportId});
      return new Map();
    }
  }

  async function resolveReportImageAssets({reportId=null,manual=false,studentPhotoPath="",className=""}={}) {
    const school=state.boot.school||{};
    const logo=await loadImage(school.logo_url?.startsWith("http")?school.logo_url:CONFIG.logoPath).catch(()=>null);
    const signer=await rpc("get_current_principal_signature")
      .catch(()=>({full_name:school.head_name||"Principal",signature_path:""}));
    let signatureImage=null,studentPhotoImage=null;
    if(signer.signature_path){
      try{signatureImage=await loadImage(await signedUrl(CONFIG.signatureBucket,signer.signature_path,900))}catch(_){signatureImage=null}
    }
    if(!manual&&studentPhotoPath){
      try{studentPhotoImage=await loadImage(await signedUrl(CONFIG.photoBucket,studentPhotoPath,900))}
      catch(error){throw new Error("The student photograph could not be loaded for the official PDF. Verify the student photo and try again.",{cause:error})}
    }
    const assignedTemplate=await resolveAssignedReportTemplate(className);
    return {logo,signer,signatureImage,studentPhotoImage,...assignedTemplate};
  }

  function reportTextLines(ctx,text,maxWidth,maxLines=3) {
    const words=String(text||"").trim().split(/\s+/).filter(Boolean),lines=[];
    let line="";
    for(const word of words){
      const test=line?`${line} ${word}`:word;
      if(line&&ctx.measureText(test).width>maxWidth){lines.push(line);line=word;if(lines.length>=maxLines)break}
      else line=test;
    }
    if(line&&lines.length<maxLines)lines.push(line);
    return lines;
  }

  function drawReportWrappedCell(ctx,text,x1,x2,y1,y2,{preferredSize=20,minimumSize=13,weight="normal",colour="#17233b",maxLines=2}={}) {
    const value=String(text??"");
    let size=preferredSize,lines=[];
    while(size>=minimumSize){
      setReportFont(ctx,size,weight);
      lines=reportTextLines(ctx,value,Math.max(10,x2-x1-16),maxLines);
      if(lines.every(line=>ctx.measureText(line).width<=x2-x1-16))break;
      size-=1;
    }
    ctx.fillStyle=colour;ctx.textBaseline="middle";
    const lineHeight=size*reportBodyFontScale()*1.08,totalHeight=lineHeight*lines.length;
    let y=y1+(y2-y1-totalHeight)/2+lineHeight/2;
    lines.forEach(line=>{ctx.fillText(line,x1+8,y);y+=lineHeight});
    ctx.textBaseline="alphabetic";
  }

  function drawReportDottedLine(ctx,x1,x2,y) {
    ctx.save();ctx.strokeStyle="#17233b";ctx.lineWidth=1.25;ctx.setLineDash([2,5]);
    ctx.beginPath();ctx.moveTo(x1,y);ctx.lineTo(x2,y);ctx.stroke();ctx.restore();
  }

  function reportDate(value) {
    const date=value?new Date(value):new Date();
    if(Number.isNaN(date.getTime()))return "";
    return date.toLocaleDateString("en-GB",{day:"2-digit",month:"2-digit",year:"numeric"});
  }

  function reportYearDigits(value) {
    const digits=String(value||"").replace(/\D/g,"");
    return digits.length>=8?digits.slice(0,8):digits||"20252026";
  }

  function reportVerificationCode(report={},templateMeta={},manual=false) {
    if(!manual&&report.report_number)return String(report.report_number);
    return `NIS-${reportYearDigits(templateMeta.academicYearName)}-00000`;
  }

  function drawInlineReportField(ctx,{label,value,x,y,maxWidth=500,align="left",fontSize=20,minimumSize=13}) {
    const labelText=String(label||""),valueText=String(value??"");
    let size=fontSize,labelWidth=0,valueWidth=0;
    while(size>=minimumSize){
      setReportFont(ctx,size,"bold");labelWidth=ctx.measureText(labelText).width;
      setReportFont(ctx,size,"normal");valueWidth=ctx.measureText(valueText).width;
      if(labelWidth+7+valueWidth<=maxWidth||size===minimumSize)break;
      size-=1;
    }
    const total=labelWidth+7+valueWidth;
    let start=x;
    if(align==="right")start=x-total;
    else if(align==="center")start=x-total/2;
    ctx.fillStyle="#17233b";
    setReportFont(ctx,size,"bold");ctx.fillText(labelText,start,y);
    setReportFont(ctx,size,"normal");ctx.fillText(valueText,start+labelWidth+7,y);
  }


  async function drawAssignedTemplateOverlay(ctx,canvas,{student={},report={},subjects=[],publication=null,manual=false,templateMeta={},assets={}}={}) {
    const school=state.boot.school||{},ink="#17233b",summaryPale="#eef4fb";
    const {logo,signer={},signatureImage,studentPhotoImage}=assets;
    const showStudentPhoto=!manual&&Boolean(studentPhotoImage);
    const tableLeft=38,tableRight=1202,tableTop=338,headerHeight=58,maximumTableBottom=1086;
    const bodyTop=tableTop+headerHeight,columns=[38,286,464,646,762,862,994,1202];
    const tableLayout=reportTableLayout(ctx,subjects,columns,bodyTop,maximumTableBottom);
    const {displaySubjects,weights,availableHeight,tableBottom}=tableLayout;
    const lowerOffset=tableBottom-maximumTableBottom,shift=y=>y+lowerOffset;

    ctx.textBaseline="alphabetic";

    // Remove all pre-filled or sample values from the uploaded design before
    // inserting the live student data. Static headings and the uploaded visual
    // design remain untouched.
    ctx.fillStyle="#ffffff";
    ctx.fillRect(38,232,1164,103);

    const identityName=manual?"....................................................................":student.full_name||"";
    const identityAdmission=manual?"NIS.......":student.admission_no||"";
    const identityClass=manual?(templateMeta.className||"Basic ........."):student.class_name||"";
    const identityYear=manual?(templateMeta.academicYearName||"................."):student.academic_year_name||"";
    const identityTerm=manual?(templateMeta.termName||"........"):student.term_name||"";
    drawInlineReportField(ctx,{label:"Name:",value:identityName,x:43,y:268,maxWidth:650,fontSize:19});
    drawInlineReportField(ctx,{label:"Admission No.:",value:identityAdmission,x:1197,y:268,maxWidth:390,align:"right",fontSize:19});
    drawInlineReportField(ctx,{label:"Class:",value:identityClass,x:43,y:323,maxWidth:360,fontSize:19});
    drawInlineReportField(ctx,{label:"Academic Year:",value:identityYear,x:620,y:323,maxWidth:410,align:"center",fontSize:19});
    drawInlineReportField(ctx,{label:"Term:",value:identityTerm,x:1197,y:323,maxWidth:300,align:"right",fontSize:19});

    if(showStudentPhoto){
      const frameX=1075,frameY=48,frameWidth=105,frameHeight=161,padding=4;
      ctx.fillStyle="#ffffff";ctx.fillRect(frameX,frameY,frameWidth,frameHeight);
      ctx.strokeStyle="rgba(255,255,255,.96)";ctx.lineWidth=2;
      ctx.strokeRect(frameX-.5,frameY-.5,frameWidth+1,frameHeight+1);
      ctx.save();
      ctx.beginPath();ctx.rect(frameX+padding,frameY+padding,frameWidth-padding*2,frameHeight-padding*2);ctx.clip();
      drawImageCover(ctx,studentPhotoImage,frameX+padding,frameY+padding,frameWidth-padding*2,frameHeight-padding*2);
      ctx.restore();
    }

    // Rebuild the data region so pre-printed subject names or sample values can
    // never show through the live report.
    ctx.fillStyle="#ffffff";
    ctx.fillRect(tableLeft-2,bodyTop+1,tableRight-tableLeft+4,1598-bodyTop);
    if(logo){
      const watermarkHeight=Math.min(390,Math.max(120,tableBottom-bodyTop-28));
      ctx.save();ctx.globalAlpha=.065;
      drawImageContain(ctx,logo,420,bodyTop+(tableBottom-bodyTop-watermarkHeight)/2,400,watermarkHeight);
      ctx.restore();
    }

    const weightTotal=weights.reduce((sum,value)=>sum+value,0);
    let rowY=bodyTop;
    const ranks=manual?new Map():await reportSubjectPositionMap(report.id);

    ctx.strokeStyle="#1d1d1d";ctx.lineWidth=1.15;
    ctx.beginPath();
    columns.forEach(x=>{ctx.moveTo(x,bodyTop);ctx.lineTo(x,tableBottom)});
    ctx.stroke();
    ctx.strokeRect(tableLeft,bodyTop,tableRight-tableLeft,tableBottom-bodyTop);

    displaySubjects.forEach((subject,index)=>{
      const rowHeight=index===displaySubjects.length-1
        ?tableBottom-rowY
        :availableHeight*(weights[index]/weightTotal);
      const nextY=rowY+rowHeight;
      ctx.strokeStyle="#1d1d1d";ctx.lineWidth=1;
      ctx.beginPath();ctx.moveTo(tableLeft,nextY);ctx.lineTo(tableRight,nextY);ctx.stroke();
      if(subject){
        const breakdown=manual
          ?{classScore:null,examScore:null,total:null}
          :subjectScoreBreakdown(subject);
        const score=value=>value===null||value===undefined?"":number(value,1);
        drawReportWrappedCell(ctx,subject.subject_name||subject.name||"",columns[0],columns[1],rowY,nextY,{
          preferredSize:20,minimumSize:13,maxLines:2,colour:ink
        });
        drawReportCellText(ctx,score(breakdown.classScore),columns[1],columns[2],(rowY+nextY)/2,{
          align:"center",preferredSize:19,minimumSize:13,colour:REPORT_RESULT_COLOURS.score
        });
        drawReportCellText(ctx,score(breakdown.examScore),columns[2],columns[3],(rowY+nextY)/2,{
          align:"center",preferredSize:19,minimumSize:13,colour:REPORT_RESULT_COLOURS.score
        });
        drawReportCellText(ctx,score(breakdown.total),columns[3],columns[4],(rowY+nextY)/2,{
          align:"center",preferredSize:19,minimumSize:13,weight:"bold",colour:REPORT_RESULT_COLOURS.total
        });
        drawReportCellText(ctx,manual?"":subject.grade||"",columns[4],columns[5],(rowY+nextY)/2,{
          align:"center",preferredSize:19,minimumSize:13,weight:"bold",colour:REPORT_RESULT_COLOURS.grade
        });
        drawReportCellText(ctx,manual?"":ranks.get(subject.subject_id)||"",columns[5],columns[6],(rowY+nextY)/2,{
          align:"center",preferredSize:18,minimumSize:12,weight:"bold",colour:REPORT_RESULT_COLOURS.position
        });
        drawReportCellText(ctx,manual?"":subject.remark||"",columns[6],columns[7],(rowY+nextY)/2,{
          preferredSize:18,minimumSize:11,colour:REPORT_RESULT_COLOURS.remark
        });
      }
      rowY=nextY;
    });

    // Rebuild the summary and signing area immediately after the final blank table row.
    ctx.fillStyle=summaryPale;
    ctx.fillRect(tableLeft,tableBottom,tableRight-tableLeft,109);
    const average=manual?"":subjects.length
      ?subjects.reduce((sum,item)=>sum+Number(item.total_score||0),0)/subjects.length
      :0;
    const position=manual
      ?{position:0,class_size:0}
      :report.id
        ?await rpc("report_position",{target_report_id:report.id}).catch(()=>({position:0,class_size:0}))
        :{position:0,class_size:0};

    ctx.fillStyle=ink;setReportFont(ctx,20,"bold");
    ctx.fillText(`Average: ${manual?"......":`${number(average,1)}%`}`,47,shift(1118));
    drawCenteredReportText(ctx,`Attendance: ${manual?".... / ....":`${report.days_present||0} / ${report.days_school_opened||0}`}`,365,850,shift(1118));
    drawRightReportText(ctx,`Overall Position: ${manual?"..../....":position.position?`${position.position} / ${position.class_size}`:".... / ...."}`,1194,shift(1118));
    ctx.fillText(`Attitude: ${manual?".................................":report.attitude||""}`,47,shift(1175));
    drawCenteredReportText(ctx,`Conduct: ${manual?"................................":report.conduct||""}`,350,860,shift(1175));
    drawRightReportText(ctx,`Interest: ${manual?".........................":report.interest||""}`,1194,shift(1175));

    ctx.fillStyle=ink;setReportFont(ctx,20,"bold");
    ctx.fillText("Class Teacher's Comment",43,shift(1219));
    [1249,1278,1307].forEach(y=>drawReportDottedLine(ctx,43,850,shift(y)));
    setReportFont(ctx,17,"normal");
    if(!manual){
      const teacherLines=reportTextLines(ctx,report.teacher_comment||"",790,3);
      [1245,1274,1303].forEach((y,index)=>{if(teacherLines[index])ctx.fillText(teacherLines[index],47,shift(y))});
    }

    setReportFont(ctx,20,"bold");ctx.fillText("Principal's Comment",43,shift(1327));
    [1357,1386].forEach(y=>drawReportDottedLine(ctx,43,650,shift(y)));
    setReportFont(ctx,17,"normal");
    if(!manual){
      const principalLines=reportTextLines(ctx,report.head_comment||"",590,2);
      [1353,1382].forEach((y,index)=>{if(principalLines[index])ctx.fillText(principalLines[index],47,shift(y))});
    }

    const promotedName=(state.boot.classes||[]).find(item=>item.id===report.promoted_to_class_id)?.name||"";
    setReportFont(ctx,20,"bold");
    ctx.fillText(`Promoted To ${manual?"Basic.........":promotedName||"Basic........."}`,43,shift(1422));

    const base=school.verification_base_url||school.website||`${location.origin}${location.pathname}`;
    const qrText=manual?base:`${base}${base.includes("?")?"&":"?"}verify=${publication?.verification_token||""}`;
    const qr=await qrCanvas(qrText);
    if(qr)ctx.drawImage(qr,949,shift(1210),190,190);

    const verificationCode=reportVerificationCode(report,templateMeta,manual);
    ctx.fillStyle="#5f708b";setReportFont(ctx,16,"normal");
    const verificationText=`Verification: ${verificationCode}`;
    if(ctx.measureText(verificationText).width<=290){
      drawCenteredReportText(ctx,verificationText,900,1190,shift(1430));
    }else{
      const splitAt=verificationCode.lastIndexOf("-");
      const first=splitAt>0?`Verification: ${verificationCode.slice(0,splitAt+1)}`:"Verification:";
      const second=splitAt>0?verificationCode.slice(splitAt+1):verificationCode;
      drawCenteredReportText(ctx,first,900,1190,shift(1424));
      drawCenteredReportText(ctx,second,900,1190,shift(1447));
    }

    const signatureLeft=515,signatureRight=865,signatureTop=shift(1370);
    if(signatureImage)drawImageContain(ctx,signatureImage,555,signatureTop,270,100);
    ctx.strokeStyle="#5f708b";ctx.lineWidth=1.2;
    ctx.beginPath();ctx.moveTo(signatureLeft,shift(1485));ctx.lineTo(signatureRight,shift(1485));ctx.stroke();
    ctx.fillStyle=ink;setReportFont(ctx,18,"bold");
    drawCenteredReportText(ctx,signer.full_name||school.head_name||"Principal",signatureLeft,signatureRight,shift(1512));
    ctx.fillStyle="#5f708b";setReportFont(ctx,16,"normal");
    drawCenteredReportText(ctx,"Digitally signed by the Principal",signatureLeft,signatureRight,shift(1538));

    const reportCode=reportVerificationCode(report,templateMeta,manual);
    ctx.fillStyle="#5f708b";setReportFont(ctx,16,"normal");
    ctx.fillText(`Report No.: ${reportCode}${manual?"...":""}`,43,shift(1572));
    const manualYear=(String(templateMeta.academicYearName||"").match(/\d{4}\s*$/)||[])[0]||String(new Date().getFullYear());
    drawRightReportText(ctx,manual
      ?`Date Issued: .../.../${manualYear}`
      :`Date Issued: ${reportDate(publication?.published_at||new Date())}`,1197,shift(1572));

    return canvas;
  }

  async function drawPreferredTerminalReport({
    student={},report={},subjects=[],publication=null,manual=false,templateMeta={},assets={}
  }) {
    await ensureReportBodyFontReady();
    const canvas=document.createElement("canvas");
    canvas.width=1240;canvas.height=1754;
    const ctx=canvas.getContext("2d"),school=state.boot.school||{};
    const navy="#123a79",accent="#f79646",headerPale="#dce8f6",summaryPale="#eef4fb",ink="#17233b";
    const {logo,signer={},signatureImage,studentPhotoImage}=assets;
    const showStudentPhoto=!manual&&Boolean(studentPhotoImage);

    ctx.fillStyle="#ffffff";ctx.fillRect(0,0,canvas.width,canvas.height);
    if(assets.templateBackground){
      drawImageContain(ctx,assets.templateBackground,0,0,canvas.width,canvas.height);
      return drawAssignedTemplateOverlay(ctx,canvas,{student,report,subjects,publication,manual,templateMeta,assets});
    }

    // Header, proportioned to the approved Nipe terminal-report template.
    ctx.fillStyle=navy;ctx.fillRect(38,29,1164,199);
    if(logo)drawImageContain(ctx,logo,57,58,140,145);
    const headerTextRight=showStudentPhoto?1057:1202;
    ctx.fillStyle="#ffffff";
    const schoolName=schoolDisplayName(school).toUpperCase();
    const titleSize=fitReportText(ctx,schoolName,headerTextRight-225,36,24,"bold");
    setReportFont(ctx,titleSize,"bold");drawCenteredReportText(ctx,schoolName,205,headerTextRight,79);
    setReportFont(ctx,16,"normal");drawCenteredReportText(ctx,school.motto||"Discipline, Commitment, Excellence",205,headerTextRight,108);
    drawCenteredReportText(ctx,school.address||"Santeo, Cedar Estate",205,headerTextRight,132);
    drawCenteredReportText(ctx,school.phone||"(+233) 559671336 / (+233) 241397124",205,headerTextRight,156);
    setReportFont(ctx,27,"bold");drawCenteredReportText(ctx,school.report_title||"Student Terminal Report",205,headerTextRight,209);
    if(showStudentPhoto){
      const frameX=1075,frameY=48,frameWidth=105,frameHeight=161,padding=4;
      ctx.fillStyle="#ffffff";ctx.fillRect(frameX,frameY,frameWidth,frameHeight);
      ctx.strokeStyle="rgba(255,255,255,.95)";ctx.lineWidth=2;ctx.strokeRect(frameX-.5,frameY-.5,frameWidth+1,frameHeight+1);
      ctx.save();ctx.beginPath();ctx.rect(frameX+padding,frameY+padding,frameWidth-padding*2,frameHeight-padding*2);ctx.clip();
      drawImageCover(ctx,studentPhotoImage,frameX+padding,frameY+padding,frameWidth-padding*2,frameHeight-padding*2);ctx.restore();
    }

    const identityName=manual?"....................................................................":student.full_name||"";
    const identityAdmission=manual?"NIS.......":student.admission_no||"";
    const identityClass=manual?(templateMeta.className||"Basic ........."):student.class_name||"";
    const identityYear=manual?(templateMeta.academicYearName||"................."):student.academic_year_name||"";
    const identityTerm=manual?(templateMeta.termName||"........"):student.term_name||"";
    drawInlineReportField(ctx,{label:"Name:",value:identityName,x:43,y:268,maxWidth:650,fontSize:19});
    drawInlineReportField(ctx,{label:"Admission No.:",value:identityAdmission,x:1197,y:268,maxWidth:390,align:"right",fontSize:19});
    drawInlineReportField(ctx,{label:"Class:",value:identityClass,x:43,y:323,maxWidth:360,fontSize:19});
    drawInlineReportField(ctx,{label:"Academic Year:",value:identityYear,x:620,y:323,maxWidth:410,align:"center",fontSize:19});
    drawInlineReportField(ctx,{label:"Term:",value:identityTerm,x:1197,y:323,maxWidth:300,align:"right",fontSize:19});

    const tableLeft=38,tableRight=1202,tableTop=338,headerHeight=58,maximumTableBottom=1086;
    const columns=[38,286,464,646,762,862,994,1202];
    const labels=["SUBJECT","CLASS SCORE","EXAMS SCORE","TOTAL","GRADE","POSITION","REMARKS"];
    const bodyTop=tableTop+headerHeight,tableLayout=reportTableLayout(ctx,subjects,columns,bodyTop,maximumTableBottom);
    const {displaySubjects,weights,availableHeight,tableBottom}=tableLayout;
    const lowerOffset=tableBottom-maximumTableBottom,shift=y=>y+lowerOffset;

    // Watermark remains behind the compact subject table only.
    if(logo){
      const watermarkHeight=Math.min(390,Math.max(120,tableBottom-bodyTop-28));
      ctx.save();ctx.globalAlpha=.065;drawImageContain(ctx,logo,420,bodyTop+(tableBottom-bodyTop-watermarkHeight)/2,400,watermarkHeight);ctx.restore();
    }

    ctx.fillStyle=headerPale;ctx.fillRect(tableLeft,tableTop,tableRight-tableLeft,headerHeight);
    ctx.strokeStyle="#1d1d1d";ctx.lineWidth=1.25;ctx.strokeRect(tableLeft,tableTop,tableRight-tableLeft,tableBottom-tableTop);
    columns.slice(1,-1).forEach(x=>{ctx.beginPath();ctx.moveTo(x,tableTop);ctx.lineTo(x,tableBottom);ctx.stroke()});
    setReportFont(ctx,19,"bold");ctx.fillStyle=ink;ctx.textBaseline="middle";
    labels.forEach((label,index)=>drawCenteredReportText(ctx,label,columns[index],columns[index+1],tableTop+headerHeight/2+1));
    ctx.textBaseline="alphabetic";

    setReportFont(ctx,20,"normal");
    const weightTotal=weights.reduce((sum,value)=>sum+value,0);
    let rowY=bodyTop;
    const ranks=manual?new Map():await reportSubjectPositionMap(report.id);
    displaySubjects.forEach((subject,index)=>{
      const rowHeight=index===displaySubjects.length-1?tableBottom-rowY:availableHeight*(weights[index]/weightTotal);
      const nextY=rowY+rowHeight;
      ctx.strokeStyle="#1d1d1d";ctx.lineWidth=1;
      ctx.beginPath();ctx.moveTo(tableLeft,nextY);ctx.lineTo(tableRight,nextY);ctx.stroke();
      if(subject){
        const breakdown=manual?{classScore:null,examScore:null,total:null}:subjectScoreBreakdown(subject);
        const score=value=>value===null||value===undefined?"":number(value,1);
        drawReportWrappedCell(ctx,subject.subject_name||subject.name||"",columns[0],columns[1],rowY,nextY,{preferredSize:20,minimumSize:13,maxLines:2});
        drawReportCellText(ctx,score(breakdown.classScore),columns[1],columns[2],(rowY+nextY)/2,{align:"center",preferredSize:19,minimumSize:13,colour:REPORT_RESULT_COLOURS.score});
        drawReportCellText(ctx,score(breakdown.examScore),columns[2],columns[3],(rowY+nextY)/2,{align:"center",preferredSize:19,minimumSize:13,colour:REPORT_RESULT_COLOURS.score});
        drawReportCellText(ctx,score(breakdown.total),columns[3],columns[4],(rowY+nextY)/2,{align:"center",preferredSize:19,minimumSize:13,weight:"bold",colour:REPORT_RESULT_COLOURS.total});
        drawReportCellText(ctx,manual?"":subject.grade||"",columns[4],columns[5],(rowY+nextY)/2,{align:"center",preferredSize:19,minimumSize:13,weight:"bold",colour:REPORT_RESULT_COLOURS.grade});
        drawReportCellText(ctx,manual?"":ranks.get(subject.subject_id)||"",columns[5],columns[6],(rowY+nextY)/2,{align:"center",preferredSize:18,minimumSize:12,weight:"bold",colour:REPORT_RESULT_COLOURS.position});
        drawReportCellText(ctx,manual?"":subject.remark||"",columns[6],columns[7],(rowY+nextY)/2,{preferredSize:18,minimumSize:11,colour:REPORT_RESULT_COLOURS.remark});
      }
      rowY=nextY;
    });

    // Summary and signing fields follow immediately after the single retained blank row.
    ctx.fillStyle=summaryPale;ctx.fillRect(tableLeft,tableBottom,tableRight-tableLeft,109);
    const average=manual?"":subjects.length?subjects.reduce((sum,item)=>sum+Number(item.total_score||0),0)/subjects.length:0;
    const position=manual?{position:0,class_size:0}:report.id
      ?await rpc("report_position",{target_report_id:report.id}).catch(()=>({position:0,class_size:0}))
      :{position:0,class_size:0};
    ctx.fillStyle=ink;setReportFont(ctx,20,"bold");
    ctx.fillText(`Average: ${manual?"......":`${number(average,1)}%`}`,47,shift(1118));
    drawCenteredReportText(ctx,`Attendance: ${manual?".... / ....":`${report.days_present||0} / ${report.days_school_opened||0}`}`,365,850,shift(1118));
    drawRightReportText(ctx,`Overall Position: ${manual?"..../....":position.position?`${position.position} / ${position.class_size}`:".... / ...."}`,1194,shift(1118));
    ctx.fillText(`Attitude: ${manual?".................................":report.attitude||""}`,47,shift(1175));
    drawCenteredReportText(ctx,`Conduct: ${manual?"................................":report.conduct||""}`,350,860,shift(1175));
    drawRightReportText(ctx,`Interest: ${manual?".........................":report.interest||""}`,1194,shift(1175));

    ctx.fillStyle=ink;setReportFont(ctx,20,"bold");ctx.fillText("Class Teacher's Comment",43,shift(1219));
    [1249,1278,1307].forEach(y=>drawReportDottedLine(ctx,43,850,shift(y)));
    setReportFont(ctx,17,"normal");ctx.fillStyle=ink;
    if(!manual){
      const lines=reportTextLines(ctx,report.teacher_comment||"",790,3);
      [1245,1274,1303].forEach((y,index)=>{if(lines[index])ctx.fillText(lines[index],47,shift(y))});
    }
    setReportFont(ctx,20,"bold");ctx.fillText("Principal's Comment",43,shift(1327));
    [1357,1386].forEach(y=>drawReportDottedLine(ctx,43,650,shift(y)));
    setReportFont(ctx,17,"normal");
    if(!manual){
      const lines=reportTextLines(ctx,report.head_comment||"",590,2);
      [1353,1382].forEach((y,index)=>{if(lines[index])ctx.fillText(lines[index],47,shift(y))});
    }
    const promotedName=(state.boot.classes||[]).find(item=>item.id===report.promoted_to_class_id)?.name||"";
    setReportFont(ctx,20,"bold");ctx.fillText(`Promoted To ${manual?"Basic.........":promotedName||"Basic........."}`,43,shift(1422));

    const base=school.verification_base_url||school.website||`${location.origin}${location.pathname}`;
    const qrText=manual?base:`${base}${base.includes("?")?"&":"?"}verify=${publication?.verification_token||""}`;
    const qr=await qrCanvas(qrText);
    if(qr)ctx.drawImage(qr,949,shift(1210),190,190);
    const verificationCode=reportVerificationCode(report,templateMeta,manual);
    ctx.fillStyle="#5f708b";setReportFont(ctx,16,"normal");
    const verificationText=`Verification: ${verificationCode}`;
    if(ctx.measureText(verificationText).width<=290)drawCenteredReportText(ctx,verificationText,900,1190,shift(1430));
    else{
      const splitAt=verificationCode.lastIndexOf("-");
      const first=splitAt>0?`Verification: ${verificationCode.slice(0,splitAt+1)}`:"Verification:";
      const second=splitAt>0?verificationCode.slice(splitAt+1):verificationCode;
      drawCenteredReportText(ctx,first,900,1190,shift(1424));
      drawCenteredReportText(ctx,second,900,1190,shift(1447));
    }

    const signatureLeft=515,signatureRight=865,signatureTop=shift(1370);
    if(signatureImage)drawImageContain(ctx,signatureImage,555,signatureTop,270,100);
    ctx.strokeStyle="#5f708b";ctx.lineWidth=1.2;ctx.beginPath();ctx.moveTo(signatureLeft,shift(1485));ctx.lineTo(signatureRight,shift(1485));ctx.stroke();
    ctx.fillStyle=ink;setReportFont(ctx,18,"bold");drawCenteredReportText(ctx,signer.full_name||school.head_name||"Principal",signatureLeft,signatureRight,shift(1512));
    ctx.fillStyle="#5f708b";setReportFont(ctx,16,"normal");drawCenteredReportText(ctx,"Digitally signed by the Principal",signatureLeft,signatureRight,shift(1538));

    const reportCode=reportVerificationCode(report,templateMeta,manual);
    ctx.fillStyle="#5f708b";setReportFont(ctx,16,"normal");
    ctx.fillText(`Report No.: ${reportCode}${manual?"...":""}`,43,shift(1572));
    const manualYear=(String(templateMeta.academicYearName||"").match(/\d{4}\s*$/)||[])[0]||String(new Date().getFullYear());
    drawRightReportText(ctx,manual?`Date Issued: .../.../${manualYear}`:`Date Issued: ${reportDate(publication?.published_at||new Date())}`,1197,shift(1572));
    ctx.fillStyle=accent;ctx.fillRect(38,1603,1164,7);
    ctx.fillStyle="#111111";setReportFont(ctx,17,"bold","italic");
    drawCenteredReportText(ctx,"N.B.: Any Alteration, Cancellation or Erasing of any part of this report renders it void",38,1202,1654);
    ctx.fillStyle=navy;ctx.fillRect(38,1671,1164,5);

    return canvas;
  }

  async function createReportPdf(editor,publication) {
    const assets=await resolveReportImageAssets({
      reportId:editor.report?.id||null,manual:false,studentPhotoPath:editor.student?.photo_url||"",className:editor.student?.class_name||""
    });
    const canvas=await drawPreferredTerminalReport({
      student:editor.student||{},report:editor.report||{},subjects:editor.subjects||[],publication,manual:false,assets
    });
    const jpeg=await new Promise(resolve=>canvas.toBlob(resolve,"image/jpeg",.97));
    return imagePdf(jpeg,595.28,841.89);
  }

  async function createManualReportTemplatePdf({academicYearName="",termName="",className="",subjects=[]}={}) {
    const assets=await resolveReportImageAssets({manual:true,className});
    const templateSubjects=subjects.map(subject=>({
      subject_id:subject.id,subject_name:subject.name,subject_code:subject.code,total_score:null,grade:"",remark:"",components:[]
    }));
    const canvas=await drawPreferredTerminalReport({
      student:{},report:{days_present:null,days_school_opened:null,attitude:"",conduct:"",interest:"",teacher_comment:"",head_comment:""},
      subjects:templateSubjects,publication:null,manual:true,templateMeta:{academicYearName,termName,className},assets
    });
    const jpeg=await new Promise(resolve=>canvas.toBlob(resolve,"image/jpeg",.97));
    return imagePdf(jpeg,595.28,841.89);
  }

  async function imagePdf(jpegBlob,pageWidth,pageHeight) {
    const jpeg=new Uint8Array(await jpegBlob.arrayBuffer()),parts=[],offsets=[0];let length=0;
    const add=value=>{const bytes=typeof value==="string"?new TextEncoder().encode(value):value;parts.push(bytes);length+=bytes.length};
    add("%PDF-1.4\n%\xFF\xFF\xFF\xFF\n");
    const object=(id,body)=>{offsets[id]=length;add(`${id} 0 obj\n${body}\nendobj\n`)};
    object(1,"<< /Type /Catalog /Pages 2 0 R >>");
    object(2,"<< /Type /Pages /Kids [3 0 R] /Count 1 >>");
    object(3,`<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${pageWidth} ${pageHeight}] /Resources << /XObject << /Im0 4 0 R >> >> /Contents 5 0 R >>`);
    offsets[4]=length;add(`4 0 obj\n<< /Type /XObject /Subtype /Image /Width 1240 /Height 1754 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length ${jpeg.length} >>\nstream\n`);add(jpeg);add("\nendstream\nendobj\n");
    const content=`q\n${pageWidth} 0 0 ${pageHeight} 0 0 cm\n/Im0 Do\nQ`;
    object(5,`<< /Length ${content.length} >>\nstream\n${content}\nendstream`);
    const xref=length;add("xref\n0 6\n0000000000 65535 f \n");
    for(let i=1;i<=5;i++)add(`${String(offsets[i]).padStart(10,"0")} 00000 n \n`);
    add(`trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF`);
    return new Blob(parts,{type:"application/pdf"});
  }


  async function renderChildren(token) {
    const data=await rpc("list_my_children_reports");
    if(token!==state.viewToken)return;
    const children=data.children||[];
    byId("content").innerHTML=`
      <div class="page-head"><div><h3>My Children</h3><p>Published report cards available for viewing and PDF download</p></div></div>
      <div class="grid ${children.length>1?"two":""}" id="childrenGrid">
        ${children.length?children.map(child=>`<section class="panel">
          <div class="panel-header"><div class="cell-copy"><strong>${esc(child.full_name)}</strong><small>${esc(child.admission_no)} • ${esc(child.class_name||"")}</small></div></div>
          <div class="panel-body">${(child.reports||[]).length?(child.reports||[]).map(report=>`<div class="diff-row"><span><strong>${esc(report.term_name)}</strong><br><small>${esc(report.academic_year_name)} • ${number(report.average,1)}%</small></span>
            <div class="button-row"><button class="button outline small" data-child-report="${attr(report.id)}">View report</button>${report.publication?`<button class="button secondary small" data-child-pdf="${attr(report.id)}">Download latest PDF</button>`:""}</div></div>`).join(""):`<div class="empty"><strong>No published reports</strong></div>`}</div>
        </section>`).join(""):`<section class="panel pad empty"><strong>No linked student report records</strong><span>Ask the System Administrator to verify the parent-student link.</span></section>`}
      </div>`;
    $$('[data-child-report]').forEach(button=>button.onclick=()=>openReportEditor(button.dataset.childReport));
    $$('[data-child-pdf]').forEach(button=>button.onclick=()=>downloadLatestOfficialPdf(button.dataset.childPdf));
  }

  async function renderTeachers(token) {
    byId("content").innerHTML=`
      <div class="page-head"><div><h3>Teacher Directory</h3><p>Staff records, accounts, classes, and subjects</p></div>
        <div class="page-actions"><button class="button outline" id="teacherExport">Export CSV</button><button class="button primary" id="teacherAdd">Add teacher</button></div></div>
      <section class="panel">
        <div class="toolbar">
          <label class="search"><input id="teacherSearch" type="search" placeholder="Search teacher or staff number"></label>
          <select id="teacherStatus"><option value="">All statuses</option><option value="active">Active</option><option value="leave">On leave</option><option value="suspended">Suspended</option><option value="resigned">Resigned</option><option value="retired">Retired</option></select>
          <select id="teacherArchive"><option value="active">Current records</option><option value="archived">Archived records</option><option value="all">All records</option></select>
        </div>
        <div id="teacherResults"><div class="empty">Loading teachers</div></div>
      </section>`;
    byId("teacherAdd").onclick=()=>openTeacherEditor();
    byId("teacherExport").onclick=exportTeachersCsv;
    let timer;
    byId("teacherSearch").oninput=()=>{clearTimeout(timer);timer=setTimeout(()=>{state.teacherPage=1;loadTeacherPage(token)},250)};
    byId("teacherStatus").onchange=()=>{state.teacherPage=1;loadTeacherPage(token)};
    byId("teacherArchive").onchange=()=>{state.teacherPage=1;loadTeacherPage(token)};
    await loadTeacherPage(token);
  }
  async function loadTeacherPage(token=state.viewToken) {
    const root=byId("teacherResults");if(!root)return;
    root.innerHTML=`<div class="empty">Loading teachers</div>`;
    const data=await rpc("list_teachers",{
      search_text:byId("teacherSearch")?.value.trim()||"",
      status_filter:byId("teacherStatus")?.value||"",
      archive_filter:byId("teacherArchive")?.value||"active",
      page_number:state.teacherPage,page_size:CONFIG.pageSize
    });
    if(token!==state.viewToken||!byId("teacherResults"))return;
    state.teacherAdmin=data;
    const rows=data.rows||[];
    root.innerHTML=rows.length?`<div class="table-wrap"><table><thead><tr><th>Teacher</th><th>Staff No.</th><th>Contact</th><th>Qualification</th><th>Assignments</th><th>Status</th><th></th></tr></thead><tbody>
      ${rows.map(row=>`<tr>
        <td><div class="cell-main"><span class="avatar small-avatar">${esc((row.first_name||"T").charAt(0).toUpperCase())}</span><div class="cell-copy"><strong>${esc(row.full_name)}</strong><small>${esc(row.profile_email||row.email||"No linked account")}</small></div></div></td>
        <td>${esc(row.staff_no)}</td><td><div class="cell-copy"><span>${esc(row.phone||"—")}</span><small>${esc(row.email||"")}</small></div></td>
        <td><div class="cell-copy"><span>${esc(row.qualification||"—")}</span><small>${esc(row.specialization||"")}</small></div></td>
        <td><div class="chip-list"><span class="chip">${number((row.class_assignments||[]).length)} classes</span><span class="chip">${number((row.subject_assignments||[]).length)} subjects</span></div></td>
        <td>${statusBadge(row.deleted_at?"archived":row.employment_status)}</td>
        <td><div class="table-actions"><button class="button secondary small" data-teacher-view="${attr(row.id)}">View</button>
          ${!row.deleted_at?`<button class="button ghost small" data-teacher-edit="${attr(row.id)}">Edit</button><button class="button danger small" data-teacher-archive="${attr(row.id)}">Remove</button>`:
          `<button class="button success small" data-teacher-restore="${attr(row.id)}">Restore</button>`}
        </div></td></tr>`).join("")}</tbody></table></div>${pagination(data.total,data.page,data.page_size,"teacher")}`:
      `<div class="empty"><strong>No teachers found</strong></div>`;
    $$("[data-teacher-view]",root).forEach(button=>button.onclick=()=>openTeacherRecord(button.dataset.teacherView));
    $$("[data-teacher-edit]",root).forEach(button=>button.onclick=()=>openTeacherEditor(button.dataset.teacherEdit));
    $$("[data-teacher-archive]",root).forEach(button=>button.onclick=()=>archiveTeacher(button.dataset.teacherArchive));
    $$("[data-teacher-restore]",root).forEach(button=>button.onclick=()=>restoreTeacher(button.dataset.teacherRestore));
    bindPagination("teacher",data);
  }
  async function openTeacherRecord(id) {
    const data=await rpc("get_teacher_record",{target_teacher_id:id});
    const t=data.teacher||{};
    modal(t.full_name||"Teacher",t.staff_no||"",`
      <div class="grid two">
        <section class="panel pad"><div class="metric"><span>Employment status</span><strong>${esc(t.employment_status||"—")}</strong></div>
          <div class="metric"><span>Telephone</span><strong>${esc(t.phone||"—")}</strong></div>
          <div class="metric"><span>Email</span><strong>${esc(t.email||"—")}</strong></div>
          <div class="metric"><span>Qualification</span><strong>${esc(t.qualification||"—")}</strong></div>
          <div class="metric"><span>Specialization</span><strong>${esc(t.specialization||"—")}</strong></div>
          <div class="metric"><span>Linked account</span><strong>${esc(t.profile_email||"—")}</strong></div></section>
        <section class="panel pad"><div class="section-title"><h4>Assignments</h4></div>
          ${(data.classes||[]).map(item=>`<div class="diff-row"><span>Class teacher</span><b>${esc(item.name)}</b></div>`).join("")}
          ${(data.subjects||[]).map(item=>`<div class="diff-row"><span>${esc(item.class_name)}</span><b>${esc(item.subject_name)}</b></div>`).join("")}
          ${!(data.classes||[]).length&&!(data.subjects||[]).length?`<div class="empty"><strong>No active assignments</strong></div>`:""}
        </section>
      </div>`,t.deleted_at?`<button class="button success" id="teacherRecordRestore" type="button">Restore teacher</button>`:
      `<button class="button primary" id="teacherRecordEdit" type="button">Edit teacher</button><button class="button danger" id="teacherRecordArchive" type="button">Remove teacher</button>`,"wide");
    byId("teacherRecordEdit")?.addEventListener("click",()=>{closeModal();openTeacherEditor(id)});
    byId("teacherRecordArchive")?.addEventListener("click",()=>{closeModal();archiveTeacher(id)});
    byId("teacherRecordRestore")?.addEventListener("click",()=>{closeModal();restoreTeacher(id)});
  }
  async function openTeacherEditor(id=null) {
    let row={gender:"Other",employment_status:"active",active:true};
    if(id){const data=await rpc("get_teacher_record",{target_teacher_id:id});row=data.teacher||row}
    else {try{row.staff_no=await rpc("generate_school_identifier",{identifier_kind:"teacher"})}catch(_){row.staff_no=""}}
    const profiles=(state.teacherAdmin?.profiles||[]).filter(profile=>["class_teacher","subject_teacher"].includes(profile.role)||profile.id===row.profile_id);
    modal(id?"Edit Teacher":"Add Teacher",row.staff_no||"",`<form id="teacherForm" class="form-stack">
      <input type="hidden" name="id" value="${attr(row.id||"")}">
      <input type="hidden" name="updated_at" value="${attr(row.updated_at||"")}">
      <div class="form-grid three">
        <label class="field"><span>Staff number</span><input name="staff_no" value="${attr(row.staff_no||"")}" readonly></label>
        <label class="field"><span>First name</span><input name="first_name" value="${attr(row.first_name||"")}" required></label>
        <label class="field"><span>Middle name</span><input name="middle_name" value="${attr(row.middle_name||"")}"></label>
        <label class="field"><span>Last name</span><input name="last_name" value="${attr(row.last_name||"")}" required></label>
        <label class="field"><span>Gender</span><select name="gender">${["Male","Female","Other"].map(v=>`<option value="${v}" ${v===row.gender?"selected":""}>${v}</option>`).join("")}</select></label>
        <label class="field"><span>Date joined</span><input type="date" name="date_joined" value="${attr(row.date_joined||"")}"></label>
        <label class="field"><span>Telephone</span><input name="phone" value="${attr(row.phone||"")}"></label>
        <label class="field"><span>Email</span><input type="email" name="email" value="${attr(row.email||"")}"></label>
        <label class="field"><span>Employment status</span><select name="employment_status">${["active","leave","suspended","resigned","retired"].map(v=>`<option value="${v}" ${v===row.employment_status?"selected":""}>${v.replaceAll("_"," ")}</option>`).join("")}</select></label>
        <label class="field"><span>Qualification</span><input name="qualification" value="${attr(row.qualification||"")}"></label>
        <label class="field"><span>Specialization</span><input name="specialization" value="${attr(row.specialization||"")}"></label>
        <label class="field"><span>Linked user account</span><select name="profile_id">${optionList(profiles,"id","full_name",row.profile_id,"No linked account")}</select></label>
        <label class="field full"><span>Address</span><input name="address" value="${attr(row.address||"")}"></label>
        <label class="field full"><span>Notes</span><textarea name="notes">${esc(row.notes||"")}</textarea></label>
        <label class="check-field full"><input type="checkbox" name="active" ${row.active!==false?"checked":""}><span>Active teacher</span></label>
      </div>
    </form>`,`<button class="button ghost" id="teacherCancel" type="button">Cancel</button><button class="button primary" id="teacherSave" type="submit" form="teacherForm">Save teacher</button>`,"wide");
    byId("teacherCancel").onclick=closeModal;
    byId("teacherForm").addEventListener("submit",event=>{event.preventDefault();saveTeacher()});
  }
  async function saveTeacher() {
    const form=byId("teacherForm"),button=byId("teacherSave");if(!form?.reportValidity()){toast("Teacher not saved","Complete the required teacher fields.","error");return}
    const v=formObject(form);button.disabled=true;button.textContent="Saving";let saved=false;
    try{
      await rpc("save_teacher",{payload:{...v,active:form.elements.active.checked,reason:v.id?"Teacher record updated":"Teacher record created"}});
      saved=true;state.workspace=null;closeModal();toast("Teacher record saved");
      try{state.boot=await rpc("get_bootstrap_data");renderBrand();renderNav();await loadTeacherPage()}
      catch(refreshError){await reportClientError(refreshError,{source:"teacher_save",stage:"refresh"});toast("Teacher saved","Reload the page to display the latest record.","warning",6500)}
    }catch(error){await reportClientError(error,{source:"teacher_save",stage:saved?"refresh":"record"});toast(saved?"Teacher saved":"Teacher not saved",saved?"Reload the page to display the latest record.":friendlyError(error),saved?"warning":"error",6500)}finally{button.disabled=false;button.textContent="Save teacher"}
  }
  async function archiveTeacher(id) {
    const ok=await confirmAction("Remove Teacher","The staff record will be archived and active class assignments will be cleared.","Remove",true);if(!ok)return;
    try{await rpc("archive_teacher",{target_teacher_id:id,reason_text:"Teacher removed from active records"});state.workspace=null;toast("Teacher removed");await loadTeacherPage()}
    catch(error){toast("Teacher not removed",friendlyError(error),"error")}
  }
  async function restoreTeacher(id) {
    const ok=await confirmAction("Restore Teacher","The staff record will return to the teacher directory.","Restore");if(!ok)return;
    try{await rpc("restore_teacher",{target_teacher_id:id,reason_text:"Teacher restored to active records"});state.workspace=null;toast("Teacher restored");await loadTeacherPage()}
    catch(error){toast("Teacher not restored",friendlyError(error),"error")}
  }
  async function exportTeachersCsv() {
    const data=await rpc("list_teachers",{search_text:byId("teacherSearch")?.value||"",status_filter:byId("teacherStatus")?.value||"",archive_filter:byId("teacherArchive")?.value||"active",page_number:1,page_size:100});
    const headers=["staff_no","first_name","middle_name","last_name","gender","phone","email","qualification","specialization","date_joined","employment_status"];
    downloadText("teachers.csv",[headers.join(","),...(data.rows||[]).map(row=>headers.map(h=>csvCell(row[h])).join(","))].join("\n"),"text/csv");
  }


  async function renderPrincipals(token) {
    byId("content").innerHTML=`
      <div class="page-head"><div><h3>Principal Directory</h3><p>Principal names, contacts, linked accounts, and digital signing</p></div>
        <div class="page-actions"><button class="button outline" id="headteacherExport">Export CSV</button><button class="button primary" id="headteacherAdd">Add principal</button></div></div>
      <section class="panel"><div class="toolbar">
        <label class="search"><input id="headteacherSearch" type="search" placeholder="Search full name, contact or staff number"></label>
        <select id="headteacherArchive"><option value="active">Current records</option><option value="archived">Removed records</option><option value="all">All records</option></select>
      </div><div id="headteacherResults"><div class="empty">Loading principals</div></div></section>`;
    byId("headteacherAdd").onclick=()=>openPrincipalEditor();byId("headteacherExport").onclick=exportPrincipalsCsv;let timer;
    byId("headteacherSearch").oninput=()=>{clearTimeout(timer);timer=setTimeout(()=>{state.headteacherPage=1;loadPrincipalPage(token)},250)};
    byId("headteacherArchive").onchange=()=>{state.headteacherPage=1;loadPrincipalPage(token)};await loadPrincipalPage(token);
  }
  async function loadPrincipalPage(token=state.viewToken) {
    const root=byId("headteacherResults");if(!root)return;root.innerHTML=`<div class="empty">Loading principals</div>`;
    const data=await rpc("list_headteachers",{search_text:byId("headteacherSearch")?.value.trim()||"",status_filter:"",archive_filter:byId("headteacherArchive")?.value||"active",page_number:state.headteacherPage,page_size:CONFIG.pageSize});
    if(token!==state.viewToken||!byId("headteacherResults"))return;state.headteacherAdmin=data;const rows=data.rows||[];
    root.innerHTML=rows.length?`<div class="table-wrap"><table><thead><tr><th>Principal</th><th>Contact</th><th>Linked Account</th><th>Signature</th><th>Status</th><th></th></tr></thead><tbody>
      ${rows.map(row=>`<tr><td><div class="cell-main"><span class="avatar small-avatar">${esc((row.full_name||"H").charAt(0).toUpperCase())}</span><div class="cell-copy"><strong>${esc(row.full_name)}</strong></div></div></td>
        <td>${esc(row.phone||"—")}</td><td>${esc(row.profile_email||"Not linked")}</td><td>${row.signature_path?`<span class="status published">Uploaded</span>`:`<span class="status draft">Not uploaded</span>`}</td>
        <td>${statusBadge(row.deleted_at?"archived":"active")}</td><td><div class="table-actions"><button class="button secondary small" data-headteacher-view="${attr(row.id)}">View</button>
          ${!row.deleted_at?`<button class="button ghost small" data-headteacher-edit="${attr(row.id)}">Edit</button><button class="button danger small" data-headteacher-archive="${attr(row.id)}">Remove</button>`:`<button class="button success small" data-headteacher-restore="${attr(row.id)}">Restore</button>`}</div></td></tr>`).join("")}</tbody></table></div>${pagination(data.total,data.page,data.page_size,"principal")}`:`<div class="empty"><strong>No principals found</strong></div>`;
    $$('[data-headteacher-view]',root).forEach(button=>button.onclick=()=>openPrincipalRecord(button.dataset.headteacherView));
    $$('[data-headteacher-edit]',root).forEach(button=>button.onclick=()=>openPrincipalEditor(button.dataset.headteacherEdit));
    $$('[data-headteacher-archive]',root).forEach(button=>button.onclick=()=>archivePrincipal(button.dataset.headteacherArchive));
    $$('[data-headteacher-restore]',root).forEach(button=>button.onclick=()=>restorePrincipal(button.dataset.headteacherRestore));bindPagination("principal",data);
  }
  async function openPrincipalRecord(id) {
    const data=await rpc("get_headteacher_record",{target_headteacher_id:id}),h=data.headteacher||{};
    modal(h.full_name||"Principal","",`<div class="grid two"><section class="panel pad"><div class="metric"><span>Full name</span><strong>${esc(h.full_name||"—")}</strong></div><div class="metric"><span>Contact</span><strong>${esc(h.phone||"—")}</strong></div><div class="metric"><span>Linked account</span><strong>${esc(h.profile_email||"Not linked")}</strong></div></section>
      <section class="panel pad"><div class="metric"><span>Digital signature</span><strong>${h.signature_path?"Uploaded":"Not uploaded"}</strong></div><p class="muted">The linked Principal uploads and manages the signature from the Principal Dashboard.</p></section></div>`,h.deleted_at?`<button class="button success" id="headteacherRecordRestore" type="button">Restore principal</button>`:`<button class="button primary" id="headteacherRecordEdit" type="button">Edit principal</button><button class="button danger" id="headteacherRecordArchive" type="button">Remove principal</button>`,"wide");
    byId("headteacherRecordEdit")?.addEventListener("click",()=>{closeModal();openPrincipalEditor(id)});byId("headteacherRecordArchive")?.addEventListener("click",()=>{closeModal();archivePrincipal(id)});byId("headteacherRecordRestore")?.addEventListener("click",()=>{closeModal();restorePrincipal(id)});
  }
  async function openPrincipalEditor(id=null) {
    let row={active:true};if(id){const data=await rpc("get_headteacher_record",{target_headteacher_id:id});row=data.headteacher||row}else{try{row.staff_no=await rpc("generate_school_identifier",{identifier_kind:"principal"})}catch(_){row.staff_no=""}}
    modal(id?"Edit Principal":"Add Principal","",`<form id="headteacherForm" class="form-stack"><input type="hidden" name="id" value="${attr(row.id||"")}"><input type="hidden" name="updated_at" value="${attr(row.updated_at||"")}"><input type="hidden" name="profile_id" value="${attr(row.profile_id||"")}"><input type="hidden" name="staff_no" value="${attr(row.staff_no||"")}">
      <div class="form-grid"><label class="field full"><span>Full name</span><input name="full_name" value="${attr(row.full_name||fullName(row)||"")}" required></label><label class="field full"><span>Contact</span><input name="contact" value="${attr(row.phone||"")}" required></label></div></form>`,
      `<button class="button ghost" id="headteacherCancel" type="button">Cancel</button><button class="button primary" id="headteacherSave" type="submit" form="headteacherForm">Save principal</button>`,"small");
    byId("headteacherCancel").onclick=closeModal;byId("headteacherForm").addEventListener("submit",event=>{event.preventDefault();savePrincipal()});
  }
  async function savePrincipal() {
    const form=byId("headteacherForm"),button=byId("headteacherSave");if(!form?.reportValidity()){toast("Principal not saved","Enter the full name and contact.","error");return}
    const v=formObject(form);button.disabled=true;button.textContent="Saving";let saved=false;try{await rpc("save_headteacher",{payload:{...v,reason:v.id?"Principal record updated":"Principal record created"}});saved=true;state.workspace=null;closeModal();toast("Principal record saved");try{state.boot=await rpc("get_bootstrap_data");renderBrand();renderNav();await loadPrincipalPage()}catch(refreshError){await reportClientError(refreshError,{source:"headteacher_save",stage:"refresh"});toast("Principal saved","Reload the page to display the latest record.","warning",6500)}}catch(error){await reportClientError(error,{source:"headteacher_save",stage:saved?"refresh":"record"});toast(saved?"Principal saved":"Principal not saved",saved?"Reload the page to display the latest record.":friendlyError(error),saved?"warning":"error",6500)}finally{button.disabled=false;button.textContent="Save principal"}
  }
  async function archivePrincipal(id) {const ok=await confirmAction("Remove Principal","The record will be archived while audit history and published reports remain preserved.","Remove",true);if(!ok)return;try{await rpc("archive_headteacher",{target_headteacher_id:id,reason_text:"Principal removed from active records"});state.workspace=null;toast("Principal removed");await loadPrincipalPage()}catch(error){toast("Principal not removed",friendlyError(error),"error")}}
  async function restorePrincipal(id) {const ok=await confirmAction("Restore Principal","The principal record will return to the active directory.","Restore");if(!ok)return;try{await rpc("restore_headteacher",{target_headteacher_id:id,reason_text:"Principal restored to active records"});state.workspace=null;toast("Principal restored");await loadPrincipalPage()}catch(error){toast("Principal not restored",friendlyError(error),"error")}}
  async function exportPrincipalsCsv() {const data=await rpc("list_headteachers",{search_text:byId("headteacherSearch")?.value||"",status_filter:"",archive_filter:byId("headteacherArchive")?.value||"active",page_number:1,page_size:100});const headers=["staff_no","full_name","phone","profile_email"];downloadText("principals.csv",[headers.join(","),...(data.rows||[]).map(row=>headers.map(h=>csvCell(row[h])).join(","))].join("\n"),"text/csv")}

  async function renderUsers(token) {
    const data=await rpc("list_profiles_with_access");
    if(token!==state.viewToken)return;
    state.userAdmin=data;
    byId("content").innerHTML=`
      <div class="page-head"><div><h3>Users and Access</h3><p>Accounts, credentials, roles, classes, and security</p></div>
        <div class="page-actions"><button class="button primary" id="userAdd">Create user</button></div></div>
      <section class="panel">
        <div class="toolbar"><label class="search"><input id="userSearch" type="search" placeholder="Search name or email"></label>
          <select id="userRoleFilter"><option value="">All roles</option>${["system_admin","principal","class_teacher","subject_teacher","parent_guardian"].map(r=>`<option value="${r}">${esc(ROLE_LABELS[r])}</option>`).join("")}</select>
          <select id="userStatusFilter"><option value="">All accounts</option><option value="active">Active</option><option value="inactive">Inactive</option></select></div>
        <div id="userResults"></div>
      </section>`;
    byId("userAdd").onclick=()=>openUserEditor();
    ["userSearch","userRoleFilter","userStatusFilter"].forEach(id=>byId(id).addEventListener(id==="userSearch"?"input":"change",renderUserRows));
    renderUserRows();
  }
  function renderUserRows() {
    const root=byId("userResults");if(!root)return;
    const search=(byId("userSearch")?.value||"").trim().toLowerCase(),roleFilter=byId("userRoleFilter")?.value||"",status=byId("userStatusFilter")?.value||"";
    const rows=(state.userAdmin?.profiles||[]).filter(user=>{
      if(search&&!`${user.full_name||""} ${user.email||""} ${user.phone||""}`.toLowerCase().includes(search))return false;
      if(roleFilter&&user.role!==roleFilter)return false;
      if(status==="active"&&!user.active)return false;
      if(status==="inactive"&&user.active)return false;
      return true;
    });
    root.innerHTML=rows.length?`<div class="table-wrap"><table><thead><tr><th>User</th><th>Role</th><th>Account</th><th>MFA</th><th>Password</th><th>Class Access</th><th>Last Seen</th><th></th></tr></thead><tbody>
      ${rows.map(user=>`<tr>
        <td><div class="cell-copy"><strong>${esc(user.full_name||"Unnamed user")}</strong><small>${esc(user.email||user.phone||"")}${user.staff_no?` • ${esc(user.staff_no)}`:""}</small></div></td>
        <td>${esc(ROLE_LABELS[user.role]||user.role)}</td>
        <td>${user.active?`<span class="status published">Active</span>`:`<span class="status withdrawn">Inactive</span>`}</td>
        <td>${user.mfa_required?`<span class="status approved">Required</span>`:`<span class="status draft">Optional</span>`}</td>
        <td>${user.must_change_password?`<span class="status withdrawn">Change required</span>`:`<span class="status published">Current</span>`}</td>
        <td>${(user.access||[]).length?`<div class="chip-list">${user.access.slice(0,3).map(a=>`<span class="chip">${esc(a.class_name)}${a.subject_name?` • ${esc(a.subject_name)}`:""}</span>`).join("")}${user.access.length>3?`<span class="chip">+${user.access.length-3}</span>`:""}</div>`:"School role"}</td>
        <td>${isoDateTime(user.last_seen_at||user.last_sign_in_at)}</td><td><div class="table-actions"><button class="button ghost small" data-user-edit="${attr(user.id)}">Edit</button><button class="button secondary small" data-user-reset="${attr(user.id)}">Reset password</button>${user.id!==state.boot.profile.id?`<button class="button danger small" data-user-delete="${attr(user.id)}">Delete</button>`:""}</div></td>
      </tr>`).join("")}</tbody></table></div>`:`<div class="empty"><strong>No users found</strong></div>`;
    $$("[data-user-edit]",root).forEach(button=>button.onclick=()=>openUserEditor(button.dataset.userEdit));
    $$("[data-user-reset]",root).forEach(button=>button.onclick=()=>openPasswordReset(button.dataset.userReset));
    $$("[data-user-delete]",root).forEach(button=>button.onclick=()=>deleteUserAccount(button.dataset.userDelete));
  }
  const ACCOUNT_EMAIL_TITLES=new Set(["mr","mrs","ms","miss","madam","master","dr","doctor","rev","reverend","prof","professor","principal","headmaster","headmistress"]);
  let userEmailPreviewTimer=0,userEmailPreviewToken=0;
  function accountEmailBase(fullNameValue) {
    const parts=String(fullNameValue||"").normalize("NFKD").replace(/[\u0300-\u036f]/g,"").toLowerCase().split(/\s+/)
      .map(part=>part.replace(/[^a-z0-9]/g,"")).filter(Boolean);
    return parts.find(part=>!ACCOUNT_EMAIL_TITLES.has(part))||parts[0]||"";
  }
  function generatedSchoolEmail(fullNameValue) {
    const base=accountEmailBase(fullNameValue);return base?`${base}@${schoolEmailDomain()}`:"";
  }
  async function refreshGeneratedUserEmail(userId=null) {
    const form=byId("userForm"),input=form?.elements?.email;if(!form||!input||userId)return;
    const base=accountEmailBase(form.elements.full_name.value),fallback=base?`${base}@${schoolEmailDomain()}`:"";
    input.value=fallback;
    if(!base||!state.boot?.profile?.id)return;
    const token=++userEmailPreviewToken;
    try{
      const resolved=await rpc("generate_nip_user_email",{actor_id:state.boot.profile.id,requested_base:base,target_user_id:null});
      if(token===userEmailPreviewToken&&byId("userForm")===form)input.value=String(resolved||fallback);
    }catch(_){/* The protected Edge Function performs the authoritative generation. */}
  }
  function scheduleGeneratedUserEmail(userId=null) {
    clearTimeout(userEmailPreviewTimer);
    userEmailPreviewTimer=setTimeout(()=>refreshGeneratedUserEmail(userId),220);
  }

  function openUserEditor(id=null) {
    const user=id?(state.userAdmin.profiles||[]).find(x=>x.id===id):{role:"parent_guardian",active:true,mfa_required:false,must_change_password:false,access:[]};if(!user)return;
    const initialEmail=id?(user.email||generatedSchoolEmail(user.full_name||"")):generatedSchoolEmail(user.full_name||"");
    state.userAccessRows=(user.access||[]).map(x=>({...x}));
    state.userAccessEditingUserId=id||"";
    state.userAccessClassSelections=new Set();
    state.userAccessSubjectSelections=new Set();
    state.userAccessAllSubjects=false;
    modal(id?"Edit User Account":"Create User Account",user.email||"",`<form id="userForm" class="form-stack">
      <div class="form-grid">
        <label class="field full hidden" id="userStaffField"><span id="userStaffLabel">Staff record</span><select id="userStaffSelect" name="staff_record_id"></select></label>
        <label class="field"><span>Full name</span><input name="full_name" value="${attr(user.full_name||"")}" required></label>
        <label class="field"><span>Email address</span><input name="email" type="email" value="${attr(initialEmail)}" readonly required></label>
        <label class="field"><span>Telephone</span><input name="phone" value="${attr(user.phone||"")}"></label>
        <label class="field"><span>Role</span><select id="userRoleSelect" name="role">
          ${["system_admin","principal","class_teacher","subject_teacher","parent_guardian"].map(r=>`<option value="${r}" ${r===user.role?"selected":""}>${esc(ROLE_LABELS[r])}</option>`).join("")}
        </select></label>
        <label class="field full"><span>${id?"New password":"Password"}</span><div class="password-wrap"><input id="adminUserPassword" name="password" type="password" autocomplete="new-password" ${id?"":"required"}><button id="generateUserPassword" class="button ghost small" type="button">Generate</button></div></label>
        <label class="check-field"><input name="active" type="checkbox" ${user.active!==false?"checked":""}><span>Active account</span></label>
        <label class="check-field"><input name="mfa_required" type="checkbox" ${user.mfa_required?"checked":""}><span>Require multi-factor authentication</span></label>
        <label class="check-field full"><input name="must_change_password" type="checkbox" ${user.must_change_password?"checked":""}><span>Force password change on next login</span></label>
      </div>
      <div id="userAccessSection"><div class="section-title"><div><h4>Teaching Responsibilities</h4><p class="help-text">Class Teacher and subject-teaching access is synchronised from Academics.</p></div></div><div id="userAccessRows"></div></div>
    </form>`,`<button class="button ghost" id="userCancel" type="button">Cancel</button><button class="button primary" id="userSave" type="button">${id?"Save account":"Create account"}</button>`,"wide");
    renderUserAccessRows();
    renderUserStaffSelector(id||"",user.headteacher_id||user.teacher_id||"");
    const userForm=byId("userForm");
    userForm.elements.full_name.addEventListener("input",()=>scheduleGeneratedUserEmail(id));
    if(!id)scheduleGeneratedUserEmail(null);
    byId("generateUserPassword").onclick=()=>{const password=generateSecurePassword();byId("adminUserPassword").value=password;byId("adminUserPassword").type="text"};
    byId("userRoleSelect").onchange=()=>{
      syncUserAccessRowsFromSelections();
      renderUserAccessRows();
      renderUserStaffSelector(id||"","");
    };
    byId("userCancel").onclick=closeModal;
    byId("userSave").onclick=()=>saveUserAccount(id);
  }

  function staffRecordsForUserRole(roleName,userId="") {
    const source=roleName==="principal"?(state.userAdmin?.headteacher_records||[]):
      (["class_teacher","subject_teacher"].includes(roleName)?(state.userAdmin?.teacher_records||[]):[]);
    return source.filter(record=>!record.profile_id||record.profile_id===userId);
  }
  function renderUserStaffSelector(userId="",selectedId="") {
    const roleName=byId("userRoleSelect")?.value||"parent_guardian",field=byId("userStaffField"),select=byId("userStaffSelect"),label=byId("userStaffLabel");
    if(!field||!select||!label)return;
    const requiredRole=["principal","class_teacher","subject_teacher"].includes(roleName);
    field.classList.toggle("hidden",!requiredRole);select.required=requiredRole;
    if(!requiredRole){select.innerHTML='<option value="">Not applicable</option>';select.value="";return}
    const rows=staffRecordsForUserRole(roleName,userId);
    label.textContent=roleName==="principal"?"Principal record":"Teacher record";
    select.innerHTML=optionList(rows,"id","label",selectedId,roleName==="principal"?"Select principal":"Select teacher");
    if(selectedId&&rows.some(row=>row.id===selectedId))select.value=selectedId;
    select.onchange=()=>{
      const record=rows.find(item=>item.id===select.value);if(!record)return;
      const form=byId("userForm");if(!form)return;
      form.elements.full_name.value=record.full_name||"";
      if(!userId)scheduleGeneratedUserEmail(null);
      if(record.phone)form.elements.phone.value=record.phone;
    };
  }

  function generateSecurePassword(length=14) {
    const sets=["ABCDEFGHJKLMNPQRSTUVWXYZ","abcdefghijkmnopqrstuvwxyz","23456789","!@#$%&*"];
    const values=new Uint32Array(length);crypto.getRandomValues(values);
    const chars=sets.map((set,index)=>set[values[index]%set.length]);
    const all=sets.join("");for(let i=chars.length;i<length;i++)chars.push(all[values[i]%all.length]);
    for(let i=chars.length-1;i>0;i--){const j=values[i]% (i+1);[chars[i],chars[j]]=[chars[j],chars[i]]}
    return chars.join("");
  }
  function userAccessKey(classId,subjectId){return `${classId}|${subjectId||"*"}`}

  function teacherResponsibilityAccessRows(userId=state.userAccessEditingUserId) {
    if(!userId)return [];
    const rows=[],seen=new Set();
    (state.userAdmin?.classes||[]).filter(item=>
      item.active!==false&&!item.deleted_at&&item.class_teacher_id===userId
    ).forEach(item=>{
      const key=userAccessKey(item.id,null);
      if(!seen.has(key)){seen.add(key);rows.push({class_id:item.id,subject_id:null,access_level:"edit"})}
    });
    (state.userAdmin?.class_subjects||[]).filter(item=>
      item.active!==false&&item.teacher_id===userId&&item.class_id&&item.subject_id
    ).forEach(item=>{
      const key=userAccessKey(item.class_id,item.subject_id);
      if(!seen.has(key)){seen.add(key);rows.push({class_id:item.class_id,subject_id:item.subject_id,access_level:"score"})}
    });
    return rows;
  }

  function syncUserAccessRowsFromSelections() {
    state.userAccessRows=teacherResponsibilityAccessRows();
  }

  function renderUserAccessRows() {
    const root=byId("userAccessRows"),section=byId("userAccessSection");if(!root)return;
    const roleName=byId("userRoleSelect")?.value||"parent_guardian";
    const teacherRole=["class_teacher","subject_teacher"].includes(roleName);
    if(section)section.classList.toggle("hidden",!teacherRole);
    if(!teacherRole){state.userAccessRows=[];root.innerHTML="";return}

    const userId=state.userAccessEditingUserId;
    if(!userId){
      root.innerHTML=`<div class="responsibility-empty">
        <strong>Create the teacher account first</strong>
        <span>After the account is created, assign the home class and exact subjects under Academics.</span>
      </div>`;
      state.userAccessRows=[];
      return;
    }

    const classes=state.userAdmin?.classes||[];
    const subjects=state.userAdmin?.subjects||[];
    const classById=new Map(classes.map(item=>[item.id,item]));
    const subjectById=new Map(subjects.map(item=>[item.id,item]));
    const homeClasses=classes.filter(item=>
      item.active!==false&&!item.deleted_at&&item.class_teacher_id===userId
    );
    const exactAssignments=(state.userAdmin?.class_subjects||[]).filter(item=>
      item.active!==false&&item.teacher_id===userId&&item.class_id&&item.subject_id
    );
    const grouped=new Map();
    exactAssignments.forEach(item=>{
      const classItem=classById.get(item.class_id);
      const subjectItem=subjectById.get(item.subject_id);
      if(!classItem||!subjectItem)return;
      if(!grouped.has(item.class_id))grouped.set(item.class_id,{class_name:classItem.name,subjects:[]});
      grouped.get(item.class_id).subjects.push(subjectItem.name);
    });
    state.userAccessRows=teacherResponsibilityAccessRows(userId);

    root.innerHTML=`<div class="teaching-responsibility-summary">
      <article><span>Class Teacher Responsibility</span><strong>${homeClasses.length?homeClasses.map(item=>esc(item.name)).join(", "):"Not assigned"}</strong><small>${homeClasses.length?"Full class-report responsibility":"Assign a home class under Academics → Classes"}</small></article>
      <article><span>Subject Teaching Responsibility</span><strong>${exactAssignments.length} exact assignment${exactAssignments.length===1?"":"s"}</strong><small>${grouped.size} class${grouped.size===1?"":"es"} • ${new Set(exactAssignments.map(item=>item.subject_id)).size} subject${new Set(exactAssignments.map(item=>item.subject_id)).size===1?"":"s"}</small></article>
    </div>
    <div class="responsibility-groups">
      ${grouped.size?[...grouped.values()].map(group=>`<div class="responsibility-group">
        <strong>${esc(group.class_name)}</strong>
        <span>${group.subjects.sort((a,b)=>a.localeCompare(b)).map(name=>esc(name)).join(", ")}</span>
      </div>`).join(""):`<div class="responsibility-empty"><strong>No subject assignments</strong><span>Use Assign Subjects under Academics to add exact class-subject responsibilities.</span></div>`}
    </div>
    <div class="button-row"><button class="button secondary small" id="manageTeachingResponsibilities" type="button">Manage in Academics</button></div>`;

    byId("manageTeachingResponsibilities").onclick=()=>{
      closeModal();
      state.academicTab="classes";
      navigate("academics");
    };
  }
  async function invokeAdminUserManagement(action,payload) {
    let {data:{session}}=await state.client.auth.getSession();
    if(!session)throw new Error("Your session has expired. Sign in again.");
    if(Number(session.expires_at||0)*1000-Date.now()<90000){
      const refreshed=await state.client.auth.refreshSession();session=refreshed.data.session||session;state.session=session;
    }
    const {data,error}=await state.client.functions.invoke("admin-user-management",{
      body:{action,payload},headers:{Authorization:`Bearer ${session.access_token}`}
    });
    if(error){
      let message=error.message||"User account operation failed";
      try{const detail=await error.context?.json();if(detail?.message)message=String(detail.message);else if(detail?.error)message=String(detail.error)}catch(_){}
      throw new Error(message.replaceAll("_"," "));
    }
    if(data?.error)throw new Error(String(data.message||data.error).replaceAll("_"," "));
    return data;
  }
  async function saveUserAccount(userId=null) {
    const form=byId("userForm"),button=byId("userSave");if(!form?.reportValidity())return;
    const v=formObject(form);button.disabled=true;button.textContent=userId?"Saving":"Creating";let saved=false;
    try{
      if(!userId&&String(v.password||"").length<8)throw new Error("Password must contain at least 8 characters");
      if(userId&&v.password&&String(v.password).length<8)throw new Error("Password must contain at least 8 characters");
      if(["principal","class_teacher","subject_teacher"].includes(v.role)&&!v.staff_record_id)throw new Error("Select the corresponding staff record");
      syncUserAccessRowsFromSelections();
      const payload={user_id:userId||undefined,full_name:v.full_name.trim(),email:v.email.trim(),phone:v.phone.trim(),role:v.role,staff_record_id:v.staff_record_id||"",
        password:v.password||"",active:form.elements.active.checked,mfa_required:form.elements.mfa_required.checked,
        must_change_password:form.elements.must_change_password.checked,
        access:state.userAccessRows.filter(x=>x.class_id),reason:userId?"User account updated":"User account created"};
      await invokeAdminUserManagement(userId?"update":"create",payload);saved=true;state.workspace=null;closeModal();toast(userId?"User account saved":"User account created");
      try{state.userAdmin=await rpc("list_profiles_with_access");state.boot=await rpc("get_bootstrap_data");renderBrand();renderNav();renderUserRows()}
      catch(refreshError){await reportClientError(refreshError,{source:"user_account_save",user_id:userId,stage:"refresh"});toast("Account saved","Reload the page to display the latest access record.","warning",6500)}
    }catch(error){await reportClientError(error,{source:"user_account_save",user_id:userId,stage:saved?"refresh":"record"});toast(saved?"Account saved":"User account not saved",saved?"Reload the page to display the latest access record.":friendlyError(error),saved?"warning":"error",6500)}finally{button.disabled=false;button.textContent=userId?"Save account":"Create account"}
  }


  function openPasswordReset(userId) {
    const user=(state.userAdmin?.profiles||[]).find(item=>item.id===userId);if(!user)return;
    const temporary=generateSecurePassword();
    modal("Reset User Password",user.email||user.full_name||"",`<form id="passwordResetForm" class="form-stack">
      <label class="field"><span>Temporary password</span><div class="password-wrap"><input name="password" type="text" value="${attr(temporary)}" minlength="8" autocomplete="new-password" required><button class="button ghost small" id="regenerateResetPassword" type="button">Generate</button></div></label>
      <label class="check-field"><input name="force_password_change" type="checkbox" checked><span>Force password change on next login</span></label>
      <p class="help-text">Copy and share the temporary password securely with the account owner.</p>
    </form>`,`<button class="button ghost" id="passwordResetCancel" type="button">Cancel</button><button class="button primary" id="passwordResetSave" type="button">Reset password</button>`,"small");
    byId("regenerateResetPassword").onclick=()=>{byId("passwordResetForm").elements.password.value=generateSecurePassword()};
    byId("passwordResetCancel").onclick=closeModal;
    byId("passwordResetSave").onclick=async()=>{
      const form=byId("passwordResetForm"),button=byId("passwordResetSave");if(!form?.reportValidity())return;
      button.disabled=true;button.textContent="Resetting";
      try{
        await invokeAdminUserManagement("reset_password",{user_id:userId,password:form.elements.password.value,
          force_password_change:form.elements.force_password_change.checked,reason:"Password reset by the System Administrator"});
        closeModal();toast("Password reset",form.elements.force_password_change.checked?"The user must change it at the next login.":"The temporary password is active.");
        state.userAdmin=await rpc("list_profiles_with_access");renderUserRows();
      }catch(error){toast("Password not reset",friendlyError(error),"error",6500)}
      finally{button.disabled=false;button.textContent="Reset password"}
    };
  }

  async function deleteUserAccount(userId) {
    const user=(state.userAdmin?.profiles||[]).find(item=>item.id===userId);if(!user)return;
    const ok=await confirmAction("Delete User Account",`Permanently delete ${user.full_name||user.email||"this account"}? The linked staff record will remain but will no longer have a login.`,"Delete",true);if(!ok)return;
    try{
      await invokeAdminUserManagement("delete",{user_id:userId,reason:"User account permanently deleted by the System Administrator"});
      toast("User account deleted");state.workspace=null;
      state.userAdmin=await rpc("list_profiles_with_access");state.boot=await rpc("get_bootstrap_data");renderBrand();renderNav();renderUserRows();
    }catch(error){toast("User account not deleted",friendlyError(error),"error",6500)}
  }

  async function renderNotifications(token) {
    const data=await rpc("list_notifications",{page_number:1,page_size:100});
    if(token!==state.viewToken)return;
    state.notifications=data.rows||[];
    byId("content").innerHTML=`
      <div class="page-head"><div><h3>Notifications</h3><p>${number(data.unread)} unread • ${number(data.total)} total</p></div>
        <div class="page-actions">${data.unread?`<button class="button secondary" id="markAllRead">Mark all read</button>`:""}${state.notifications.length?`<button class="button danger" id="clearNotifications">Clear notifications</button>`:""}</div></div>
      <section class="panel"><div class="managed-card-list">
        ${state.notifications.length?state.notifications.map(item=>`<div class="panel-header" data-notification-id="${attr(item.id)}" style="${item.read_at?"opacity:.7":""}">
          <div><h4>${esc(item.title)}</h4><p>${esc(item.body)} • ${isoDateTime(item.created_at)}</p></div>
          <div class="button-row">${item.entity_type==="report"&&item.entity_id?`<button class="button outline small" data-notification-report="${attr(item.entity_id)}">Open</button>`:""}
            ${!item.read_at?`<button class="button ghost small" data-notification-read="${attr(item.id)}">Mark read</button>`:""}<button class="button danger small" data-notification-delete="${attr(item.id)}">Delete</button></div>
        </div>`).join(""):`<div class="empty"><strong>No notifications</strong></div>`}
      </div></section>`;
    byId("markAllRead")?.addEventListener("click",async()=>{await rpc("mark_notifications_read",{notification_ids:null});await loadNotificationCount();renderNotifications(state.viewToken,true)});
    byId("clearNotifications")?.addEventListener("click",async()=>{if(!await confirmAction("Clear Notifications","Delete all notifications for this account?","Clear",true))return;await rpc("delete_notifications",{notification_ids:null});await loadNotificationCount();renderNotifications(state.viewToken,true)});
    $$('[data-notification-read]').forEach(button=>button.onclick=async()=>{await rpc("mark_notifications_read",{notification_ids:[button.dataset.notificationRead]});await loadNotificationCount();renderNotifications(state.viewToken,true)});
    $$('[data-notification-delete]').forEach(button=>button.onclick=async()=>{if(!await confirmAction("Delete Notification","Remove this notification?","Delete",true))return;await rpc("delete_notifications",{notification_ids:[button.dataset.notificationDelete]});await loadNotificationCount();renderNotifications(state.viewToken,true)});
    $$('[data-notification-report]').forEach(button=>button.onclick=()=>openReportEditor(button.dataset.notificationReport));
  }

  async function renderAudit(token) {
    const data=await rpc("list_audit_events",{target_table:null,target_record_id:null,page_number:1,page_size:100});
    if(token!==state.viewToken)return;
    state.audit=data;
    const tables=[...new Set((data.rows||[]).map(x=>x.table_name))].sort();
    byId("content").innerHTML=`
      <div class="page-head"><div><h3>Audit Trail</h3><p>${number(data.total)} recorded changes</p></div><div class="page-actions"><button class="button danger" id="auditReset">Reset audit log</button></div></div>
      <section class="panel">
        <div class="toolbar"><select id="auditTable"><option value="">All records</option>${tables.map(t=>`<option value="${attr(t)}">${esc(t.replaceAll("_"," "))}</option>`).join("")}</select></div>
        <div id="auditRows">${auditRows(data.rows||[])}</div>
      </section>`;
    byId("auditTable").onchange=async()=>{
      const filtered=await rpc("list_audit_events",{target_table:byId("auditTable").value||null,target_record_id:null,page_number:1,page_size:100});
      state.audit=filtered;byId("auditRows").innerHTML=auditRows(filtered.rows||[]);bindAuditRows();
    };
    byId("auditReset").onclick=resetAuditLog;
    bindAuditRows();
  }
  function auditRows(rows) {
    return rows.length?`<div class="table-wrap"><table><thead><tr><th>Time</th><th>Actor</th><th>Record</th><th>Action</th><th>Reason</th><th></th></tr></thead><tbody>
      ${rows.map((row,index)=>`<tr><td>${isoDateTime(row.created_at)}</td><td>${esc(row.actor_name||"System")}</td><td>${esc(row.table_name)}<br><small>${esc(row.record_id||"")}</small></td>
      <td><span class="chip">${esc(row.action)}</span></td><td>${esc(row.reason||"")}</td><td><div class="table-actions"><button class="button ghost small" data-audit-index="${index}">Details</button><button class="button danger small" data-audit-delete="${attr(row.id)}">Delete</button></div></td></tr>`).join("")}
    </tbody></table></div>`:`<div class="empty"><strong>No audit events</strong></div>`;
  }
  function bindAuditRows() {
    $$('[data-audit-index]').forEach(button=>button.onclick=()=>{
      const row=(state.audit.rows||[])[Number(button.dataset.auditIndex)];
      modal("Audit Event",`${row.table_name} • ${row.action}`,`<div class="revision-compare"><div class="diff-card"><h4>Before</h4><pre>${esc(JSON.stringify(row.old_data,null,2))}</pre></div><div class="diff-card"><h4>After</h4><pre>${esc(JSON.stringify(row.new_data,null,2))}</pre></div></div>`,`<button class="button ghost" id="auditClose" type="button">Close</button>`,"wide");
      byId("auditClose").onclick=closeModal;
    });
    $$('[data-audit-delete]').forEach(button=>button.onclick=async()=>{if(!await confirmAction("Delete Audit Event","Remove this audit event permanently?","Delete",true))return;await rpc("delete_audit_events",{event_ids:[Number(button.dataset.auditDelete)]});toast("Audit event deleted");await renderAudit(state.viewToken,true)});
  }
  async function resetAuditLog() {
    modal("Reset Audit Log","This permanently deletes the current audit trail.",`<div class="form-stack"><p class="help-text">Type <strong>RESET AUDIT LOG</strong> to confirm.</p><label class="field"><span>Confirmation</span><input id="auditResetConfirm" autocomplete="off"></label></div>`,`<button class="button ghost" id="auditResetCancel" type="button">Cancel</button><button class="button danger" id="auditResetRun" type="button">Reset audit log</button>`,"small");
    byId("auditResetCancel").onclick=closeModal;
    byId("auditResetRun").onclick=async()=>{const value=byId("auditResetConfirm").value;try{const result=await rpc("reset_audit_log",{confirmation_text:value});closeModal();toast("Audit log reset",`${number(result.deleted)} events deleted`);await renderAudit(state.viewToken,true)}catch(error){toast("Audit log not reset",friendlyError(error),"error")}};
  }


  function reportTemplateCardsHtml(templates=[],loadError="") {
    if(loadError)return `<div class="template-information"><strong>Template service unavailable</strong><span>${esc(loadError)}</span></div>`;
    return `<div class="report-template-grid">${REPORT_TEMPLATE_GROUPS.map(group=>{
      const template=templates.find(item=>item.range_key===group.key),classes=templateClassesForRange(group.key);
      return `<article class="report-template-card" data-template-card="${attr(group.key)}">
        <div class="report-template-card-head"><div><h5>${esc(group.label)}</h5><p>${classes.length?esc(classes.map(item=>item.name).join(", ")):"No matching active classes found"}</p></div>
          <span class="status ${template?"published":"draft"}">${template?"Assigned":"Built-in fallback"}</span></div>
        ${template?`<div class="template-file-summary"><strong>${esc(template.original_name)}</strong><span>${esc(String(template.mime_type||"").includes("pdf")?"PDF":"DOCX")} • ${readableBytes(template.file_size)} • Version ${number(template.version||1)}</span><small>Updated ${isoDateTime(template.updated_at)}</small></div>`:
          `<div class="template-file-summary empty-template"><strong>No uploaded template</strong><span>The approved built-in terminal-report design is used automatically for this class range.</span></div>`}
        <label class="field"><span>${template?"Replace template":"Upload template"}</span><input type="file" data-template-file="${attr(group.key)}" accept=".pdf,.docx,application/pdf,application/vnd.openxmlformats-officedocument.wordprocessingml.document"></label>
        <div class="button-row">
          <button class="button primary small" type="button" data-template-upload="${attr(group.key)}">${template?"Replace":"Upload"}</button>
          ${template?`<button class="button outline small" type="button" data-template-preview="${attr(group.key)}">Preview</button><button class="button secondary small" type="button" data-template-download="${attr(group.key)}">Download</button><button class="button danger small" type="button" data-template-remove="${attr(group.key)}">Remove</button>`:""}
        </div>
      </article>`;
    }).join("")}</div>`;
  }

  function findReportTemplate(rangeKey) {
    return (state.reportTemplates||[]).find(item=>item.range_key===rangeKey)||null;
  }

  async function uploadReportCardTemplate(rangeKey) {
    const input=document.querySelector(`[data-template-file="${rangeKey}"]`),button=document.querySelector(`[data-template-upload="${rangeKey}"]`);
    const file=input?.files?.[0];
    try{
      const info=validateReportTemplateFile(file);button.disabled=true;setLoading(true);button.textContent="Validating";
      await renderReportTemplateBlob(file,info.mimeType);
      button.textContent="Uploading";
      const checksum=await sha256(file),path=`${rangeKey}/${Date.now()}-${uuid()}.${info.extension}`,previous=findReportTemplate(rangeKey);
      const {error}=await state.client.storage.from(CONFIG.templateBucket).upload(path,file,{contentType:info.mimeType,upsert:false,cacheControl:"3600"});if(error)throw error;
      try{
        await rpc("save_report_card_template",{target_range_key:rangeKey,target_storage_path:path,target_original_name:file.name,target_mime_type:info.mimeType,target_file_size:file.size,target_checksum:checksum});
      }catch(error){await state.client.storage.from(CONFIG.templateBucket).remove([path]).catch(()=>{});throw error}
      if(previous?.storage_path&&previous.storage_path!==path)await state.client.storage.from(CONFIG.templateBucket).remove([previous.storage_path]).catch(()=>{});
      state.reportTemplates=null;state.reportTemplatesLoadedAt=0;state.templateUrls.clear();state.templateCanvases.clear();
      toast("Report-card template assigned",`${reportTemplateGroup(rangeKey)?.shortLabel||rangeKey} now uses ${file.name}.`);
      await renderSettings(state.viewToken,true);
    }catch(error){toast("Template not uploaded",friendlyError(error),"error",7000);await reportClientError(error,{source:"report_template_upload",range_key:rangeKey})}
    finally{setLoading(false);if(button){button.disabled=false;button.textContent=findReportTemplate(rangeKey)?"Replace":"Upload"}}
  }

  async function reportTemplateBlob(template) {
    const {data,error}=await state.client.storage.from(CONFIG.templateBucket).download(template.storage_path);if(error)throw error;return data;
  }

  async function previewReportCardTemplate(rangeKey) {
    const template=findReportTemplate(rangeKey);if(!template)return;
    setLoading(true);
    try{
      const canvas=await renderReportTemplateBlob(await reportTemplateBlob(template),template.mime_type);
      modal(
        `${reportTemplateGroup(rangeKey)?.shortLabel||"Report"} Template`,
        `${template.original_name} • exact uploaded-file preview`,
        `<div class="report-template-preview"><img src="${canvas.toDataURL("image/png")}" alt="Exact uploaded report-card template preview"></div>
         <div class="template-preview-note">This preview shows the uploaded design exactly as supplied. When an official report is generated, the system clears pre-filled sample data and inserts the current student details, results, QR code and current Principal signature without ghost text.</div>`,
        `<button class="button ghost" id="templatePreviewClose" type="button">Close</button><button class="button primary" id="templatePreviewDownload" type="button">Download original</button>`,
        "wide"
      );
      byId("templatePreviewClose").onclick=closeModal;
      byId("templatePreviewDownload").onclick=()=>downloadReportCardTemplate(rangeKey);
    }catch(error){
      toast("Preview unavailable",friendlyError(error),"error",6500);
    }finally{
      setLoading(false);
    }
  }

  async function downloadReportCardTemplate(rangeKey) {
    const template=findReportTemplate(rangeKey);if(!template)return;
    try{downloadBlob(template.original_name,await reportTemplateBlob(template))}catch(error){toast("Template not downloaded",friendlyError(error),"error")}
  }

  async function removeReportCardTemplate(rangeKey) {
    const template=findReportTemplate(rangeKey);if(!template)return;
    const group=reportTemplateGroup(rangeKey);
    if(!await confirmAction("Remove Report-card Template",`${group?.label||rangeKey} will return to the approved built-in report-card design. Existing published PDF files remain unchanged until regenerated.`,"Remove",true))return;
    try{
      const removed=await rpc("remove_report_card_template",{target_range_key:rangeKey});
      if(removed?.storage_path)await state.client.storage.from(CONFIG.templateBucket).remove([removed.storage_path]).catch(()=>{});
      state.reportTemplates=null;state.reportTemplatesLoadedAt=0;state.templateUrls.clear();state.templateCanvases.clear();
      toast("Report-card template removed",`${group?.shortLabel||rangeKey} now uses the built-in design.`);await renderSettings(state.viewToken,true);
    }catch(error){toast("Template not removed",friendlyError(error),"error",6500)}
  }

  function bindReportTemplateAdmin() {
    $$('[data-template-upload]').forEach(button=>button.onclick=()=>uploadReportCardTemplate(button.dataset.templateUpload));
    $$('[data-template-preview]').forEach(button=>button.onclick=()=>previewReportCardTemplate(button.dataset.templatePreview));
    $$('[data-template-download]').forEach(button=>button.onclick=()=>downloadReportCardTemplate(button.dataset.templateDownload));
    $$('[data-template-remove]').forEach(button=>button.onclick=()=>removeReportCardTemplate(button.dataset.templateRemove));
  }


  function licenceLimitText(value) {return value==null?"Unlimited":number(value)}
  function licenceUsageMetric(label,used,limit) {
    const capped=limit!=null,ratio=capped&&Number(limit)>0?Math.min(100,Math.round(Number(used||0)/Number(limit)*100)):0;
    return `<div class="metric"><span>${esc(label)}</span><strong>${number(used)}${capped?` / ${number(limit)}`:""}</strong>${capped?`<div class="progress compact"><span style="width:${ratio}%"></span></div>`:`<small>Unlimited by plan</small>`}</div>`;
  }
  function platformEventSummary(event) {
    return ({license_initialized:"Licence initialized",license_updated:"Licence updated",access_lock_applied:"Access lock applied",access_lock_released:"Access lock released",platform_admin_provisioned:"Platform administrator provisioned"})[event.event_type]||String(event.event_type||"Event").replaceAll("_"," ");
  }
  async function renderLicensing(token,force=false) {
    if(!can("manage_licenses"))throw new Error("Platform Super Administrator access required");
    if(force||!state.licenseConsole)state.licenseConsole=await rpc("get_platform_license_console");
    if(token!==state.viewToken)return;
    const data=state.licenseConsole||{},snapshot=data.snapshot||{},license=data.license||{},plan=snapshot.plan||{};
    const plans=data.plans||[],usage=data.usage||{},locks=data.active_locks||[],events=data.recent_events||[],admins=data.platform_admins||[];
    const status=snapshot.computed_status||license.status||"unknown";
    byId("content").innerHTML=`
      <div class="page-head"><div><h3>Platform Licensing Control</h3><p>Manage the installation licence, compliance state, capacity, and access restrictions.</p></div><button class="button ghost" id="licenseRefresh">Refresh</button></div>
      <section class="platform-control-hero ${snapshot.access_mode==='locked'?'locked':snapshot.access_mode==='read_only'?'restricted':'active'}">
        <div><span>Current licence</span><h3>${esc(plan.name||"Unconfigured")}</h3><p>${esc(snapshot.license_reference||"No licence reference")}</p></div>
        <div><span>Status</span><strong>${esc(licenseStatusLabel(status))}</strong><small>${esc(snapshot.access_lock_status||"unlocked")}</small></div>
        <div><span>Issue date</span><strong>${esc(isoDate(snapshot.issued_on))}</strong><small>Activated ${esc(isoDateTime(snapshot.activated_at))}</small></div>
        <div><span>Expiry</span><strong>${snapshot.expires_at?esc(isoDateTime(snapshot.expires_at)):"No expiry"}</strong><small>${snapshot.days_remaining==null?"Perpetual or unset":`${number(snapshot.days_remaining)} days remaining`}</small></div>
      </section>
      ${snapshot.warning?`<section class="license-banner ${snapshot.access_mode==='read_only'||snapshot.access_mode==='locked'?'restricted':'warning'}"><div><strong>Licence attention</strong><span>${esc(snapshot.warning)}</span></div></section>`:""}
      <div class="grid two platform-license-grid">
        <section class="panel pad">
          <div class="section-title"><div><h4>Licence lifecycle</h4><p>Changes are effective immediately and recorded in immutable licensing history.</p></div></div>
          <form id="platformLicenseForm" class="form-grid">
            <label class="field"><span>Licence plan</span><select name="plan_id" required>${plans.map(item=>`<option value="${attr(item.id)}" ${item.id===license.plan_id?"selected":""}>${esc(item.name)}</option>`).join("")}</select></label>
            <label class="field"><span>Licence status</span><select name="status">${["pending_activation","active","grace_period","expired","suspended","revoked","perpetual"].map(item=>`<option value="${item}" ${item===license.status?"selected":""}>${esc(licenseStatusLabel(item))}</option>`).join("")}</select></label>
            <label class="field"><span>Issue date</span><input type="date" name="issued_on" value="${attr(license.issued_on||localDateValue())}" required></label>
            <label class="field"><span>Activation date and time</span><input type="datetime-local" name="activated_at" value="${attr(dateTimeLocalValue(license.activated_at))}"></label>
            <label class="field"><span>Expiry date and time</span><input type="datetime-local" name="expires_at" value="${attr(dateTimeLocalValue(license.expires_at))}"></label>
            <label class="field"><span>Grace-period end</span><input type="datetime-local" name="grace_ends_at" value="${attr(dateTimeLocalValue(license.grace_ends_at))}"></label>
            <label class="field full"><span>Licence reference</span><input name="license_reference" maxlength="100" value="${attr(license.license_reference||"")}" required></label>
            <label class="field full"><span>Compliance reason</span><input name="compliance_reason" maxlength="500" value="${attr(license.compliance_reason||"")}" placeholder="Required when suspended or revoked"></label>
            <label class="field full"><span>Internal notes</span><textarea name="notes">${esc(license.notes||"")}</textarea></label>
            <div class="full button-row"><button class="button primary" id="platformLicenseSave" type="button">Save licence</button></div>
          </form>
        </section>
        <section class="panel pad">
          <div class="section-title"><div><h4>Plan capacity and features</h4><p>${esc(plan.description||"")}</p></div></div>
          <div class="metric-row">
            ${licenceUsageMetric("Active students",usage.active_students,plan.max_students)}
            ${licenceUsageMetric("Active teachers",usage.active_teachers,plan.max_teachers)}
            ${licenceUsageMetric("System administrators",usage.active_system_admins,plan.max_system_admins)}
            <div class="metric"><span>Published reports</span><strong>${number(usage.published_reports)}</strong><small>Historical total</small></div>
          </div>
          <div class="hr"></div>
          <div class="chip-list">${Object.entries(plan.feature_flags||{}).filter(([,enabled])=>enabled).map(([key])=>`<span class="chip">${esc(key.replaceAll("_"," "))}</span>`).join("")||'<span class="chip">No enabled features</span>'}</div>
          <div class="template-information" style="margin-top:18px"><strong>Capacity enforcement</strong><span>Student, teacher, and System Administrator limits are enforced on the server. Existing records are never deleted when a limit or licence state changes.</span></div>
        </section>
        <section class="panel pad">
          <div class="section-title"><div><h4>Access lock control</h4><p>Use read-only mode before a complete denial unless a serious compliance or security condition requires full restriction.</p></div></div>
          <form id="platformLockForm" class="form-grid">
            <label class="field"><span>Lock scope</span><select name="scope"><option value="system_admin">System Administrator only</option><option value="school">All school users</option><option value="platform">Entire school platform</option></select></label>
            <label class="field"><span>Lock mode</span><select name="mode"><option value="read_only">Read-only</option><option value="deny">Deny access</option></select></label>
            <label class="field full"><span>Reason</span><textarea name="reason" required placeholder="State the contractual, security, or compliance reason"></textarea></label>
            <label class="field full"><span>Automatic end date and time (optional)</span><input type="datetime-local" name="ends_at"></label>
            <div class="full button-row"><button class="button danger" id="platformLockApply" type="button">Apply access lock</button></div>
          </form>
          <div class="hr"></div>
          <div class="section-title"><h4>Active locks</h4></div>
          ${locks.length?`<div class="record-list">${locks.map(item=>`<article class="license-lock-row"><div><strong>${esc(item.lock_scope.replaceAll("_"," "))} • ${esc(item.lock_mode.replaceAll("_"," "))}</strong><span>${esc(item.reason)}</span><small>Applied ${esc(isoDateTime(item.created_at))}${item.ends_at?` • Ends ${esc(isoDateTime(item.ends_at))}`:""}</small></div><button class="button outline small" data-release-license-lock="${attr(item.id)}">Release</button></article>`).join("")}</div>`:`<div class="empty"><strong>No active access locks</strong></div>`}
        </section>
        <section class="panel pad">
          <div class="section-title"><div><h4>Platform Super Administrators</h4><p>These accounts are isolated from school academic portals and must use multi-factor authentication.</p></div></div>
          ${admins.length?`<div class="record-list">${admins.map(item=>`<article class="license-admin-row"><div><strong>${esc(item.full_name||"Platform administrator")}</strong><span>${esc(item.email||"")}</span><small>${item.active?"Active":"Inactive"} • MFA ${item.mfa_required?"required":"not configured"} • Last seen ${esc(isoDateTime(item.last_seen_at))}</small></div></article>`).join("")}</div>`:`<div class="empty"><strong>No Platform Super Administrator profile found</strong></div>`}
          <div class="template-information"><strong>Account provisioning</strong><span>Create a separate Supabase Authentication user, then run PLATFORM_SUPER_ADMIN_SETUP.sql with that user’s email. School System Administrators cannot grant themselves this role.</span></div>
        </section>
      </div>
      <section class="panel">
        <div class="panel-header"><div><h3>Licence and compliance history</h3><p>Latest 100 immutable platform events</p></div></div>
        <div class="table-wrap"><table><thead><tr><th>Date</th><th>Event</th><th>Reason</th><th>Actor</th></tr></thead><tbody>${events.length?events.map(item=>`<tr><td>${esc(isoDateTime(item.created_at))}</td><td><strong>${esc(platformEventSummary(item))}</strong></td><td>${esc(item.event_reason||"—")}</td><td>${esc(item.actor_name||item.actor_id||"System")}</td></tr>`).join(""):`<tr><td colspan="4"><div class="empty">No licensing events recorded</div></td></tr>`}</tbody></table></div>
      </section>`;
    byId("licenseRefresh").onclick=()=>{state.licenseConsole=null;renderLicensing(state.viewToken,true)};
    byId("platformLicenseSave").onclick=savePlatformLicense;
    byId("platformLockApply").onclick=applyPlatformAccessLock;
    $$('[data-release-license-lock]').forEach(button=>button.onclick=()=>releasePlatformAccessLock(button.dataset.releaseLicenseLock));
  }
  async function savePlatformLicense() {
    const form=byId("platformLicenseForm"),button=byId("platformLicenseSave");if(!form?.reportValidity())return;
    const values=formObject(form);button.disabled=true;button.textContent="Saving";
    try{
      const payload={target_plan_id:values.plan_id,target_status:values.status,issue_date:values.issued_on,
        activation_date:values.activated_at?new Date(values.activated_at).toISOString():null,
        expiry_date:values.expires_at?new Date(values.expires_at).toISOString():null,
        grace_end_date:values.grace_ends_at?new Date(values.grace_ends_at).toISOString():null,
        license_reference_text:values.license_reference.trim(),notes_text:values.notes.trim(),compliance_reason_text:values.compliance_reason.trim()};
      if(["suspended","revoked"].includes(values.status)&&payload.compliance_reason_text.length<5)throw new Error("Enter a clear compliance reason for a suspended or revoked licence.");
      state.licenseConsole=await rpc("platform_update_license",payload);state.boot=await rpc("get_bootstrap_data");renderBrand();toast("Platform licence updated");await renderLicensing(state.viewToken);
    }catch(error){toast("Licence not updated",friendlyError(error),"error",7500)}finally{button.disabled=false;button.textContent="Save licence"}
  }
  async function applyPlatformAccessLock() {
    const form=byId("platformLockForm"),button=byId("platformLockApply");if(!form?.reportValidity())return;
    const values=formObject(form);if(values.reason.trim().length<5){toast("Lock not applied","Enter a clear reason.","error");return}
    const ok=await confirmAction("Apply access lock",`Apply ${values.mode.replaceAll("_"," ")} access to ${values.scope.replaceAll("_"," ")}?`,"Apply lock",true);if(!ok)return;
    button.disabled=true;button.textContent="Applying";
    try{state.licenseConsole=await rpc("platform_set_access_lock",{lock_scope_text:values.scope,lock_mode_text:values.mode,reason_text:values.reason.trim(),ends_at_value:values.ends_at?new Date(values.ends_at).toISOString():null});toast("Access lock applied");await renderLicensing(state.viewToken)}
    catch(error){toast("Lock not applied",friendlyError(error),"error",7500)}finally{button.disabled=false;button.textContent="Apply access lock"}
  }
  async function releasePlatformAccessLock(lockId) {
    const ok=await confirmAction("Release access lock","School access will return to the level allowed by the current licence status.","Release lock");if(!ok)return;
    try{state.licenseConsole=await rpc("platform_release_access_lock",{target_lock_id:lockId,reason_text:"Access lock released through the Platform Licensing portal"});toast("Access lock released");await renderLicensing(state.viewToken)}
    catch(error){toast("Lock not released",friendlyError(error),"error",7500)}
  }

  async function renderSettings(token) {
    const school=state.boot.school||{};
    let health=null,readiness=null,backupData=null,templates=[],templateLoadError="";
    try{templates=await loadReportCardTemplates(true)}catch(error){templateLoadError=friendlyError(error)}
    try{health=await rpc("system_health")}catch(_){}
    if(can("run_backup")){try{backupData=await rpc("backup_dashboard")}catch(_){}}
    if(can("manage_academics")||can("manage_users")){try{readiness=await rpc("validate_operational_readiness")}catch(_){}}
    if(token!==state.viewToken)return;
    byId("content").innerHTML=`
      <div class="page-head"><div><h3>System Settings</h3><p>School identity, security, health, and continuity</p></div></div>
      <div class="grid two">
        <section class="panel pad">
          <div class="section-title"><h4>School Identity</h4></div>
          <form id="schoolForm" class="form-grid">
            <label class="field full"><span>School name</span><input name="school_name" value="${attr(schoolDisplayName(school))}" ${!can("manage_users")?"disabled":""}></label>
            <label class="field full"><span>Motto</span><input name="motto" value="${attr(school.motto||"")}" ${!can("manage_users")?"disabled":""}></label>
            <label class="field full"><span>Address</span><input name="address" value="${attr(school.address||"")}" ${!can("manage_users")?"disabled":""}></label>
            <label class="field"><span>Telephone</span><input name="phone" value="${attr(school.phone||"")}" ${!can("manage_users")?"disabled":""}></label>
            <label class="field"><span>Email</span><input type="email" name="email" value="${attr(school.email||"")}" ${!can("manage_users")?"disabled":""}></label>
            <label class="field"><span>Website</span><input name="website" value="${attr(school.website||"")}" ${!can("manage_users")?"disabled":""}></label>
            <label class="field"><span>Principal</span><input name="head_name" value="${attr(school.head_name||"")}" ${!can("manage_users")?"disabled":""}></label>
            <label class="field"><span>Report number prefix</span><input name="report_number_prefix" value="${attr(schoolReportPrefix(school))}" ${!can("manage_users")?"disabled":""}></label>
            <label class="field"><span>User email domain</span><input name="user_email_domain" value="${attr(schoolEmailDomain(school))}" placeholder="school.edu.gh" ${!can("manage_users")?"disabled":""}><small>Used for automatically generated user account email addresses.</small></label>
            <label class="field"><span>Time zone</span><input name="timezone" value="${attr(school.timezone||"Africa/Accra")}" ${!can("manage_users")?"disabled":""}></label>
            <label class="field full"><span>Verification base URL</span><input name="verification_base_url" value="${attr(school.verification_base_url||"")}" ${!can("manage_users")?"disabled":""}></label>
            <label class="field"><span>Primary colour</span><input type="color" name="primary_colour" value="${attr(school.primary_colour||"#082d70")}" ${!can("manage_users")?"disabled":""}></label>
            <label class="field"><span>Accent colour</span><input type="color" name="accent_colour" value="${attr(school.accent_colour||"#f0b51d")}" ${!can("manage_users")?"disabled":""}></label>
            <label class="field"><span>Report body font</span><select name="report_body_font" ${!can("manage_users")?"disabled":""}>${reportFontOptionsHtml(school.report_body_font||"Times New Roman")}</select></label>
            <label class="field"><span>Report body font size</span><input type="number" name="report_body_font_size" min="8" max="16" step="0.5" value="${attr(school.report_body_font_size??11)}" ${!can("manage_users")?"disabled":""}><small>Applied to generated report data and embedded in the downloaded PDF. Default: 11 pt.</small></label>
            ${can("manage_users")?`<div class="full"><button class="button primary" id="schoolSave" type="button">Save identity and report appearance</button></div>`:""}
          </form>
        </section>
        <div class="grid">
          <section class="panel pad"><div class="section-title"><h4>Account Security</h4></div>
            <div class="metric-row"><div class="metric"><span>Role</span><strong>${esc(ROLE_LABELS[role()]||role())}</strong></div>
              <div class="metric"><span>MFA policy</span><strong>${state.boot.profile.mfa_required?"Required":"Optional"}</strong></div></div>
            <div class="button-row" style="margin-top:15px"><button class="button secondary" id="mfaManage">Manage authentication</button></div>
          </section>
          <section class="panel pad"><div class="section-title"><h4>System Health</h4><button class="button ghost small" id="healthRefresh">Refresh</button></div>
            ${health?`<div class="metric-row">
              <div class="metric"><span>Active users</span><strong>${number(health.active_users)}</strong></div>
              <div class="metric"><span>Active teachers</span><strong>${number(health.active_teachers)}</strong></div>
              <div class="metric"><span>Active students</span><strong>${number(health.active_students)}</strong></div>
              <div class="metric"><span>Pending messages</span><strong>${number(health.pending_notifications)}</strong></div>
              <div class="metric"><span>Errors, 24h</span><strong>${number(health.client_errors_24h)}</strong></div>
            </div><div class="hr"></div>
            <div class="diff-row"><span>Latest full backup</span><b>${isoDateTime(health.latest_backup)}</b></div>
            <div class="diff-row"><span>Latest verified backup</span><b>${isoDateTime(health.latest_verified_backup)}</b></div>
            <div class="diff-row"><span>Latest off-site copy</span><b>${isoDateTime(health.latest_offsite_copy)}</b></div>
            <div class="diff-row"><span>Failed backups, 30 days</span><b>${number(health.failed_backups_30d)}</b></div>
            <div class="diff-row"><span>Completed backups awaiting verification</span><b>${number(health.unverified_completed_backups)}</b></div>
            <div class="diff-row"><span>Published reports without PDF</span><b>${number(health.published_without_pdf)}</b></div>
            <div class="diff-row"><span>Incomplete assessment schemes</span><b>${number((health.incomplete_schemes||[]).length)}</b></div>
            ${readiness?`<div class="diff-row"><span>Record save services</span><b>${readiness.ready?"Operational":"Attention required"}</b></div><div class="diff-row"><span>Data security</span><b>${Object.values(readiness.rls||{}).every(Boolean)?"Protected":"Attention required"}</b></div><div class="diff-row"><span>Data integrity</span><b>${Object.values(readiness.integrity||{}).every(value=>Number(value)===0)?"Healthy":"Attention required"}</b></div><div class="diff-row"><span>Role portals</span><b>${Object.values(readiness.roles||{}).every(Boolean)?"Ready":"Attention required"}</b></div>`:""}`:`<p class="help-text">Health details are not available for this role.</p>`}
          </section>
          ${can("run_backup")?`<section class="panel pad backup-recovery-panel"><div class="section-title"><div><h4>Backup and Recovery</h4><p>Encrypted database, authentication metadata, report files, student photographs, signatures and uploaded templates.</p></div></div>
            <form id="backupPolicyForm" class="form-grid compact">
              <label class="field"><span>Retention days</span><input type="number" name="retention_days" min="7" max="365" value="${attr(backupData?.retention_days??school.backup_retention_days??30)}"></label>
              <label class="field"><span>Minimum retained copies</span><input type="number" name="minimum_copies" min="2" max="90" value="${attr(backupData?.minimum_copies??school.backup_minimum_copies??7)}"></label>
              <div class="full button-row"><button class="button secondary" id="backupPolicySave" type="button">Save retention policy</button><button class="button primary" id="backupCreate" type="button">Create full encrypted backup</button></div>
            </form>
            <div class="template-information"><strong>Continuity rule</strong><span>Daily encrypted backups are retained under this policy. A weekly integrity rehearsal decrypts, decompresses, parses and checksum-verifies the latest backup. Download an encrypted package regularly and keep it outside Supabase.</span></div>
            ${backupHistoryHtml(backupData?.backups||[])}
          </section>`:""}
          ${can("manage_academics")?`<section class="panel pad"><div class="section-title"><h4>Scheduled Operations</h4></div>
            <div class="button-row"><button class="button secondary" id="notifyIncomplete">Queue incomplete-report alerts</button></div></section>`:""}
        </div>
      </div>
      <section class="panel pad report-template-admin">
        <div class="section-title"><div><h4>Report Card Templates by Class Range</h4><p>Upload one A4 portrait PDF or DOCX design for each fixed class range. The system automatically places the official student data, photograph, scores, comments, signature and verification details on the assigned design.</p></div></div>
        <div class="template-information"><strong>Template field map</strong><span>Uploaded designs should follow the approved A4 report-card field positions. A valid template is preview-rendered before it can be assigned. When a range has no uploaded template, the approved built-in terminal-report design supplied with the system is used automatically.</span></div>
        ${reportTemplateCardsHtml(templates,templateLoadError)}
      </section>`;
    byId("schoolSave")?.addEventListener("click",saveSchoolSettings);
    byId("mfaManage").onclick=openMfaManager;
    byId("healthRefresh")?.addEventListener("click",()=>renderSettings(state.viewToken,true));
    byId("backupCreate")?.addEventListener("click",createManualBackup);
    byId("backupPolicySave")?.addEventListener("click",saveBackupPolicy);
    bindBackupHistoryControls();
    byId("notifyIncomplete")?.addEventListener("click",queueIncompleteNotifications);
    bindReportTemplateAdmin();
  }
  async function saveSchoolSettings() {
    const form=byId("schoolForm"),values=formObject(form),button=byId("schoolSave");button.disabled=true;
    try{
      if(!Object.prototype.hasOwnProperty.call(REPORT_FONT_OPTIONS,values.report_body_font))throw new Error("Choose a supported report body font.");
      const reportFontSize=Number(values.report_body_font_size);
      if(!Number.isFinite(reportFontSize)||reportFontSize<8||reportFontSize>16)throw new Error("Report body font size must be between 8 and 16 points.");
      values.report_body_font_size=Math.round(reportFontSize*2)/2;
      values.user_email_domain=String(values.user_email_domain||"").trim().toLowerCase();
      if(!/^(?:[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?\.)+[a-z]{2,63}$/i.test(values.user_email_domain))throw new Error("Enter a valid user email domain, for example school.edu.gh.");
      values.report_number_prefix=String(values.report_number_prefix||"").trim().toUpperCase().replace(/[^A-Z0-9]/g,"").slice(0,12);
      if(values.report_number_prefix.length<2)throw new Error("Report number prefix must contain at least two letters or numbers.");
      await query(state.client.from("school_settings").update(values).eq("id",state.boot.school.id));
      state.boot=await rpc("get_bootstrap_data");renderBrand();toast("School identity and report appearance saved");
    }catch(error){toast("Settings not saved",friendlyError(error),"error")}finally{button.disabled=false}
  }
  async function openMfaManager() {
    const {data,error}=await state.client.auth.mfa.listFactors();if(error){toast("Security details unavailable",friendlyError(error),"error");return}
    const factors=data.totp||[];
    modal("Multi-factor Authentication","",`
      <div class="section-title"><h4>Authenticator Factors</h4></div>
      ${factors.length?factors.map(f=>`<div class="diff-row"><span><strong>${esc(f.friendly_name||"Authenticator")}</strong><br><small>${esc(f.status)}</small></span>
        <button class="button danger small" data-mfa-remove="${attr(f.id)}">Remove</button></div>`).join(""):`<div class="empty"><strong>No authenticator factor</strong></div>`}`,
      `<button class="button ghost" id="mfaManagerClose" type="button">Close</button><button class="button primary" id="mfaManagerAdd" type="button">Add authenticator</button>`,"small");
    byId("mfaManagerClose").onclick=closeModal;
    byId("mfaManagerAdd").onclick=enrollMfaFromSettings;
    $$("[data-mfa-remove]").forEach(button=>button.onclick=async()=>{
      if(!await confirmAction("Remove Authenticator","This authentication factor will be removed.","Remove",true))return;
      const {error}=await state.client.auth.mfa.unenroll({factorId:button.dataset.mfaRemove});
      if(error)toast("Authenticator not removed",friendlyError(error),"error");else{closeModal();toast("Authenticator removed")}
    });
  }
  async function enrollMfaFromSettings() {
    const {data,error}=await state.client.auth.mfa.enroll({factorType:"totp",friendlyName:schoolDisplayName()});
    if(error){toast("Authenticator not added",friendlyError(error),"error");return}
    modal("Add Authenticator","",`<div class="mfa-qr"><img src="${attr(data.totp.qr_code)}" alt="Authentication QR code"></div>
      <label class="field"><span>Authentication code</span><input id="settingsMfaCode" inputmode="numeric" autocomplete="one-time-code"></label>`,
      `<button class="button ghost" id="settingsMfaCancel" type="button">Cancel</button><button class="button primary" id="settingsMfaVerify" type="button">Verify</button>`,"small");
    byId("settingsMfaCancel").onclick=async()=>{await state.client.auth.mfa.unenroll({factorId:data.id}).catch(()=>{});closeModal()};
    byId("settingsMfaVerify").onclick=async()=>{
      const button=byId("settingsMfaVerify");button.disabled=true;
      const {error}=await state.client.auth.mfa.challengeAndVerify({factorId:data.id,code:byId("settingsMfaCode").value.trim()});
      if(error){toast("Code not verified",friendlyError(error),"error");button.disabled=false}
      else{closeModal();toast("Authenticator verified");state.session=(await state.client.auth.getSession()).data.session}
    };
  }
  function backupStatusLabel(backup) {
    if(backup.status==="processing")return `<span class="chip warning">Processing</span>`;
    if(backup.status==="failed")return `<span class="chip danger">Failed</span>`;
    if(backup.verification_status==="passed")return `<span class="chip success">Verified</span>`;
    if(backup.verification_status==="failed")return `<span class="chip danger">Verification failed</span>`;
    return `<span class="chip">Completed, not tested</span>`;
  }
  function backupHistoryHtml(backups=[]) {
    if(!backups.length)return `<div class="empty"><strong>No full backup has been recorded</strong><span>Create the first encrypted continuity backup.</span></div>`;
    return `<div class="table-wrap backup-history"><table><thead><tr><th>Created</th><th>Status</th><th>Database rows</th><th>Storage</th><th>Off-site</th><th></th></tr></thead><tbody>${backups.map(backup=>{
      const rows=Object.values(backup.row_counts||{}).reduce((sum,value)=>sum+Number(value||0),0);
      const objectCount=Object.values(backup.storage_object_counts||{}).reduce((sum,value)=>sum+Number(value||0),0);
      return `<tr><td><strong>${isoDateTime(backup.created_at)}</strong><br><small>${esc(backup.backup_key||backup.id)}</small></td><td>${backupStatusLabel(backup)}${backup.error_message?`<br><small>${esc(backup.error_message)}</small>`:""}</td><td>${number(rows)}</td><td>${number(objectCount)} files<br><small>${readableBytes(backup.storage_bytes||0)}</small></td><td>${backup.offsite_copied_at?`${isoDateTime(backup.offsite_copied_at)}${backup.offsite_copy_note?`<br><small>${esc(backup.offsite_copy_note)}</small>`:""}`:"Not confirmed"}</td><td><div class="button-row compact"><button class="button ghost small" type="button" data-backup-verify="${attr(backup.id)}" ${backup.status!=="completed"||backup.backup_type!=="full"?"disabled":""}>Verify</button><button class="button secondary small" type="button" data-backup-download="${attr(backup.id)}" ${backup.status!=="completed"||backup.backup_type!=="full"?"disabled":""}>Download encrypted package</button><button class="button ghost small" type="button" data-backup-offsite="${attr(backup.id)}" ${backup.status!=="completed"||backup.backup_type!=="full"||backup.offsite_copied_at?"disabled":""}>Confirm off-site copy</button></div></td></tr>`;
    }).join("")}</tbody></table></div>`;
  }
  function bindBackupHistoryControls() {
    $$('[data-backup-verify]').forEach(button=>button.onclick=()=>verifyFullBackup(button.dataset.backupVerify,button));
    $$('[data-backup-download]').forEach(button=>button.onclick=()=>downloadEncryptedBackupPackage(button.dataset.backupDownload,button));
    $$('[data-backup-offsite]').forEach(button=>button.onclick=()=>confirmBackupOffsiteCopy(button.dataset.backupOffsite,button));
  }
  async function saveBackupPolicy() {
    const form=byId("backupPolicyForm"),values=formObject(form),button=byId("backupPolicySave");
    const retention=Number(values.retention_days),minimum=Number(values.minimum_copies);
    if(!Number.isInteger(retention)||retention<7||retention>365){toast("Policy not saved","Retention must be a whole number from 7 through 365 days.","error");return}
    if(!Number.isInteger(minimum)||minimum<2||minimum>90){toast("Policy not saved","Minimum copies must be a whole number from 2 through 90.","error");return}
    button.disabled=true;
    try{await rpc("save_backup_policy",{target_retention_days:retention,target_minimum_copies:minimum});toast("Backup policy saved",`${minimum} copies will be retained, with age-based cleanup after ${retention} days.`)}
    catch(error){toast("Policy not saved",friendlyError(error),"error")}finally{button.disabled=false}
  }
  async function waitForBackup(backupId,timeoutMs=420000) {
    const started=Date.now();
    while(Date.now()-started<timeoutMs){
      const {data,error}=await state.client.from("backup_exports").select("*").eq("id",backupId).single();
      if(error)throw error;
      if(data.status==="completed")return data;
      if(data.status==="failed")throw new Error(data.error_message||"The full backup did not complete.");
      await new Promise(resolve=>setTimeout(resolve,3500));
    }
    throw new Error("The backup is still processing. Refresh Settings shortly to view its final status.");
  }
  async function createManualBackup() {
    const button=byId("backupCreate");button.disabled=true;setSync("pending","Backing up");
    try{
      const {data,error}=await state.client.functions.invoke("scheduled-backup",{body:{action:"create",mode:"manual"}});
      if(error)throw error;
      const backupId=data?.backup_id;if(!backupId)throw new Error("The backup service did not return a backup identifier.");
      toast("Full backup started","Database records and private Storage objects are being encrypted and copied.","warning",5000);
      const completed=await waitForBackup(backupId);
      toast("Full backup completed",`${Object.values(completed.storage_object_counts||{}).reduce((sum,value)=>sum+Number(value||0),0)} files protected • ${readableBytes(completed.storage_bytes||0)} storage data.`);setSync("online","Synced");
      await renderSettings(state.viewToken,true);
    }catch(error){toast("Backup unsuccessful",friendlyError(error),"error",8000);setSync("pending","Retry required")}
    finally{button.disabled=false}
  }
  async function verifyFullBackup(backupId,button) {
    button.disabled=true;setSync("pending","Verifying backup");
    try{
      const {data,error}=await state.client.functions.invoke("scheduled-backup",{body:{action:"verify",backup_id:backupId}});
      if(error)throw error;
      toast("Backup verification passed",`${number(data.checked_objects||0)} storage files and the complete database export passed decryption and checksum verification.`);setSync("online","Synced");
      await renderSettings(state.viewToken,true);
    }catch(error){toast("Backup verification failed",friendlyError(error),"error",9000);setSync("pending","Attention required")}
    finally{button.disabled=false}
  }
  async function downloadEncryptedBackupPackage(backupId,button) {
    if(!window.JSZip){toast("Download unavailable","The packaged ZIP library did not load.","error");return}
    if(!await confirmAction("Download Encrypted Off-site Package","This can be a large download because it contains the encrypted database and every protected Storage object in the selected backup. Keep the package and the backup encryption secret in separate secure locations.","Download package"))return;
    button.disabled=true;setSync("pending","Packaging backup");
    try{
      const {data:backup,error:backupError}=await state.client.from("backup_exports").select("*").eq("id",backupId).single();if(backupError)throw backupError;
      const {data:objects,error:objectsError}=await state.client.from("backup_storage_objects").select("backup_path").eq("backup_export_id",backupId).order("source_bucket").order("source_path");if(objectsError)throw objectsError;
      const paths=[backup.storage_path,backup.manifest_path,backup.database_path,...(objects||[]).map(item=>item.backup_path)].filter((path,index,array)=>path&&array.indexOf(path)===index);
      const zip=new window.JSZip(),prefix=`full/${backup.backup_key}/`;
      for(let index=0;index<paths.length;index+=1){
        setSync("pending",`Packaging ${index+1}/${paths.length}`);
        const path=paths[index],{data,error}=await state.client.storage.from(CONFIG.backupBucket).download(path);if(error)throw error;
        zip.file(path.startsWith(prefix)?path.slice(prefix.length):path,await data.arrayBuffer(),{binary:true});
      }
      zip.file("RESTORE_README.txt",`${schoolDisplayName()} Report Card Enterprise v6.9.0 Reusable Schools Edition\n\nThis package contains AES-256-GCM encrypted NISB2 payloads. Keep the NIS_BACKUP_ENCRYPTION_KEY secret separately. Follow FINAL_BACKUP_AND_RESTORE_RUNBOOK.md from the complete system package. Authentication password hashes are not exportable through the supported Supabase Auth API; users must reset passwords after a full project rebuild.\n`);
      const blob=await zip.generateAsync({type:"blob",compression:"STORE"});
      const filename=`${slugify(schoolDisplayName(),"school")}-Full-Backup-${backup.backup_key}.zip`;downloadBlob(filename,blob);
      toast("Encrypted package downloaded",`${filename}. After copying it to a separate secure location, use Confirm off-site copy.`);setSync("online","Synced");
    }catch(error){toast("Backup package not downloaded",friendlyError(error),"error",9000);setSync("pending","Retry required")}
    finally{button.disabled=false}
  }
  async function confirmBackupOffsiteCopy(backupId,button) {
    if(!await confirmAction("Confirm Secure Off-site Copy","Confirm only after the downloaded encrypted backup package has been stored in a separate protected location, such as an encrypted external drive or approved cloud archive.","Confirm copy"))return;
    button.disabled=true;
    try{
      const note=window.prompt("Optional location or reference note (do not enter the encryption key):","Encrypted package stored in a separate secure location")||"Encrypted package stored in a separate secure location";
      await rpc("mark_backup_offsite_copy",{target_backup_id:backupId,target_note:note});
      toast("Off-site copy confirmed","The continuity record has been updated.");
      await renderSettings(state.viewToken,true);
    }catch(error){toast("Off-site copy not confirmed",friendlyError(error),"error",7000)}
    finally{button.disabled=false}
  }
  async function queueIncompleteNotifications() {
    const term=activeTerm();if(!term)return;
    const count=await run(()=>rpc("queue_incomplete_report_notifications",{target_term_id:term.id}),{success:"Notifications queued"});
    toast("Scheduled operation completed",`${number(count)} notifications queued`);
  }


  const REUSABLE_FRONTEND_TEXT_FILES=Object.freeze(["index.html","style.css","app.js"]);
  const REUSABLE_FRONTEND_BINARY_FILES=Object.freeze([
    "assets/approved-terminal-report-template.png",
    "assets/vendor/supabase-2.110.5.js","assets/vendor/qrcode-1.0.0.min.js",
    "assets/vendor/pdfjs-3.11.174.min.js","assets/vendor/pdfjs-3.11.174.worker.min.js",
    "assets/vendor/jszip-3.10.1.min.js","assets/vendor/docx-preview-0.4.0.min.js",
    "assets/vendor/html2canvas-1.4.1.min.js"
  ]);
  const REUSABLE_PACKAGE_SOURCE_FILES=Object.freeze([
    "01_schema_foundation.sql","02_schema_operations.sql","03A_schema_hardening_persistence_and_jobs.sql",
    "03B1_schema_staff_academics_and_signatures.sql","03B2_schema_governance_workflow_and_upgrades.sql","04_schema.sql","05_schema.sql","06_schema.sql","07_schema.sql",
    "supabase/functions/admin-user-management/index.ts","supabase/functions/notification-dispatcher/index.ts","supabase/functions/scheduled-backup/index.ts",
    "tools/backup-decryptor.html","tools/vendor/jszip-3.10.1.min.js",
    "README_FIRST_FRESH_INSTALL.txt","QUICK_INSTALL_CHECKLIST.txt","SCHEMA_SEQUENCE_POLICY.txt","PROJECT_MANIFEST.json",
    "COMPLETE_FRESH_SETUP_SUPABASE_TO_GITHUB.md","FINAL_BACKUP_AND_RESTORE_RUNBOOK.md",
    "REUSABLE_SCHOOL_PACKAGE_GENERATOR_GUIDE.md","RELEASE_NOTES_6_7_2_OPTIONAL_EMAIL_DOMAIN.txt","UPGRADE_FROM_V6_7_1_TO_V6_7_2_OPTIONAL_EMAIL_DOMAIN.txt","RELEASE_NOTES_6_7_3_COMPACT_SCROLL_LISTS.txt","UPGRADE_FROM_V6_7_2_TO_V6_7_3_COMPACT_SCROLL_LISTS.txt","Report_Card_Enterprise_v6_7_3_VALIDATION_REPORT.txt",
    "RELEASE_NOTES_6_7_4_COMPACT_REPORTS_AND_BULK_DOWNLOADS.txt","UPGRADE_FROM_V6_7_3_TO_V6_7_4_COMPACT_REPORTS_AND_BULK_DOWNLOADS.txt","Report_Card_Enterprise_v6_7_4_VALIDATION_REPORT.txt",
    "RELEASE_NOTES_6_8_0_ATTENDANCE_AND_CLASS_SECURITY.txt","UPGRADE_FROM_V6_7_4_TO_V6_8_0.txt","Report_Card_Enterprise_v6_8_0_VALIDATION_REPORT.txt",
    "RELEASE_NOTES_6_8_1_REPORT_WORKFLOW_CONTROL.txt","UPGRADE_FROM_V6_8_0_TO_V6_8_1.txt","Report_Card_Enterprise_v6_8_1_VALIDATION_REPORT.txt",
    "RELEASE_NOTES_6_8_2_PDF_AND_TEMPLATE_STORAGE_FIX.txt","UPGRADE_FROM_V6_8_1_TO_V6_8_2.txt","Report_Card_Enterprise_v6_8_2_VALIDATION_REPORT.txt",
    "RELEASE_NOTES_6_9_0_PLATFORM_LICENSING_CONTROL.txt","UPGRADE_FROM_V6_8_2_TO_V6_9_0.txt","Report_Card_Enterprise_v6_9_0_VALIDATION_REPORT.txt","PLATFORM_SUPER_ADMIN_SETUP.sql"
  ]);
  const PACKAGE_LOGO_TYPES=new Set(["image/png","image/jpeg","image/webp"]);
  const PACKAGE_LOGO_MAX_BYTES=5*1024*1024;

  function githubNavigatorStepsHtml() {
    return `<div class="navigator-steps">
      <article><b>1</b><div><strong>Generate</strong><span>Enter the new school identity, upload its logo, and download the complete fresh package.</span></div></article>
      <article><b>2</b><div><strong>Configure Supabase</strong><span>Run the nine schema files, deploy the three Edge Functions, run SCHOOL_IDENTITY_SETUP.sql, then provision the separate Platform Super Administrator.</span></div></article>
      <article><b>3</b><div><strong>Create GitHub repository</strong><span>Upload only the contents of GITHUB_PAGES_FRONTEND to the repository root.</span></div></article>
      <article><b>4</b><div><strong>Enable GitHub Pages</strong><span>Publish from the main branch and root folder, then configure the final URL in Supabase Auth.</span></div></article>
    </div>`;
  }

  async function renderGithubNavigator(token) {
    if(token!==state.viewToken)return;
    const currentSchool=schoolDisplayName();
    byId("content").innerHTML=`
      <div class="page-head"><div><h3>GitHub Navigator</h3><p>Create a separate, fully branded Report Card Enterprise package for another school</p></div></div>
      <div class="grid two package-generator-layout">
        <section class="panel pad">
          <div class="section-title"><div><h4>Reusable School Package Generator</h4><p>The generated ZIP does not modify this school. It contains a complete fresh Supabase package and a GitHub Pages frontend branded for the new school.</p></div></div>
          <form id="schoolPackageForm" class="form-grid">
            <label class="field full"><span>New school name</span><input name="school_name" maxlength="120" placeholder="Example Academy" required></label>
            <label class="field"><span>Short application name</span><input name="short_name" maxlength="30" placeholder="Example Reports"></label>
            <label class="field"><span>Report number prefix</span><input name="report_prefix" maxlength="12" placeholder="EA" required></label>
            <label class="field full"><span>User account email domain <em>(optional)</em></span><input name="email_domain" placeholder="school.edu.gh (optional)"><small>Enter only a domain, such as school.edu.gh. Leave blank to use a safe non-deliverable .invalid placeholder. It can be changed later under Settings before email delivery is enabled.</small></label>
            <label class="field full"><span>School logo</span><input id="schoolPackageLogo" name="school_logo" type="file" accept="image/png,image/jpeg,image/webp" required><small>PNG, JPEG, or WebP. Maximum 5 MB. The generator converts the image to a deployment-ready PNG.</small></label>
            <div class="package-logo-preview full"><img id="schoolPackageLogoPreview" src="${CONFIG.logoPath}" alt="Package logo preview"><div><strong id="schoolPackageNamePreview">New school package</strong><span>The generated package will use this name and logo on login, MFA, sidebar, verification, reports, manifest, and browser icons.</span></div></div>
            <label class="field full"><span>GitHub repository name</span><input name="repository_name" maxlength="80" placeholder="example-academy-report-card" required></label>
            <label class="field full"><span>Supabase Project URL (optional)</span><input name="supabase_url" placeholder="https://your-project.supabase.co"><small>Leave blank to generate a placeholder config.js for the new school.</small></label>
            <label class="field full"><span>Supabase Publishable key (optional)</span><input name="supabase_key" placeholder="sb_publishable_..."><small>Only a browser-safe Publishable key may be included. Secret and service-role keys are rejected.</small></label>
            <div class="full template-information"><strong>Current installation protected</strong><span>${esc(currentSchool)} remains unchanged. The generator performs all branding and packaging in your browser.</span></div>
            <div class="full button-row"><button class="button primary" id="generateSchoolPackage" type="button">Generate complete school package</button></div>
            <div id="packageGeneratorProgress" class="generator-progress full hidden" aria-live="polite"><span class="spinner small"></span><strong>Preparing package</strong><span id="packageGeneratorProgressText">Validating school identity</span></div>
          </form>
        </section>
        <div class="grid">
          <section class="panel pad"><div class="section-title"><div><h4>GitHub Deployment Navigator</h4><p>Use these shortcuts after downloading the generated ZIP.</p></div></div>
            ${githubNavigatorStepsHtml()}
            <div class="github-link-grid">
              <a class="github-link-card" href="https://github.com/new" target="_blank" rel="noopener"><strong>Create GitHub repository</strong><span>Open GitHub's new repository page</span></a>
              <a class="github-link-card" href="https://github.com/settings/pages" target="_blank" rel="noopener"><strong>GitHub Pages settings</strong><span>Open account Pages settings</span></a>
              <a class="github-link-card" href="https://supabase.com/dashboard/projects" target="_blank" rel="noopener"><strong>Supabase projects</strong><span>Create or open the new school's project</span></a>
            </div>
          </section>
          <section class="panel pad"><div class="section-title"><h4>Generated Package Contents</h4></div>
            <div class="diff-row"><span>Eight ordered database schema files</span><b>Included</b></div>
            <div class="diff-row"><span>Three Supabase Edge Functions</span><b>Included</b></div>
            <div class="diff-row"><span>Branded GitHub Pages frontend</span><b>Included</b></div>
            <div class="diff-row"><span>School identity SQL</span><b>Included</b></div>
            <div class="diff-row"><span>Backup decryptor and recovery guide</span><b>Included</b></div>
            <div class="diff-row"><span>Deployment instructions</span><b>Included</b></div>
          </section>
        </div>
      </div>`;
    bindGithubNavigator();
  }

  function suggestedPrefix(name) {
    const words=String(name||"").trim().split(/\s+/).filter(word=>!/^(school|academy|college|international|the|of)$/i.test(word));
    const initials=(words.length?words:String(name||"").trim().split(/\s+/)).map(word=>word[0]||"").join("").replace(/[^a-z0-9]/gi,"").toUpperCase();
    return (initials||"SCH").slice(0,8);
  }
  function validEmailDomain(value) {return /^(?:[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?\.)+[a-z]{2,63}$/i.test(String(value||"").trim())}
  function generatedPlaceholderEmailDomain(schoolName) {
    const label=slugify(schoolName,"school").slice(0,55).replace(/-+$/g,"")||"school";
    return `${label}.invalid`;
  }
  function sqlLiteral(value) {return `'${String(value??"").replace(/'/g,"''")}'`}
  function safeShortName(name,value) {return String(value||`${suggestedPrefix(name)} Reports`).trim().slice(0,30)||"School Reports"}
  function generatedAppJs(baseApp,identity) {
    return baseApp
      .replace(/window\.NIS_CONFIG\?\.appName \|\| "[^"]*"/,`window.NIS_CONFIG?.appName || ${JSON.stringify(`${identity.schoolName} Report Card System`)}`)
      .replace(/window\.NIS_CONFIG\?\.schoolName \|\| "[^"]*"/,`window.NIS_CONFIG?.schoolName || ${JSON.stringify(identity.schoolName)}`)
      .replace(/window\.NIS_CONFIG\?\.schoolShortName \|\| "[^"]*"/,`window.NIS_CONFIG?.schoolShortName || ${JSON.stringify(identity.shortName)}`)
      .replace(/window\.NIS_CONFIG\?\.userEmailDomain \|\| "[^"]*"/,`window.NIS_CONFIG?.userEmailDomain || ${JSON.stringify(identity.emailDomain)}`)
      .replace(/window\.NIS_CONFIG\?\.reportNumberPrefix \|\| "[^"]*"/,`window.NIS_CONFIG?.reportNumberPrefix || ${JSON.stringify(identity.reportPrefix)}`)
      .replace(/window\.NIS_CONFIG\?\.logoPath \|\| "[^"]*"/,'window.NIS_CONFIG?.logoPath || "assets/school-logo.png"');
  }
  function generatorConfigText(identity) {
    return `// Generated by Report Card Enterprise v6.9.0 Reusable Schools Edition.\n// Add only the browser-safe Supabase Project URL and Publishable key.\nwindow.NIS_CONFIG = Object.freeze({\n  supabaseUrl: ${JSON.stringify(identity.supabaseUrl||"YOUR_SUPABASE_URL")},\n  supabaseAnonKey: ${JSON.stringify(identity.supabaseKey||"YOUR_SUPABASE_PUBLISHABLE_KEY")},\n  appName: ${JSON.stringify(`${identity.schoolName} Report Card System`)},\n  schoolName: ${JSON.stringify(identity.schoolName)},\n  schoolShortName: ${JSON.stringify(identity.shortName)},\n  userEmailDomain: ${JSON.stringify(identity.emailDomain)},\n  reportNumberPrefix: ${JSON.stringify(identity.reportPrefix)},\n  generatedSchoolPackage: true,\n  logoPath: "assets/school-logo.png",\n  defaultReportTemplatePath: "assets/approved-terminal-report-template.png"\n});\n`;
  }
  function generatorIdentitySql(identity) {
    return `-- ${identity.schoolName} identity bootstrap\n-- Run after 06_schema.sql in the new school's Supabase SQL Editor.\n\nbegin;\n\nupdate public.school_settings\nset school_name=${sqlLiteral(identity.schoolName)},\n    logo_url='assets/school-logo.png',\n    report_number_prefix=${sqlLiteral(identity.reportPrefix)},\n    user_email_domain=${sqlLiteral(identity.emailDomain)},\n    updated_at=now()\nwhere id=(select id from public.school_settings order by created_at,id limit 1);\n\ncommit;\n\nselect school_name,logo_url,report_number_prefix,user_email_domain\nfrom public.school_settings\norder by created_at,id\nlimit 1;\n`;
  }
  function generatorReadme(identity) {
    const configured=Boolean(identity.supabaseUrl&&identity.supabaseKey);
    return `# ${identity.schoolName} Report Card Enterprise\n\nGenerated with Report Card Enterprise v6.9.0 Reusable Schools Edition.\n\n## Fresh setup order\n\n1. Create a separate Supabase project for ${identity.schoolName}.\n2. Run the nine SQL files in order, from 01_schema_foundation.sql through 07_schema.sql.\n3. Deploy the three Edge Functions in supabase/functions.\n4. Configure Edge Function secrets and Vault as described in COMPLETE_FRESH_SETUP_SUPABASE_TO_GITHUB.md.\n5. Run SCHOOL_IDENTITY_SETUP.sql.\n6. ${configured?"The generated config.js already contains the supplied Project URL and Publishable key. Verify both values before deployment.":"Edit GITHUB_PAGES_FRONTEND/config.js and enter the new Supabase Project URL and Publishable key."}\n7. Create a GitHub repository named ${identity.repositoryName}.\n8. Upload the contents inside GITHUB_PAGES_FRONTEND to the repository root.\n9. Enable GitHub Pages from main / root.\n10. Add the final GitHub Pages URL to Supabase Authentication Site URL and Redirect URLs.\n11. Create the intended System Administrator as the first Auth user.\n12. Create a separate platform-owner Auth user, edit PLATFORM_SUPER_ADMIN_SETUP.sql with that email, run it, and complete mandatory MFA.\n\n## Branding\n\nSchool name: ${identity.schoolName}\nShort name: ${identity.shortName}\nReport prefix: ${identity.reportPrefix}\nUser email domain: ${identity.emailDomain}${identity.emailDomainProvided?"":" (generated non-deliverable placeholder; change in Settings before enabling email delivery)"}\nLogo file: GITHUB_PAGES_FRONTEND/assets/school-logo.png\n\nDo not publish Supabase Secret keys, service-role keys, database passwords, cron secrets, backup encryption keys, or email-service secrets to GitHub.\n`;
  }
  function generatedIndexHtml(baseHtml,identity) {
    const safeName=esc(identity.schoolName);
    return baseHtml
      .replace(/assets\/(?:nipe-school-logo|school-logo)\.png/g,"assets/school-logo.png")
      .replace(/(<[^>]+data-school-name[^>]*>)[\s\S]*?(<\/[^>]+>)/g,`$1${safeName}$2`)
      .replace(/(<strong id="brandName"[^>]*>)[\s\S]*?(<\/strong>)/i,`$1${safeName}$2`)
      .replace(/(<img[^>]+data-school-logo[^>]+alt=")[^"]*(")/g,`$1${safeName}$2`)
      .replace(/<title>[\s\S]*?<\/title>/i,`<title>${safeName} | Report Cards</title>`);
  }
  function generatedServiceWorker(identity) {
    const cache=`report-card-${slugify(identity.schoolName)}-v6-8-2-r1`;
    return `const CACHE_NAME=${JSON.stringify(cache)};\nconst STATIC_ASSETS=[\n  "./","index.html","style.css","app.js","config.js","manifest.webmanifest",\n  "assets/school-logo.png","assets/approved-terminal-report-template.png",\n  "assets/vendor/supabase-2.110.5.js","assets/vendor/qrcode-1.0.0.min.js",\n  "assets/vendor/pdfjs-3.11.174.min.js","assets/vendor/pdfjs-3.11.174.worker.min.js",\n  "assets/vendor/jszip-3.10.1.min.js","assets/vendor/docx-preview-0.4.0.min.js",\n  "assets/vendor/html2canvas-1.4.1.min.js"\n];\nself.addEventListener("install",event=>event.waitUntil(caches.open(CACHE_NAME).then(cache=>cache.addAll(STATIC_ASSETS)).then(()=>self.skipWaiting())));\nself.addEventListener("activate",event=>event.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(key=>key!==CACHE_NAME).map(key=>caches.delete(key)))).then(()=>self.clients.claim())));\nself.addEventListener("fetch",event=>{const request=event.request;if(request.method!=="GET")return;const url=new URL(request.url);if(url.hostname.endsWith(".supabase.co")){event.respondWith(fetch(request).catch(()=>new Response(JSON.stringify({message:"offline"}),{status:503,headers:{"Content-Type":"application/json"}})));return;}if(url.pathname.endsWith("/config.js")){event.respondWith(fetch(request,{cache:"no-store"}).then(response=>{if(response.ok){const clone=response.clone();caches.open(CACHE_NAME).then(cache=>cache.put(request,clone));}return response;}).catch(()=>caches.match(request)));return;}if(request.mode==="navigate"){event.respondWith(fetch(request).then(response=>{const clone=response.clone();caches.open(CACHE_NAME).then(cache=>cache.put("index.html",clone));return response;}).catch(()=>caches.match("index.html")));return;}event.respondWith(caches.match(request).then(cached=>cached||fetch(request).then(response=>{if(response.ok&&url.origin===self.location.origin){const clone=response.clone();caches.open(CACHE_NAME).then(cache=>cache.put(request,clone));}return response;})));});\nself.addEventListener("sync",event=>{if(event.tag==="nis-outbox")event.waitUntil(self.clients.matchAll({type:"window",includeUncontrolled:true}).then(clients=>clients.forEach(client=>client.postMessage({type:"FLUSH_OUTBOX"}))));});\nself.addEventListener("message",event=>{if(event.data?.type==="SKIP_WAITING")self.skipWaiting();});\n`;
  }
  function generatedManifest(identity) {
    return JSON.stringify({name:`${identity.schoolName} Report Card Enterprise`,short_name:identity.shortName,description:`Academic reporting and student records for ${identity.schoolName}`,start_url:"./",display:"standalone",background_color:"#f4f7fb",theme_color:"#0a2f73",icons:[{src:"assets/school-logo.png",sizes:"512x512",type:"image/png",purpose:"any maskable"}]},null,2)+"\n";
  }
  async function fetchPackageFile(path,binary=false) {
    const response=await fetch(path,{cache:"no-store"});
    if(!response.ok)throw new Error(`Required package file is unavailable: ${path}`);
    return binary?response.arrayBuffer():response.text();
  }
  async function packageLogoPng(file) {
    if(!file)throw new Error("Upload the new school's logo.");
    if(!PACKAGE_LOGO_TYPES.has(file.type))throw new Error("School logo must be PNG, JPEG, or WebP.");
    if(file.size>PACKAGE_LOGO_MAX_BYTES)throw new Error("School logo must not exceed 5 MB.");
    const objectUrl=URL.createObjectURL(file);
    try{
      const image=await loadImage(objectUrl),maximum=1024,scale=Math.min(1,maximum/Math.max(image.naturalWidth||image.width,image.naturalHeight||image.height));
      const width=Math.max(1,Math.round((image.naturalWidth||image.width)*scale)),height=Math.max(1,Math.round((image.naturalHeight||image.height)*scale));
      if(width<64||height<64)throw new Error("School logo must be at least 64 by 64 pixels.");
      const canvas=document.createElement("canvas");canvas.width=width;canvas.height=height;
      const context=canvas.getContext("2d");context.clearRect(0,0,width,height);context.drawImage(image,0,0,width,height);
      return await new Promise((resolve,reject)=>canvas.toBlob(blob=>blob?resolve(blob):reject(new Error("School logo could not be converted to PNG.")),"image/png",0.95));
    } finally {URL.revokeObjectURL(objectUrl)}
  }
  function bindGithubNavigator() {
    const form=byId("schoolPackageForm"),nameInput=form.elements.school_name,shortInput=form.elements.short_name,prefixInput=form.elements.report_prefix,repoInput=form.elements.repository_name,logoInput=byId("schoolPackageLogo");
    let previousName="";
    const syncSuggestions=()=>{
      const name=nameInput.value.trim();byId("schoolPackageNamePreview").textContent=name||"New school package";
      if(!shortInput.value.trim()||shortInput.dataset.auto==="true"){shortInput.value=name?`${suggestedPrefix(name)} Reports`:"";shortInput.dataset.auto="true"}
      if(!prefixInput.value.trim()||prefixInput.dataset.auto==="true"){prefixInput.value=name?suggestedPrefix(name):"";prefixInput.dataset.auto="true"}
      if(!repoInput.value.trim()||repoInput.dataset.auto==="true"){repoInput.value=name?`${slugify(name)}-report-card`:"";repoInput.dataset.auto="true"}
      previousName=name;
    };
    nameInput.addEventListener("input",syncSuggestions);
    [shortInput,prefixInput,repoInput].forEach(input=>input.addEventListener("input",()=>{input.dataset.auto="false"}));
    logoInput.addEventListener("change",()=>{
      const file=logoInput.files?.[0];if(!file)return;
      if(state.packageLogoPreviewUrl)URL.revokeObjectURL(state.packageLogoPreviewUrl);
      state.packageLogoPreviewUrl=URL.createObjectURL(file);byId("schoolPackageLogoPreview").src=state.packageLogoPreviewUrl;
    });
    byId("generateSchoolPackage").onclick=generateReusableSchoolPackage;
  }
  async function generateReusableSchoolPackage() {
    if(state.packageGeneratorBusy)return;
    if(!window.JSZip){toast("Package generator unavailable","The packaged ZIP library did not load.","error");return}
    const form=byId("schoolPackageForm");if(!form?.reportValidity())return;
    const values=formObject(form),schoolName=String(values.school_name||"").trim(),shortName=safeShortName(schoolName,values.short_name),reportPrefix=String(values.report_prefix||"").trim().toUpperCase().replace(/[^A-Z0-9]/g,"").slice(0,12),emailDomainInput=String(values.email_domain||"").trim().toLowerCase(),emailDomainProvided=Boolean(emailDomainInput),emailDomain=emailDomainInput||generatedPlaceholderEmailDomain(schoolName),repositoryName=slugify(values.repository_name||`${schoolName}-report-card`),supabaseUrl=String(values.supabase_url||"").trim(),supabaseKey=String(values.supabase_key||"").trim();
    if(schoolName.length<3){toast("Package not generated","School name must contain at least three characters.","error");return}
    if(reportPrefix.length<2){toast("Package not generated","Report number prefix must contain at least two letters or numbers.","error");return}
    if(emailDomainProvided&&!validEmailDomain(emailDomain)){toast("Package not generated","Enter only a valid domain, for example school.edu.gh, or leave this optional field blank.","error");return}
    if(supabaseUrl&&!/^https:\/\/[a-z0-9-]+\.supabase\.co\/?$/i.test(supabaseUrl)){toast("Package not generated","Supabase Project URL is invalid.","error");return}
    if(/service_role|sb_secret_/i.test(supabaseKey)){toast("Secret key rejected","Use only a browser-safe Supabase Publishable key. Never package a Secret or service-role key.","error",8000);return}
    if(supabaseKey&&!/^sb_publishable_[A-Za-z0-9._-]+$/.test(supabaseKey)&&!/^eyJ[A-Za-z0-9._-]+$/.test(supabaseKey)){toast("Package not generated","Supabase key is not a valid Publishable or legacy anon key.","error");return}
    const identity={schoolName,shortName,reportPrefix,emailDomain,emailDomainProvided,repositoryName,supabaseUrl:supabaseUrl.replace(/\/$/,""),supabaseKey};
    const button=byId("generateSchoolPackage"),progress=byId("packageGeneratorProgress"),progressText=byId("packageGeneratorProgressText");
    state.packageGeneratorBusy=true;button.disabled=true;progress.classList.remove("hidden");setSync("pending","Generating package");
    try{
      progressText.textContent="Converting school logo";const logoBlob=await packageLogoPng(byId("schoolPackageLogo").files?.[0]);
      const zip=new window.JSZip(),root=`${slugify(schoolName)}-report-card-enterprise-v6.9.0`,frontend=`${root}/GITHUB_PAGES_FRONTEND`;
      progressText.textContent="Loading application files";
      const textFiles={};
      for(const path of REUSABLE_FRONTEND_TEXT_FILES)textFiles[path]=await fetchPackageFile(path,false);
      zip.file(`${frontend}/index.html`,generatedIndexHtml(textFiles["index.html"],identity));
      zip.file(`${frontend}/style.css`,textFiles["style.css"]);zip.file(`${frontend}/app.js`,generatedAppJs(textFiles["app.js"],identity));
      zip.file(`${frontend}/config.js`,generatorConfigText(identity));zip.file(`${frontend}/service-worker.js`,generatedServiceWorker(identity));zip.file(`${frontend}/manifest.webmanifest`,generatedManifest(identity));zip.file(`${frontend}/.nojekyll`,"");
      zip.file(`${frontend}/.gitignore`,".DS_Store\nThumbs.db\n*.log\n");zip.file(`${frontend}/DEPLOY_README.txt`,generatorReadme(identity));zip.file(`${frontend}/assets/school-logo.png`,logoBlob);
      let completed=0,total=REUSABLE_FRONTEND_BINARY_FILES.length+REUSABLE_PACKAGE_SOURCE_FILES.length;
      for(const path of REUSABLE_FRONTEND_BINARY_FILES){completed+=1;progressText.textContent=`Copying frontend assets ${completed}/${total}`;zip.file(`${frontend}/${path}`,await fetchPackageFile(path,true));}
      for(const path of REUSABLE_PACKAGE_SOURCE_FILES){completed+=1;progressText.textContent=`Copying Supabase and recovery files ${completed}/${total}`;const data=await fetchPackageFile(`package-source/${path}`,true);zip.file(`${root}/${path}`,data);zip.file(`${frontend}/package-source/${path}`,data);}
      zip.file(`${root}/SCHOOL_IDENTITY_SETUP.sql`,generatorIdentitySql(identity));zip.file(`${root}/GENERATED_PACKAGE_README.md`,generatorReadme(identity));
      zip.file(`${root}/GENERATED_PACKAGE_METADATA.json`,JSON.stringify({generator_version:"6.9.0",generated_at:new Date().toISOString(),school_name:schoolName,school_short_name:shortName,report_number_prefix:reportPrefix,user_email_domain:emailDomain,user_email_domain_provided:emailDomainProvided,email_delivery_ready:emailDomainProvided,repository_name:repositoryName,supabase_config_included:Boolean(supabaseUrl&&supabaseKey)},null,2)+"\n");
      progressText.textContent="Compressing complete package";const blob=await zip.generateAsync({type:"blob",compression:"DEFLATE",compressionOptions:{level:6}});const filename=`${slugify(schoolName)}_Report_Card_Enterprise_v6_7_4_Fresh_Complete_Package.zip`;downloadBlob(filename,blob);
      toast("Reusable school package generated",emailDomainProvided?`${filename} is ready for the new school's separate Supabase and GitHub deployment.`:`${filename} is ready. A safe .invalid email-domain placeholder was added and can be changed later in Settings.`,"success",9000);setSync("online","Synced");
    } catch(error){toast("Package not generated",friendlyError(error),"error",9000);setSync("pending","Retry required");await reportClientError(error,{source:"reusable_school_package_generator"})}
    finally{state.packageGeneratorBusy=false;button.disabled=false;progress.classList.add("hidden")}
  }

  async function showVerification(token) {
    showOnly("verifyView");
    const root=byId("verifyView");root.innerHTML=`<div class="verify-card"><div class="empty">Verifying report</div></div>`;
    try{
      if(!isConfigured()||!window.supabase?.createClient)throw new Error("Verification service unavailable");
      if(!state.client)state.client=window.supabase.createClient(CONFIG.supabaseUrl,CONFIG.supabaseAnonKey,{auth:{persistSession:false}});
      const data=await rpc("verify_report",{token});
      root.innerHTML=`<section class="verify-card">
        <div class="verify-head"><img src="${schoolDisplayLogo()}" alt=""><div><h1>${esc(schoolDisplayName())}</h1><p>Report Card Verification</p></div></div>
        <div class="verify-state ${data.valid?"valid":"invalid"}">${data.valid?"Authentic published report":data.revoked?"Publication withdrawn":"Report not verified"}</div>
        ${data.report_number?`<div class="verify-result">
          ${verifyField("Report number",data.report_number)}${verifyField("Student",data.student_name)}
          ${verifyField("Admission number",data.admission_no)}${verifyField("Class",data.class_name)}
          ${verifyField("Academic year",data.academic_year)}${verifyField("Term",data.term_name)}
          ${verifyField("Average",`${number(data.average,1)}%`)}${verifyField("Published",isoDateTime(data.published_at))}
        </div>`:""}
      </section>`;
    }catch(error){root.innerHTML=`<section class="verify-card"><div class="verify-state invalid">Verification unavailable</div></section>`}
  }
  function verifyField(label,value){return `<div class="verify-field"><span>${esc(label)}</span><strong>${esc(value??"—")}</strong></div>`}

})();
