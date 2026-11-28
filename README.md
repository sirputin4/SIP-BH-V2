# SIP-BH V2 — Sistem Informasi Pengawasan dan Evaluasi Bantuan Hukum

Prototype application for a thesis project. Frontend: React + Vite. Authentication, PostgreSQL database, Row Level Security and private file storage: Supabase. Hosting: GitHub Pages.

> **Terminologi antarmuka:** aplikasi menggunakan istilah **PBH (Pemberi Bantuan Hukum)** dan **Layanan Bantuan Hukum**. Untuk menjaga kompatibilitas dengan database yang sudah berjalan, nama tabel dan kolom internal seperti `obhs`, `obh_id`, dan alias `obh` tetap dipertahankan. Nama teknis tersebut tidak ditampilkan kepada pengguna.

## What is included

### Admin Kanwil
- Overview dashboard with annual filter, organization accreditation, verified service statistics and regional distribution.
- PBH master data: address, region, contact, accreditation status/year and active status.
- Account approval for PBH users.
- Beneficiary records and service registration for any PBH.
- Service verification, revision request and rejection with an Admin note.
- Service progress timeline.
- Periodic report review (accept, request revision, reject).
- Evaluation instrument with five configurable 1–5 criteria.
- CSV exports for service data, beneficiary data and automatic service recap.

### PBH
- Registration with an existing active PBH directory entry; new account waits for Admin approval.
- Organization profile and personnel/member directory.
- Beneficiary registration.
- Litigation service input: Perdata, Pidana, PTUN.
- Non-litigation activity input: Drafting Dokumen, Investigasi Kasus, Konsultasi Hukum, Mediasi, Negosiasi, Pemberdayaan Masyarakat, Pendampingan di Luar Pengadilan, Penelitian Hukum, Penyuluhan Hukum.
- Progress history for litigation and non-litigation services.
- Upload quarterly, semester and annual PDF/Excel reports (private storage, max 10 MB).
- Own-organization dashboard and evaluation results.

## Important: migrate the existing Supabase project safely

This project is designed to upgrade the V1 project without deleting the existing Admin account or PBH rows.

1. **Back up first.** In Supabase, make a database backup or export important tables before changing the schema.
2. Open the existing Supabase project (the one currently used by SIP-BH V1).
3. Open **SQL Editor → New query**.
4. Open `supabase/migration_v2.sql`, copy all SQL and run it once.
5. Review the SQL Editor result. If it reports an error, stop and share the complete error; do not repeatedly run partial fragments.
6. The migration adds V2 tables, policies, private Storage bucket and attempts to migrate V1 `assistance_records` into the new service model. V1 tables are not dropped.
7. The V1 Admin account and `profiles` table are retained. If the current Admin role is active, it should continue to work.

### Fresh Supabase project (only if starting from zero)

1. Run `supabase/v1_base_schema.sql` first. This creates the original V1 tables and starter PBH rows.
2. Then run `supabase/migration_v2.sql`.
3. Register an Admin email through the application, then promote it using the SQL below.

### Promote the first Admin

Replace the email with the account that should be Admin:

```sql
update public.profiles p
set role='admin', account_status='active', obh_id=null
from auth.users u
where p.id=u.id and u.email='admin@example.com';
```

Sign out and sign in again after promoting the account.


## Stage 2 — improved authentication and account management

This release adds friendly login error messages, keeps public registration exclusively for PBH, and adds an Admin Kanwil account-management screen. Admin account creation is handled by a Supabase Edge Function; the service-role key is never sent to the browser.

Before using **Manajemen Akun → Admin Kanwil → Tambah Admin**, deploy the function once. Follow `docs/STAGE-2-SETUP.md`. In short, from the project folder run:

```bash
supabase login
supabase link --project-ref YOUR_SUPABASE_PROJECT_REF
supabase functions deploy admin-user-management
```

The Edge Function uses Supabase's server-side `SUPABASE_SERVICE_ROLE_KEY` environment variable. Do not add this key to GitHub secrets or any `VITE_*` variable. Existing Admin and PBH accounts are retained.

