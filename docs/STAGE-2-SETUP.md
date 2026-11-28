# SIP-BH Stage 2 — Account and authentication improvements

This update adds:

- Human-readable login and registration feedback.
- Separate public PBH registration and internal Admin provisioning.
- Admin Kanwil account list, creation, activation and deactivation.
- PBH approval remains a separate workflow.

## Important architecture and security note

The browser application must never create Admin users directly with the Supabase public/anon key. Admin creation uses the Supabase Edge Function `admin-user-management`, which verifies the caller's access token and checks that the caller has an active `admin` profile before using the server-side Supabase service-role key.

The service-role key is supplied to Supabase Edge Functions by the Supabase runtime. Do not place it in `.env`, GitHub Actions frontend secrets, `VITE_*` variables, or any source file.

## 1. Deploy the Edge Function

Install the Supabase CLI if it is not already installed: https://supabase.com/docs/guides/cli

Open a terminal in the project folder and run:

```bash
supabase login
supabase link --project-ref YOUR_SUPABASE_PROJECT_REF
supabase functions deploy admin-user-management
```

The project reference is the Project ID shown in Supabase project settings. The function uses the standard Supabase Edge Function environment variables `SUPABASE_URL`, `SUPABASE_ANON_KEY`, and `SUPABASE_SERVICE_ROLE_KEY`.

The included `supabase/config.toml` keeps JWT verification enabled for this function.

## 2. Frontend deployment

No new frontend environment variable is required. Keep the existing GitHub Actions repository secrets:

- `VITE_SUPABASE_URL`
- `VITE_SUPABASE_ANON_KEY`

Commit and push the updated project to the repository's `main` branch. GitHub Actions should rebuild and publish the site.

## 3. Account workflows

### Admin Kanwil

- There is no public Admin registration tab.
- An already-active Admin opens **Manajemen Akun → Admin Kanwil → Tambah Admin**.
- The Admin enters the new person's name, email and initial password (minimum 10 characters).
- The Edge Function creates the Supabase Auth user with `email_confirm: true`, then creates/updates the matching `public.profiles` row with `role='admin'`, `account_status='active'`, and `obh_id=NULL`.
- The initial password must be unique and handed to the new Admin privately. Do not share it in a group or public message. A password-change screen is not part of this update, so do not describe forced password rotation as an implemented feature.
- An Admin cannot deactivate their own account. The last active Admin cannot be deactivated.

### PBH

- Public registration remains only for PBH.
- The user must provide a name, email, password and choose an active PBH.
- If Supabase email confirmation is enabled, the user must click the email confirmation link before sign-in succeeds.
- The profile remains `pending` until an Admin approves it under **Manajemen Akun → Persetujuan Akun PBH**.
- Email confirmation and Admin approval are separate checks. The user gets access only after email confirmation (when enabled) and account approval.

## 4. Supabase Auth settings

In Supabase → Authentication → URL Configuration:

- Set the Site URL to the deployed GitHub Pages URL.
- Add the GitHub Pages URL to Redirect URLs, including the project path used by the app.

Keep email confirmation enabled if the intended policy is that PBH must verify their email. Admins created by the Edge Function are internally confirmed and do not need the PBH email-verification flow.

## 5. Test checklist

1. Existing Admin can log in.
2. Wrong password shows a clear message on the login page.
3. Unconfirmed PBH email shows an email-confirmation message.
4. PBH registration shows a success message explaining email confirmation and Admin approval.
5. A PBH account remains blocked until approved.
6. An Admin can list existing Admin accounts.
7. An Admin can create a new Admin account; the new account appears in `auth.users` and `public.profiles` with matching UUIDs.
8. The new Admin can log in without a confirmation email.
9. An Admin cannot deactivate their own account or the last active Admin.
10. A non-Admin cannot invoke Admin account management successfully.

## Notes

- Deactivation sets `public.profiles.account_status='rejected'`. The user may still authenticate with Supabase, but the application blocks access and RLS helper functions do not grant active Admin permissions. This is application-level deactivation, not deletion of the Auth identity.
- Existing Admin users (including accounts previously promoted through SQL) are retained. This update does not recreate or delete them.
- The initial password is set by the creating Admin. Share it privately and arrange a password change after first sign-in. For a production deployment, adding a forced password-change flow or secure invite/password-reset flow is recommended.
