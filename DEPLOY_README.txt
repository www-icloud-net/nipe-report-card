REPORT CARD ENTERPRISE v7.0.1 REUSABLE SCHOOLS EDITION
GITHUB PAGES DEPLOYMENT

Deploy the contents of this GITHUB_PAGES_FRONTEND directory only.

Upgrade from the confirmed v6.9.2 baseline:
1. Preserve v6.9.2 and create a verified encrypted backup.
2. Run 08_schema.sql after the complete 07_schema.sql.
3. Confirm: 08 SCHEMA v7.0.1 PRODUCTION MATURITY SUITE: PASS.
4. Redeploy scheduled-backup and platform-package-manager.
5. Preserve the existing production config.js values.
6. Upload the protected PLATFORM_PACKAGE_TEMPLATE_v7_0_1.zip through GitHub Navigator.
7. Hard-refresh the browser and complete the acceptance tests in UPGRADE_FROM_V6_9_2_TO_V7_0_1.txt.

Never upload Supabase service-role keys, signing secrets, backup encryption keys, GitHub tokens, or database passwords to this public directory.
