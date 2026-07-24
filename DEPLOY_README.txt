REPORT CARD ENTERPRISE v7.0.2 REUSABLE SCHOOLS EDITION
GITHUB PAGES DEPLOYMENT

1. Preserve the production config.js values.
2. Apply the appended v7.0.2 section of 08_schema.sql in Supabase.
3. Confirm: 08 SCHEMA v7.0.2 NEXT-TERM REOPENING DATE: PASS.
4. Deploy only the contents of GITHUB_PAGES_FRONTEND to the configured GitHub Pages branch.
5. Redeploy scheduled-backup and platform-package-manager.
6. Keep RCE_PACKAGE_SIGNING_SECRET and all existing production secrets unchanged.
7. Upload PLATFORM_PACKAGE_TEMPLATE_v7_0_2.zip through GitHub Navigator after Platform Super Administrator MFA.
8. Hard-refresh the browser or clear the previous service-worker cache.
9. Complete the acceptance tests in UPGRADE_FROM_V7_0_1_TO_V7_0_2.txt.

Never publish service-role credentials, backup encryption keys, package signing secrets, or the private reusable package source.
