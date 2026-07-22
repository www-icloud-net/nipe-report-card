REPORT CARD ENTERPRISE v6.9.1 REUSABLE SCHOOLS EDITION

DEPLOYMENT SUMMARY
1. Preserve the confirmed v6.9.0 package and create a verified backup.
2. Run only the appended v6.9.1 continuation in 07_schema.sql.
3. Confirm: 07 SCHEMA v6.9.1 PLATFORM PACKAGE CONTROL: PASS.
4. Redeploy admin-user-management, scheduled-backup, and the new platform-package-manager Edge Function.
5. Configure RCE_PACKAGE_SIGNING_SECRET with at least 32 random characters.
6. Deploy the contents of this GITHUB_PAGES_FRONTEND directory while preserving production config.js values.
7. Confirm that no package-source directory is published.
8. Sign in as the Platform Super Administrator with MFA and upload PLATFORM_PACKAGE_TEMPLATE_v6_9_1.zip through GitHub Navigator.
9. Confirm that school System Administrators cannot see or invoke GitHub Navigator.
10. Complete all acceptance tests in UPGRADE_FROM_V6_9_0_TO_V6_9_1.txt.

Never publish Supabase Secret keys, service-role keys, RCE_PACKAGE_SIGNING_SECRET, backup encryption keys, cron secrets, or email-service credentials.
