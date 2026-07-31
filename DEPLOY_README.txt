REPORT CARD ENTERPRISE v7.3.0 FINAL LICENSING HARDENING

Deploy every file in this directory together. Do not deploy files selectively.

MASTER PLATFORM
- Preserve the production Supabase URL and publishable key in config.js.
- generatedSchoolPackage must remain false.
- Deploy all six master Edge Functions separately according to SUPABASE_DASHBOARD_SETUP.txt.

GENERATED SCHOOL
- Use the generated config.js without replacing its package, installation, tenant, project, domain, or key-binding values.
- Deploy only admin-user-management, notification-dispatcher, scheduled-backup, and license-verifier.
- Do not deploy platform-package-manager or license-authority.

After deployment, hard-refresh browsers and confirm service-worker cache `rce-v7-3-0-final-r1`. Complete the live licence, role, offline, Storage, and report acceptance tests before production use.
