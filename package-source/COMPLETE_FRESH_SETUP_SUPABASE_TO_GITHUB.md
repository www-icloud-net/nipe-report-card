# Report Card Enterprise v6.8.2 Reusable Schools Edition

## Complete Fresh Setup: Supabase Dashboard to GitHub Pages

This procedure uses the Supabase Dashboard, SQL Editor and Edge Function editor. The permanent database contains seven ordered SQL files.

## 1. Prepare the package

Extract the ZIP. Keep these areas available:

- Seven SQL files at package root
- `supabase/functions`
- `GITHUB_PAGES_FRONTEND`
- `FINAL_BACKUP_AND_RESTORE_RUNBOOK.md`

Do not upload the complete package to GitHub Pages.

## 2. Create the Supabase project

1. Create a new Supabase project.
2. Save the database password securely.
3. Wait for provisioning to complete.
4. Copy the Project URL.
5. Copy the browser-safe Publishable key.
6. Never place a Secret key, service-role key or database password in public frontend files.

## 3. Generate two different security secrets

In Supabase SQL Editor, run the following twice, saving each result under a different name:

```sql
select encode(gen_random_bytes(32),'base64') as generated_secret;
```

Use the first value as `NIS_CRON_SECRET`.
Use the second value as `NIS_BACKUP_ENCRYPTION_KEY`.

The values must be different. Store the backup encryption key separately from backup files.

## 4. Run files 01 and 02

Run each file in a separate SQL Editor tab:

1. `01_schema_foundation.sql`
2. `02_schema_operations.sql`

Confirm file 02 returns:

```text
02 SCHEMA OPERATIONS: PASS
```

## 5. Deploy the Edge Functions

Create and deploy the following functions using the files supplied in the package.

### admin-user-management

- Source: `supabase/functions/admin-user-management/index.ts`
- Verify JWT: enabled

### notification-dispatcher

- Source: `supabase/functions/notification-dispatcher/index.ts`
- Verify JWT: disabled
- Scheduled requests remain protected by `x-cron-secret`

### scheduled-backup

- Source: `supabase/functions/scheduled-backup/index.ts`
- Verify JWT: disabled
- Scheduled requests use `x-cron-secret`
- Manual requests require an authenticated MFA AAL2 System Administrator

## 6. Configure Edge Function Secrets

Add:

| Secret | Requirement |
|---|---|
| `NIS_CRON_SECRET` | Required, first generated value |
| `NIS_BACKUP_ENCRYPTION_KEY` | Required, separate second value of at least 32 characters |
| `RESEND_API_KEY` | Only when email dispatch is used |
| `NIS_EMAIL_FROM` | Only when email dispatch is used |

Optional capacity controls:

- `NIS_BACKUP_MAX_OBJECTS`, default 5000
- `NIS_BACKUP_MAX_BYTES`, default 536870912
- `NIS_BACKUP_VERIFY_MAX_OBJECTS`, default 5000

Increase these only after reviewing the actual project size and Edge Function execution limits.

## 7. Configure Supabase Vault through SQL Editor

Run:

```sql
create extension if not exists supabase_vault cascade;
```

Create the Project URL secret, without a trailing slash:

```sql
select vault.create_secret(
  'https://PROJECT_REF.supabase.co',
  'nis_project_url',
  'Nipe Report Card Supabase project URL'
);
```

Create the cron secret using the exact `NIS_CRON_SECRET` value:

```sql
select vault.create_secret(
  'PASTE_NIS_CRON_SECRET_HERE',
  'nis_cron_secret',
  'Nipe scheduled Edge Function authentication secret'
);
```

Verify names without exposing values:

```sql
select name,description,created_at
from vault.secrets
where name in ('nis_project_url','nis_cron_secret')
order by name;
```

Do not store `NIS_BACKUP_ENCRYPTION_KEY` in public application tables or frontend files.

## 8. Run files 03A through 07

Run separately and in order:

1. `03A_schema_hardening_persistence_and_jobs.sql`
2. `03B1_schema_staff_academics_and_signatures.sql`
3. `03B2_schema_governance_workflow_and_upgrades.sql`
4. `04_schema.sql`
5. `05_schema.sql`
6. `06_schema.sql`
7. `07_schema.sql`

Confirm:

```text
04 SCHEMA: PASS
05 SCHEMA: PASS
06 SCHEMA: PASS
07 SCHEMA: PASS
```

Fresh installations do not run historical `SQL_HOTFIX` files.

## 9. Verify Storage buckets

Run:

