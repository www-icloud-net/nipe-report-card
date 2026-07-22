import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.110.5";

function getServiceKey(): string {
  const current = Deno.env.get("SUPABASE_SECRET_KEYS") ?? "";
  if (current) {
    try {
      const keys = JSON.parse(current) as Record<string, string>;
      if (keys.default) return keys.default;
      const first = Object.values(keys).find(Boolean);
      if (first) return first;
    } catch {
      // Fall through to the legacy hosted variable.
    }
  }
  return Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
}

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-cron-secret",
};

const SCHEMA_VERSION = "6.9.0";
const BACKUP_FORMAT_VERSION = 2;
const BACKUP_BUCKET = "system-backups";
const SOURCE_BUCKETS = [
  "student-photos",
  "report-pdfs",
  "headteacher-signatures",
  "report-card-templates",
] as const;

const TABLES = [
  "school_settings",
  "profiles",
  "teachers",
  "headteachers",
  "academic_years",
  "terms",
  "classes",
  "subjects",
  "class_subjects",
  "user_class_access",
  "students",
  "student_guardians",
  "guardian_links",
  "enrollments",
  "class_attendance_registers",
  "student_attendance_entries",
  "grading_scales",
  "assessment_schemes",
  "assessment_components",
  "student_reports",
  "subject_scores",
  "subject_results",
  "assessment_score_entries",
  "report_workflow_events",
  "report_revisions",
  "report_publications",
  "report_card_templates",
  "license_plans",
  "school_licenses",
  "platform_access_locks",
  "license_events",
  "license_verification_logs",
  "notifications",
  "notification_outbox",
  "import_batches",
  "import_errors",
  "audit_log",
  "client_error_events",
  "system_maintenance_log",
  "backup_exports",
  "backup_storage_objects",
] as const;

type BackupRow = {
  id: string;
  backup_key: string;
  status: string;
  manifest_path: string;
  database_path: string;
  checksum: string;
  backup_type: string;
};

type Authorisation = {
  actorId: string | null;
  mode: "scheduled" | "manual";
};

type StoredObject = {
  source_bucket: string;
  source_path: string;
  backup_path: string;
  content_type: string;
  original_size: number;
  encrypted_size: number;
  checksum: string;
};

type BackupManifest = {
  format_version: number;
  schema_version: string;
  backup_id: string;
  backup_key: string;
  generated_at: string;
  encryption: {
    algorithm: string;
    key_hint: string;
    payload_format: string;
  };
  database: {
    path: string;
    checksum: string;
    row_counts: Record<string, number>;
    compressed_size: number;
    encrypted_size: number;
  };
  storage: {
    buckets: string[];
    object_counts: Record<string, number>;
    total_bytes: number;
    objects: StoredObject[];
  };
  auth_users: {
    count: number;
    password_hashes_included: false;
    note: string;
  };
};

const encoder = new TextEncoder();
const decoder = new TextDecoder();

function jsonResponse(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}

function parsePositiveLimit(name: string, fallback: number): number {
  const value = Number(Deno.env.get(name) ?? fallback);
  return Number.isFinite(value) && value > 0 ? Math.floor(value) : fallback;
}

function base64UrlDecode(value: string): string {
  const normalised = value.replaceAll("-", "+").replaceAll("_", "/");
  const padded = normalised.padEnd(Math.ceil(normalised.length / 4) * 4, "=");
  return atob(padded);
}

function jwtAssuranceLevel(token: string): string {
  try {
    const payload = JSON.parse(base64UrlDecode(token.split(".")[1] ?? "")) as Record<string, unknown>;
    return String(payload.aal ?? "");
  } catch {
    return "";
  }
}

