# Reusable School Package Generator

The GitHub Navigator is available only to the System Administrator and appears immediately after **Settings**.

## Purpose

It creates a separate fresh installation package for another school. Generation occurs in the browser and does not update the current school's database, name, logo, students, reports, or configuration.

## Required information

- New school name
- New school logo in PNG, JPEG, or WebP format
- Report-number prefix
- User-account email domain
- GitHub repository name

The Supabase Project URL and browser-safe Publishable key are optional. Leave them blank when the new school's Supabase project has not yet been created.

## Generated package

The ZIP includes:

- Eight ordered database schema files
- Three Supabase Edge Functions
- A branded `GITHUB_PAGES_FRONTEND` folder
- `SCHOOL_IDENTITY_SETUP.sql`
- Complete fresh setup and backup-recovery guides
- Offline backup decryptor
- Generated deployment README and metadata

## Security

The generator rejects Supabase Secret keys and service-role keys. Never enter database passwords, cron secrets, backup encryption keys, or email-service secrets in the generator.

## New-school installation

1. Create a separate Supabase project.
2. Run the eight SQL files in their numbered order, ending with `06_schema.sql`.
3. Deploy all three Edge Functions and configure required secrets.
4. Run `SCHOOL_IDENTITY_SETUP.sql` after `06_schema.sql`.
5. Edit the generated `config.js` when Supabase values were not supplied during generation.
6. Upload the contents of `GITHUB_PAGES_FRONTEND` to a new GitHub repository.
7. Enable GitHub Pages and configure the final URL in Supabase Authentication URL settings.
8. Create the intended System Administrator as the first Auth user.


## Optional user-account email domain

The email-domain field may be left blank. In that case, the generator assigns a safe school-specific placeholder ending in `.invalid`. This placeholder supports account generation but cannot receive email. Replace it later under **Settings → School Identity → User email domain** before relying on invitation, recovery, or notification email delivery. Enter only a domain such as `school.edu.gh`, not a complete email address.
