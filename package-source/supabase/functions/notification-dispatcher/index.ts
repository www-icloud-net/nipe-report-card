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
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-cron-secret",
};

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: cors });
  const cronSecret = Deno.env.get("NIS_CRON_SECRET") ?? "";
  if (!cronSecret || request.headers.get("x-cron-secret") !== cronSecret) {
    return new Response(JSON.stringify({ error: "unauthorised" }), { status: 401, headers: { ...cors, "Content-Type": "application/json" } });
  }

  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = getServiceKey();
  if (!url || !serviceKey) return new Response(JSON.stringify({ error: "service configuration unavailable" }), { status: 500, headers: { ...cors, "Content-Type": "application/json" } });

  const supabase = createClient(url, serviceKey, { auth: { persistSession: false } });
  const workerId = crypto.randomUUID();
  const { data: jobs, error } = await supabase.rpc("claim_notification_jobs", {
    target_batch_size: 50,
    target_worker_id: workerId,
  });

  if (error) return new Response(JSON.stringify({ error: error.message }), { status: 500, headers: { ...cors, "Content-Type": "application/json" } });

  const resendKey = Deno.env.get("RESEND_API_KEY") ?? "";
  const fromAddress = Deno.env.get("NIS_EMAIL_FROM") ?? "";
  let processed = 0;
  let failed = 0;

  for (const job of jobs ?? []) {
    try {
      if (job.channel !== "email" || !job.recipient_email) throw new Error("Unsupported or incomplete notification channel");
      if (!resendKey) throw new Error("Email provider unavailable");
      if (!fromAddress) throw new Error("NIS_EMAIL_FROM is not configured");

      const response = await fetch("https://api.resend.com/emails", {
        method: "POST",
        headers: { "Authorization": `Bearer ${resendKey}`, "Content-Type": "application/json" },
        body: JSON.stringify({
          from: fromAddress,
          to: [job.recipient_email],
          subject: String(job.payload?.title ?? "Nipe International School"),
          text: String(job.payload?.body ?? ""),
        }),
      });
      if (!response.ok) throw new Error(`Email provider returned ${response.status}`);

      const { data: completed, error: completionError } = await supabase.rpc("complete_notification_job", {
        target_job_id: job.id,
        target_worker_id: workerId,
        target_success: true,
        target_error: "",
      });
      if (completionError || completed !== true) throw completionError ?? new Error("Notification lock ownership changed");
      processed += 1;
    } catch (jobError) {
      await supabase.rpc("complete_notification_job", {
        target_job_id: job.id,
        target_worker_id: workerId,
        target_success: false,
        target_error: jobError instanceof Error ? jobError.message : String(jobError),
      });
      failed += 1;
    }
  }

  return new Response(JSON.stringify({ processed, failed }), {
    headers: { ...cors, "Content-Type": "application/json" },
  });
});