```sql
select id,public,file_size_limit,allowed_mime_types
from storage.buckets
where id in (
  'student-photos','report-pdfs','system-backups',
  'headteacher-signatures','report-card-templates'
)
order by id;
```

Expected: five rows and `public = false` for every bucket.

## 10. Verify scheduled jobs

Run:

```sql
select jobname,schedule,active
from cron.job
where jobname in (
  'nis-notification-dispatcher',
  'nis-scheduled-backup',
  'nis-backup-verification'
)
order by jobname;
```

Expected backup schedules:

- `nis-scheduled-backup`: `15 2 * * *`
- `nis-backup-verification`: `15 3 * * 0`

If backup jobs are absent, verify the two Vault names and rerun `05_schema.sql`.

## 11. Create the first System Administrator

1. Open Authentication > Users.
2. Create the intended administrator with a strong temporary password.
3. Confirm the email.
4. Do not create test accounts before the intended first administrator.
5. Sign in and complete MFA enrollment.

## 12. Configure GitHub Pages frontend

Open `GITHUB_PAGES_FRONTEND/config.js` and enter only:

- Supabase Project URL
- Browser-safe Publishable key

Never enter server secrets.

Upload the CONTENTS of `GITHUB_PAGES_FRONTEND` to the root of the GitHub repository. The folder includes locally hosted exact library versions, so no runtime CDN is required.

Enable GitHub Pages:

- Source: Deploy from a branch
- Branch: `main`
- Folder: `/(root)`

Wait for deployment and record the final URL.

## 13. Configure Supabase Authentication URLs

Open Authentication > URL Configuration.

- Set Site URL to the exact GitHub Pages URL.
- Add the same exact URL as an allowed Redirect URL.
- Include the repository path and trailing slash where applicable.

## 14. Configure the application

As System Administrator:

1. Save school identity and report appearance.
2. Set the final verification base URL.
3. Create academic years and terms.
4. Create classes and subjects.
5. Configure class subjects, assessment schemes and grading scales.
6. Create the Principal and upload the current signature.
7. Create teachers and role assignments.
8. Create students and upload photographs where available.
9. Upload and preview the three class-range report templates when required.
10. Configure the Term 3 promotion cutoff.

## 15. Validate backup and recovery

1. Open Settings > Backup and Recovery.
2. Save a retention policy.
3. Create a full encrypted backup.
4. Wait for Completed.
5. Select Verify and require a Passed result.
6. Download the encrypted package.
7. Copy it to a separate protected location.
8. Select Confirm off-site copy only after that copy exists.
9. Test the offline decryptor according to the recovery runbook.

## 16. Validate promotion governance

1. Prepare a complete passing Term 3 report in Draft status.
2. Confirm it displays Eligible for the next class, awaiting approval.
3. Run individual or all-class promotion processing.
4. Confirm it is counted as eligible pending approval and no next-year enrolment is created.
5. Approve or publish the report.
6. Confirm the next-year enrolment is created automatically.
7. Return or withdraw the report and confirm its linked automatic enrolment is withdrawn.
8. Reapprove or republish and confirm it is restored without duplication.

## 17. Final role acceptance

Test System Administrator, Principal, Class Teacher, Subject Teacher and Parent or Guardian access. Verify score entry, comments, class-teacher-only submission, Principal individual and bulk approval, class-teacher or System Administrator individual and bulk publication, withdrawal, republication, deletion, PDF regeneration, QR verification, student photographs, signatures, templates, ranking and promotion. Also verify that Students, Teachers, Users and Access, Report Cards, Notifications and Audit Trail remain compact and scroll vertically when they contain long lists. Open **New report**, choose a class, and confirm that the student chooser scrolls within a fixed-height list.

The included validation report documents package-level checks. Live Supabase and browser acceptance remains required because production credentials and data are not available inside the package-build environment.


## Reusable installation for another school

After the primary system is deployed, the System Administrator can open **GitHub Navigator**, immediately after **Settings**, and generate a separate complete package for another school. The generator requires the new school name, logo, report-number prefix, and repository name. The user-account email domain is optional. When it is left blank, the generator inserts a safe school-specific placeholder ending in `.invalid`; replace that placeholder later under Settings before relying on email invitations, password recovery, or notification delivery. The generator may also include the new school's browser-safe Supabase Project URL and Publishable key.

The generated ZIP contains its own `SCHOOL_IDENTITY_SETUP.sql`. Run that file after `07_schema.sql` in the separate Supabase project. Upload only the contents of the generated `GITHUB_PAGES_FRONTEND` folder to the new school's GitHub repository. Package generation does not modify the original school's database or branding.