Public PBH registration still requires an active PBH selection. If Supabase email confirmation is enabled, the PBH must confirm their email and then wait for Admin approval. Admin accounts are created internally by an active Admin and are confirmed during secure server-side provisioning.

## Run locally on Windows

Install Node.js LTS (Node 20 or newer): https://nodejs.org/

1. Extract the ZIP.
2. Open the `SIP-BH-V2` folder in VS Code.
3. Copy `.env.example` to `.env`.
4. Put the Supabase Project URL and publishable/anon key into `.env`:

```env
VITE_SUPABASE_URL=https://YOUR_PROJECT_ID.supabase.co
VITE_SUPABASE_ANON_KEY=YOUR_SUPABASE_PUBLISHABLE_OR_ANON_KEY
```

5. Open VS Code Terminal in the project folder and run:

```bash
npm install
npm run dev
```

6. Open the local URL printed by Vite, usually `http://localhost:5173`.

No PostgreSQL connection string or connection pooler is required. The browser application uses the Supabase HTTPS API through `@supabase/supabase-js`.

## Deploy to GitHub Pages

1. Create a GitHub repository, e.g. `SIP-BH`.
2. Upload/push all contents of this project to the repository's `main` branch.
3. Open **Settings → Secrets and variables → Actions** and add:
   - `VITE_SUPABASE_URL`
   - `VITE_SUPABASE_ANON_KEY`
4. Open **Settings → Pages** and set the source to **GitHub Actions**.
5. Push to `main` (or run the workflow manually under Actions).
6. Open the deployment URL shown by GitHub Pages.
7. In Supabase **Authentication → URL Configuration**, add the deployed GitHub Pages URL to the allowed redirect/site URLs.

The Supabase publishable/anon key is intended to be used by browser clients when Row Level Security is correctly configured. Never put a `service_role` or `sb_secret_` key in `.env`, GitHub Actions frontend variables, or source code.

## User roles and access model

- Admin Kanwil can view/manage all PBH data, beneficiaries, services, progress, evaluations and reports.
- PBH users can access records associated with their own `obh_id` only.
- Both Admin and PBH can create service records. The `entry_source` and `created_by` fields identify who entered them.
- Only Admin can verify/reject services, review periodic reports, and change accreditation status.
- New PBH accounts remain pending until approved by Admin.
- Storage bucket `sipbh-private` is private. Files are served through short-lived signed URLs.

## Data model overview

`obhs` → `beneficiaries` → `assistance_services` → `service_progress`

A PBH can have many beneficiaries. A beneficiary can have many assistance services. Each service can have many progress entries. Evaluations and reports are stored separately. See `docs/ARCHITECTURE.md`.

## Privacy and academic-use cautions

- NIK, date of birth, beneficiary identity and case-related information are sensitive. Use fictional data for the thesis demonstration unless the institution has authorized the use and processing of real data.
- The UI masks NIK in ordinary tables, but the current prototype stores it as a text field in PostgreSQL; it is **not application-layer encrypted**. Do not use real NIK data until encryption/key management and institutional privacy review are implemented.
- The sample evaluation criteria are proposed placeholders, not a validated official instrument. Align them with the supervisor's research methodology and applicable PBH rules.
- Litigation progress stages and non-litigation workflow labels are configurable starting points, not a statement of mandatory legal procedure.
- V1 legacy service categories that cannot be mapped exactly are marked `Belum Diklasifikasikan`; they are not silently assigned to a guessed category.
- The prototype is not an officially approved government information system. Before operational use, arrange security review, access review, retention rules, backups, and approval from the institution.

## Current limitations to be aware of

- CSV exports open in Excel; native `.xlsx` and PDF report generation are not included in this build.
- Evaluation scores are captured per service; the criteria should be validated before interpreting averages as official performance ratings.
- Audit events are stored for service, progress, report and PBH changes; a dedicated audit-log viewer is not included in the current UI.
- Password reset UI, MFA, bulk import, advanced document preview and formal e-signature are not included.