async function authorise(
  request: Request,
  service: SupabaseClient,
): Promise<Authorisation> {
  const cronSecret = Deno.env.get("NIS_CRON_SECRET") ?? "";
  const suppliedCronSecret = request.headers.get("x-cron-secret") ?? "";
  if (cronSecret && suppliedCronSecret && suppliedCronSecret === cronSecret) {
    return { actorId: null, mode: "scheduled" };
  }

  const authorization = request.headers.get("authorization") ?? "";
  const token = authorization.match(/^Bearer\s+(.+)$/i)?.[1] ?? "";
  if (!token) throw new Error("unauthorised");

  const { data: userData, error: userError } = await service.auth.getUser(token);
  if (userError || !userData.user) throw new Error("unauthorised");
  if (jwtAssuranceLevel(token) !== "aal2") throw new Error("multi-factor authentication required");

  const { data: profile, error: profileError } = await service
    .from("profiles")
    .select("id,role,active")
    .eq("id", userData.user.id)
    .maybeSingle();
  if (profileError || !profile || !profile.active || profile.role !== "system_admin") {
    throw new Error("access denied");
  }
  const { data: licenceAccess, error: licenceError } = await service.rpc("license_access_for_actor", { actor_id: userData.user.id });
  if (licenceError) throw new Error(`licence check failed: ${licenceError.message}`);
  if (licenceAccess?.read_allowed !== true) throw new Error("platform access locked");
  return { actorId: userData.user.id, mode: "manual" };
}

async function sha256Bytes(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function encryptionMaterial(): Promise<{ key: CryptoKey; hint: string }> {
  const source = Deno.env.get("NIS_BACKUP_ENCRYPTION_KEY") ?? "";
  if (!source) throw new Error("NIS_BACKUP_ENCRYPTION_KEY is required");
  if (source.length < 32) throw new Error("NIS_BACKUP_ENCRYPTION_KEY must contain at least 32 characters");
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(source)));
  const key = await crypto.subtle.importKey("raw", digest, { name: "AES-GCM" }, false, ["encrypt", "decrypt"]);
  const hint = (await sha256Bytes(digest)).slice(0, 16);
  return { key, hint };
}

async function encryptPayload(bytes: Uint8Array, key: CryptoKey): Promise<Uint8Array> {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ciphertext = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, bytes));
  const magic = encoder.encode("NISB2");
  const output = new Uint8Array(magic.length + iv.length + ciphertext.length);
  output.set(magic, 0);
  output.set(iv, magic.length);
  output.set(ciphertext, magic.length + iv.length);
  return output;
}

async function decryptPayload(bytes: Uint8Array, key: CryptoKey): Promise<Uint8Array> {
  const magic = decoder.decode(bytes.slice(0, 5));
  if (magic !== "NISB2") throw new Error("Unsupported encrypted backup payload");
  const iv = bytes.slice(5, 17);
  const ciphertext = bytes.slice(17);
  return new Uint8Array(await crypto.subtle.decrypt({ name: "AES-GCM", iv }, key, ciphertext));
}

