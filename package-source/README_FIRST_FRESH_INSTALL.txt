REPORT CARD ENTERPRISE v6.8.0 REUSABLE SCHOOLS EDITION
FRESH COMPLETE PACKAGE

CURRENT STATUS
- Built from the confirmed stable production baseline: v6.7.4 Reusable Schools Edition.
- Student, teacher, principal, and account directories use deterministic alphabetical name ordering.
- Teacher student visibility is restricted to current students in officially assigned classes.
- Approved Term 3 promotion changes the student's active placement to the next class and deactivates the previous placement.
- Students who are not promoted remain in their previous class.
- Class teachers have a daily Attendance section for only their assigned home class.
- Attendance totals automatically update report-card days present and days school opened.
- The reusable-school generator includes the same v6.8.0 database, frontend, attendance, security, and backup updates.

THIS PACKAGE INCLUDES
- Complete frontend and GitHub Pages deployment folder.
- Eight ordered permanent database SQL files.
- Three Supabase Edge Functions.
- Reusable school package-source files for browser-based generation.
- Exact locally hosted browser libraries.
- Complete encrypted backup, retention, verification, and off-site export controls.
- Offline backup decryptor and recovery runbook.
- Approval-gated Term 3 promotion governance.
- Class attendance registers and attendance entries included in encrypted backups.

FRESH DATABASE ORDER
1. 01_schema_foundation.sql
2. 02_schema_operations.sql
3. 03A_schema_hardening_persistence_and_jobs.sql
4. 03B1_schema_staff_academics_and_signatures.sql
5. 03B2_schema_governance_workflow_and_upgrades.sql
6. 04_schema.sql
7. 05_schema.sql
8. 06_schema.sql

IMPORTANT
- Run each SQL file separately and wait for success before continuing.
- Deploy the three Edge Functions after files 01 and 02, before file 03A.
- Configure NIS_CRON_SECRET and NIS_BACKUP_ENCRYPTION_KEY before deploying scheduled-backup.
- Configure nis_project_url and nis_cron_secret through Supabase Vault SQL before file 03A.
- Fresh installations must not run historical SQL_HOTFIX files.
- Only upload the CONTENTS of GITHUB_PAGES_FRONTEND to GitHub Pages.
- Preserve the real Project URL and Publishable key in config.js during upgrades.
- For another school, use GitHub Navigator to generate a separate package and run its SCHOOL_IDENTITY_SETUP.sql after 06_schema.sql.

START HERE
Read COMPLETE_FRESH_SETUP_SUPABASE_TO_GITHUB.md.
For an existing v6.7.4 installation, read UPGRADE_FROM_V6_7_4_TO_V6_8_0.txt.
For package generation, read REUSABLE_SCHOOL_PACKAGE_GENERATOR_GUIDE.md.
For continuity and recovery, read FINAL_BACKUP_AND_RESTORE_RUNBOOK.md.
