import { createClient } from "npm:@supabase/supabase-js@2.110.5";

function getServiceKey() {
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
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const jsonHeaders = { ...cors, "Content-Type": "application/json" };
const allowedRoles = new Set([
  "system_admin", "principal", "class_teacher", "subject_teacher", "parent_guardian",
]);

function response(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: jsonHeaders });
}
function decodeJwtPayload(token: string): Record<string, unknown> {
  try {
    const encoded = token.split(".")[1] ?? "";
    const normalized = encoded.replaceAll("-", "+").replaceAll("_", "/");
    const padded = normalized.padEnd(Math.ceil(normalized.length / 4) * 4, "=");
    return JSON.parse(atob(padded));
  } catch {
    return {};
  }
}
function normalizeAccess(value: unknown) {
  if (value == null) return [];
  if (!Array.isArray(value)) return [{ class_id: "", subject_id: null, access_level: "invalid" }];
  return value.map((raw) => ({
    class_id: String(raw?.class_id ?? "").trim(),
    subject_id: String(raw?.subject_id ?? "").trim() || null,
    access_level: String(raw?.access_level ?? "view").trim(),
  }));
}
function normalizeAuthPhone(value: string) {
  const phone = value.trim();
  return /^\+[1-9]\d{7,14}$/.test(phone) ? phone : undefined;
}
const nameTitles = new Set([
  "mr", "mrs", "ms", "miss", "madam", "master", "dr", "doctor", "rev", "reverend",
  "prof", "professor", "principal", "headmaster", "headmistress",
]);
function nipEmailBase(fullName: string) {
  const parts = fullName.normalize("NFKD").replace(/[\u0300-\u036f]/g, "").toLowerCase().split(/\s+/)
    .map((part) => part.replace(/[^a-z0-9]/g, "")).filter(Boolean);
  return parts.find((part) => !nameTitles.has(part)) ?? parts[0] ?? "user";
}
function isDuplicateEmailError(error: unknown) {
  return /already registered|already exists|duplicate|email.*exists/i.test(errorMessage(error));
}
function errorMessage(error: unknown) {
  if (error instanceof Error) return error.message;
  if (typeof error === "object" && error && "message" in error) return String((error as { message: unknown }).message);
  return String(error ?? "User account operation failed");
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (request.method !== "POST") return response({ error: "method_not_allowed" }, 405);

  const url = Deno.env.get("SUPABASE_URL") ?? "";
  const serviceKey = getServiceKey();
  if (!url || !serviceKey) return response({ error: "service_configuration_unavailable" }, 500);

  const authorization = request.headers.get("authorization") ?? "";
  const token = authorization.replace(/^Bearer\s+/i, "").trim();
  if (!token) return response({ error: "authentication_required" }, 401);

  const service = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: userData, error: userError } = await service.auth.getUser(token);
  if (userError || !userData.user) return response({ error: "invalid_session" }, 401);

  const actorId = userData.user.id;
  const { data: actor, error: actorError } = await service
    .from("profiles")
    .select("id, role, active, mfa_required")
    .eq("id", actorId)
    .maybeSingle();
  if (actorError || !actor?.active || !["system_admin", "admin"].includes(actor.role)) {
    return response({ error: "access_denied" }, 403);
  }
  const jwt = decodeJwtPayload(token);
  if (actor.mfa_required && jwt.aal !== "aal2") return response({ error: "mfa_required" }, 403);

  let body: Record<string, any>;
  try {
    body = await request.json();
  } catch {
    return response({ error: "invalid_request" }, 400);
  }

  const action = String(body.action ?? "");
  const payload = body.payload ?? {};
  const role = String(payload.role ?? "parent_guardian").trim();
  const active = payload.active !== false;
  let fullName = String(payload.full_name ?? "").trim();
  let phone = String(payload.phone ?? "").trim();
  let email = "";
  const staffRecordId = String(payload.staff_record_id ?? "").trim();
  const mfaRequired = payload.mfa_required === true;
  const mustChangePassword = payload.must_change_password === true || payload.force_password_change === true;
  const access = normalizeAccess(payload.access);

  if (["principal", "class_teacher", "subject_teacher"].includes(role)) {
    if (!staffRecordId) return response({ error: "staff_record_required" }, 400);
    const table = role === "principal" ? "headteachers" : "teachers";
    const { data: staff, error: staffError } = await service
      .from(table)
      .select("id, first_name, middle_name, last_name, phone, email, active, deleted_at")
      .eq("id", staffRecordId)
      .maybeSingle();
    if (staffError || !staff || staff.deleted_at || !staff.active) {
      return response({ error: "staff_record_unavailable" }, 400);
    }
    fullName = [staff.first_name, staff.middle_name, staff.last_name].filter(Boolean).join(" ").trim();
    if (!phone && staff.phone) phone = String(staff.phone).trim();
  }

  const authPhone = normalizeAuthPhone(phone);
  if (["create", "update"].includes(action)) {
    if (!fullName || !allowedRoles.has(role)) {
      return response({ error: "invalid_account_details" }, 400);
    }
  }

  async function resolveGeneratedEmail(targetUserId: string | null) {
    const { data, error } = await service.rpc("generate_nip_user_email", {
      actor_id: actorId,
      requested_base: nipEmailBase(fullName),
      target_user_id: targetUserId,
    });
    if (error) throw error;
    const generated = String(data ?? "").trim().toLowerCase();
    if (!/^[a-z0-9]+@(?!-)(?:[a-z0-9-]+\.)+[a-z]{2,63}$/.test(generated)) throw new Error("Generated account email is invalid");
    email = generated;
    return generated;
  }

  async function ensureLastAdministrator(targetId: string, nextRole: string, nextActive: boolean) {
    const { data: targetProfile, error } = await service.from("profiles").select("role, active").eq("id", targetId).maybeSingle();
    if (error) throw error;
    if (!targetProfile || !["system_admin", "admin"].includes(targetProfile.role)) return;
    if (nextActive && ["system_admin", "admin"].includes(nextRole)) return;
    const { count, error: countError } = await service
      .from("profiles")
      .select("id", { count: "exact", head: true })
      .eq("active", true)
      .in("role", ["system_admin", "admin"])
      .neq("id", targetId);
    if (countError) throw countError;
    if ((count ?? 0) < 1) throw new Error("At least one active system administrator is required");
  }

  function bundleFor(userId: string | null, reason: string) {
    return {
      user_id: userId,
      full_name: fullName,
      phone,
      email,
      role,
      staff_record_id: staffRecordId || null,
      active,
      mfa_required: mfaRequired,
      must_change_password: mustChangePassword,
      access,
      reason,
    };
  }

  async function validateBundle(userId: string | null, requireExistingUser: boolean, reason: string) {
    const { data, error } = await service.rpc("admin_validate_user_bundle", {
      actor_id: actorId,
      bundle: bundleFor(userId, reason),
      require_existing_user: requireExistingUser,
    });
    if (error) throw error;
    return data;
  }

  async function applyBundle(userId: string, reason: string) {
    const { data, error } = await service.rpc("admin_apply_user_bundle", {
      actor_id: actorId,
      bundle: bundleFor(userId, reason),
    });
    if (error) throw error;
    return data;
  }

  try {
    if (action === "create") {
      const password = String(payload.password ?? "");
      if (password.length < 8) return response({ error: "password_too_short" }, 400);

      let createdUser: any = null;
      for (let attempt = 0; attempt < 5 && !createdUser; attempt += 1) {
        await resolveGeneratedEmail(null);
        await validateBundle(null, false, String(payload.reason ?? "User account created"));
        const { data: created, error: createError } = await service.auth.admin.createUser({
          email,
          password,
          email_confirm: true,
          phone: authPhone,
          user_metadata: { full_name: fullName, must_change_password: mustChangePassword },
          app_metadata: { role },
        });
        if (!createError && created.user) {
          createdUser = created.user;
          break;
        }
        if (!isDuplicateEmailError(createError)) throw createError ?? new Error("User account was not created");
      }
      if (!createdUser) throw new Error("A unique school user account email could not be created");

      const userId = createdUser.id;
      try {
        if (!active) {
          const { error: banError } = await service.auth.admin.updateUserById(userId, { ban_duration: "876000h" });
          if (banError) throw banError;
        }
        const bundle = await applyBundle(userId, String(payload.reason ?? "User account created"));
        return response({ id: userId, email, full_name: fullName, role, active, bundle });
      } catch (error) {
        await service.auth.admin.deleteUser(userId).catch(() => undefined);
        throw error;
      }
    }

    if (action === "update") {
      const userId = String(payload.user_id ?? "").trim();
      if (!userId) return response({ error: "user_id_required" }, 400);
      if (userId === actorId && !active) return response({ error: "cannot_deactivate_current_account" }, 400);

      const { data: previousAuthData, error: previousAuthError } = await service.auth.admin.getUserById(userId);
      if (previousAuthError || !previousAuthData.user) throw previousAuthError ?? new Error("Authentication account not found");
      const previousAuth = previousAuthData.user;
      email = String(previousAuth.email ?? "").trim().toLowerCase();
      if (!email) await resolveGeneratedEmail(userId);

      await ensureLastAdministrator(userId, role, active);
      await validateBundle(userId, true, String(payload.reason ?? "User account updated"));

      const authAttributes: Record<string, unknown> = {
        email,
        email_confirm: true,
        ...(authPhone ? { phone: authPhone } : {}),
        user_metadata: { ...(previousAuth.user_metadata ?? {}), full_name: fullName, must_change_password: mustChangePassword },
        app_metadata: { ...(previousAuth.app_metadata ?? {}), role },
        ban_duration: active ? "none" : "876000h",
      };
      const password = String(payload.password ?? "");
      if (password) {
        if (password.length < 8) return response({ error: "password_too_short" }, 400);
        authAttributes.password = password;
      }

      const { error: authUpdateError } = await service.auth.admin.updateUserById(userId, authAttributes);
      if (authUpdateError) throw authUpdateError;
      try {
        const bundle = await applyBundle(userId, String(payload.reason ?? "User account updated"));
        return response({ id: userId, email, full_name: fullName, role, active, bundle });
      } catch (bundleError) {
        await service.auth.admin.updateUserById(userId, {
          email: previousAuth.email,
          email_confirm: Boolean(previousAuth.email_confirmed_at),
          phone: previousAuth.phone || undefined,
          user_metadata: previousAuth.user_metadata,
          app_metadata: previousAuth.app_metadata,
          ban_duration: previousAuth.banned_until ? "876000h" : "none",
        }).catch(() => undefined);
        throw bundleError;
      }
    }

    if (action === "delete") {
      const userId = String(payload.user_id ?? "").trim();
      if (!userId) return response({ error: "user_id_required" }, 400);
      if (userId === actorId) return response({ error: "cannot_delete_current_account" }, 400);
      await ensureLastAdministrator(userId, "parent_guardian", false);

      const { data: profile, error: profileError } = await service
        .from("profiles")
        .select("id, full_name, role, active, phone, mfa_required")
        .eq("id", userId)
        .maybeSingle();
      if (profileError || !profile) throw profileError ?? new Error("User profile not found");
      const { data: authRecord, error: authRecordError } = await service.auth.admin.getUserById(userId);
      if (authRecordError || !authRecord.user) throw authRecordError ?? new Error("Authentication account not found");
      const { data: accessRows } = await service.from("user_class_access").select("*").eq("user_id", userId);
      const { data: teacher } = await service.from("teachers").select("id, staff_no").eq("profile_id", userId).is("deleted_at", null).maybeSingle();
      const { data: principal } = await service.from("headteachers").select("id, staff_no").eq("profile_id", userId).is("deleted_at", null).maybeSingle();
      const snapshot = {
        profile,
        email: authRecord.user.email,
        access: accessRows ?? [],
        teacher: teacher ?? null,
        principal: principal ?? null,
      };

      const { error: deleteError } = await service.auth.admin.deleteUser(userId);
      if (deleteError) throw deleteError;
      const { error: auditError } = await service.from("audit_log").insert({
        actor_id: actorId,
        table_name: "profiles",
        record_id: userId,
        action: "ADMIN_DELETE_USER",
        old_data: snapshot,
        new_data: null,
        reason: String(payload.reason ?? "User account permanently deleted"),
      });
      if (auditError) throw auditError;
      return response({ id: userId, deleted: true });
    }

    if (action === "reset_password") {
      const userId = String(payload.user_id ?? "").trim();
      const password = String(payload.password ?? "");
      if (!userId || password.length < 8) return response({ error: "invalid_password_reset" }, 400);

      const { data: targetProfile, error: profileError } = await service
        .from("profiles")
        .select("id, full_name, must_change_password")
        .eq("id", userId)
        .maybeSingle();
      if (profileError || !targetProfile) throw profileError ?? new Error("User profile not found");

      const previousRequired = targetProfile.must_change_password === true;
      const { data: authData, error: authReadError } = await service.auth.admin.getUserById(userId);
      if (authReadError || !authData.user) throw authReadError ?? new Error("Authentication account not found");

      const { error: profileUpdateError } = await service
        .from("profiles")
        .update({ must_change_password: mustChangePassword, updated_at: new Date().toISOString() })
        .eq("id", userId);
      if (profileUpdateError) throw profileUpdateError;

      const { error: authUpdateError } = await service.auth.admin.updateUserById(userId, {
        password,
        user_metadata: { ...(authData.user.user_metadata ?? {}), must_change_password: mustChangePassword },
      });
      if (authUpdateError) {
        await service.from("profiles").update({ must_change_password: previousRequired }).eq("id", userId);
        throw authUpdateError;
      }

      const { error: auditError } = await service.from("audit_log").insert({
        actor_id: actorId,
        table_name: "profiles",
        record_id: userId,
        action: "ADMIN_RESET_PASSWORD",
        old_data: { must_change_password: previousRequired },
        new_data: { must_change_password: mustChangePassword },
        reason: String(payload.reason ?? "Password reset by the System Administrator"),
      });
      if (auditError) throw auditError;

      return response({ id: userId, reset: true, must_change_password: mustChangePassword });
    }

    return response({ error: "unsupported_action" }, 400);
  } catch (error) {
    const message = errorMessage(error);
    const status = /already|duplicate|exists/i.test(message) ? 409 : 400;
    return response({ error: message }, status);
  }
});