async function gzip(bytes: Uint8Array): Promise<Uint8Array> {
  const stream = new Blob([bytes]).stream().pipeThrough(new CompressionStream("gzip"));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

async function gunzip(bytes: Uint8Array): Promise<Uint8Array> {
  const stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream("gzip"));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

async function readAll(client: SupabaseClient, table: string): Promise<unknown[]> {
  const rows: unknown[] = [];
  const pageSize = 1000;
  for (let start = 0; ; start += pageSize) {
    const { data, error } = await client.from(table).select("*").range(start, start + pageSize - 1);
    if (error) throw new Error(`${table}: ${error.message}`);
    rows.push(...(data ?? []));
    if (!data || data.length < pageSize) break;
  }
  return rows;
}

async function readAuthUsers(client: SupabaseClient): Promise<unknown[]> {
  const users: unknown[] = [];
  const perPage = 1000;
  for (let page = 1; ; page += 1) {
    const { data, error } = await client.auth.admin.listUsers({ page, perPage });
    if (error) throw new Error(`auth.users: ${error.message}`);
    for (const user of data.users ?? []) {
      users.push({
        id: user.id,
        email: user.email,
        phone: user.phone,
        app_metadata: user.app_metadata,
        user_metadata: user.user_metadata,
        identities: user.identities,
        created_at: user.created_at,
        updated_at: user.updated_at,
        confirmed_at: user.confirmed_at,
        last_sign_in_at: user.last_sign_in_at,
        banned_until: user.banned_until,
      });
    }
    if ((data.users ?? []).length < perPage) break;
  }
  return users;
}

async function listBucketFiles(
  client: SupabaseClient,
  bucket: string,
  prefix = "",
): Promise<Array<{ path: string; metadata: Record<string, unknown> }>> {
  const files: Array<{ path: string; metadata: Record<string, unknown> }> = [];
  const pageSize = 100;
  for (let offset = 0; ; offset += pageSize) {
    const { data, error } = await client.storage.from(bucket).list(prefix, {
      limit: pageSize,
      offset,
      sortBy: { column: "name", order: "asc" },
    });
    if (error) throw new Error(`${bucket}/${prefix}: ${error.message}`);
    for (const item of data ?? []) {
      const path = prefix ? `${prefix}/${item.name}` : item.name;
      const metadata = (item.metadata ?? {}) as Record<string, unknown>;
      const isFolder = !item.id && Object.keys(metadata).length === 0;
      if (isFolder) files.push(...await listBucketFiles(client, bucket, path));
      else files.push({ path, metadata });
    }
    if (!data || data.length < pageSize) break;
  }
  return files;
}

function encodedStoragePath(path: string): string {
  return path.split("/").map((segment) => encodeURIComponent(segment)).join("/");
}

async function uploadBytes(
  client: SupabaseClient,
  path: string,
  bytes: Uint8Array,
  contentType: string,
): Promise<void> {
  const { error } = await client.storage.from(BACKUP_BUCKET).upload(path, bytes, {
    contentType,
    upsert: false,
  });
  if (error) throw new Error(`${path}: ${error.message}`);
}

async function downloadBytes(client: SupabaseClient, bucket: string, path: string): Promise<Uint8Array> {
  const { data, error } = await client.storage.from(bucket).download(path);
  if (error || !data) throw new Error(`${bucket}/${path}: ${error?.message ?? "download failed"}`);
  return new Uint8Array(await data.arrayBuffer());
}

async function createBackupRecord(
  client: SupabaseClient,
  actorId: string | null,
  mode: "scheduled" | "manual",
): Promise<BackupRow> {
  const now = new Date();
  const backupKey = `${now.toISOString().replaceAll(":", "-").replaceAll(".", "-")}-${crypto.randomUUID().slice(0, 8)}`;

  await client
    .from("backup_exports")
    .update({
      status: "failed",
      error_message: "Previous backup did not complete within two hours",
      completed_at: now.toISOString(),
    })
    .eq("status", "processing")
    .lt("started_at", new Date(now.getTime() - 2 * 60 * 60 * 1000).toISOString());

  const { data: active } = await client
    .from("backup_exports")
    .select("id")
    .eq("status", "processing")
    .gte("started_at", new Date(now.getTime() - 2 * 60 * 60 * 1000).toISOString())
    .limit(1);
  if (active?.length) throw new Error("A full backup is already processing");

  const { data, error } = await client
    .from("backup_exports")
    .insert({
      storage_path: "",
      checksum: "",
      status: "processing",
      row_counts: {},
      initiated_by: actorId,
      backup_key: backupKey,
      schema_version: SCHEMA_VERSION,
      backup_type: "full",
      manifest_path: "",
      database_path: "",
      storage_object_counts: {},
      storage_bytes: 0,
      encrypted: true,
      started_at: now.toISOString(),
      expires_at: null,
      error_message: "",
      verification_status: "not_tested",
      verification_notes: mode === "manual" ? "Manual full backup" : "Scheduled full backup",
    })
    .select("id,backup_key,status,manifest_path,database_path,checksum,backup_type")
    .single();
  if (error || !data) throw new Error(error?.message ?? "Backup record could not be created");
  return data as BackupRow;
}

async function buildDatabaseSnapshot(client: SupabaseClient, backup: BackupRow): Promise<{
  bytes: Uint8Array;
  checksum: string;
  rowCounts: Record<string, number>;
  authUserCount: number;
}> {
  const tables: Record<string, unknown[]> = {};
  const rowCounts: Record<string, number> = {};
  for (const table of TABLES) {
    let rows = await readAll(client, table);
    // The backup being created is operational metadata, not source application
    // data. Excluding it prevents a restored database from containing a stale
    // processing record or self-referential object rows. Prior backup history
    // remains included.
    if (table === "backup_exports") {
      rows = rows.filter((row) => String((row as Record<string, unknown>).id ?? "") !== backup.id);
    } else if (table === "backup_storage_objects") {
      rows = rows.filter((row) => String((row as Record<string, unknown>).backup_export_id ?? "") !== backup.id);
    }
    tables[table] = rows;
    rowCounts[table] = rows.length;
  }
  const authUsers = await readAuthUsers(client);
  rowCounts.auth_users = authUsers.length;
  const payload = encoder.encode(JSON.stringify({
    metadata: {
      format_version: BACKUP_FORMAT_VERSION,
      schema_version: SCHEMA_VERSION,
      backup_id: backup.id,
      backup_key: backup.backup_key,
      generated_at: new Date().toISOString(),
      auth_password_hashes_included: false,
      auth_restore_note: "Authentication users are included without password hashes. Recreated users must set or reset passwords during recovery.",
    },
    tables,
    auth_users: authUsers,
  }));
  return {
    bytes: payload,
    checksum: await sha256Bytes(payload),
    rowCounts,
    authUserCount: authUsers.length,
  };
}

async function performFullBackup(client: SupabaseClient, backup: BackupRow): Promise<void> {
  const maxObjects = parsePositiveLimit("NIS_BACKUP_MAX_OBJECTS", 5000);
  const maxBytes = parsePositiveLimit("NIS_BACKUP_MAX_BYTES", 536_870_912);
  const { key, hint } = await encryptionMaterial();
  const prefix = `full/${backup.backup_key}`;
  const databasePath = `${prefix}/database/database.json.gz.nisb`;
  const manifestPath = `${prefix}/manifest.json.nisb`;
  const indexPath = `${prefix}/index.json`;
  const objectCounts: Record<string, number> = {};
  const storedObjects: StoredObject[] = [];
  let totalStorageBytes = 0;

  try {
    const database = await buildDatabaseSnapshot(client, backup);
    const compressedDatabase = await gzip(database.bytes);
    const encryptedDatabase = await encryptPayload(compressedDatabase, key);
    await uploadBytes(client, databasePath, encryptedDatabase, "application/octet-stream");

    let discoveredObjects = 0;
    for (const bucket of SOURCE_BUCKETS) {
      const files = await listBucketFiles(client, bucket);
      objectCounts[bucket] = files.length;
      discoveredObjects += files.length;
      if (discoveredObjects > maxObjects) {
        throw new Error(`Storage object limit exceeded (${maxObjects}). Increase NIS_BACKUP_MAX_OBJECTS after reviewing Edge Function limits.`);
      }

      for (const file of files) {
        const originalBytes = await downloadBytes(client, bucket, file.path);
        totalStorageBytes += originalBytes.byteLength;
        if (totalStorageBytes > maxBytes) {
          throw new Error(`Storage byte limit exceeded (${maxBytes}). Increase NIS_BACKUP_MAX_BYTES after reviewing Edge Function limits.`);
        }
        const checksum = await sha256Bytes(originalBytes);
        const encryptedBytes = await encryptPayload(originalBytes, key);
        const backupPath = `${prefix}/storage/${bucket}/${encodedStoragePath(file.path)}.nisb`;
        await uploadBytes(client, backupPath, encryptedBytes, "application/octet-stream");
        const contentType = String(file.metadata.mimetype ?? file.metadata.contentType ?? "application/octet-stream");
        const objectRow: StoredObject = {
          source_bucket: bucket,
          source_path: file.path,
          backup_path: backupPath,
          content_type: contentType,
          original_size: originalBytes.byteLength,
          encrypted_size: encryptedBytes.byteLength,
          checksum,
        };
        storedObjects.push(objectRow);
        const { error: objectError } = await client.from("backup_storage_objects").insert({
          backup_export_id: backup.id,
          ...objectRow,
          status: "completed",
        });
        if (objectError) throw new Error(`Backup object record: ${objectError.message}`);
      }
    }

    const manifest: BackupManifest = {
      format_version: BACKUP_FORMAT_VERSION,
      schema_version: SCHEMA_VERSION,
      backup_id: backup.id,
      backup_key: backup.backup_key,
      generated_at: new Date().toISOString(),
      encryption: {
        algorithm: "AES-256-GCM",
        key_hint: hint,
        payload_format: "NISB2 + 12-byte IV + ciphertext/tag",
      },
      database: {
        path: databasePath,
        checksum: database.checksum,
        row_counts: database.rowCounts,
        compressed_size: compressedDatabase.byteLength,
        encrypted_size: encryptedDatabase.byteLength,
      },
      storage: {
        buckets: [...SOURCE_BUCKETS],
        object_counts: objectCounts,
        total_bytes: totalStorageBytes,
        objects: storedObjects,
      },
      auth_users: {
        count: database.authUserCount,
        password_hashes_included: false,
        note: "User identities and metadata are exported, but password hashes are not available through the supported Auth administration API.",
      },
    };

    const manifestPlain = encoder.encode(JSON.stringify(manifest));
    const encryptedManifest = await encryptPayload(manifestPlain, key);
    await uploadBytes(client, manifestPath, encryptedManifest, "application/octet-stream");
    const indexBytes = encoder.encode(JSON.stringify({
      format_version: BACKUP_FORMAT_VERSION,
      schema_version: SCHEMA_VERSION,
      backup_id: backup.id,
      backup_key: backup.backup_key,
      generated_at: manifest.generated_at,
      encrypted: true,
      algorithm: "AES-256-GCM",
      key_hint: hint,
      manifest_path: manifestPath,
      database_path: databasePath,
      storage_object_counts: objectCounts,
      storage_bytes: totalStorageBytes,
    }, null, 2));
    await uploadBytes(client, indexPath, indexBytes, "application/json");

    const { data: settings } = await client
      .from("school_settings")
      .select("backup_retention_days")
      .order("created_at", { ascending: true })
      .limit(1)
      .maybeSingle();
    const retentionDays = Number(settings?.backup_retention_days ?? 30);
    const completedAt = new Date();
    const expiresAt = new Date(completedAt.getTime() + retentionDays * 86_400_000);

    const { error: completeError } = await client.from("backup_exports").update({
      storage_path: indexPath,
      checksum: database.checksum,
      status: "completed",
      row_counts: database.rowCounts,
      manifest_path: manifestPath,
      database_path: databasePath,
      storage_object_counts: objectCounts,
      storage_bytes: totalStorageBytes,
      encrypted: true,
      encryption_key_hint: hint,
      completed_at: completedAt.toISOString(),
      expires_at: expiresAt.toISOString(),
      error_message: "",
    }).eq("id", backup.id);
    if (completeError) throw new Error(completeError.message);

    await applyRetention(client).catch((retentionError) => {
      console.error("Backup retention cleanup failed", retentionError);
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    await removePrefix(client, `full/${backup.backup_key}`).catch((cleanupError) => {
      console.error("Partial backup cleanup failed", cleanupError);
    });
    await client.from("backup_exports").update({
      status: "failed",
      completed_at: new Date().toISOString(),
      error_message: message.slice(0, 2000),
    }).eq("id", backup.id);
    throw error;
  }
}

async function removePrefix(client: SupabaseClient, prefix: string): Promise<void> {
  const files = await listBucketFiles(client, BACKUP_BUCKET, prefix);
  const paths = files.map((file) => file.path);
  for (let index = 0; index < paths.length; index += 100) {
    const batch = paths.slice(index, index + 100);
    const { error } = await client.storage.from(BACKUP_BUCKET).remove(batch);
    if (error) throw new Error(`Retention cleanup: ${error.message}`);
  }
}

async function applyRetention(client: SupabaseClient): Promise<void> {
  const { data: settings } = await client
    .from("school_settings")
    .select("backup_retention_days,backup_minimum_copies")
    .order("created_at", { ascending: true })
    .limit(1)
    .maybeSingle();
  const retentionDays = Number(settings?.backup_retention_days ?? 30);
  const minimumCopies = Number(settings?.backup_minimum_copies ?? 7);
  const cutoff = Date.now() - retentionDays * 86_400_000;
  const { data: backups, error } = await client
    .from("backup_exports")
    .select("id,backup_key,created_at,status")
    .eq("status", "completed")
    .eq("backup_type", "full")
    .order("created_at", { ascending: false });
  if (error) throw new Error(`Retention query: ${error.message}`);

  for (const [index, backup] of (backups ?? []).entries()) {
    if (index < minimumCopies) continue;
    if (new Date(backup.created_at).getTime() >= cutoff) continue;
    await removePrefix(client, `full/${backup.backup_key}`);
    const { error: deleteError } = await client.from("backup_exports").delete().eq("id", backup.id);
    if (deleteError) throw new Error(`Retention record cleanup: ${deleteError.message}`);
  }
}

async function verifyBackup(client: SupabaseClient, backupId?: string): Promise<Record<string, unknown>> {
  const query = client
    .from("backup_exports")
    .select("id,backup_key,status,manifest_path,database_path,checksum,backup_type")
    .eq("status", "completed")
    .eq("backup_type", "full")
    .order("created_at", { ascending: false })
    .limit(1);
  const { data, error } = backupId
    ? await client.from("backup_exports").select("id,backup_key,status,manifest_path,database_path,checksum,backup_type").eq("id", backupId).single()
    : await query.single();
  if (error || !data) throw new Error(error?.message ?? "Completed full backup not found");
  const backup = data as BackupRow;
  const { key, hint } = await encryptionMaterial();
  let checkedObjects = 0;
  let checkedBytes = 0;

  try {
    const encryptedManifest = await downloadBytes(client, BACKUP_BUCKET, backup.manifest_path);
    const manifestPlain = await decryptPayload(encryptedManifest, key);
    const manifest = JSON.parse(decoder.decode(manifestPlain)) as BackupManifest;
    if (manifest.backup_id !== backup.id || manifest.encryption.key_hint !== hint) {
      throw new Error("Backup manifest identity or encryption key does not match");
    }

    const encryptedDatabase = await downloadBytes(client, BACKUP_BUCKET, backup.database_path);
    const compressedDatabase = await decryptPayload(encryptedDatabase, key);
    const databaseBytes = await gunzip(compressedDatabase);
    const databaseChecksum = await sha256Bytes(databaseBytes);
    if (databaseChecksum !== manifest.database.checksum || databaseChecksum !== backup.checksum) {
      throw new Error("Database backup checksum verification failed");
    }
    JSON.parse(decoder.decode(databaseBytes));

    const maxVerifyObjects = parsePositiveLimit("NIS_BACKUP_VERIFY_MAX_OBJECTS", 5000);
    if (manifest.storage.objects.length > maxVerifyObjects) {
      throw new Error(`Verification object limit exceeded (${maxVerifyObjects})`);
    }
    for (const object of manifest.storage.objects) {
      const encryptedObject = await downloadBytes(client, BACKUP_BUCKET, object.backup_path);
      const originalObject = await decryptPayload(encryptedObject, key);
      const checksum = await sha256Bytes(originalObject);
      if (checksum !== object.checksum || originalObject.byteLength !== object.original_size) {
        throw new Error(`Storage verification failed for ${object.source_bucket}/${object.source_path}`);
      }
      checkedObjects += 1;
      checkedBytes += originalObject.byteLength;
    }

    const notes = `Full integrity rehearsal passed: database JSON decrypted, decompressed and parsed; ${checkedObjects} storage objects (${checkedBytes} bytes) decrypted and checksum-verified.`;
    await client.from("backup_exports").update({
      verification_status: "passed",
      verification_checked_at: new Date().toISOString(),
      verification_notes: notes,
    }).eq("id", backup.id);
    return { backup_id: backup.id, verification_status: "passed", checked_objects: checkedObjects, checked_bytes: checkedBytes };
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    await client.from("backup_exports").update({
      verification_status: "failed",
      verification_checked_at: new Date().toISOString(),
      verification_notes: message.slice(0, 2000),
    }).eq("id", backup.id);
    throw error;
  }
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (request.method !== "POST") return jsonResponse({ error: "method not allowed" }, 405);

  const url = Deno.env.get("SUPABASE_URL") ?? "";
  const serviceKey = getServiceKey();
  if (!url || !serviceKey) return jsonResponse({ error: "service configuration unavailable" }, 500);
  const service = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });

  try {
    const authorisation = await authorise(request, service);
    const body = await request.json().catch(() => ({})) as Record<string, unknown>;
    const action = String(body.action ?? "create");

    if (action === "verify" || action === "verify_latest") {
      const result = await verifyBackup(service, action === "verify" ? String(body.backup_id ?? "") : undefined);
      return jsonResponse(result);
    }
    if (action !== "create") return jsonResponse({ error: "unsupported action" }, 400);

    const backup = await createBackupRecord(service, authorisation.actorId, authorisation.mode);
    const task = performFullBackup(service, backup);
    const runtime = (globalThis as unknown as { EdgeRuntime?: { waitUntil(promise: Promise<unknown>): void } }).EdgeRuntime;
    if (runtime?.waitUntil) {
      runtime.waitUntil(task.catch((error) => console.error("Full backup failed", error)));
      return jsonResponse({ backup_id: backup.id, backup_key: backup.backup_key, status: "processing" }, 202);
    }
    await task;
    const { data: completed } = await service.from("backup_exports").select("*").eq("id", backup.id).single();
    return jsonResponse(completed ?? { backup_id: backup.id, status: "completed" });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    const status = message === "unauthorised" ? 401 : message === "access denied" || message.includes("multi-factor") ? 403 : 500;
    return jsonResponse({ error: message }, status);
  }
});
