REPORT CARD ENTERPRISE v6.8.2 REUSABLE SCHOOLS EDITION
FRESH COMPLETE PACKAGE

CURRENT STATUS
- Built from the confirmed stable production baseline: v6.8.0 Reusable Schools Edition.
- Student and staff directories retain deterministic alphabetical name ordering.
- Teacher student visibility remains restricted to current students in officially assigned classes.
- Approved Term 3 promotion changes the student's active placement only when promotion is applied.
- Class teachers retain the class-only daily attendance workflow and automatic term totals.
- Only the assigned class teacher can submit reports for Principal approval.
- Only the assigned class teacher or System Administrator can publish Principal-approved reports.
- Principals can approve all eligible reports for a selected class and term.
- Class teachers can submit or publish all eligible reports for their assigned home class and selected term.
- Subject teachers can enter assigned subject scores but cannot submit or publish reports.

THIS PACKAGE INCLUDES
- Complete frontend and GitHub Pages deployment folder.
- Nine ordered permanent database SQL files.
- Three Supabase Edge Functions.
- Reusable school package-source files for browser-based generation.
- Exact locally hosted browser libraries.
- Complete encrypted backup, retention, verification, and off-site export controls.
- Offline backup decryptor and recovery runbook.
- Approval-gated Term 3 promotion governance.
- Class attendance registers and attendance entries included in encrypted backups.
- Class-level bulk submit, approve, and publish controls with per-report validation.

FRESH DATABASE ORDER
1. 01_schema_foundation.sql
2. 02_schema_operations.sql
3. 03A_schema_hardening_persistence_and_jobs.sql
4. 03B1_schema_staff_academics_and_signatures.sql
5. 03B2_schema_governance_workflow_and_upgrades.sql
6. 04_schema.sql
7. 05_schema.sql
8. 06_schema.sql
9. 07_schema.sql

IMPORTANT
- Run each SQL file separately and wait for success before continuing.
- Deploy the three Edge Functions after files 01 and 02, before file 03A.
- Configure NIS_CRON_SECRET and NIS_BACKUP_ENCRYPTION_KEY before deploying scheduled-backup.
- Configure nis_project_url and nis_cron_secret through Supabase Vault SQL before file 03A.
- Fresh installations must not run historical SQL_HOTFIX files.
- Only upload the CONTENTS of GITHUB_PAGES_FRONTEND to GitHub Pages.
- Preserve the real Project URL and Publishable key in config.js during upgrades.
- For another school, use GitHub Navigator to generate a separate package and run its SCHOOL_IDENTITY_SETUP.sql after 07_schema.sql.

START HERE
Read COMPLETE_FRESH_SETUP_SUPABASE_TO_GITHUB.md.
For an existing v6.8.0 installation, read UPGRADE_FROM_V6_8_0_TO_V6_8_1.txt.
For package generation, read REUSABLE_SCHOOL_PACKAGE_GENERATOR_GUIDE.md.
For continuity and recovery, read FINAL_BACKUP_AND_RESTORE_RUNBOOK.md.
