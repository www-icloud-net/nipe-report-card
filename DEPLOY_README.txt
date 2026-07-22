REPORT CARD ENTERPRISE v6.9.0 REUSABLE SCHOOLS EDITION

DEPLOYMENT
1. Preserve the production config.js values and a verified v6.8.2 backup.
2. Run the v6.9.0 continuation appended to 07_schema.sql.
3. Confirm: 07 SCHEMA v6.9.0 PLATFORM LICENSING CONTROL: PASS.
4. Redeploy admin-user-management and scheduled-backup.
5. Deploy this frontend folder to GitHub Pages.
6. Hard refresh or allow the v6.9.0 service worker to activate.
7. Create a separate platform-owner Auth user and run PLATFORM_SUPER_ADMIN_SETUP.sql.
8. Complete mandatory MFA and perform the acceptance tests in UPGRADE_FROM_V6_8_2_TO_V6_9_0.txt.

The package-source folder is required by GitHub Navigator and must remain in the deployment.
